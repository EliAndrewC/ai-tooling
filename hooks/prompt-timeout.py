#!/usr/bin/env python3
"""PermissionRequest hook: a permission prompt nobody answers is denied after PROMPT_TIMEOUT_S (default 120 s).

Why (2026-11-11): under --dangerously-skip-permissions Claude Code still asks for some built-in safety checks.
Only the dangerous-`rm` check carries its own 2-minute auto-deny, and even that only in the main thread. A prompt
raised inside a background subagent waits forever, and the coordinator is never told. The Diagram backlog
session lost 24 min, 70 min, 3 h, 4 h and 11 h this way (Nov 8-11). Claude Code runs PermissionRequest hooks
alongside the dialog, and the first answer wins. So this hook sleeps, then denies. If Eli answers first, his
answer stands and this result is dropped.

Scope: only sessions in bypassPermissions mode (where a prompt is never expected). Never denies a tool that
exists to ask Eli something (AskUserQuestion, plan-mode exits). Every prompt it sees is logged to
~/.claude/hooks/logs/prompt-timeout.log (one JSON line: seen / denied), which also shows which prompts reach
hooks at all (person-only safety asks may skip PermissionRequest hooks).

Test: bash ~/.claude/hooks/test-prompt-timeout.sh
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
