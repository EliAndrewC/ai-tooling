#!/usr/bin/env bash
# test-usage-cap.sh - the self-test of usage_cap.py (the per-goal usage cap, 2026-10-07; the per-account weekly soft
# cap, 2026-10-24: wind-down once per cap and window, re-armed by a raise, a backstop at cap + 5, two accounts apart).
# Unarmed sessions see nothing; an armed one gets a note per whole point, the warning once, the cap notice once; at the
# cap new work is refused while reading, git, the stop-work step and the tool itself pass; a reset window and
# SessionEnd disarm. Run directly, or by the diagram repository's `make hooks-test`.
set -uo pipefail
TOOL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/usage_cap.py"
pass=0; fail=0
export USAGE_CAP_DIR; USAGE_CAP_DIR=$(mktemp -d); trap 'rm -rf "$USAGE_CAP_DIR"' EXIT
export CLAUDE_CODE_SESSION_ID=s1
ACCTS=$(mktemp -d); trap 'rm -rf "$USAGE_CAP_DIR" "$ACCTS"' EXIT
echo '{"oauthAccount":{"accountUuid":"u-eli","emailAddress":"eli@example.org","displayName":"Eli"}}' >"$ACCTS/eli.json"
echo '{"oauthAccount":{"accountUuid":"u-alex","emailAddress":"alex@example.org","displayName":"Alex"}}' >"$ACCTS/alex.json"
export USAGE_CAP_CLAUDE_JSON="$ACCTS/eli.json"
export USAGE_CAP_CREDENTIALS=/nonexistent  # no login token: the ~/.claude.json profile is the fallback
export USAGE_CAP_PROFILE_URL=http://127.0.0.1:9/  # never the network in the test

ok() { pass=$((pass+1)); }
bad() { fail=$((fail+1)); printf 'FAIL [%s]: %s\n' "$1" "$2"; }
check() {  # label want-regex(or "^$" for silent) output
  if grep -Eq -- "$2" <<<"$3" || { [ "$2" = '^$' ] && [ -z "$3" ]; }; then ok; else bad "$1" "$3"; fi
}
usage() {  # seven_day [resets_at] -> through the status line, as Claude Code would
  local resets=${2:-9999999999}
  printf '{"session_id":"s1","rate_limits":{"seven_day":{"used_percentage":%s,"resets_at":%s},"five_hour":{"used_percentage":10}}}' \
    "$1" "$resets" | python3 "$TOOL" statusline
}
post() { printf '{"session_id":"%s","tool_name":"Read","tool_input":{}}' "${1:-s1}" | python3 "$TOOL" hook post; }
pre() {  # tool [command] [sid]
  python3 -c 'import json,sys; t,c,s=sys.argv[1:4]; print(json.dumps({"session_id":s,"tool_name":t,"tool_input":{"command":c}}))' \
    "$1" "${2:-}" "${3:-s1}" | python3 "$TOOL" hook pre
}

check "statusline prints" '^Eli · 7d 60% \(resets [A-Z][a-z]{2} [0-9:]+[ap]m\) · cap 90%$' "$(usage 60)"
check "unarmed post silent" '^$' "$(post)"
check "unarmed pre silent" '^$' "$(usage 80 >/dev/null; pre Agent)"
usage 60 >/dev/null
check "arm" '^armed: cap 75%, warn 70%' "$(python3 "$TOOL" arm 75 "test goal")"
check "statusline shows cap" 'cap 75%' "$(usage 60)"
check "no rise, no note" '^$' "$(post)"
check "fraction, no note" '^$' "$(usage 60.9 >/dev/null; post)"
check "point rise notes" 'Usage note: 7-day usage 61%' "$(usage 61.2 >/dev/null; post)"
check "once per point" '^$' "$(post)"
check "other session silent" '^$' "$(usage 64 >/dev/null; post s2)"
check "skipped points: one note" 'usage 64%' "$(post)"
check "warn" 'WARNING: past 70%' "$(usage 70.4 >/dev/null; post)"
check "warn once" '^(Usage note[^W]*)?$' "$(usage 71.1 >/dev/null; post | grep WARNING)"
check "below cap: agent allowed" '^$' "$(pre Agent)"
usage 75 >/dev/null
check "cap notice" 'USAGE CAP REACHED' "$(post)"
check "cap notice once" '^$' "$(usage 76 >/dev/null; post | grep 'CAP REACHED')"
for t in Agent Workflow Edit Write Skill SendMessage; do check "deny $t" '"permissionDecision": "deny"' "$(pre "$t")"; done
for c in "make quick" "python3 x.py" "git status && make done" "cat a > b" "echo hi > f" "find . -delete" "rm -rf x"; do
  check "deny bash: $c" '"deny"' "$(pre Bash "$c")"
