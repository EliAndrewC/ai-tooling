# Unanswered permission prompts in `--dangerously-skip-permissions` sessions

Load this file when: a Claude Code session started with `--dangerously-skip-permissions` stops and waits
on a permission prompt (often for hours, unattended), or you want to install the `prompt-timeout` hook on
another machine.

## The symptom

A session runs with `--dangerously-skip-permissions` (`bypassPermissions` mode). It still sometimes stops and
asks "is it okay to run this command?" Sometimes the prompt is denied automatically after a 2-minute
countdown, and the session carries on. Other times there is no countdown, and the session waits until someone
answers. Left overnight, that loses hours of work.

## Why it happens

Observed on Claude Code 2.1.318–2.1.322 (November 2026):

1. **Bypass mode still asks for some built-in safety checks.** Examples:
   - `rm` on a path Claude Code can't resolve, such as a shell variable (`rm -f "$D"/*`, `rm -rf $X/...`).
     Even `git rm` inside a larger command has triggered it.
   - `sed` scripts that aren't on Claude Code's list of known-safe sed commands.
   - Writes into Claude Code's own protected folders.
2. **Only the dangerous-`rm` check has a built-in auto-deny (2 minutes), and only in the main thread.** That
   is the countdown you may remember.
3. **A prompt raised by a background subagent never times out.** The subagent waits forever, and the main
   session (the coordinator) gets no notice; it only sees that the agent has gone quiet. In one session,
   subagents sat waiting 24 min, 70 min, 3 h, 4 h and 11 h over four days. The commands were Bash calls
   containing heredocs (`python3 - <<'EOF' ...` editing a Makefile) or `rm -f "$D"/*`. In every transcript,
   each safety-check auto-deny came from a main-thread call, never from a subagent's.

How to confirm from transcripts (`~/.claude/projects/<project>/<session>.jsonl`, subagents in
`<session>/subagents/agent-*.jsonl`):
- A countdown denial reads: "Permission for this command was denied by a built-in Claude Code safety
  check, not by the user ... (the permission prompt timed out, or none was shown)". It arrives about 120 s
  after the `tool_use`.
- A hung subagent prompt shows as a `tool_use` whose `tool_result` comes hours later. If the agent was then
  stopped, the result reads "The user doesn't want to proceed with this tool use", with
  `"toolDenialKind":"user-rejected"`.

## The fix: a `PermissionRequest` hook that denies after 120 s

When a dialog is shown, Claude Code runs `PermissionRequest` hooks alongside it, and the first answer wins.
So a hook that sleeps and then denies acts as a countdown. If you answer the prompt first, your answer
stands, and the hook's late result is ignored.

What the hook does:
- Acts only in `bypassPermissions` sessions. Normal interactive sessions are untouched.
- Never denies a tool that exists to ask you something (`AskUserQuestion`, plan-mode tools).
- Waits `PROMPT_TIMEOUT_S` (default 120), then denies. The denial message tells the model not to retry the
  same call, to find another way (Edit/Write instead of a shell heredoc, no `rm` on a variable path), and to
  tell you what it wanted to run.
- Logs every prompt it sees (`seen` / `waiting` / `denied`, with `agent` set for subagents) to
  `~/.claude/hooks/logs/prompt-timeout.log`.

### 1. `~/.claude/hooks/prompt-timeout.py`

