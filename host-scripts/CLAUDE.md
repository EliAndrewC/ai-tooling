# host-scripts: the scripts every dev container can see

This folder is mounted **read-only at `/host-scripts`** in every container that `launch-container`
starts. It holds what a container session may want to read about its own environment:

| File | What it is |
|---|---|
| `launch-container.sh` | Starts or attaches to a repo's dev container (on the host's PATH as `launch-container`). The repo is mounted, and the shell starts, at `/<repo folder name>` (`~/budget` -> `/budget`); don't re-add a shared default like `/workspace`, because Claude memory is keyed by that path and every such project would share one (until 2026-10-03 one project's sessions loaded another's memory). Its header documents every mount, the memory caps and the flags. A tab whose connection drops reattaches to its tmux session by itself (`attach_loop`). |
| `claude-diagnostics/` | Read-only host diagnostics. In a container: `/host-scripts/claude-diagnostics/client/host-diag <command>`. The host side (sudo) is `grant-claude-diagnostics.sh`; see its header. |
| `clipboard-bridge.py` (+ `.service`), `clipboard-to-host` | Copies inside a container's tmux (Claude Code's drag-select, tmux copy mode) reach the host's desktop clipboard. GNOME Terminal ignores OSC 52, so the container drops each copy in `/clipboard-bridge/<name>` (host `~/.local/share/container-clipboard`) and the host user service `clipboard-bridge` puts it on the clipboard via GTK/X11. The other way, for Claude Code's right-click paste: the service mirrors the host clipboard into `.host-clipboard` there, and `container-bin/wl-paste` (linked into the container's `/usr/local/bin` on every launch) prints it. A container made before the `/clipboard-bridge` mount gets that path as a symlink into its `~/.claude` mount (`~/.claude/container-clipboard`, also watched), so no `--fresh` is needed. Its docstring has the details; tests: `test-clipboard-bridge.sh`. Installed: `cp clipboard-bridge.service ~/.config/systemd/user/ && systemctl --user enable --now clipboard-bridge`. |
| `voice-corrections/` | The Claude Code mod that fixes Eli's known dictation mis-hearings and autosaves unsent prompts to `~/.claude/prompt-drafts/`, loaded in containers from here (`CLAUDE_CODE_PLUGIN_DIRS` in launch-container's `~/.bashrc` block). A container adds a rule with `/host-scripts/voice-corrections/voice-corrections add FROM TO` (the rules live in the shared `~/.claude`). See its `CLAUDE.md`. |
| `propose`, `host-script-proposals` | The proposals queue (below). |
| `test-proposals.sh` | Tests for the queue tools. Run it after changing either. |
| `test-launch-container-drop.sh` | The REAL test of that reattach: from the project folder of a running container it floods a throwaway tmux session until podman drops the connection, and checks the launcher reattaches and a detach still ends it (about a minute; touches only its own `droptest` session). Run it after changing `attach_loop`. |
| `test-capture-stall.py` | Reproduces the voice-input error flood on an ALSA capture device (`Audio capture error ... POLLERR`, which dropped container tabs on 2026-11-26): a reader that stalls longer than the 100 ms buffer. Its docstring has the measurements; run it before and after changing how containers record. |
| `test-launch-container.sh` | Tests the launcher's mounts (host-scripts, `.volume-overrides/`) and its tmux attach paths (reattach after a dropped connection, bare `--attach`) against a fake podman. Run it after changing the mounts or the shell paths, then do one real launch: the fake can't catch everything (2026-11-26: a real plain launch failed where the fake passed, on a terminal reporting size `0 0`). |

## Why read-only, and how to change a host script anyway

These scripts run on the host as Eli, and the diagnostics files are installed with sudo. A container
that could edit them could act as Eli. So a container session **proposes** a change instead:

```
/host-scripts/propose launch-container.sh     # copies it to /proposed-host-script-updates/<session>/
```

Edit the copy it prints, write the reason in the `.why.md` beside it, leave the `.base` alone, and
tell Eli it is queued. The queue is `~/.local/share/host-script-proposals/` on the host.

## Reviewing the queue (host session)