done
for c in "git -C /diagram/.clones/x commit -F msg" "/diagram/.clones/x/scripts/sync-with-main.sh done" \
         "scripts/sync-with-main.sh done 2>&1" "cat log | tail -5" "sed -n 1,5p f" "python3 ~/.claude/hooks/usage_cap.py disarm" \
         "ls /tmp 2>/dev/null"; do
  check "allow bash: $c" '^$' "$(pre Bash "$c")"
done
for t in Read Grep Glob TaskStop; do check "allow $t" '^$' "$(pre "$t")"; done
for c in "make claims-checked BUNDLE=/tmp/b REPLY=/tmp/r" "make claims-triaged BUNDLE=/tmp/b REPLY=/tmp/r" "make record-checked X=1"; do
  check "allow recording: $c" '^$' "$(pre Bash "$c")"
done
filepre() {  # tool path
  python3 -c 'import json,sys; t,p=sys.argv[1:3]; print(json.dumps({"session_id":"s1","tool_name":t,"tool_input":{"file_path":p}}))' "$1" "$2" | python3 "$TOOL" hook pre
}
check "allow Write to /tmp reply" '^$' "$(filepre Write /tmp/x/reply.txt)"
check "deny Write in a repo" '"deny"' "$(filepre Write /diagram/.clones/x/a.py)"
check "deny Edit in a repo" '"deny"' "$(filepre Edit /diagram/.clones/x/a.py)"
check "deny make done" '"deny"' "$(pre Bash "make done")"
subpre() {  # tool [command] - a subagent's call: the parent's session_id plus an agent_id
  python3 -c 'import json,sys; t,c=sys.argv[1:3]; print(json.dumps({"session_id":"s1","agent_id":"a1","agent_type":"glyph-check","tool_name":t,"tool_input":{"command":c}}))' \
    "$1" "${2:-}" | python3 "$TOOL" hook pre
}
check "running subagent's Bash passes" '^$' "$(subpre Bash "make map GEN=x")"
check "running subagent's Edit passes" '^$' "$(subpre Edit)"
check "subagent dispatching an agent is refused" '"deny"' "$(subpre Agent)"
check "subagent gets no usage note" '^$' "$(usage 77 >/dev/null; printf '{"session_id":"s1","agent_id":"a1","tool_name":"Read"}' | python3 "$TOOL" hook post)"
check "other session not capped" '^$' "$(pre Agent "" s2)"
check "disarm" '^disarmed$' "$(python3 "$TOOL" disarm)"
check "disarmed: agent allowed" '^$' "$(pre Agent)"
# the window resets -> the budget goes
usage 76 1 >/dev/null; python3 "$TOOL" arm 75 g >/dev/null
check "reset window disarms" '^$' "$(pre Agent)"
check "reset window removed file" '^not armed' "$(python3 "$TOOL" status | tail -1)"
# SessionEnd
usage 76 >/dev/null; python3 "$TOOL" arm 75 g >/dev/null
echo '{"session_id":"s1"}' | python3 "$TOOL" hook end
check "session end disarms" '^$' "$(pre Agent)"
check "garbage stdin never fails" '^$' "$(echo 'not json' | python3 "$TOOL" hook pre; echo -n)"
check "no figure warns at arm" 'WARNING: no usage figure' "$(rm -f "$USAGE_CAP_DIR"/latest*.json; python3 "$TOOL" arm 75 g)"
# another account's session redraws its status line: this session keeps reading its own figure (2026-10-10, 21% vs 88%)
python3 "$TOOL" disarm >/dev/null; usage 21 >/dev/null; python3 "$TOOL" arm 90 g >/dev/null
printf '{"session_id":"otthem","rate_limits":{"seven_day":{"used_percentage":95,"resets_at":9999999999}}}' | python3 "$TOOL" statusline >/dev/null
check "own reading, not another account's" '7-day 21%' "$(python3 "$TOOL" status | head -1)"
check "another account's figure never caps" '^$' "$(pre Agent)"


