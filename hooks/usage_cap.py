#!/usr/bin/env python3
"""usage_cap.py - the weekly soft cap (every session, per account) and the per-goal usage cap.

THE SOFT CAP (always on; Eli, 2026-10-24). When an account's 7-day usage reaches its cap (default 90%), each session
on that account is told once, at its next tool call, to wind down: finish the step in hand, commit, push to a branch
where the project uses them, write down where it stopped, and stop - not finish the task. At cap + 5 new work is
refused (BACKSTOP). Caps are per Claude account: two people can share one laptop, the login flips often, and a
project container can always run as the other account while a host tab runs as the first. Raising the cap re-arms the message at the
new number ("warned" records the cap and window it fired at), lowering it below the usage fires it at once, and the
weekly reset clears it. `continue` is not needed: once warned, a session hears nothing more until the cap changes,
and only raising the cap lifts the backstop.

THE PER-GOAL CAP (armed by one session; the GM, 2026-10-07): "a 75% stop on a particular goal" - notes as the figure
rises, a warning at cap-5, at the cap new work is refused. Both run side by side.

Where the numbers come from: Claude Code hands a status line script `rate_limits.seven_day.used_percentage` (the 5-hour
window is gone, 2026-11). `statusline` is that script: it prints the line and saves the session's own reading, with the account
it is logged in as (whose login token it holds - see _account; a container's .volume-overrides replace it), to
`latest-<session>.json`. Hooks read ONLY that file: the percentage is the session's own (true for whatever token it
bills), and the account only picks which cap applies. Never fall back to another session's reading - a session at
21% once read another account's 88% (2026-10-10). Known limit: a host session still on the old token right after a
/login switch is labelled with the new account at its next redraw; only the cap NUMBER can be wrong for it. A reading
updates when the status line redraws (after each message); idle, nothing redraws, but idle spends nothing.

Commands (the session runs these; CLAUDE_CODE_SESSION_ID names the session):
  cap                                         every account's soft cap and latest reading
  cap <N> [--account <email or name>]         set a soft cap (this session's account by default)
  arm <cap%> "<goal>" [--warn N] [--step N]   arm the per-goal cap (warn default cap-5, a note every N=1 points)
  disarm                                      the goal landed, or the GM said continue without a cap
  status                                      this session's reading, soft cap and budget
Hooks (wired in ~/.claude/settings.json):
  statusline                 statusLine.command
  hook post                  PostToolUse: the soft-cap wind-down; the per-goal notes, warning and cap notice
  hook pre                   PreToolUse: at soft cap + 5, or a per-goal cap, refuse new work; allow reading, git,
                             the stop-work step, this tool
  hook end                   SessionEnd: forget the session (budget, warned, reading)

State: ~/.claude/usage-cap/ (USAGE_CAP_DIR overrides; USAGE_CAP_CLAUDE_JSON and USAGE_CAP_CREDENTIALS override ~/.claude.json
and ~/.claude/.credentials.json, all for the self-test test-usage-cap.sh). caps.json holds {account uuid: {cap, email, name}}. Never fails a hook: any error in a
hook path exits 0 silently.
"""

import hashlib
import json
import os
import re
import sys
import time

DIR = os.environ.get("USAGE_CAP_DIR") or os.path.expanduser("~/.claude/usage-cap")
CAPS = os.path.join(DIR, "caps.json")
CLAUDE_JSON = os.environ.get("USAGE_CAP_CLAUDE_JSON") or os.path.expanduser("~/.claude.json")
CREDENTIALS = os.environ.get("USAGE_CAP_CREDENTIALS") or os.path.expanduser("~/.claude/.credentials.json")
TOKENS = os.path.join(DIR, "tokens.json")  # {sha256 of a token: account} - hashes only, never a token
PROFILE_URL = os.environ.get("USAGE_CAP_PROFILE_URL") or "https://api.anthropic.com/api/oauth/profile"
DEFAULT_CAP = 90.0
BACKSTOP = 5.0  # points past the soft cap where new work is refused

