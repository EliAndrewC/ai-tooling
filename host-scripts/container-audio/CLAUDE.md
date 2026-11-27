# container-audio: microphone for container sessions without the raw-device overrun (NOT BUILT YET)

Load this file when: building or changing how containers record voice, or weighing another way to.

**Status 2026-11-26:** design proven in a throwaway container; not wired into `launch-container`.

## Why

Containers record from the raw ALSA device (`plughw:0,4`, launcher-generated `/etc/asound.conf`) with
Claude Code's 100 ms buffer. A recording thread held up longer leaves it in XRUN, and cpal 0.15.3 then
reports POLLERR in a tight loop (`Audio capture error ... POLLERR` over the screen), which dropped tabs
twice on 2026-11-26. Reproduce: `../test-capture-stall.py plughw:0,3 0.3` (600,000+ POLLERR a second).

## Design (one-way: audio into the container, nothing back)

- **Host:** a user service records the mic with PulseAudio and writes raw s16le 48 kHz stereo,
  NONBLOCKING, into a host-owned FIFO (pipe size 1 MB, about 5 s) in a folder mounted READ-ONLY into
  the container. A full pipe drops audio rather than queueing it: a mic never waits.
- **Container:** its own PulseAudio (packages `pulseaudio libasound2-plugins`) with `module-pipe-source`
  on a container-local FIFO, a looping blocking copy `cat /hostaudio/mic.fifo > /tmp/ha/mic.fifo`, and
  `/etc/asound.conf` = `pcm.!default { type pulse }`. Module loading there touches only the container.

## Don't (each measured or reasoned 2026-11-26)

- **Don't give containers the host's PulseAudio socket:** any client can load modules into the host
  daemon (`module-ladspa-sink` loads a library by path; the container can write files at host paths
  through its rw mounts): host code execution as Eli.
- **Don't let the container create the FIFO the host writes into** (PulseAudio 17's pipe source insists
  on `mkfifo`): a container-made path can be swapped for a symlink, and the host would write into any
  file. Hence the host-owned read-only FIFO and the relay.
- **Don't use a clocked device in the container** (`module-null-sink` + `pacat`): freezing the player
  2 s replaced 1.5 s of audio with silence and left a permanent 2 s delay.
- **Don't use ALSA's `file` plugin** as the container end: not clocked (read 116,000 frames/s of a
  48,000/s source, padding with silence).
- **Don't use `dsnoop` for a bigger buffer:** the buffer stays ~107 ms and the stream still ends in XRUN.
- **Don't stop writing when idle:** with the pipe open and no data, a reader blocked (likely in start); with the pipe
  closed the relay exits. Write silence at real time instead, and real audio only while recording.

## Measured (proof/ scripts; feeder = real-time counting pattern, latency = behind real time)

| Case | Delay after | Lost |
|---|---|---|
| steady | 1-25 ms | none |
| reader stalled 0.3 / 2 / 6 s (the POLLERR trigger) | ~10 ms, backlog delivered | none, 0 POLLERR |
| container relay or PulseAudio frozen 2 s / 4 s, 1 MB host pipe | back to ~10 ms within 0.5 s | none |
| same, 64 KB default pipe | back to ~10 ms | the frozen interval |
| record after 10 s idle | one stale chunk, then ~15 ms | none |

Mic start from suspended: first audio after 150 ms (7-9 ms when already awake). Not measured: end-to-end
latency with a real mic and Claude Code's own transcription.

## Open decisions (Eli)

1. Host mic open all the time (GNOME's mic indicator always on) or only while space is held, via
   `~/.claude/voice-corrections/spacebar` (silence otherwise; 150 ms cold start, likely inside Claude
   Code's own hold detection: unverified).
2. FIFO folder: a new read-only mount (`--fresh` per container) or a gitignored folder inside the
   already-mounted read-only `/host-scripts` (no recreate; every container can see every pipe).
