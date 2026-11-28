# memwatch, memguard, cmem: Claude dev containers and memory

Load this file when: a session was told about a memory warning or an OOM kill, memguard killed something,
you want to know how much of the containers' memory cap is in use or how much disk each container takes,
or you're changing any of these.

The dev containers (started by `launch-container`, `host-scripts/launch-container.sh`) share one memory
limit, the user-level `claude-containers.slice` (see the launcher's header for its numbers). These tools
watch that slice. Files: `memwatch-events.sh` (producer, user service `memwatch`, unit `memwatch.service`
here), `memlib.sh` (the shared "memory in use" measure), `memguard.py` (the kill), `cmem.sh` (on PATH as
`cmem`), `cdisk-scan.sh` (per-container disk sizes for `cmem`, user timer `cdisk-scan.timer`), and the consumer hook `hooks/memwatch-hook.sh` (installed by `hooks/install.sh`).

Install: `cp memwatch/memwatch.service ~/.config/systemd/user/ && systemctl --user daemon-reload &&
systemctl --user enable --now memwatch`; for cmem's disk figures `cp memwatch/cdisk-scan.{service,timer}
~/.config/systemd/user/ && systemctl --user daemon-reload && systemctl --user enable --now cdisk-scan.timer`; then wire `memwatch-hook.sh` as in `hooks/settings.example.json`.

## `cmem`: how much of the container cap is in use (2026-10-01)

`cmem` (`memwatch/cmem.sh`, on PATH as `cmem`) splits the cap into
in use (memlib.sh's measure, same as memwatch; also per container with its Claude sessions; a `claude` process with a terminal counts as a session, one without, e.g. `claude -p` launched by a script, as "headless") + caches (file cache and dentry/inode cache, freed
on demand) + unused = cap, and prints AVAILABLE = unused + caches (and how much is left before
the memwatch warning), plus the laptop's `MemAvailable` (free + droppable file cache; excludes tmpfs/shmem). The figures are rounded so the column adds up. Use it before starting another container session. `cmem --watch` (or `-w`) refreshes every 10 s, `cmem --watch 3` every 3 s; the terminal title reads `cmem` while it runs and is restored on Ctrl-C (xterm title stack, which gnome-terminal supports).
htop can't show this split: it only shows the whole laptop. If the laptop has less available than
the containers have left, the laptop's RAM is the real limit, and `cmem` says so.

## `cmem` Disk section and `cdisk-scan` (2026-11-25)

`cmem` also prints the disk: live `df` (used, free, % free), each container's writable layer (what it wrote
outside its bind mounts: `/tmp`, `~/.cache`, build caches) with its change over ~1 h and ~1 day, "images +
unused old layers", and "everything else" (host files, the repos containers mount, system). Under 10% free
it prints a NOTE. Per-container sizes come from `cdisk-scan.sh`'s cache, `~/.cache/cmem/disk-history.tsv`
(`<epoch> TAB <name> TAB <MB>`, 8 days kept; `_images`, `_used`), because a live `du` of a 200 GB layer
takes 2-4 min. The figures for a container you just stopped linger until the next scan.

The scan must never be what slows the laptop (its freezes are disk stalls). So: hourly; idle I/O class +
nice 19 + `IOWeight=10`/`CPUWeight=10` like `claude.slice` (idle class only works because the NVMe scheduler
is bfq, set by this-laptop's `fix-memory-priority.sh`; under `none` it does nothing); skips when PSI io
"full" avg60 >= 5%; SIGSTOPs its own `du` while io full avg10 >= 5% and resumes below 2.5%; gives up after
30 min keeping the last figures. Tunables: `CDISK_SKIP_FULL`, `CDISK_PAUSE_FULL`, `CDISK_MAX_SECS`,
`CDISK_HISTORY`, `CDISK_STORAGE`. Don't match `du` by command line to pause or kill it: two scans (timer +
manual) run the same line, and the 2026-11-25 test killed the timer's scan that way; `dupids()` walks this
scan's own process tree.

- **Check it:** `systemctl --user list-timers cdisk-scan.timer`, `journalctl --user -u cdisk-scan` (one line
  per run: sizes, or "skipped"/"gave up"), `cmem | tail -12`.
- **Test without touching the live cache:** `CDISK_HISTORY=<scratch>/t.tsv CDISK_SKIP_FULL=0 ./cdisk-scan.sh`
  (must say skipped); `... CDISK_SKIP_FULL=100 CDISK_PAUSE_FULL=0 CDISK_MAX_SECS=12 ./cdisk-scan.sh` with a decoy
  `podman unshare du -x --block-size=1M -d 1 overlay` running: its own `du` shows state `T`, gives up at 12 s,
  and the decoy must survive. `CDISK_HISTORY=<scratch>/none.tsv cmem` shows the "no figures yet" hint.

## memwatch: sessions are told about warnings and OOM kills (2026-09-29)

Every Claude session (in the containers and on the laptop, main threads and subagents) is told
when the containers get within 1 GB of their cap, and when the kernel OOM-kills something in them. A
session whose job died with "Killed" / exit 137 then knows why, and doesn't just re-run it.

- **Producer:** `memwatch/memwatch-events.sh`, enabled user service `memwatch`. Every 10 s it reads
  the slice's **memory in use** and the `oom_kill` count in `memory.events`. In use is `inuse()` in
  `memwatch/memlib.sh` (shared with `cmem`): `memory.current − inactive_file − active_file −
  slab_reclaimable + file_mapped`, i.e. process and kernel memory plus mapped program code, without the
  file and dentry/inode caches the kernel frees before killing anything. Warnings, re-arming, per-container
  figures and memguard's near-cap gate all use it; the warning also gives the caches. Don't go back to
  subtracting only `inactive_file` (the 2026-09-30 "working set"): on 2026-11-19 a container that had
  stat'ed ~1.7 M files carried 5.4 GB of `slab_reclaimable` plus 2 GB of `active_file` against 1.7 GB of
  anon, the warning fired for hours, and memguard's gate stood open (20:02: "working set" 9.5 GB, 11% stalled).
  Raw `memory.current` is worse still (~50 warnings with no kill, 2026-09-29/30). Keep `file_mapped` counted:
  evicting mapped code is the 2026-10-02 thrash. Keep the awk `printf "%.0f"`: mawk's `%d` caps at 2 GB. It writes events to
  `~/.claude/memwatch/events/<seq>.txt` and `~/.claude/memwatch/latest`; `~/.claude` is mounted in
  every container. A kill message names the process, its container and its size, taken from `journalctl -k`
  (Eli is in `adm`). The warning is re-armed once usage falls 512 MB below the warning level.
- **Consumer:** `~/.claude/hooks/memwatch-hook.sh`, wired in `~/.claude/settings.json`. Its source is `hooks/memwatch-hook.sh`;
  after editing it, run `hooks/install.sh`.
  - PostToolUse / PostToolUseFailure / UserPromptSubmit → `deliver`: unseen events as
    `additionalContext`, once per session and once per subagent (`agent_id`).
  - Stop → `wait` (`asyncRewake`, timeout 24 h): if the turn ended with `background_tasks` or
    `session_crons`, it waits and exits 2 on a new event, which **wakes the idle session**. With nothing
    in flight it exits at once, so a session that's simply done is not woken; it sees the event with
    Eli's next prompt. The next Stop replaces the waiter.
  - Events are delivered for 60 min. A session or subagent seen for the first time gets only the last 10 min.
- **Gap:** work Claude launched outside its own task tracking (`nohup … &`) doesn't count as
  "something running", so that session isn't woken.
- **Messaging one session that `SendMessage` can't reach** (e.g. a container made before the shared socket
  folder): write a targeted event by hand. `events/<seq>.mine.txt` = the message, `events/<seq>.to` =
  `sid:<session id>` and/or `pid:<readlink /proc/<pid>/ns/pid>:<claude pid as the container sees it>`
  (`podman exec <c> pgrep -x claude`), `events/<seq>.txt` **empty** (an empty text reaches no one else;
  the hook skips it since 2026-11-28), then `latest` = `<seq> <epoch>`, each via a temp file + `mv`. Start the
  message by saying it isn't a memory event: the hook's header calls it one. Delivered when
  `seen/<session id>` reaches `<seq>`.
- **Why not the session inbox socket** (cross-session messaging, which would also wake idle
  sessions): its message format isn't documented, and reading it out of the binary was blocked
  (it touches the session token). `asyncRewake` is documented and does the same job.
- **Tested 2026-09-29, on the laptop:** a real OOM kill in a throwaway 300 MB cgroup
  (`MEMWATCH_SLICE=… MEMWATCH_LABEL=TEST`) gave the warning and then the kill event. Live delivery
  worked after a tool call in the main thread and in a subagent, and an idle session with a background
  job was woken ~5 s after the event. It shows in the transcript as "Stop hook blocking error" (only a
  label).
- **End-to-end in a container, 2026-09-29:** a throwaway container from the real `launch-container.sh`
  (`CONTAINER_PREFIX=mwtest CONTAINER_MEMORY=3g CONTAINER_SLICE=claude-memtest.slice
  CONTAINER_SLICE_HIGH=2G CONTAINER_SLICE_MAX=2G … --no-shell --no-ports --no-pull --no-apt --no-setup`,
  then `systemctl --user set-property --runtime claude-memtest.slice MemorySwapMax=0`). A second
  producer ran on that slice with `MEMWATCH_DIR=~/.claude/memwatch-test`, and the test session got the same
  `MEMWATCH_DIR`, so real sessions never saw the test events. The session ran a script growing to
  1.3 GB and then past 2 GB as a background task. It was **woken by the warning** while idle. When the
  kernel killed `python3` (1.8 GB, not Claude), Claude Code's own "exit code 137" notice woke it, and
  the kill notice arrived on its next tool call. Claude can't start the test session itself: the
  auto-mode classifier blocks launching `claude` ("Create Unsafe Agents"), even in auto mode, so Eli
  starts it (`podman exec -it -e MEMWATCH_DIR=… -w /memtest mwtest-memtest claude --permission-mode auto`).
  Don't `pkill -f memwatch-events` from a shell whose own command line contains that text: it kills
  the shell, and it stops the real service too.
- **Check it:** `systemctl --user status memwatch`, `ls ~/.claude/memwatch/events`, and
  `pgrep -af "memwatch-hook.sh wait"`, which lists the waiters of sessions paused on background work.
- **Turn off:** remove the `memwatch-hook.sh` entries from `~/.claude/settings.json` (a backup from
  before they were added is not kept in the repo), then `systemctl --user disable --now memwatch`.

## memguard: kill the biggest process when the containers thrash (2026-10-02)

Part of the `memwatch` service (no separate unit). Every 2 s `memwatch-events.sh` reads the slice's
`memory.pressure` and works out the share of time in which *every* task in the slice was stalled on memory.
At ≥ **10%** for **3 samples in a row** (~6 s), **and only if memory in use (memlib.sh) is within 1 GB of the cap**,
it runs `memwatch/memguard.py`. Every stalled sample logs in use, the raw figure, anon, `active_file`,
`slab_reclaimable`, the cap, and laptop RAM available. Don't drop the near-cap check. A disk/swap storm stalls the slice on memory too: on 2026-10-03 at
14:49 a Claude Code update put disk I/O stall at 25%, and the slice was 12–16% stalled at 6.3 of 10 GB.
memguard killed an innocent 0.3 GB process, which did nothing for the storm. It now logs `memguard: NOT
killing: …` instead. Reclaiming a huge dentry cache at the cap stalls the slice too (2026-11-19: 29–36% at
2/3 samples with ~2.6 GB in use), which the same gate now covers. memguard.py:

1. Picks the process in the slice with the most anonymous memory. Never Claude Code, conmon, tini, tmux etc.
   Claude Code started by its versioned path has `comm` = its version (`2.1.321`); `is_claude()` matches that
   and `/claude/versions/` in the exe link (before 2026-11-19 the dry run picked a resumed session as victim).
2. Traces it to the Claude session(s) that started it. Every command a session runs inherits
   `CLAUDE_CODE_SESSION_ID` and `CLAUDE_PID`, even after `nohup`. memguard reads them from `/proc/<pid>/environ` of the process and its
   ancestors inside the same container, plus any `claude` ancestor. Nested `claude -p` inside a session's
   script: both are traced.
3. Kills it (SIGKILL). If the same session already had a memguard kill **1–15 min earlier** (its work
   refilled the cap: a kill-and-relaunch loop), it kills the victim's **whole command** instead. That is its
   Unix session, i.e. one Bash tool call, including any `make`/pool/loop that would relaunch it. If
   that group would include a `claude`, it tries the process group, else only the victim. Kills within 60 s of
   each other count as one episode (several workers may need killing), so they don't escalate.
4. Writes a memwatch event with two texts. The responsible session gets "MEMGUARD KILLED ONE OF YOUR
   PROCESSES … do NOT re-run it as it was, cut parallelism at least in half, next time the whole command
   goes" (or "…YOUR WHOLE COMMAND … tell the user"). Every other session gets "memguard killed X in the Y
   container, which belongs to another session; nothing of yours was killed; hold off on memory-heavy work".
   Files: `events/<seq>.txt` (general), `<seq>.mine.txt` + `<seq>.to` (match keys `sid:<id>` and
   `pid:<pid namespace>:<claude pid>`). The hook matches either key, so a session still gets its message
   after `/clear` changes its id. Kill history for the escalation: `~/.claude/memwatch/memguard-history.json`.

The kernel's own OOM kills (at the cap, without thrashing) are still reported by memwatch to everyone, but
can't be targeted: the process is gone before memwatch can read its environment.

- **Tuning:** `MEMGUARD_FULL_PCT` (10), `MEMGUARD_SAMPLES` (3), `MEMGUARD_INTERVAL` (2 s), `MEMGUARD_NEAR_CAP_MB` (1024),
  `MEMGUARD_EPISODE_GAP` (60 s), `MEMGUARD_REPEAT_WINDOW` (900 s), `MEMGUARD_DRY_RUN=1` (log only); set with
  `Environment=` in a drop-in for `memwatch.service`. The journal logs every 2 s sample at ≥ 2% stalled, to tune
  against. For scale: in the 2026-10-02 freeze the whole *system* was fully stalled on memory 20–60% of the
  time (the slice is at least that). Normal cap hits stay ≤ 1–2% system-wide. A small throwaway cgroup
  thrashing a file only reached 7–13%.
- **Test the near-cap gate** with a fake slice dir (files `memory.max`, `memory.current`, `memory.stat`,
  `memory.events`, and `memory.pressure` whose `full … total=` climbs 60000 every 0.25 s), run with
  `MEMWATCH_SLICE=<dir> MEMWATCH_DIR=<scratch> MEMGUARD_INTERVAL=1 MEMGUARD_DRY_RUN=1 timeout 8 ./memwatch-events.sh`.
  At `memory.current` 10.3 GB: with `memory.stat` mostly `active_file`/`slab_reclaimable` (anon 2 GB) you should see
  no warning and `memguard: NOT killing`; with anon 9.7 GB, or a `memory.stat` holding only `anon`/`inactive_file`,
  or none at all, the warning fires and memguard.py runs.
- **Real-kernel check of the measure:** in `systemd-run --user --scope -p MemoryMax=1200M -p MemorySwapMax=0`,
  touch + stat 200k files and read a 400 MB file twice: `inuse` stays ~1 MB while `memory.current` is ~730 MB;
  then hold a 500 MB `bytearray`: `inuse` ~508 MB (2026-11-19).
- **Dry run against the real slice** (shows what it would kill and whom it would tell; touches nothing):
  `python3 memwatch/memguard.py --slice /sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/claude.slice/claude-containers.slice --dir /tmp/mg --stall 0 --dry-run`
- **Tested 2026-10-02** in a 300 MB scope (`systemd-run --user --scope -p MemoryMax=300M -p MemorySwapMax=0`) with
  a 150 MB decoy named `claude` and a loop relaunching a 100 MB-anon + 150 MB-file scanner, producer run with
  `MEMWATCH_SLICE=<scope> MEMWATCH_DIR=<scratch> MEMWATCH_LABEL=TEST MEMGUARD_FULL_PCT=4 MEMGUARD_EPISODE_GAP=5`.
  First episode: killed the scanner only. After the relaunch: killed the whole command (loop + scanner), so
  nothing relaunched. The decoy was never touched. The hook gave this session the targeted texts (also under a
  different session id, by claude pid) and a session outside it the general text. The keys computed on the host for a
  diagram-container process matched the keys computed inside the container.