# At the cap these tools start new work; refused. Read, Grep, Glob, TaskStop and the like stay open.
DISPATCH_TOOLS = {"Agent", "Task", "Workflow"}
BLOCKED_TOOLS = {"Agent", "Task", "Workflow", "Edit", "Write", "NotebookEdit", "Skill", "SendMessage"}
# At the cap a Bash command passes only if EVERY segment (split on ; && || |) starts with one of these: read-only
# looks, git (commit), the stop-work step, and this tool itself.
ALLOWED_BASH = re.compile(
    r"^\s*(?:[A-Z_][A-Z0-9_]*=\S*\s+)*"
    r"(?:git|cat|ls|head|tail|wc|grep|rg|find|stat|date|echo|printf|pwd|true|"
    r"sed\s+-n|\S*sync-with-main\.sh|python3\s+\S*usage_cap\.py|\S*usage_cap\.py|"
    # recording a check that was already running when the cap hit (a verdict is work done, not new work)
    r"make\s+(?:-C\s+\S+\s+)?claims-(?:checked|triaged|report)|make\s+(?:-C\s+\S+\s+)?record-checked)\b"
)
# At the cap a Write or Edit passes only into a scratch path: the reply file a recording command reads.
SCRATCH_PREFIXES = ("/tmp/",)


def _load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def _save(path, data):
    os.makedirs(DIR, exist_ok=True)
    tmp = f"{path}.{os.getpid()}.tmp"
    with open(tmp, "w") as f:
        json.dump(data, f)
    os.replace(tmp, path)


def _budget_path(sid):
    return _sid_file("budget", sid)


def _sid_file(prefix, sid):
    return os.path.join(DIR, f"{prefix}-{re.sub(r'[^A-Za-z0-9_-]', '_', sid)}.json")


def _latest_path(sid):
    return _sid_file("latest", sid)


def _latest(sid=""):
    """The session's own last reading - never another session's: sessions on both accounts share this directory."""
    return (_load(_latest_path(sid)) if sid else None) or {}


def _token_hashes():
    o = (_load(CREDENTIALS) or {}).get("claudeAiOauth") or {}
    return [hashlib.sha256(t.encode()).hexdigest() for t in (o.get("accessToken"), o.get("refreshToken")) if t]


def _profile(token):
    import urllib.request

    req = urllib.request.Request(
        PROFILE_URL, headers={"Authorization": f"Bearer {token}", "anthropic-beta": "oauth-2025-04-20"}
    )
    a = (json.load(urllib.request.urlopen(req, timeout=3)).get("account") or {})
    if not a.get("uuid"):
        return {}
    email = a.get("email") or ""
    return {"uuid": a["uuid"], "email": email, "name": a.get("display_name") or email.split("@")[0]}


def _account():
    """{uuid, email, name} of the account this process's login token belongs to, or {}.

    From the token, not ~/.claude.json's oauthAccount: /login rewrites .credentials.json but left oauthAccount on
    the previous account (2026-10-24: after a /login, the status line still named the other account). Each new token is looked up
    once at the profile endpoint and cached by its hash (a refreshed access token still matches its refresh token);
    oauthAccount is only the fallback when the lookup cannot be made."""
    hashes = _token_hashes()
    cache = _load(TOKENS) or {}
    for h in hashes:
        if cache.get(h):
            acct = cache[h]
            break
    else:
        acct = {}
        if hashes:
            try:
                o = (_load(CREDENTIALS) or {}).get("claudeAiOauth") or {}
                acct = _profile(o["accessToken"])
            except Exception:
                acct = {}
    if acct:
        if any(cache.get(h) != acct for h in hashes):
            cache.update({h: acct for h in hashes})
            _save(TOKENS, cache)
        return acct
    a = (_load(CLAUDE_JSON) or {}).get("oauthAccount") or {}
    if not a.get("accountUuid"):
        return {}
    email = a.get("emailAddress") or ""
    return {"uuid": a["accountUuid"], "email": email, "name": a.get("displayName") or email.split("@")[0]}


