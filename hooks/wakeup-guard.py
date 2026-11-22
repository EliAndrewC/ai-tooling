#!/usr/bin/env python3
"""wakeup-guard.py - a timed wakeup cannot outlive its purpose, in every project.

Ported 2026-10-27 from the diagram project's feature 263 (`scripts/hooks/wakeup-hooks.sh`, spec and
measurements in its `specs/263-stale-wakeup-guard/`), which until now guarded only sessions in that
project. The same defect then hit the character-sheet session: a `ScheduleWakeup` set as a "fallback"
while clicktests ran in the background stayed pending after they reported back, so the Stop payload kept a
one-shot cron and `tab-title.sh` showed the hourglass while the session was waiting for Eli. The fallback
was never needed: `ScheduleWakeup` is the /loop pacing tool, and background shells, agents and workflows
wake the session by themselves when they finish.

TWO LAYERS, because either alone leaves a way through:
  pretool (PreToolUse, matcher ScheduleWakeup) - REFUSE the call unless this session is running a LIVE
          /loop and the wakeup carries that loop's own prompt. `stop: true` (ending a loop) always passes.
  stop    (Stop) - BLOCK the turn from ending while a ScheduleWakeup is pending outside a live loop,
          naming `CronDelete <id>`. The backstop, for a wakeup made before this guard or after a loop
          was stopped.

WHAT IS A WAKEUP (measured in diagram's research.md R1): in the Stop payload a pending cron is
`{id, schedule, recurring, prompt}`, the same shape for `ScheduleWakeup` and a `CronCreate` reminder.
The transcript tells them apart: a wakeup's prompt is verbatim the prompt of a `ScheduleWakeup` call in
the session's own transcript. So a reminder Eli asked for (CronCreate) is never named or blocked.

A LOOP IS LIVE, not merely once run (R3): a /loop wakeup's prompt is the loop input prefixed with
`/loop ` (or the autonomous sentinel), and the loop is live while the transcript's latest loop event is
a /loop invocation (the command entry, or the `loop` skill) rather than a `ScheduleWakeup(stop: true)`.

EVERY TURN END, NO ESCAPE: the Stop layer blocks each time; one `CronDelete` always satisfies it, and an
escape token would let the incident itself through.

UNREADABLE INPUT: the ScheduleWakeup layer fails CLOSED (a call that cannot be shown to belong to a live
loop is refused); the Stop layer fails OPEN (without the transcript it cannot tell a wakeup from a
reminder Eli asked for).

STANDS ASIDE in a project that wires its own copy (`$CLAUDE_PROJECT_DIR/scripts/hooks/wakeup-hooks.sh`,
i.e. diagram and its clones), so a session there is not told everything twice.

Wired in ~/.claude/settings.json: PreToolUse (matcher ScheduleWakeup) -> `wakeup-guard.py pretool`,
Stop -> `wakeup-guard.py stop`. Tests: bash ~/.claude/hooks/test-wakeup-guard.sh
"""

import json
import os
import sys

SENTINEL = "<<autonomous-loop-dynamic>>"


def is_loop_prompt(text):
    """A loop's own wakeup: the loop input prefixed with `/loop `, or the autonomous sentinel.
    Anything else a ScheduleWakeup carries is a fallback timer."""
    t = (text or "").strip()
    return t.startswith("/loop ") or t == "/loop" or t == SENTINEL


def read_transcript(path):
    """(every ScheduleWakeup prompt, whether a loop is live). Raises on an unreadable transcript."""
    wakeup_prompts, loop_live = set(), False
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            if "/loop" not in line and "ScheduleWakeup" not in line and '"loop"' not in line:
                continue
            try:
                r = json.loads(line)
            except ValueError:
                continue
            content = (r.get("message") or {}).get("content")
            if r.get("type") == "user":
                texts = [content] if isinstance(content, str) else [
                    b.get("text", "") for b in content or [] if isinstance(b, dict)]
                if any("<command-name>/loop</command-name>" in t for t in texts if isinstance(t, str)):
                    loop_live = True
            if not isinstance(content, list):
                continue
            for b in content:
                if not isinstance(b, dict) or b.get("type") != "tool_use":
                    continue
                inp = b.get("input") or {}
                if b.get("name") == "ScheduleWakeup":
                    if inp.get("stop"):
                        loop_live = False
                    elif inp.get("prompt"):
                        wakeup_prompts.add(inp["prompt"])
                elif b.get("name") == "Skill" and inp.get("skill") == "loop":
                    loop_live = True
    return wakeup_prompts, loop_live


