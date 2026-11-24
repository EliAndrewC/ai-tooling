#!/usr/bin/env bash
# tab-title.sh - the terminal tab's title shows which of THREE states a Claude Code
# session is in (GM 2026-09-26), in place of Claude Code's own title, which shows the
# same asterisk whether it is waiting for you or waiting on background work.
#
#   IDLE   - done; waiting for you
#   ASK    - stopped mid-task on a question (AskUserQuestion) or a permission prompt;
#            needs your answer to go on (added 2026-10-01: the tab kept showing BUSY)
#   BUSY   - working in the foreground right now
#   BACKGROUND - the turn ended, but background work (a shell, a subagent, a
#            monitor, a workflow) or a scheduled wakeup will bring it back
#
# Wired in ~/.claude/settings.json (with CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1 so
# Claude Code does not overwrite it):
#   SessionStart      -> tab-title.sh idle
#   UserPromptSubmit  -> tab-title.sh busy
#   PreToolUse        -> tab-title.sh busy   (also covers a background task waking
#                                             the session, which is not a prompt; an
#                                             AskUserQuestion call shows ASK instead)
#   PermissionRequest -> tab-title.sh ask    (a permission dialog is showing)
#   PostToolUse       -> tab-title.sh busy   (the question was answered / the permission
#                                             granted, so back to BUSY)
#   Stop              -> tab-title.sh stop   (reads the hook's JSON: non-empty
#                                             background_tasks or a ONE-SHOT cron ->
#                                             BACKGROUND, otherwise IDLE; a recurring
#                                             cron alone is IDLE, GM 2026-10-01)
#
# WHICH TAB (rewritten 2026-09-26 after two failures in one evening). A session is found by the
# session_id in the hook's own input, looked up in Claude Code's session registry
# (~/.claude/sessions/<pid>.json) - NEVER by walking up the process tree. Claude Code can hand a
# session's conversation to a background session (`kind: "bg"`) hosted by a daemon (`claude daemon
# run --origin transient`) that another session happened to spawn; every such background session's
# hooks then run under that daemon, so the process tree leads to the SPAWNING session's tab. Measured:
# the first version stopped at the daemon (whose output is /dev/null) and the "Diagram buildings" tab
# froze; the ancestor-walk fix then walked past it and wrote the "Diagram research" session's icons -
# and its Stop payload - onto the "Diagram buildings" tab. So:
#   - the registry entry with this session_id is the session;
#   - if it names a tmux pane, that pane is the tab;
#   - if it is a background job (`jobId`, no pane), the tab is the interactive session whose
#     `parkedJobId` is that job - the tab the user parked it from - and the title uses THAT tab's
#     name (the background copy is auto-named "<name> (2)" when the name is taken);
#   - a background job no tab has parked has no tab, and nothing is written.
# The title escape is written to the pane's own terminal (tmux's #{pane_tty}); tmux's set-titles
# passes it on to the tab. Outside tmux, a session's own terminal (/proc/<pid>/fd/1) is used.
#
# /rename fires no hook, so the first call in a session also starts ONE watcher per tab (setsid,
# detached from the hook's pipes, gone when the tab's session ends) that re-titles within a second of
# the tab's registry name changing, keeping the current icon. $RUN_DIR/<tab pid>.watch holds its pid
# and WATCH_VERSION.
#
# The last Stop payload is kept per session at $RUN_DIR/<session pid>.stop.json (overwritten each
# turn): when a tab shows the hourglass and you think it should not, it says which background task or
# cron Claude Code reported.
# A ScheduleWakeup left pending as a "fallback" was the usual culprit (2026-09-26 diagram, 2026-10-27
# character-sheet); wakeup-guard.py now refuses one outside a live /loop and blocks a turn from ending
# while one is pending, so a stray hourglass should no longer come from that.
#
# A STALLED BACKGROUND SHELL IS NOT WORK (2026-11-24). A background shell that hangs stays "running"
# in every later Stop payload, and nothing in the payload says it is hung: a `grep -r /` blocked
# reading /dev/snd/timer kept one tab on the hourglass for 15 hours. So while the icon is BACKGROUND
# the watcher measures, every $TAB_TITLE_STALL_CHECK_SECS (60), the processes of each background
# shell (found by the task's output file, <scratchpad_dir>/../tasks/<id>.output, on their fd 1 or 2,
# plus all descendants). When, for $TAB_TITLE_STALL_SECS (1800) on end, the set of processes is the
# same, they have read and written no bytes, the output file has not changed and they used under 1%
# of a core (a hung ugrep still polls select()), the tab shows IDLE. It goes back to the hourglass if
# any of that moves. Only when EVERY background task is such a shell and no one-shot cron is pending:
# subagents, monitors and workflows are never judged, and a shell whose processes can't be found
# keeps the hourglass. Known false positive: one silent wait longer than the limit (`sleep 3600`, a
# quiet `tail -f`) shows IDLE until it ends; a polling loop does not (its process set changes).
# `tab-title.sh __stalled <session pid>` runs one measurement (exit 0 = stalled); the samples are in
# $RUN_DIR/<session pid>.stall. Tests: test-tab-title.sh.
# Never fails a hook: every path exits 0 and prints nothing.