def _soft_cap(uuid):
    c = ((_load(CAPS) or {}).get(uuid or "") or {}).get("cap")
    return float(c) if isinstance(c, (int, float)) else DEFAULT_CAP


def _live_pct(latest):
    """The reading's 7-day figure, or None once its window has reset (a stale figure from last week)."""
    resets = latest.get("seven_day_resets_at")
    if isinstance(resets, (int, float)) and time.time() > resets:
        return None
    return _pct(latest)


def _pct(latest):
    v = latest.get("seven_day")
    return float(v) if isinstance(v, (int, float)) else None


def _budget(sid):
    """The live budget for sid, or None; a budget whose 7-day window has reset is removed."""
    if not sid:
        return None
    b = _load(_budget_path(sid))
    if not b:
        return None
    resets = b.get("resets_at")
    if isinstance(resets, (int, float)) and time.time() > resets:
        _remove(sid)
        return None
    return b


def _remove(sid, *prefixes):
    for prefix in prefixes or ("budget",):
        try:
            os.remove(_sid_file(prefix, sid))
        except OSError:
            pass


def _fmt_pct(v):
    return "?" if v is None else f"{v:.0f}%"


def _fmt_reset(ts):
    """Epoch seconds -> local 'Wed 11pm' / 'Wed 11:30pm'; None if unknown."""
    if not isinstance(ts, (int, float)):
        return None
    t = time.localtime(ts)
    hour = t.tm_hour % 12 or 12
    mins = f":{t.tm_min:02d}" if t.tm_min else ""
    return f"{time.strftime('%a', t)} {hour}{mins}{'am' if t.tm_hour < 12 else 'pm'}"


# ---------------------------------------------------------------- status line


def statusline(payload):
    rl = payload.get("rate_limits") or {}
    week = (rl.get("seven_day") or {}).get("used_percentage")
    acct = _account()
    sid = payload.get("session_id") or ""
    if week is not None:
        reading = {
            "seven_day": week,
            "seven_day_resets_at": (rl.get("seven_day") or {}).get("resets_at"),
            "at": time.time(),
            "account": acct,
        }
        if sid:
            _save(_latest_path(sid), reading)
        if acct:  # for `cap` to show both people's figures; hooks never read it
            _save(_sid_file("account", acct["uuid"]), reading)
    reset = _fmt_reset((rl.get("seven_day") or {}).get("resets_at"))
    parts = [f"7d {_fmt_pct(week)}" + (f" (resets {reset})" if reset else ""), f"cap {_soft_cap(acct.get('uuid')):g}%"]
    b = _budget(sid)
    if b:
        parts.append(f"goal cap {b['cap']:g}%")
    ctx = (payload.get("context_window") or {}).get("used_percentage")
    if ctx is not None:
        parts.append(f"ctx {ctx:.0f}%")
    line = " · ".join(parts)
    print(f"{acct['name']} · {line}" if acct else line)


# ---------------------------------------------------------------- hooks


def _context(event, text):
    print(json.dumps({"hookSpecificOutput": {"hookEventName": event, "additionalContext": text}}))


