# ai-tooling

The Claude Code tooling I use day to day on one Ubuntu laptop: user-level hooks, a dev-container
launcher, a voice-dictation correction mod, and memory watchdogs for the containers. It's shared as a
reference, not as a polished package. Paths assume the checkout lives at `~/ai-tooling` and that the
host runs Linux with systemd user services, and some comments mention my own projects. Each folder's
`CLAUDE.md` explains its design, the bugs behind each rule, and how to test it.

## What's here

| Folder | What it is |
|---|---|
| `hooks/` | User-level Claude Code hooks (they run in every project), each with a test. `install.sh` copies them into `~/.claude/hooks/`, and `settings.example.json` has the `hooks` block for `~/.claude/settings.json`. |
| `host-scripts/` | `launch-container.sh` (one podman dev container per repo, with `~/.claude` shared), the read-only `/host-scripts` mount plus a queue where containers *propose* host-script changes, a tmux-to-desktop clipboard bridge, read-only host diagnostics for containers, and the voice-corrections mod. |
| `memwatch/` | `memwatch` (tells every Claude session about memory warnings and OOM kills in the containers' cgroup), memguard (kills the biggest non-Claude process when the containers thrash, then tells the session that owned it), and `cmem` (memory in use against the cap). |
| `docs/` | Standalone write-ups, e.g. `bypass-prompt-timeout.md`. |

## The hooks

| Hook | Event | What it enforces |
|---|---|---|
| `wakeup-guard.py` | PreToolUse (ScheduleWakeup), Stop | A timed wakeup can't outlive its purpose: no "fallback" wakeups left pending after the work they guarded is done. |
| `prompt-timeout.py` | PermissionRequest | In bypass mode, a permission prompt nobody answers is denied after 120 s, so a background subagent can't hang forever. |
| `readme-guard.py` | PreToolUse (Write/Edit/Bash) | README files only at a repo's top level, `CLAUDE.md` below it. |
| `usage_cap.py` | status line, PreToolUse, PostToolUse, SessionEnd | Weekly soft cap per Claude account (wrap up, then refuse new work), per-goal caps, and the status line. |
| `memwatch-hook.sh` | PostToolUse, UserPromptSubmit, Stop (`asyncRewake`) | Delivers memwatch/memguard events and wakes an idle session that has background work running. |
| `missing-program-hook.sh` | PostToolUse(Failure) (Bash) | In a container, a "command not found" reminds the session it has passwordless sudo to install it. |
| `tab-title.sh` | most events | Terminal tab title shows idle / busy / background / waiting on a prompt. A background shell that has hung (silent for 30 minutes) stops counting as background work. |
| `voice-mod-check.sh` | SessionStart | Warns when a session started without the voice-corrections mod. |

Install: `hooks/install.sh` (it only rewrites files that differ, atomically) and merge
`hooks/settings.example.json` into `~/.claude/settings.json`. `hooks/install.sh --check` reports drift.
Install never silently overwrites a hand edit made in `~/.claude/hooks/` (e.g. by a container session, which
can't see this repo): it refuses until the edit is copied back here, or `--force` discards it.
Run every `hooks/test-*.sh` after a change (each ends with `N passed, 0 failed`).

Why copies and not a symlink: containers mount `~/.claude` and run `$HOME/.claude/hooks/...`, so a link
out of `~/.claude` would dangle inside them. And a hook script must never be missing, even briefly:
`python3 missing.py` exits 2, which Claude Code treats as a block on every tool call.

## Tests

```sh
for t in hooks/test-*.sh; do bash "$t" || echo "FAILED: $t"; done
bash host-scripts/test-launch-container.sh      # fake podman, no container started
bash host-scripts/test-proposals.sh
bash host-scripts/test-clipboard-bridge.sh
node host-scripts/voice-corrections/mod/hooks/test-corrector.mjs
```

## License

CC0 1.0 Universal (public domain dedication); see `LICENSE`.