ICON_IDLE="✳"
ICON_BUSY="◐"
ICON_ASK="❯"
ICON_BACKGROUND="⏳"

SESSIONS_DIR="${TAB_TITLE_SESSIONS_DIR:-$HOME/.claude/sessions}"
RUN_DIR="${TMPDIR:-/tmp}/tab-title-$(id -u)"

set_title() {  # set_title <tty> <icon> <name>
  printf '\033]0;%s %s\007' "$2" "$3" > "$1" 2>/dev/null
}

registry_name() {  # registry_name <pid> -> the tab's name in the registry, else its folder
  local n
  n=$(grep -o '"name":"[^"]*"' "$SESSIONS_DIR/$1.json" 2>/dev/null | head -1 | cut -d'"' -f4)
  [ -n "$n" ] || n=$(basename "$(readlink "/proc/$1/cwd" 2>/dev/null || echo "$PWD")")
  printf '%s' "$n"
}

# Bump when the watcher's code changes: a hook call replaces a running watcher of another version
# (watchers live as long as their tab, which can be weeks).
WATCH_VERSION=2
STALL_SECS="${TAB_TITLE_STALL_SECS:-1800}"
STALL_CHECK_SECS="${TAB_TITLE_STALL_CHECK_SECS:-60}"

stalled() {  # stalled <session pid>: takes one sample; exit 0 when every background task is a stalled shell
  python3 - "$RUN_DIR/$1.stop.json" "$RUN_DIR/$1.stall" "$STALL_SECS" 2>/dev/null <<'PY'
import json, os, sys, time
stop_path, state_path, limit = sys.argv[1], sys.argv[2], float(sys.argv[3])
NO = 1  # not stalled, or can't tell: the hourglass stays
try:
    d = json.load(open(stop_path))
except Exception:
    sys.exit(NO)
bg = d.get("background_tasks") or []
crons = [c for c in (d.get("session_crons") or []) if not (isinstance(c, dict) and c.get("recurring"))]
if crons or not bg:
    sys.exit(NO)
if any(not isinstance(t, dict) or t.get("type") != "shell" or not t.get("id") for t in bg):
    sys.exit(NO)
scratch = (d.get("scratchpad_dir") or "").rstrip("/")
if not scratch:
    sys.exit(NO)
tasks = os.path.join(os.path.dirname(scratch), "tasks")
outs = sorted(os.path.join(tasks, str(t["id"]) + ".output") for t in bg)

ppid, ticks, roots = {}, {}, {o: set() for o in outs}
for name in os.listdir("/proc"):
    if not name.isdigit():
        continue
    pid = int(name)
    try:
        f = open("/proc/%d/stat" % pid).read().rsplit(")", 1)[1].split()
        ppid[pid], ticks[pid] = int(f[1]), int(f[11]) + int(f[12])  # ppid, utime + stime
    except Exception:
        continue
    for fd in (1, 2):
        try:
            target = os.readlink("/proc/%d/fd/%d" % (pid, fd))
        except OSError:
            continue
        if target in roots:
            roots[target].add(pid)
if not all(roots.values()):
    sys.exit(NO)  # a task with no process we can see: finished, or laid out in a way we do not know
tree = set().union(*roots.values())
grew = True
while grew:
    more = {p for p, pp in ppid.items() if pp in tree and p not in tree}
    grew = bool(more)
    tree |= more
io = 0
for pid in tree:
    try:
        for line in open("/proc/%d/io" % pid):
            if line.startswith(("rchar:", "wchar:")):
                io += int(line.split()[1])
    except Exception:
        sys.exit(NO)  # another user's process (sudo ...): can't measure it
try:
    out = [[os.stat(o).st_mtime_ns, os.stat(o).st_size] for o in outs]
except OSError:
    sys.exit(NO)
now = time.time()
cur = {"t": now, "pids": sorted(tree), "io": io, "cpu": sum(ticks[p] for p in tree), "out": out, "since": now}
try:
    prev = json.load(open(state_path))
    quiet = (prev["pids"] == cur["pids"] and prev["io"] == io and prev["out"] == out
             and cur["cpu"] - prev["cpu"] <= 1 + 0.01 * os.sysconf("SC_CLK_TCK") * (now - prev["t"]))
    if quiet:
        cur["since"] = prev["since"]
except Exception:
    pass
try:
    tmp = "%s.%d" % (state_path, os.getpid())
    json.dump(cur, open(tmp, "w"))
    os.replace(tmp, state_path)
except Exception:
    sys.exit(NO)
sys.exit(0 if now - cur["since"] >= limit else NO)
PY
}