# ---- the weekly soft cap (per account)
python3 "$TOOL" disarm >/dev/null
sread() {  # sid account seven_day [resets_at]
  printf '{"session_id":"%s","rate_limits":{"seven_day":{"used_percentage":%s,"resets_at":%s},"five_hour":{"used_percentage":5}}}' \
    "$1" "$3" "${4:-9999999999}" | USAGE_CAP_CLAUDE_JSON="$ACCTS/$2.json" python3 "$TOOL" statusline
}
spost() { printf '{"session_id":"%s","tool_name":"Read","tool_input":{}}' "$1" | python3 "$TOOL" hook post; }
check "no account file: plain line" '^7d 50% · cap 90%$' "$(printf '{"session_id":"x","rate_limits":{"seven_day":{"used_percentage":50}}}' | USAGE_CAP_CLAUDE_JSON=/nonexistent python3 "$TOOL" statusline)"
check "alex's line names them" '^Alex · 7d 40%' "$(sread jm alex 40)"
sread e1 eli 89 >/dev/null; sread e2 eli 89 >/dev/null
check "under default 90: silent" '^$' "$(spost e1)"
sread e1 eli 90 >/dev/null; sread e2 eli 90.5 >/dev/null
check "at 90: wind-down" "WEEKLY SOFT CAP REACHED on Eli's account: 7-day usage 90% >= soft cap 90%" "$(spost e1)"
check "wind-down says save, don't finish" 'Do NOT try to finish the task.*commit the work locally.*branch' "$(spost e2)"
check "wind-down once" '^$' "$(sread e1 eli 92 >/dev/null; spost e1)"
check "alex's session unaffected by eli's cap" '^$' "$(spost jm)"
check "subagent gets no wind-down" '^$' "$(sread e3 eli 92 >/dev/null; printf '{"session_id":"e3","agent_id":"a","tool_name":"Read"}' | python3 "$TOOL" hook post)"
check "below backstop: agents allowed" '^$' "$(pre Agent "" e1)"
check "below backstop: edits allowed" '^$' "$(pre Edit "" e1)"
check "raise to 95 (this session's account)" '^Eli <eli@example.org>: soft cap 95%, hard stop at 100%$' "$(CLAUDE_CODE_SESSION_ID=e1 python3 "$TOOL" cap 95)"
check "statusline shows the raised cap" 'cap 95%' "$(sread e1 eli 92)"
check "raised: silent between caps" '^$' "$(sread e1 eli 94 >/dev/null; spost e1)"
check "raised: fires again at the new cap" 'soft cap 95%' "$(sread e1 eli 95 >/dev/null; spost e1)"
check "alex's cap still the default" '^Alex.*soft cap 90%' "$(python3 "$TOOL" cap | grep Alex)"
check "cap by name" '^Alex <alex@example.org>: soft cap 50%' "$(python3 "$TOOL" cap 50 --account alex)"
check "lowered below usage: fires at once" "on Alex's account: 7-day usage 60% >= soft cap 50%" "$(sread jm alex 60 >/dev/null; spost jm)"
check "eli unaffected by alex's cap" '^$' "$(sread e4 eli 60 >/dev/null; spost e4)"
check "unknown account refused" 'no single account matches' "$(python3 "$TOOL" cap 50 --account bob 2>&1)"
python3 "$TOOL" cap 80 >/dev/null  # s1's account (eli)
check "backstop: alex at 55 (50+5) refused" '"deny"' "$(sread jm alex 55 >/dev/null; pre Agent "" jm)"
check "backstop reason names the raise" 'Only Eli lifts this, by raising the cap' "$(pre Edit "" jm)"
check "backstop: git push passes" '^$' "$(pre Bash "git push -u origin wip/x" jm)"
check "backstop: reading passes" '^$' "$(pre Read "" jm)"
check "backstop: running subagent's edit passes" '^$' "$(printf '{"session_id":"jm","agent_id":"a","tool_name":"Edit","tool_input":{}}' | python3 "$TOOL" hook pre)"
check "eli at 84 (cap 80): not blocked" '^$' "$(sread e5 eli 84 >/dev/null; pre Agent "" e5)"
check "eli at 85: blocked" '"deny"' "$(sread e5 eli 85 >/dev/null; pre Agent "" e5)"
check "raising lifts the backstop" '^$' "$(python3 "$TOOL" cap 90 >/dev/null; pre Agent "" e5)"
# a new week: the old window's figure is stale and ignored; the next week warns again
sread w1 eli 96 1 >/dev/null
check "reset window: stale figure ignored" '^$' "$(spost w1; pre Agent "" w1)"
sread w2 eli 91 1000 >/dev/null; spost w2 >/dev/null; sread w2 eli 91 9999999999 >/dev/null
check "new window warns again" 'SOFT CAP REACHED' "$(spost w2)"
check "status shows soft cap" 'soft cap 90%, hard stop at 95% \(this session was told to wind down\)' "$(CLAUDE_CODE_SESSION_ID=w2 python3 "$TOOL" status)"
echo '{"session_id":"w2"}' | python3 "$TOOL" hook end
check "session end forgets the session" '^$' "$(ls "$USAGE_CAP_DIR" | grep -- '-w2\.json')"
check "both accounts listed" 'Eli <eli@example.org>: soft cap 90%.*' "$(python3 "$TOOL" cap | grep Eli)"

