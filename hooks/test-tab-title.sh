#!/usr/bin/env bash
# Tests for tab-title.sh's stalled-background-shell detection (2026-11-24).
# Run: bash ~/ai-tooling/hooks/test-tab-title.sh   (exit 0 = all green; takes about 35 s)
#
# Every case starts REAL processes writing to a task output file laid out as Claude Code does
# (<scratchpad_dir>/../tasks/<id>.output on fd 1 and 2) and drives the real hook with a Stop payload
# of the real shape. The stall limit is cut to 2 s through TAB_TITLE_STALL_SECS.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
HOOK="$HERE/tab-title.sh"
T=$(mktemp -d)
PIDS=()
trap 'kill -- "${PIDS[@]}" 2>/dev/null; rm -rf "$T"' EXIT
export TMPDIR="$T" TAB_TITLE_STALL_SECS=2 TAB_TITLE_STALL_CHECK_SECS=1 TAB_TITLE_SESSIONS_DIR="$T/sessions"
RUN="$T/tab-title-$(id -u)"
mkdir -p "$RUN" "$T/proj/scratchpad" "$T/proj/tasks" "$T/sessions"
PASS=0; FAIL=0
ok() { echo "  ok      $1"; PASS=$((PASS+1)); }
no() { echo "  FAIL    $1 ${2:-}"; FAIL=$((FAIL+1)); }

task() {  # task <id> <bash code> -> starts it as a background shell task
  setsid bash -c "$2" </dev/null >"$T/proj/tasks/$1.output" 2>&1 &
  PIDS+=("-$!")
}
payload() {  # payload <session> <background_tasks json> [session_crons json]
  printf '{"session_id":"s","scratchpad_dir":"%s","background_tasks":%s,"session_crons":%s}' \
    "$T/proj/scratchpad" "$2" "${3:-[]}" > "$RUN/$1.stop.json"
}
shell() { printf '{"id":"%s","type":"shell","status":"running"}' "$1"; }
verdict() {  # verdict <session> -> "stalled" | "working", after sampling across the limit
  bash "$HOOK" __stalled "$1"; sleep 1; bash "$HOOK" __stalled "$1"; sleep 1.5
  if bash "$HOOK" __stalled "$1"; then echo stalled; else echo working; fi
}
expect() {  # expect <want> <session> <label>
  local got; got=$(verdict "$2")
  if [ "$got" = "$1" ]; then ok "$3"; else no "$3" "(got $got, want $1)"; fi
}

task hung 'sleep infinity'
task hungpipe 'sleep infinity | cat | head'
task busy 'while :; do :; done'
task chatty 'while sleep 0.3; do echo line; done'
task poll 'until [ -e /nonexistent ]; do sleep 0.3; done'
sleep 0.5

payload 1 "[$(shell hung)]"
bash "$HOOK" __stalled 1 && no "first sample is never stalled" || ok "first sample is never stalled"
expect stalled 1 "a shell that sleeps forever is stalled after the limit"
payload 2 "[$(shell hungpipe)]";                 expect stalled 2 "a silent pipeline is stalled"
payload 3 "[$(shell busy)]";                     expect working 3 "a shell burning CPU is working"
payload 4 "[$(shell chatty)]";                   expect working 4 "a shell writing output is working"
payload 5 "[$(shell poll)]";                     expect working 5 "a polling loop (new processes) is working"
payload 6 "[$(shell hung),$(shell busy)]";       expect working 6 "one working shell keeps the hourglass"
payload 7 "[$(shell hung),{\"id\":\"a1\",\"type\":\"subagent\",\"status\":\"running\"}]"
expect working 7 "a subagent beside a hung shell keeps the hourglass"
payload 8 "[$(shell hung)]" '[{"id":"c","recurring":false}]'
expect working 8 "a one-shot cron keeps the hourglass"
payload 9 "[$(shell gone)]";                     expect working 9 "a shell with no visible process keeps the hourglass"
payload 10 "[]";                                 expect working 10 "no background tasks: nothing to judge"

# The watcher: the hourglass turns to IDLE on the tab, and comes back when the shell works again.
sleep 600 & TAB=$!; PIDS+=("$TAB")
printf '{"pid":%s,"sessionId":"s","name":"My tab"}' "$TAB" > "$T/sessions/$TAB.json"
task wakes 'trap "while :; do :; done" USR1; while :; do sleep infinity & wait $!; done'
WAKES=$!
sleep 0.3
payload 20 "[$(shell wakes)]"; printf '⏳' > "$RUN/20.icon"; : > "$T/tty"
setsid bash "$HOOK" __watch "$TAB" "$T/tty" 20 </dev/null >/dev/null 2>&1 & PIDS+=("-$!")
sleep 6
case "$(cat "$T/tty")" in *"✳ My tab"*) ok "watcher shows IDLE for a stalled shell" ;; *) no "watcher shows IDLE for a stalled shell" "(tty: $(cat -v "$T/tty"))" ;; esac
kill -USR1 "$WAKES"
sleep 3
case "$(cat "$T/tty")" in *"⏳ My tab"*) ok "watcher restores the hourglass when the shell works again" ;; *) no "watcher restores the hourglass when the shell works again" "(tty: $(cat -v "$T/tty"))" ;; esac

# The hook end to end, on a session whose terminal is a real pty (its output lands in $T/pty).
script -qfc 'exec sleep 600' /dev/null </dev/null >"$T/pty" 2>&1 & SCRIPT=$!; PIDS+=("$SCRIPT")
sleep 0.5
SESS=$(pgrep -P "$SCRIPT" | head -1); PIDS+=("$SESS")
printf '{"pid":%s,"sessionId":"e2e","name":"E2E"}' "$SESS" > "$T/sessions/$SESS.json"
bash -c 'exec -a "old __watch" sleep 600' & OLD=$!; PIDS+=("$OLD")
echo "$OLD" > "$RUN/$SESS.watch"  # the file an older tab-title.sh wrote: a pid, no version
stop() {
  printf '{"session_id":"e2e","hook_event_name":"Stop","scratchpad_dir":"%s","background_tasks":[%s],"session_crons":[]}' \
    "$T/proj/scratchpad" "$(shell hung)" | bash "$HOOK" stop
}
titles() { grep -ao '[^;]* E2E' "$T/pty" | tr '\n' ' '; }
out=$(stop 2>&1)
[ -z "$out" ] && ok "hook prints nothing" || no "hook prints nothing" "($out)"
sleep 0.3
[ "$(titles)" = "⏳ E2E " ] && ok "Stop with a background shell shows the hourglass" || no "Stop with a background shell shows the hourglass" "($(titles))"
read -r W V < "$RUN/$SESS.watch"; PIDS+=("$W")
if ! kill -0 "$OLD" 2>/dev/null && [ "$V" = 2 ] && kill -0 "$W" 2>/dev/null; then ok "an old-version watcher is replaced"; else no "an old-version watcher is replaced" "(watch file: $W $V)"; fi
sleep 5
[ "$(titles)" = "⏳ E2E ✳ E2E " ] && ok "the hook's watcher turns it to IDLE once stalled" || no "the hook's watcher turns it to IDLE once stalled" "($(titles))"
stop; sleep 0.3
[ "$(titles)" = "⏳ E2E ✳ E2E ✳ E2E " ] && ok "a later Stop with the same hung shell stays IDLE" || no "a later Stop with the same hung shell stays IDLE" "($(titles))"
read -r W2 _ < "$RUN/$SESS.watch"
[ "$W2" = "$W" ] && ok "a current watcher is kept" || no "a current watcher is kept"

echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