if [ "${1:-}" = __stalled ]; then stalled "${2:-}"; exit $?; fi

if [ "${1:-}" = __watch ]; then  # the watcher: __watch <tab pid> <tty> <session pid>
  tab=$2 tty=$3 me=$4 last=$(registry_name "$2") n=0 over="" lastover=""
  while kill -0 "$tab" 2>/dev/null; do
    sleep 1
    n=$((n + 1))
    name=$(registry_name "$tab")
    icon=$(cat "$RUN_DIR/$me.icon" 2>/dev/null || echo "$ICON_IDLE")
    if [ "$icon" = "$ICON_BACKGROUND" ]; then
      if [ $((n % STALL_CHECK_SECS)) -eq 0 ]; then
        if stalled "$me"; then over=1; else over=""; fi
      fi
    else
      over=""
    fi
    if [ "$name" != "$last" ] || [ "$over" != "$lastover" ]; then
      last=$name lastover=$over
      [ -n "$over" ] && icon=$ICON_IDLE
      set_title "$tty" "$icon" "$name"
    fi
  done
  rm -f "${RUN_DIR:?}/${tab:?}.watch"
  exit 0
fi

state="${1:-}"
case "$state" in idle|busy|ask|stop) ;; *) exit 0 ;; esac
input="$(cat 2>/dev/null)"

