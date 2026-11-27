# container-audio: the microphone for container sessions, through a one-way pipe from the host

Load this file when: voice in a container session floods `Audio capture error ... POLLERR`, records
nothing, or you're changing how containers record voice (or weighing another way to).

## Why

Containers used to record from the raw ALSA device (`plughw:0,4`) with Claude Code's 100 ms buffer. A
recording thread held up longer (routine in a busy container at CPUWeight 20) left it in XRUN, and
Claude Code's capture library (cpal 0.15.3) then reported POLLERR in a tight loop. The lines were
printed over the screen, and the flood dropped the tab (twice on 2026-11-26).
Reproduce: `../test-capture-stall.py plughw:0,3 0.3` (600,000+ POLLERR a second).

## How it works (since 2026-11-26)

- **Host:** `container-audio-feeder.py`, user service `container-audio`. It writes a real-time stream
  (s16le, 48 kHz, stereo) into `pipes/<container>.fifo` here, one per container, made by
  launch-container with mode 600. The folder is gitignored and mounted read-only in the container at
  `/host-scripts/container-audio/pipes/`.
  - The stream is silence until space has been held 150 ms (`~/.claude/voice-corrections/spacebar`,
    from spacebar-watch). Then it carries the host's default PulseAudio source (a headset too, if it
    is the default) until 1.5 s after release. The mic, and GNOME's mic indicator, are on only while
    dictating.
  - Writes are nonblocking and atomic, into a 1 MB pipe (about 5 s). A container that stops reading
    loses audio rather than queueing it, and nothing is ever read back from a container.
- **Container:** `container-side.sh`, run as root by launch-container on every start, attach and new
  tab (idempotent). It runs three things as `agent`, all in `/tmp/container-audio`:
  - its own PulseAudio, whose `module-pipe-source` "hostmic" reads a container-local pipe;
  - the relay: a looping blocking `cat` from the host pipe into that local pipe;
  - the drain: an always-on `parec` to `/dev/null`.

  It then rewrites `/etc/asound.conf` so that capture goes to `hostmic` (through the ALSA pulse plugin)
  and playback stays on the raw device. The previous config is kept as `/etc/asound.conf.raw`.
- **Fallback:** if anything is missing, `container-side.sh` puts `/etc/asound.conf.raw` back, so the
  container records the old way. That covers no host pipe, no packages, no space-bar state, and no
  audio arriving within 3 s. The launcher prints a `>> container-audio:` line saying why.
- **Packages** (`pulseaudio pulseaudio-utils libasound2-plugins`): in the launcher's apt list for fresh
  containers; an older container gets them once on its next launch or attach.

## Install, check, fix

- **Host:** `install.sh` installs and starts the service (no sudo). `install.sh --check` reports the
  unit, the service, the space-bar state and the pipes.
- **A container picks it up** on its next `launch-container` from its project folder (`--no-shell` is
  enough). Sessions already running switch at their next dictation, with no restart: ALSA re-reads
  `/etc/asound.conf` each time a recording opens (confirmed 2026-11-26 with a days-old session).
- **Voice silent in a container:** `install.sh --check`, then `test-container-audio.sh` from that
  project folder. `journalctl --user -u container-audio` shows `mic on` / `mic off` per dictation.
- **Back to the raw device by hand:**
  `podman exec --user root claude-NAME cp /etc/asound.conf.raw /etc/asound.conf`. The next launch
  switches it back to the pipe, unless the host service is stopped.

## Test

- `test-container-audio.sh [container]`, from the project folder of a running container (about 30 s,
  never opens the mic). It checks the host service, the pipe, the wiring, no POLLERR after a 2 s
  reader stall, that a recording starts live, and silence while space is up.
- **Real mic, by hand:** hold space in a container session and dictate. Expect no `Audio capture
  error` lines, `mic on` then `mic off` in the journal, and GNOME's mic indicator only while you hold
  space.
- **Real mic without the space bar:**
  1. `systemctl --user stop container-audio`
  2. Run `CONTAINER_AUDIO_FORCE_MIC=1 python3 -I container-audio-feeder.py` for 20 s.
  3. Meanwhile, in the container, run
     `arecord -D default -f S16_LE -c1 -r16000 -d 3 -t raw /tmp/r.raw`: it should be non-zero at
     the host mic's level (RMS ~50 in a quiet room, 2026-11-26).
  4. `systemctl --user start container-audio`

## Don't (each measured or reasoned 2026-11-26)

- **Don't give containers the host's PulseAudio socket.** Any client can load modules into the host
  daemon (`module-ladspa-sink` loads a library by path), and the container can write files at host
  paths through its read-write mounts. That is host code execution as Eli.
- **Don't let the container create the pipe the host writes into.** PulseAudio 17's pipe source
  insists on `mkfifo`, but a path the container made can be swapped for a symlink, and the host would
  then write into any file. That is why the host owns a read-only pipe and a relay copies from it.
- **Don't drop the drain.** The pipe source stops reading while no one records. The pipes then filled
  with seconds of old audio, and every recording began with it: a 3 s recording returned in 0.03 s,
  twice in a row, so back-to-back dictations would have started with the end of the previous one.
- **Don't use a clocked device in the container** (`module-null-sink` + `pacat`). Freezing the player
  for 2 s replaced 1.5 s of audio with silence and left a permanent 2 s delay.
- **Don't use ALSA's `file` plugin** as the container end. It isn't clocked: it read 116,000
  frames/s from a 48,000/s source, padding with silence.
- **Don't use `dsnoop` for a bigger buffer.** The buffer stays about 107 ms and the stream still
  ends in XRUN.
- **Don't stop writing when idle.** With the pipe open and no data arriving, a reader blocked; with
  the pipe closed, the relay exits. The feeder writes silence in real time instead.
- **Don't set `Nice=-5` on the unit.** A user service may not raise its own priority, so it would fail
  to start.

## Measured (`proof/`: a real-time counting pattern; delay = how far behind real time)

| Case | Delay after | Lost |
|---|---|---|
| steady | 1-25 ms | none |
| reader stalled 0.3 / 2 / 6 s (the POLLERR trigger) | ~10 ms, backlog delivered | none, 0 POLLERR |
| container relay or PulseAudio frozen 2 s / 4 s, 1 MB host pipe | back to ~10 ms within 0.5 s | none |
| same, 64 KB default pipe | back to ~10 ms | the frozen interval |

The mic's first audio arrives 150 ms after starting from suspended (7-9 ms when already awake).
Claude Code starts recording only after the key repeat begins (500 ms), so the 150 ms hold threshold
plus the cold start fit inside that. Confirmed with a real dictation 2026-11-26: `mic on`/`mic off` in the
journal, the transcription worked, and the raw device stayed closed.