def _soft_cap_note(sid):
    """The wind-down message, once per session per (cap, window); None otherwise."""
    latest = _latest(sid)
    pct = _live_pct(latest)
    if pct is None:
        return None
    acct = latest.get("account") or {}
    cap = _soft_cap(acct.get("uuid"))
    if pct < cap:
        return None
    mark = {"cap": cap, "resets_at": latest.get("seven_day_resets_at")}
    warned = _load(_sid_file("warned", sid)) or {}
    if warned.get("cap") == mark["cap"] and warned.get("resets_at") == mark["resets_at"]:
        return None
    _save(_sid_file("warned", sid), mark)
    who = f"{acct['name']}'s account" if acct.get("name") else "this account"
    return (
        f"WEEKLY SOFT CAP REACHED on {who}: 7-day usage {_fmt_pct(pct)} >= soft cap {cap:g}%. Wind down now. Do NOT "
        "try to finish the task - it may be long. Finish only the step you are in the middle of, then make sure "
        "nothing is lost: commit the work locally; push it to a branch if this project uses a remote (a work-in-progress "
        "branch, not main, unless the project's own rules say otherwise); write down where you stopped and what comes "
        "next (the project's task notes or issue, and your final message). Let subagents already running finish and "
        "record their results; start no new agents or new pieces of work. Then stop and tell Eli where things stand. "
        f"At {cap + BACKSTOP:g}% new work is refused outright. Eli lifts this by raising the cap: "
        "python3 ~/.claude/hooks/usage_cap.py cap <N>."
    )


def _budget_note(sid):
    b = _budget(sid)
    if not b:
        return None
    pct = _pct(_latest(sid))
    if pct is None:
        return None
    cap, warn, step = b["cap"], b["warn"], b["step"]
    last = b.get("last_reported")
    goal = b["goal"]
    if pct >= cap and not b.get("cap_reported"):
        b["cap_reported"] = True
        b["last_reported"] = pct
        _save(_budget_path(sid), b)
        return (
            f"USAGE CAP REACHED: 7-day usage {_fmt_pct(pct)} >= cap {cap:g}% (goal: {goal}). Start nothing new. Let "
            "the subagent checks already running finish and record their results, commit in the clone, run the "
            "stop-work step, then tell the GM where the goal stands and wait for them to say continue. New agents, "
            "edits and builds are refused from here."
        )
    if last is None or int(pct // step) > int(last // step):
        b["last_reported"] = pct
        note = f"Usage note: 7-day usage {_fmt_pct(pct)} (cap {cap:g}%, goal: {goal})."
        if pct >= warn and not b.get("warn_reported"):
            b["warn_reported"] = True
            note += f" WARNING: past {warn:g}% - finish the unit in hand and start nothing large."
        _save(_budget_path(sid), b)
        return note
    return None


def hook_post(payload):
    if payload.get("agent_id"):  # the notes are for the session that decides what starts next, not its subagents
        return
    sid = payload.get("session_id") or ""
    if not sid:
        return
    notes = [n for n in (_soft_cap_note(sid), _budget_note(sid)) if n]
    if notes:
        _context("PostToolUse", "\n\n".join(notes))


def _bash_allowed(command):
    # A redirect into a file, or find's -exec / -delete, turns a look into a write.
    if ">" in re.sub(r"\d?>&\d|\d?>\s*/dev/null", "", command) or re.search(r"\s-(?:exec|delete)\b", command):
        return False
    segments = [s for s in re.split(r"&&|\|\||;|\||\n", command) if s.strip()]
    return bool(segments) and all(ALLOWED_BASH.match(s) for s in segments)


def hook_pre(payload):
    sid = payload.get("session_id") or ""
    # A SUBAGENT's call carries the parent's session_id plus its own agent_id (measured 2026-10-07: a Bash call of a
    # general-purpose agent reached this hook with both). The GM: "let whatever subagents are currently running
    # complete" - so a running subagent's work passes; only its dispatching MORE agents is refused.
    if payload.get("agent_id") and (payload.get("tool_name") or "") not in DISPATCH_TOOLS:
        return
    latest = _latest(sid)
    b = _budget(sid)
    pct = _pct(latest)
    soft = _soft_cap(((latest.get("account") or {}).get("uuid")))
    over_goal = b is not None and pct is not None and pct >= b["cap"]
    live = _live_pct(latest)
    over_soft = live is not None and live >= soft + BACKSTOP
    if not (over_goal or over_soft):
        return
    tool = payload.get("tool_name") or ""
    tool_input = payload.get("tool_input") or {}
    if tool == "Bash":
        if _bash_allowed(tool_input.get("command") or ""):
            return
    elif tool in ("Write", "Edit") and str(tool_input.get("file_path") or "").startswith(SCRATCH_PREFIXES):
        return
    elif tool not in BLOCKED_TOOLS:
        return
    if over_soft:
        reason = (
            f"Weekly soft cap backstop: 7-day usage {_fmt_pct(live)} >= soft cap {soft:g}% + {BACKSTOP:g}. New work is "
            "refused; allowed are reading, git (commit, push to a branch), writes under /tmp, and usage_cap.py. Make "
            "sure the work is committed and pushed, say where you stopped, and stop. Only Eli lifts this, by raising the "
            "cap: python3 ~/.claude/hooks/usage_cap.py cap <N>."
        )
    else:
        reason = (
            f"Usage cap reached: 7-day usage {_fmt_pct(pct)} >= cap {b['cap']:g}% (goal: {b['goal']}). New work is "
            "refused; allowed are reading, git (commit), recording a running check's verdict (a reply file under /tmp, "
            "make claims-checked / claims-triaged / record-checked), the stop-work step (scripts/sync-with-main.sh "
            "done - no gate run: it refuses the landing and pushes the backup branch) and usage_cap.py. Let running "
            "checks finish, record them, commit, stop, and wait for the GM. When the GM says continue: "
            "python3 ~/.claude/hooks/usage_cap.py arm <higher cap> \"<goal>\" or ... disarm."
        )
    print(
        json.dumps(
            {
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": reason,
                }
            }
        )
    )