def decide(mode, raw):
    """-> ("PASS"|"REFUSE"|"BLOCK", detail). For BLOCK, detail is the list of stale crons."""
    try:
        p = json.loads(raw or "{}")
        if not isinstance(p, dict):
            raise ValueError
    except ValueError:
        return ("REFUSE", "unreadable") if mode == "pretool" else ("PASS", "unreadable-payload")
    if mode == "pretool" and p.get("tool_name") not in (None, "ScheduleWakeup"):
        return "PASS", "not-a-wakeup"
    ti = p.get("tool_input") or {}
    if mode == "pretool" and ti.get("stop"):
        return "PASS", "ending-a-loop"
    try:
        wakeup_prompts, loop_live = read_transcript(p.get("transcript_path") or "")
    except Exception:
        return ("REFUSE", "unreadable") if mode == "pretool" else ("PASS", "no-transcript")

    if mode == "pretool":
        if loop_live and is_loop_prompt(ti.get("prompt")):
            return "PASS", "live-loop"
        return "REFUSE", "not-the-loop-prompt" if loop_live else "outside-loop"

    stale = [c for c in p.get("session_crons") or []
             if isinstance(c, dict) and c.get("id") and c.get("prompt") in wakeup_prompts
             and not (loop_live and is_loop_prompt(c.get("prompt")))]
    return ("BLOCK", stale) if stale else ("PASS", "no-stale-wakeup")


OUTSIDE_LOOP = """BLOCKED: ScheduleWakeup outside /loop (wakeup-guard).

ScheduleWakeup is the /loop pacing tool. Outside a loop it is a fallback timer, and a fallback outlives
its purpose: it stays pending after the work it guarded has finished, and Eli's tab shows the hourglass
instead of waiting-for-you. You do not need one:
  - background work (a shell, an agent, a workflow, a Monitor) wakes this session by itself when it finishes;
  - a reminder Eli asked for ("remind me at 3pm") is CronCreate's job, not this tool's.
There is no escape token."""

NOT_LOOP_PROMPT = """BLOCKED: a live /loop paces itself with its OWN prompt - "/loop <the loop input>" - and this wakeup
carries something else, which makes it a fallback timer riding on the loop (wakeup-guard). Re-arm with the
loop prompt."""

UNREADABLE = """BLOCKED: ScheduleWakeup, and wakeup-guard could not establish that this session is running a live
/loop (its transcript was unreadable). Outside a loop, background work wakes the session by itself; a
reminder Eli asked for is CronCreate's job."""


def main(argv):
    mode = argv[1] if len(argv) > 1 else ""
    if mode not in ("pretool", "stop"):
        return 0
    raw = sys.stdin.read()  # always drained first: a writer must never meet a closed pipe
    project = os.environ.get("CLAUDE_PROJECT_DIR") or ""
    if project and os.path.exists(os.path.join(project, "scripts", "hooks", "wakeup-hooks.sh")):
        return 0  # the project wires its own copy (diagram)
    verdict, detail = decide(mode, raw)
    if verdict == "PASS":
        return 0
    if verdict == "REFUSE":
        msg = {"outside-loop": OUTSIDE_LOOP, "not-the-loop-prompt": NOT_LOOP_PROMPT}.get(detail, UNREADABLE)
        print(msg, file=sys.stderr)
        return 2
    lines = ["A WAKEUP WOULD OUTLIVE THIS TURN (wakeup-guard): a ScheduleWakeup is still pending outside /loop.",
             "It keeps Eli's tab on the hourglass and brings this session back for nothing. Cancel it:"]
    for c in detail:
        prompt = (c.get("prompt") or "")[:80].replace("\n", " ")
        lines.append("    CronDelete %s      (%s: %s)" % (c["id"], c.get("schedule", ""), prompt))
    lines.append("(ScheduleWakeup with stop: true cancels it too.) Background work wakes this session by "
                 "itself when it finishes; nothing needs a timer.")
    print("\n".join(lines), file=sys.stderr)
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except SystemExit:
        raise
    except Exception as exc:  # the decision itself crashed: closed on the call, open on the turn end
        if len(sys.argv) > 1 and sys.argv[1] == "pretool":
            print(UNREADABLE + " (%s)" % exc, file=sys.stderr)
            sys.exit(2)
        sys.exit(0)