# the login token decides the account, not ~/.claude.json's stale profile (2026-10-24: after /login the line still named the other account)
echo '{"claudeAiOauth":{"accessToken":"tokA","refreshToken":"refA"}}' >"$ACCTS/cred.json"
h() { printf %s "$1" | sha256sum | cut -d' ' -f1; }
printf '{"%s":{"uuid":"u-eli","email":"eli@example.org","name":"Eli"}}' "$(h refA)" >"$USAGE_CAP_DIR/tokens.json"
tok() { printf '{"session_id":"t1","rate_limits":{"seven_day":{"used_percentage":30}}}' | USAGE_CAP_CREDENTIALS="$ACCTS/cred.json" USAGE_CAP_CLAUDE_JSON="$ACCTS/alex.json" python3 "$TOOL" statusline; }
check "token's account beats a stale profile" '^Eli · ' "$(tok)"
check "refreshed access token cached too" "$(h tokA)" "$(cat "$USAGE_CAP_DIR/tokens.json")"
check "tokens are stored only as hashes" '^$' "$(grep -l 'tokA\|refA' "$USAGE_CAP_DIR"/*.json)"
echo '{"claudeAiOauth":{"accessToken":"tokB","refreshToken":"refB"}}' >"$ACCTS/cred.json"
check "unknown token, lookup fails: profile fallback" '^Alex · ' "$(tok)"

# the 5-hour window is gone (2026-11): never shown, even if Claude Code still sends it
check "no 5h segment" '^Eli · 7d 60% \(resets [^)]*\) · cap 90%$' "$(usage 60)"

printf 'usage-cap self-test: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