def hook_end(payload):
    sid = payload.get("session_id") or ""
    if sid:
        _remove(sid, "budget", "warned", "latest")


# ---------------------------------------------------------------- commands


def _sid_or_die():
    sid = os.environ.get("CLAUDE_CODE_SESSION_ID", "")
    if not sid:
        sys.exit("usage_cap: CLAUDE_CODE_SESSION_ID is not set - run this from a Claude Code session's Bash tool")
    return sid


def cmd_arm(args):
    import argparse

    p = argparse.ArgumentParser(prog="usage_cap.py arm")
    p.add_argument("cap", type=float)
    p.add_argument("goal")
    p.add_argument("--warn", type=float)
    p.add_argument("--step", type=float, default=1.0)
    a = p.parse_args(args)
    if not 0 < a.cap <= 100 or a.step <= 0:
        sys.exit("usage_cap: cap must be in (0, 100] and step > 0")
    sid = _sid_or_die()
    latest = _latest(sid)
    pct = _pct(latest)
    b = {
        "cap": a.cap,
        "warn": a.warn if a.warn is not None else max(a.cap - 5, 0),
        "step": a.step,
        "goal": a.goal,
        "armed_at": time.time(),
        "resets_at": latest.get("seven_day_resets_at"),
        "last_reported": pct,
    }
    _save(_budget_path(sid), b)
    age = f", read {time.time() - latest['at']:.0f}s ago" if latest.get("at") else ""
    print(f"armed: cap {a.cap:g}%, warn {b['warn']:g}%, note every {a.step:g} point(s); 7-day now {_fmt_pct(pct)}{age}")
    if pct is None:
        print(
            "WARNING: no usage figure yet - the status line has not reported rate_limits. The cap cannot fire until "
            "it does (it needs a claude.ai account and statusLine set to `usage_cap.py statusline`)."
        )


def cmd_disarm(_args):
    sid = _sid_or_die()
    existed = os.path.exists(_budget_path(sid))
    _remove(sid)
    print("disarmed" if existed else "not armed")