# -> "<session pid>\t<tab pid>\t<tty>\t<tab name>", or nothing when this session has no tab to title.
target=$(printf '%s' "$input" | python3 -c '
import json, os, subprocess, sys
sd = sys.argv[1]
try:
    sid = json.loads(sys.stdin.read() or "{}").get("session_id") or ""
except Exception:
    sid = ""
if not sid:
    sys.exit(0)
regs = []
for f in os.listdir(sd):
    if not f.endswith(".json"):
        continue
    try:
        d = json.load(open(os.path.join(sd, f)))
        os.kill(int(d["pid"]), 0)  # a live session only - stale files of dead pids stay behind
    except Exception:
        continue
    regs.append(d)
me = next((d for d in regs if d.get("sessionId") == sid), None)
if me is None:
    sys.exit(0)
tab = me
if not me.get("tmux") and me.get("jobId"):
    tab = next((d for d in regs if d.get("parkedJobId") == me["jobId"]), None)
    if tab is None:
        sys.exit(0)  # a background job no tab has parked: no tab to title
tty = ""
if tab.get("tmux"):
    pane = tab["tmux"].rsplit(".", 1)[-1]
    tty = subprocess.run(["tmux", "display", "-p", "-t", pane, "#{pane_tty}"], capture_output=True, text=True).stdout.strip()
elif tab is me:
    try:
        t = os.readlink("/proc/%s/fd/1" % me["pid"])
    except OSError:
        t = ""
    if t.startswith(("/dev/pts/", "/dev/tty")):
        tty = t
if not tty:
    sys.exit(0)
name = tab.get("name") or os.path.basename(tab.get("cwd") or "")
print("%s\t%s\t%s\t%s" % (me["pid"], tab["pid"], tty, name))
' "$SESSIONS_DIR" 2>/dev/null)
[ -n "${TAB_TITLE_DRYRUN:-}" ] && { printf "%s\n" "${target:-<no tab>}"; exit 0; }  # testing: say which tab, write nothing
[ -n "$target" ] || exit 0
IFS=$'\t' read -r me tab tty name <<< "$target"
[ -n "$tty" ] || exit 0

case "$state" in
  idle) icon=$ICON_IDLE ;;
  busy)
    if printf '%s' "$input" | grep -qE '"tool_name"[[:space:]]*:[[:space:]]*"AskUserQuestion"' \
       && printf '%s' "$input" | grep -qE '"hook_event_name"[[:space:]]*:[[:space:]]*"PreToolUse"'; then
      icon=$ICON_ASK  # the question is on screen until its PostToolUse
    else
      icon=$ICON_BUSY
    fi ;;
  ask) icon=$ICON_ASK ;;
  stop)
    # Non-empty background_tasks, or a ONE-SHOT cron, = paused, not done. A RECURRING cron is not
    # (GM 2026-10-01): a periodic report - an hourly sweep update made with CronCreate - lives for
    # days, and between its firings the session is waiting on the GM, so it shows IDLE. A one-shot
    # cron (a wakeup or a reminder) still shows BACKGROUND, as it will bring the session back.
    if printf '%s' "$input" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
bg = d.get("background_tasks") or []
crons = [c for c in (d.get("session_crons") or []) if not (isinstance(c, dict) and c.get("recurring"))]
sys.exit(0 if bg or crons else 1)' 2>/dev/null; then
      icon=$ICON_BACKGROUND
    else
      icon=$ICON_IDLE
    fi ;;
esac

mkdir -p "$RUN_DIR" 2>/dev/null
printf '%s' "$icon" > "$RUN_DIR/$me.icon" 2>/dev/null
[ "$state" = stop ] && printf '%s' "$input" > "$RUN_DIR/$me.stop.json" 2>/dev/null
shown=$icon
# The same hung shell is in every later Stop payload: don't flash the hourglass until the next check.
[ "$icon" = "$ICON_BACKGROUND" ] && stalled "$me" && shown=$ICON_IDLE
set_title "$tty" "$shown" "$name"

# One rename watcher per tab, started by whichever hook call comes first.
# (Not `kill -0 0`: signal 0 to pid 0 is the caller's own process group and succeeds.)
watcher="" wver=""
{ read -r watcher wver < "$RUN_DIR/$tab.watch"; } 2>/dev/null
if [ -n "$watcher" ] && [ "$wver" != "$WATCH_VERSION" ]; then
  # A watcher running older code. Only if that pid still is one: the pid may have been reused.
  grep -qa __watch "/proc/$watcher/cmdline" 2>/dev/null && kill "$watcher" 2>/dev/null
  watcher=""
fi
if [ -z "$watcher" ] || ! kill -0 "$watcher" 2>/dev/null; then
  setsid bash "$0" __watch "$tab" "$tty" "$me" </dev/null >/dev/null 2>&1 &
  echo "$! $WATCH_VERSION" > "$RUN_DIR/$tab.watch" 2>/dev/null
fi
exit 0
