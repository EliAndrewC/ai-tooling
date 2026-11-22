#!/usr/bin/env bash
# Tests for readme-guard.py: bash ~/.claude/hooks/test-readme-guard.sh
set -u
HOOK="$(dirname "$(readlink -f "$0")")/readme-guard.py"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0

expect() {  # expect <want-exit> <description> <json>
  local out code
  out="$(printf '%s' "$3" | python3 -I "$HOOK" 2>&1)"; code=$?
  if [ "$code" -eq "$1" ]; then pass=$((pass + 1)); echo "ok   - $2"
  else fail=$((fail + 1)); echo "FAIL - $2 (exit $code, wanted $1): $out"; fi
}

git init -q "$T/repo" && mkdir -p "$T/repo/docs/audio" "$T/loose/sub"
git -C "$T/repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
R="$T/repo"

expect 0 "top-level README allowed"         "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$R/README.md\"},\"cwd\":\"$R\"}"
expect 2 "subfolder README refused"         "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$R/docs/audio/README.md\"},\"cwd\":\"$R\"}"
expect 2 "relative path, any case, refused" "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"docs/readme.txt\"},\"cwd\":\"$R\"}"
expect 2 "README without extension refused" "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$R/docs/README\"},\"cwd\":\"$R\"}"
expect 0 "subfolder CLAUDE.md allowed"      "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$R/docs/audio/CLAUDE.md\"},\"cwd\":\"$R\"}"
expect 0 "README-ish name allowed"          "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$R/docs/readme_parser.py\"},\"cwd\":\"$R\"}"
expect 0 "outside any repo allowed"         "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$T/loose/sub/README.md\"},\"cwd\":\"$T\"}"
expect 0 "other tools ignored"              "{\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"$R/docs/README.md\"},\"cwd\":\"$R\"}"

echo hi > "$R/docs/README.md" && git -C "$R" add docs/README.md
expect 2 "commit with staged subfolder README refused" "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m x\"},\"cwd\":\"$R\"}"
expect 2 "git -C commit refused too"        "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $R commit -qm x\"},\"cwd\":\"$T\"}"
expect 0 "other git commands allowed"       "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git status\"},\"cwd\":\"$R\"}"
git -C "$R" restore --staged docs/README.md
echo hi > "$R/README.md" && git -C "$R" add README.md
expect 0 "commit with only a top-level README allowed" "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m x\"},\"cwd\":\"$R\"}"

out="$(printf '%s' "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$R/docs/audio/README.md\"},\"cwd\":\"$R\"}" | python3 -I "$HOOK" 2>&1)"
case "$out" in *"docs/audio/CLAUDE.md"*"git mv docs/audio/README.md docs/audio/CLAUDE.md"*) pass=$((pass + 1)); echo "ok   - refusal names the CLAUDE.md and the git mv";;
  *) fail=$((fail + 1)); echo "FAIL - refusal text: $out";; esac

echo "$pass passed / $fail failed"
[ "$fail" -eq 0 ]