def cmd_status(_args):
    sid = os.environ.get("CLAUDE_CODE_SESSION_ID", "")
    latest = _latest(sid)
    acct = latest.get("account") or _account()
    age = f" (read {time.time() - latest['at']:.0f}s ago)" if latest.get("at") else ""
    who = f"{acct.get('name')} <{acct.get('email')}>: " if acct else ""
    print(f"{who}7-day {_fmt_pct(_pct(latest))}{age}")
    soft = _soft_cap(acct.get("uuid"))
    warned = _load(_sid_file("warned", sid)) if sid else None
    note = " (this session was told to wind down)" if warned and warned.get("cap") == soft else ""
    print(f"soft cap {soft:g}%, hard stop at {soft + BACKSTOP:g}%{note}")
    b = _budget(sid)
    print(f"armed: cap {b['cap']:g}%, goal: {b['goal']}" if b else "not armed in this session")


def _accounts():
    """Every account seen, {uuid: {email, name, reading}}; the caps file's entries too."""
    seen = {}
    for uuid, c in (_load(CAPS) or {}).items():
        seen[uuid] = {"email": c.get("email", ""), "name": c.get("name", ""), "reading": {}}
    try:
        names = os.listdir(DIR)
    except OSError:
        names = []
    for n in names:
        if n.startswith("account-") and n.endswith(".json"):
            r = _load(os.path.join(DIR, n)) or {}
            a = r.get("account") or {}
            if a.get("uuid"):
                seen[a["uuid"]] = {"email": a.get("email", ""), "name": a.get("name", ""), "reading": r}
    return seen


def cmd_cap(args):
    import argparse

    p = argparse.ArgumentParser(prog="usage_cap.py cap")
    p.add_argument("cap", type=float, nargs="?")
    p.add_argument("--account", help="email or display name; default: the account this session is logged in as")
    a = p.parse_args(args)
    seen = _accounts()
    if a.cap is None:
        if not seen:
            print(f"no account seen yet; every account's soft cap is the default {DEFAULT_CAP:g}%")
        for uuid, info in seen.items():
            r = info["reading"]
            when = time.strftime(" at %a %H:%M", time.localtime(r["at"])) if r.get("at") else ""
            cap = _soft_cap(uuid)
            print(f"{info['name']} <{info['email']}>: soft cap {cap:g}% (hard stop {cap + BACKSTOP:g}%), "
                  f"7-day {_fmt_pct(_live_pct(r))}{when}")
        return
    if not 0 < a.cap <= 100:
        sys.exit("usage_cap: cap must be in (0, 100]")
    if a.account:
        want = a.account.lower()
        hits = [(u, i) for u, i in seen.items() if want in (i["email"].lower(), i["name"].lower())]
        if len(hits) != 1:
            known = ", ".join(f"{i['name']} <{i['email']}>" for i in seen.values()) or "none yet"
            sys.exit(f"usage_cap: no single account matches {a.account!r}; known: {known}")
        uuid, info = hits[0]
    else:
        acct = _latest(os.environ.get("CLAUDE_CODE_SESSION_ID", "")).get("account") or _account()
        if not acct:
            sys.exit("usage_cap: cannot tell which account this is (no login token or profile); use --account")
        uuid, info = acct["uuid"], acct
    caps = _load(CAPS) or {}
    caps[uuid] = {"cap": a.cap, "email": info["email"], "name": info["name"], "set_at": time.time()}
    _save(CAPS, caps)
    print(f"{info['name']} <{info['email']}>: soft cap {a.cap:g}%, hard stop at {a.cap + BACKSTOP:g}%")


def main(argv):
    if not argv:
        sys.exit(__doc__)
    cmd, rest = argv[0], argv[1:]
    if cmd in ("statusline", "hook"):
        try:
            payload = json.load(sys.stdin)
        except ValueError:
            payload = {}
        try:
            if cmd == "statusline":
                statusline(payload)
            else:
                {"post": hook_post, "pre": hook_pre, "end": hook_end}[rest[0]](payload)
        except Exception:  # a hook never fails the session
            if cmd == "statusline":
                print("7d ?")
        return
    {"arm": cmd_arm, "disarm": cmd_disarm, "status": cmd_status, "cap": cmd_cap}.get(cmd, lambda _a: sys.exit(__doc__))(rest)


if __name__ == "__main__":
    main(sys.argv[1:])