A SessionStart hook (`host-script-proposals --summary`, wired in a host project's `.claude/settings.json`)
prints a one-line notice when proposals are pending. Then:

1. `host-script-proposals` lists them; `host-script-proposals diff <id>` shows the reason, the change,
   and anything that landed on the host since.
2. Review it as **untrusted code**. It came from a container, and the point of the queue is that
   nothing runs on the host unreviewed. Reject anything that widens what containers can do on the
   host without Eli asking for exactly that: new mounts of host paths, `--privileged`, extra
   capabilities or devices, sudoers changes, or a path that reaches outside the container.
3. Accept: `host-script-proposals merge <id>` (three-way: keeps changes landed meanwhile; refuses
   on conflict and prints the `git merge-file` command), review `git diff`, run `test-proposals.sh`
   if the queue tools changed and `bash -n` on shell scripts, then commit and push (this repo).
4. Either way, `host-script-proposals drop <id>`, and tell Eli what was accepted or rejected and why.

A change to `claude-diagnostics/files/` or `libexec/` only takes effect when Eli re-runs
`sudo ~/ai-tooling/host-scripts/claude-diagnostics/grant-claude-diagnostics.sh`; say so.
A change to the mounts only reaches a container after `launch-container --fresh`.
Moving or deleting a folder that an existing container mounts breaks its next start (after a stop or
reboot), not the running container. The launcher checks this before `podman start` and prints the `ln -s`
fix; a symlink at the old path is enough, no recreate needed.

## Session messaging between host and containers

Since 2026-11-26 a container on the host's Claude account shares two things with the host and with every
other such container, so `ListAgents` / `SendMessage` work host <-> container and container <-> container:

- the session registry `~/.claude/sessions/` (records `<pid>.json`, pid as that container sees it, plus the
  per-session `.key` files), which is simply inside the `~/.claude` mount;
- the host's socket folder `$XDG_RUNTIME_DIR/cc-socks`, mounted at the **same path**, with `XDG_RUNTIME_DIR`
  set in the container so its sessions create their sockets there. A record stores the socket's absolute
  path, so it has to resolve on every side. No networking, capability or shared pid namespace is involved.

**Pid offset, and why not to drop it:** Claude Code names records by bare pid and deletes its own on exit,
and every container counts pids from 1. On 2026-11-25 two containers restarted together both ran their first
session as pid 31; one's exit deleted the other's record (tab showed the folder name, `/rename` said "the
session list couldn't be updated"). So after every create, start and attach the launcher forks the
container's pid counter up to `slot * 5000` (`peer_after_start`; slots in `~/.claude/container-pid-slots`,
one per existing container). Don't share the registry without it. A chance collision between two
long-lived sessions stays possible and very unlikely; the fix is the one above (rewrite the record).

**Not shared:** a `.volume-overrides/` project (another person's account), `CONTAINER_PEERS=0`, or a host
without `XDG_RUNTIME_DIR`: that container gets its own registry (`~/.claude/container-sessions/<container>/`)
and no socket folder. A container made before 2026-11-26 has no socket folder either; attaching prints a
note and `--fresh` applies it.

**Confirm it works:** in a container session, `ListAgents` lists the host's sessions. From the host:
`ls $XDG_RUNTIME_DIR/cc-socks` shows one `<pid>.sock` per live session, and `podman exec <c> sh -c 'stat -c %i
$XDG_RUNTIME_DIR/cc-socks'` prints the same inode as on the host. A different inode means the host folder
was recreated (reboot, logout) while the container ran: restart the container through the launcher.

**What it opens up:** any container session can put a message in front of the host's sessions and read the
registry's key files. Messages arrive marked as coming from another session and can't approve anything.
Sessions in different permission modes may hold each other's messages for the user's approval.

**Tested 2026-11-26 (Claude Code 2.1.332):** host <-> container and container <-> container round trips,
launcher-made containers, including stop and start of two together. Not tested: a session started with
`--dangerously-skip-permissions`, waking an idle interactive session, a real reboot.

## Per-project Claude account: `.volume-overrides/`

A project folder with a `.volume-overrides/` folder runs its container as its own Claude account
(e.g. a project that always runs as another family member's account; since 2026-10-03). The folder mirrors the container's home, and
exactly two files are allowlisted: `.claude.json` (profile; replaces the host's mount) and
`.claude/.credentials.json` (the token, which decides billing; shadows the file inside the shared
`~/.claude`). Everything else in `~/.claude` (CLAUDE.md, hooks, memory) stays shared. The launcher
creates missing files (`{}` credentials, i.e. logged out; `.claude.json` copied from the host's minus
`oauthAccount`), sets modes 700/600, refuses symlinks, warns about other files and about a folder
that isn't gitignored, and prints `>> volume-overrides: ... (from <project>)` on every launch.

- **Set it up:** `mkdir -m 700 <project>/.volume-overrides`, gitignore it, `launch-container --fresh`,
  then `/login` inside as the right person.
- **Confirm the account:** `/status` in the container. On the host, the project's
  `.volume-overrides/.claude/.credentials.json` changes on login and `~/.claude/.credentials.json` doesn't.
- **Attach** to a container made before the folder existed prints a WARNING: it runs as the host's account.
- **Don't re-add** a second mount at `/home/agent/.claude.json`: podman refuses two mounts at one
  destination (`duplicate mount destination`). A temp-file rename onto a single-file mount fails with
  `EBUSY`; Claude Code 2.1.288 falls back to writing in place, so token refresh works. If a future
  version breaks refresh, the fallback is `claude setup-token` passed as `CLAUDE_CODE_OAUTH_TOKEN`.
