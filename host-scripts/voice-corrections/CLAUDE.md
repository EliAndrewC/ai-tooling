# voice-corrections: fix dictated prompt text before it is sent

Load this file when: dictated text in Claude Code isn't being corrected (or is corrected wrongly), you're
adding or changing a correction rule, you're changing the mod or the space-bar service, or an unsent
prompt was lost and you want it back ("Unsent drafts").

Claude Code's voice dictation (hold space) mishears names and game terms the same way every time (Asawa
Ishii → Isawa Ishi, role → roll). This mod fixes them **in the prompt box**: once Eli releases space and
the box has been still for 1 s, the dictated text is rewritten in place, so he sees the corrected text
before pressing Enter. If he presses Enter sooner, the same correction is applied on submit.

| Piece | What it does |
|---|---|
| `mod/` | The Claude Code mod. `hooks/register.js` polls the prompt box every 100 ms (and autosaves unsent drafts, below), `hooks/corrector.mjs` applies the rules. Loaded in every session through `CLAUDE_CODE_PLUGIN_DIRS`: host from `~/.bash_aliases` (`docs/shell/bash_aliases`), containers from launch-container's `~/.bashrc` block (`/host-scripts/voice-corrections/mod`). |
| `~/.claude/voice-corrections/corrections.json` | The rules, in order. Shared by host and containers through the `~/.claude` mount. Backed up to `corrections.json` here by the `voice-corrections-backup.path` user unit (`docs/claude-code/`). |
| `voice-corrections` (on PATH; containers: `/host-scripts/voice-corrections/voice-corrections`) | Adds, removes, lists and checks rules, with a file lock and atomic writes. `--help` has the rule format. |
| `spacebar-watch.py` + `.service`, installed by `fix-voice-corrections.sh` (Eli, sudo) | System service that publishes whether space is held to `~/.claude/voice-corrections/spacebar`: `0` while held, otherwise the epoch ms of the last release. |

## How it decides what to correct

- **Only dictated text.** Claude Code puts dictation into the box without firing any mods event
  (`prompt.edit` fires only for keys and pastes; probed 2026-10-27). So a box change that no keystroke
  explains, with space seen held just before or during it, is dictation. The corrected span is the diff
  between the box before and after. Typed text, pastes and recalled history are never changed.
- **Never mid-recording.** Eli pauses 10+ s with space held to think, so no timer can tell a pause from
  the end. Only the space-bar file can. Wayland gives apps no global key state, so the service reads
  `/dev/input` itself. It runs as eli with `input` as a supplementary group, so no other process gets
  keyboard access, and it publishes only the space key. Don't replace it with "add eli to the `input`
  group": that lets every process of his log every key.
- **Typing a key** (not space) before a dictation's correction lands: after the dictated text (a
  paragraph break, more typing), the correction is applied first and the key lands on the corrected
  text; inside it, the correction is dropped, since Eli is fixing it by hand. Don't go back to "any key
  cancels": a quick Shift+Enter after each paragraph left whole paragraphs uncorrected (2026-10-27).
- **Without the service** (state file missing), corrections happen on submit only.
- **A rule added mid-conversation** applies to the very next dictation: the mod re-reads the rules file
  (if its mtime changed) right before every correction and submit, besides every 2 s.
- **A session without the mod** (started from a shell older than the `CLAUDE_CODE_PLUGIN_DIRS` setting)
  applies nothing. `~/.claude/hooks/voice-mod-check.sh` (SessionStart) then shows a warning saying how
  to restart; a "rule that doesn't work" is usually this.
- The rewrite uses `$.prompt.fill` replace, which leaves the cursor at the end of the box.

## Unsent drafts (autosave)

The same 100 ms poll keeps the prompt box on disk, typed or dictated, in `~/.claude/prompt-drafts/`
(shared by host and containers; files older than 14 days are removed at session start):

- `<session id>.txt`: the box as of the last 2 s, once it is 40+ characters. Emptied when the box is
  (a sent prompt is in `~/.claude/history.jsonl`). It survives the session being killed or crashing.
- `<session id>.<UTC time>Z.cleared.txt`: a draft of 200+ characters that left the box without being
  sent (Ctrl+C, Esc Esc, recalled history over it): less than half of it remained.

Get one back: `ls -lt ~/.claude/prompt-drafts | head`, then `cat` the file (the session id is the
transcript's file name). A session started before 2026-11-26 19:30 runs the old mod and saves nothing
until it is restarted. Why it exists: 2026-11-26, a 15-minute dictated draft seemed lost when a container
tab dropped (it was still in the box; the launcher now reattaches by itself).

## `(X -> Y)` footnotes

When a submitted prompt (typed or dictated) contains "(Third Dawn -> 3rd Dan)", the mod runs
`voice-corrections add "Third Dawn" "3rd Dan"`, applies the swap to that message, removes the footnote, and
adds a `voice-corrections:` context line so Claude mentions it (or adds the rule itself if the CLI refused).
It only counts as a footnote when each side is 1-5 plain words, the left side has 3+ letters and also
appears elsewhere in the message, so "map each field (input -> output)" or "f(x -> y)" is left alone.

## Rules

`voice-corrections --help` documents them. In short: `from`/`to` whole-word swaps (case-insensitive;
a `to` with a capital is used as written, an all-lowercase one is capitalized only at a sentence start),
`near`/`not_near` context gates (roll vs role), and JavaScript `pattern`s. Each rule may carry `examples`
(`[dictated, expected]`), which `check` runs, along with an idempotency check (a second pass must change
nothing). `add` refuses a rule that fails either.

Leave a mis-hearing out when context can't decide it reliably (heat → Hida, worthy → wealthy,
think → feint). A wrong rewrite is worse than a missed one.

## Test

- Unit tests: `node host-scripts/voice-corrections/mod/hooks/test-corrector.mjs ~/.claude/voice-corrections/corrections.json`
  and `cd host-scripts/voice-corrections/mod && claude plugin test` (mod logic with a fake clock, box and space bar).
- Footnotes: send "how Rakugani budgeting works (Rakugani -> Rokugani)"; Claude should get "how Rokugani
  budgeting works" plus a context line, and `voice-corrections list Rakugani` shows the rule.
- Rules: `voice-corrections check`; `voice-corrections try "the Asawa Ishii third DOM technique"`.
- Service: `fix-voice-corrections.sh --check` while holding space in another window shows `space: held`.
- Live: start a new `claude`, `/plugin` shows `voice-corrections` active. Dictate "the Asawa Ishii
  school", release, wait a second: the box changes to "the Isawa Ishi school".
- Drafts: in a new `claude`, type 200+ characters and wait 3 s: `~/.claude/prompt-drafts/<id>.txt` holds
  them. Press Ctrl+C: a `.cleared.txt` copy appears and `<id>.txt` is empty.
- Diagnose: `VOICE_CORRECTIONS_DEBUG=1 claude` logs every decision to `~/.claude/voice-corrections/debug.log`.
