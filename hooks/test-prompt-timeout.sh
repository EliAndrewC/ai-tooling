#!/usr/bin/env bash
# Tests for prompt-timeout.py (PermissionRequest auto-deny). Ends "N passed, 0 failed".
H="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/prompt-timeout.py"
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
