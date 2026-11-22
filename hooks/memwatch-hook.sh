#!/usr/bin/env bash
# memwatch-hook.sh - tell Claude sessions (main thread and subagents, in the containers and on the
# host) about memory events on mujina: "containers near their cap" warnings and OOM kills. The events
# are written by memwatch/memwatch-events.sh (user service `memwatch`) into
# ~/.claude/memwatch/ (mounted into every container). Doc: memwatch/CLAUDE.md in the ai-tooling repo.
#
# Wired in ~/.claude/settings.json:
#   PostToolUse, PostToolUseFailure, UserPromptSubmit -> memwatch-hook.sh deliver
#       adds unseen events as additionalContext. Each session, and each subagent (by agent_id),
#       gets each event once. A session idle at the prompt gets them with Eli's next prompt.
#   Stop (asyncRewake, long timeout)                  -> memwatch-hook.sh wait
#       if the turn ended with background work or crons in flight, waits in the background and
#       exits 2 on a new event, which wakes the session with the message. It gives up when the
#       next Stop starts a newer waiter. With nothing in flight it exits at once (no wake-ups for
#       sessions that are simply done).
# A memguard kill (CLAUDE.md, "memguard") has two texts: events/<seq>.mine.txt goes to the sessions
# listed in events/<seq>.to (by session id, or by container pid namespace + claude pid, which still
# matches after /clear changes the id), events/<seq>.txt to everyone else.
# Events are delivered for 60 minutes. A session or subagent seen for the first time gets only the
# last 10 minutes' events. Never fails a hook: every path but the wake-up exits 0.

MW_DIR="${MEMWATCH_DIR:-$HOME/.claude/memwatch}"
mode="${1:-}"
case "$mode" in deliver|wait) ;; *) exit 0 ;; esac

# Fast path for every tool call: nothing in the last hour -> done, without starting python.
if [ "$mode" = deliver ]; then
  { read -r _ epoch < "$MW_DIR/latest"; } 2>/dev/null || exit 0
  [ $(( $(date +%s) - ${epoch:-0} )) -le 3600 ] || exit 0
fi

PY=$(cat <<'PY'
import fcntl, json, os, sys, time

mode, mw = sys.argv[1], sys.argv[2]  # run as python3 -c, so argv[0] is -c
EXPIRE, FIRST = 3600, 600
HEAD = ("Memory watch (automatic notice from the laptop's memwatch hook, not from the user; "
        "it only reports, and needs no reply unless it affects your work):\n\n")

try:
    inp = json.loads(sys.stdin.read() or "{}")
except Exception:
    sys.exit(0)
sid = inp.get("session_id") or ""
if not sid or "/" in sid:
    sys.exit(0)

def latest():
    try:
        return int(open(os.path.join(mw, "latest")).read().split()[0])
    except Exception:
        return 0

_keys = None
def my_keys():
    """This session's match keys for targeted events: its id, and its claude process as
    "pid:<pid namespace>:<pid>" (this hook runs under claude: claude -> sh -> bash -> python3)."""
    global _keys
    if _keys is None:
        _keys = {"sid:" + sid}
        try:
            ns, p = os.readlink("/proc/self/ns/pid"), os.getppid()
            while p > 1:
                st = open("/proc/%d/stat" % p).read()
                if st[st.index("(") + 1:st.rindex(")")] == "claude":
                    _keys.add("pid:%s:%d" % (ns, p))
                    break
                p = int(st[st.rindex(")") + 2:].split()[1])
        except Exception:
            pass
    return _keys

def text(seq):
    base = os.path.join(mw, "events", "%d" % seq)
    try:
        if set(open(base + ".to").read().split()) & my_keys():
            return open(base + ".mine.txt").read().strip()
    except OSError:
        pass
    return open(base + ".txt").read().strip()

def take(key):
    """Unseen, unexpired event texts for `key`; marks them seen. Locked, so two hooks
    of one session never deliver the same event twice."""
    os.makedirs(os.path.join(mw, "seen"), exist_ok=True)
    path = os.path.join(mw, "seen", key)
    with open(path, "a+") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        f.seek(0)
        raw = f.read().strip()
        first = not raw.isdigit()
        seen = 0 if first else int(raw)
        top, now, out = latest(), time.time(), []
        for seq in range(seen + 1, top + 1):
            p = os.path.join(mw, "events", "%d.txt" % seq)
            try:
                if now - os.path.getmtime(p) <= (FIRST if first else EXPIRE):
                    out.append(text(seq))
            except OSError:
                pass
        if top != seen or first:
            f.seek(0); f.truncate(); f.write(str(top))
        return out

if mode == "deliver":
    agent = inp.get("agent_id") or ""
    key = sid + ("." + agent if agent and "/" not in agent else "")
    msgs = take(key)
    if msgs:
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": inp.get("hook_event_name") or "PostToolUse",
            "additionalContext": HEAD + "\n\n".join(msgs)}}))
    sys.exit(0)

# mode == wait (Stop, asyncRewake)
if not (inp.get("background_tasks") or inp.get("session_crons")):
    sys.exit(0)
try:
    os.makedirs(os.path.join(mw, "wait"), exist_ok=True)
    token = os.path.join(mw, "wait", sid)
    me = "%d %f" % (os.getpid(), time.time())
    open(token, "w").write(me)
    seen_path = os.path.join(mw, "seen", sid)
    while True:
        time.sleep(5)
        if open(token).read() != me or os.getppid() == 1:
            sys.exit(0)  # a newer Stop took over, or the session is gone
        try:
            seen = int(open(seen_path).read().strip() or 0)
        except (OSError, ValueError):
            seen = 0
        if latest() > seen:
            msgs = take(sid)
            if msgs:
                sys.stderr.write(HEAD + "\n\n".join(msgs) + "\n")
                sys.exit(2)
except SystemExit:
    raise
except Exception:
    sys.exit(0)
PY
)
if [ "$mode" = wait ]; then
  python3 -c "$PY" "$mode" "$MW_DIR"
  [ $? = 2 ] && exit 2  # the wake-up; its message is on stderr
  exit 0
fi
python3 -c "$PY" "$mode" "$MW_DIR" 2>/dev/null
exit 0
