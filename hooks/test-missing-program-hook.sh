#!/usr/bin/env bash
# test-missing-program-hook.sh - the self-test of missing-program-hook.sh (diagram feature 301, FR-026).
# Every listed form fires in a container, on both payload kinds and on every repetition; a found program, an unrelated
# failure, and every miss on the host stay silent. Run directly, or by the diagram repository's `make hooks-test`.
set -uo pipefail
HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/missing-program-hook.sh"
pass=0; fail=0
CT=$(mktemp -d); HOST=$(mktemp -d); trap 'rm -rf "$CT" "$HOST"' EXIT
mkdir -p "$CT/run" && : > "$CT/run/.containerenv"
mkdir -p "$HOST/proc/1" && echo "0::/user.slice" > "$HOST/proc/1/cgroup"

payload() {  # event command output -> JSON
  python3 -c 'import json,sys; ev,cmd,out=sys.argv[1:4]
d={"hook_event_name":ev,"tool_name":"Bash","tool_input":{"command":cmd},"session_id":"t"}
if ev=="PostToolUseFailure": d["error"]=out
else: d["tool_response"]={"stdout":out,"stderr":"","interrupted":False}
print(json.dumps(d))' "$1" "$2" "$3"
}
run() {  # root container_env event command output
  payload "$3" "$4" "$5" | MPH_ROOT="$1" MPH_CONTAINER_ENV="$2" bash "$HOOK"
}
expect() {  # want(fire|silent) label root env event command output
  local want=$1 label=$2; shift 2
  local out; out=$(run "$@")
  local got=silent; [ -n "$out" ] && got=fire
  if [ "$got" = "$want" ] && { [ "$got" = silent ] || grep -q 'passwordless sudo' <<<"$out"; }; then
    pass=$((pass+1))
  else
    fail=$((fail+1)); printf 'FAIL [%s] want %s got %s: %s\n' "$label" "$want" "$got" "$out"
  fi
}

# Each case: command@@output (both events are tried for every firing case; F: marks a failure-only case - a
# command that exits 0 on success, so its "no" can only arrive as a failure).
FIRING=(
  "resvg x.svg@@Exit code 127
bash: line 1: resvg: command not found"
  "foo --version@@Exit code 127
/bin/bash: foo: command not found"
  "sh -c bar@@Exit code 127
sh: 1: bar: not found"
  "env baz@@Exit code 127
env: 'baz': No such file or directory"
  "rg foo src@@Exit code 127
bash: rg: command not found"
  "which git-filter-repo@@Exit code 1"
  "command -v pandoc@@Exit code 1"
  "type pandoc@@Exit code 1
bash: type: pandoc: not found"
  "hash pandoc@@Exit code 1
bash: hash: pandoc: not found"
  "whereis pandoc@@pandoc:"
  "dpkg -s pandoc@@Exit code 1
dpkg-query: package 'pandoc' is not installed and no information is available"
  "dpkg -l pandoc@@Exit code 1
dpkg-query: no packages found matching pandoc"
  "apt list --installed pandoc@@Listing..."
  "apt-cache policy pandoc@@pandoc:
  Installed: (none)
  Candidate: 3.1"
  "pip show shapely2@@WARNING: Package(s) not found: shapely2"
  "python3 -m pip show shapely2@@WARNING: Package(s) not found: shapely2"
  "pip list | grep -i shapely2@@Exit code 1"
  "python3 -c 'import yaml'@@Exit code 1
ModuleNotFoundError: No module named 'yaml'"
  "F:test -x /usr/bin/pandoc@@Exit code 1"
  "F:[ -x /usr/local/bin/pandoc ] && echo ok@@Exit code 1"
  "ls /usr/bin/pandoc@@Exit code 2
ls: cannot access '/usr/bin/pandoc': No such file or directory"
  "which pandoc; echo done@@done"
)
for case in "${FIRING[@]}"; do
  cmd=${case%%@@*}; out=${case#*@@}; evs="PostToolUse PostToolUseFailure"
  case $cmd in F:*) cmd=${cmd#F:}; evs=PostToolUseFailure ;; esac
  for ev in $evs; do
    expect fire "$cmd ($ev)" "$CT" "" "$ev" "$cmd" "$out"
    expect fire "$cmd ($ev, again)" "$CT" "" "$ev" "$cmd" "$out"     # every time, no once-per-session limit
    expect silent "$cmd ($ev, host)" "$HOST" "" "$ev" "$cmd" "$out"  # the host: no markers, no notice
  done
done
# The container detected by the environment alone, and by cgroup.
expect fire "env-detected" "$HOST" "podman" PostToolUseFailure "which pandoc" "Exit code 1"
mkdir -p "$CT/cg/proc/1" && echo "0::/libpod_parent/x" > "$CT/cg/proc/1/cgroup"
expect fire "cgroup-detected" "$CT/cg" "" PostToolUseFailure "which pandoc" "Exit code 1"

SILENT=(
  "make append LINE='| a | which south side the survey counted; size | b |'@@appended"
  "cat >> notes.md <<'EOF'
which writes no attempt line until this feature lands.
type a word here; hash it out
EOF@@"
  "which git@@/usr/bin/git"
  "command -v python3@@/usr/bin/python3"
  "command -v cd@@cd"
  "type ls@@ls is /usr/bin/ls"
  "whereis git@@git: /usr/bin/git /usr/share/man/man1/git.1.gz"
  "dpkg -s resvg@@Package: resvg
Status: install ok installed"
  "apt list --installed resvg@@Listing...
resvg/now 0.38 amd64 [installed]"
  "pip show shapely@@Name: shapely
Version: 2.0"
  "pip list | grep -i shapely@@shapely   2.0.6"
  "ls /usr/bin/git@@/usr/bin/git"
  "ls missing.txt@@ls: cannot access 'missing.txt': No such file or directory"
  "echo hi > /tmp/nodir/out.log@@bash: line 1: /tmp/nodir/out.log: No such file or directory"
  "sed -n 38,46p test-missing-program-hook.sh@@env: 'baz': No such file or directory"
  "grep -r foo src@@Exit code 1"
  "make test@@Exit code 2
FAILED tests/test_x.py::test_y"
  "cat notes.txt@@the phrase command not found appears in prose here"
)
for case in "${SILENT[@]}"; do
  cmd=${case%%@@*}; out=${case#*@@}
  for ev in PostToolUse PostToolUseFailure; do
    expect silent "$cmd ($ev)" "$CT" "" "$ev" "$cmd" "$out"
  done
done
# Not Bash: silent.
printf '{"hook_event_name":"PostToolUse","tool_name":"Read","tool_input":{},"tool_response":"bash: x: command not found"}' \
  | MPH_ROOT="$CT" MPH_CONTAINER_ENV="" bash "$HOOK" | grep -q . && { fail=$((fail+1)); echo "FAIL [non-Bash tool fired]"; } || pass=$((pass+1))

printf 'missing-program-hook: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