```python
#!/usr/bin/env python3
"""PermissionRequest hook: a permission prompt nobody answers is denied after PROMPT_TIMEOUT_S (default 120 s).

Under --dangerously-skip-permissions, Claude Code still asks for some built-in safety checks. Only the
dangerous-`rm` check has its own 2-minute auto-deny, and only in the main thread. A prompt raised inside a
background subagent waits forever. Claude Code runs PermissionRequest hooks alongside the dialog, and the first
answer wins: this hook sleeps, then denies. If a person answers first, their answer stands.
"""
import json
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

LOG = Path.home() / ".claude/hooks/logs/prompt-timeout.log"
NEVER = {"AskUserQuestion", "ExitPlanMode", "EnterPlanMode"}


def log(**row):
    try:
        LOG.parent.mkdir(parents=True, exist_ok=True)
        row["at"] = datetime.now(timezone.utc).isoformat(timespec="seconds")
        with LOG.open("a") as f:
            f.write(json.dumps(row) + "\n")
    except OSError:
        pass


def main():
    try:
        d = json.load(sys.stdin)
    except Exception:
        return
    tool = d.get("tool_name", "")
    mode = d.get("permission_mode", "")
    inp = d.get("tool_input") or {}
    what = inp.get("command") or inp.get("file_path") or inp.get("url") or ""
    row = dict(session=d.get("session_id", ""), agent=d.get("agent_id", ""), tool=tool, mode=mode,
               what=str(what)[:200], cwd=d.get("cwd", ""))
    if mode != "bypassPermissions" or tool in NEVER:
        log(event="seen", **row)
        return
    wait = float(os.environ.get("PROMPT_TIMEOUT_S", "120"))
    log(event="waiting", wait=wait, **row)
    time.sleep(wait)
    log(event="denied", **row)
    msg = (f"No one answered this permission prompt within {wait:.0f} seconds, so it was denied automatically "
           "(the user runs unattended). The call was NOT run. Do not retry the same call: it will prompt again. "
           "Reach the goal another way that does not trigger a prompt (e.g. the Edit/Write tools instead of a "
           "shell heredoc or sed script; no `rm` on a variable path), or skip it, and tell the user what you "
           "wanted to run and why.")
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PermissionRequest",
                                             "decision": {"behavior": "deny", "message": msg}}}))


if __name__ == "__main__":
    main()
```

### 2. Register it in `~/.claude/settings.json`

Add this to `hooks` and merge it with any `PermissionRequest` entries you already have. The `timeout` (in
seconds) must be longer than the wait, or Claude Code kills the hook before it can deny.

```json
{
  "hooks": {
    "PermissionRequest": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "python3 \"$HOME/.claude/hooks/prompt-timeout.py\"",
            "timeout": 180
          }
        ]
      }
    ]
  }
}
```

If you run Claude Code in containers, the hook works there only if the container sees the same `~/.claude`
(mounted) or has its own copy of the script and settings.

### 3. Unit test: `~/.claude/hooks/test-prompt-timeout.sh`

```bash
#!/usr/bin/env bash
# Tests for prompt-timeout.py. Ends "5 passed, 0 failed".
H="$HOME/.claude/hooks/prompt-timeout.py"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL $1: got [$2] want [$3]"; fi; }
run() { HOME="$T" PROMPT_TIMEOUT_S=0.2 python3 "$H"; }
mkdir -p "$T/.claude/hooks"

out=$(printf '%s' '{"tool_name":"Bash","permission_mode":"bypassPermissions","tool_input":{"command":"rm -f \"$D\"/*"},"agent_id":"a1"}' | run)
check "bypass prompt denied" "$(printf '%s' "$out" | python3 -c 'import json,sys;print(json.load(sys.stdin)["hookSpecificOutput"]["decision"]["behavior"])')" "deny"
check "logged waiting+denied" "$(grep -c '"event": "\(waiting\|denied\)"' "$T/.claude/hooks/logs/prompt-timeout.log")" "2"

out=$(printf '%s' '{"tool_name":"Bash","permission_mode":"default","tool_input":{"command":"ls"}}' | run)
check "default mode untouched" "$out" ""

out=$(printf '%s' '{"tool_name":"AskUserQuestion","permission_mode":"bypassPermissions","tool_input":{}}' | run)
check "AskUserQuestion untouched" "$out" ""

out=$(printf 'not json' | run)
check "bad input silent" "$out" ""

echo "$pass passed, $fail failed"; [ "$fail" = 0 ]
```

Run it with `bash ~/.claude/hooks/test-prompt-timeout.sh`.

## Live test

Restart Claude Code after installing, so it loads the new hook.

1. In a scratch folder, start `claude --dangerously-skip-permissions`.
2. Ask it: *spawn a background general-purpose subagent that runs, in one Bash call:
   `D=$(mktemp -d); rm -f "$D"/*`*
3. Don't answer the prompt. Within about 2 minutes the subagent should receive the hook's denial and carry on.
4. Run `tail ~/.claude/hooks/logs/prompt-timeout.log`. It should show `waiting`, then `denied`, with an `agent` id.

## Caveat: not yet confirmed for every prompt

Claude Code marks some safety asks as person-only, and those may skip `PermissionRequest` hooks altogether.
If the log shows nothing while a prompt sits waiting, the hook never saw that prompt. For those, the
fallback is to keep the triggering command shapes out of subagents:
- Edit files with the Edit/Write tools, not shell heredocs or `sed` scripts.
- Never `rm` a variable path.
- Write any helper script to a file first, then run it.

A project hook (`PreToolUse`) can block those shapes before they ever reach the prompt.
