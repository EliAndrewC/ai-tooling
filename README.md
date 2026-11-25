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
| `spinner-verbs/` | Extra Claude Code spinner verbs: about 240 made from an office running joke (a fake band's song titles), plus themed categories from a public collection. See [Spinner verbs](#spinner-verbs) below. |
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

## Spinner verbs

`spinner-verbs/` adds to the spinner text Claude Code shows while it works ("Making a suspiciously
minor change…"). It **appends** to the built-in verbs and never replaces them. It keeps your other
settings, and a rerun only removes verbs it added itself.

```sh
spinner-verbs/spinner-verbs.py apply --dry-run   # show what would change in ~/.claude/settings.json
spinner-verbs/spinner-verbs.py apply             # the band verbs + the extra categories
spinner-verbs/spinner-verbs.py apply --no-dsk    # only the extra categories
spinner-verbs/spinner-verbs.py apply --no-extras # only the band verbs
spinner-verbs/spinner-verbs.py extras -v         # list the extra categories' verbs
```

There are two sources:

- **`verbs.json`**: the band verbs. They come from the song titles of Differently Sized Kittens, a fake
  band that's been a running joke at work for 15+ years ([the discography][dsk]). Each title was
  reviewed by hand against the criteria in `spinner-verbs/CLAUDE.md`.
- **`extras.json`**: themed categories from
  [wynandw87/claude-code-spinner-verbs](https://github.com/wynandw87/claude-code-spinner-verbs), with
  thanks. To choose your own, edit `categories` using the exact headings from that repo's README.
  Use the short-verb categories, not the "… Phrases" ones, which are sentences and which the tool
  refuses. That repo has no license, so its verbs are **downloaded when you run `apply`**, never
  copied here.

One category, Noir Detective, mixes verbs with sentences, so the maintainer rewrote its entries by
hand. Those rewordings are private (derived from an unlicensed list), so without them the tool skips
that category with a note.

To turn your own list of titles into verbs, `fetch` / `new` / `lint` work on any Google Doc laid out
the same way. Pass `--doc URL`, and see `spinner-verbs/CLAUDE.md` for the review workflow and the
principles behind a good spinner verb.

[dsk]: https://docs.google.com/document/d/1kO6DRPxsuS4XvP8sjDwwgcAjuVuv5-oIGPIxuguu_Zc

## Tests

```sh
for t in hooks/test-*.sh; do bash "$t" || echo "FAILED: $t"; done
bash host-scripts/test-launch-container.sh      # fake podman, no container started
bash host-scripts/test-proposals.sh
bash host-scripts/test-clipboard-bridge.sh
node host-scripts/voice-corrections/mod/hooks/test-corrector.mjs
bash spinner-verbs/test-spinner-verbs.sh
```

## License

CC0 1.0 Universal (public domain dedication); see `LICENSE`.
