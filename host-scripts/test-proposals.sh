#!/usr/bin/env bash
# Tests for propose and host-script-proposals. Run: host-scripts/test-proposals.sh  (exit 0 = all green)
# Everything runs in a throwaway dir through the env seams (HOST_SCRIPTS_DIR, CLAUDE_CONFIG_DIR,
# HOST_SCRIPT_PROPOSALS_QUEUE / HOST_SCRIPT_PROPOSALS); nothing real is touched.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)"
FAIL=0
ok()   { echo "ok   - $1"; }
bad()  { echo "FAIL - $1"; FAIL=1; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

export HOST_SCRIPTS_DIR="$T/hs" CLAUDE_CONFIG_DIR="$T/claude"
export HOST_SCRIPT_PROPOSALS_QUEUE="$T/queue" HOST_SCRIPT_PROPOSALS="$T/queue"
export CLAUDE_CODE_SESSION_ID=sid-1
mkdir -p "$T/hs/sub" "$T/queue" "$T/claude/sessions" "$T/claude/projects/-x"
printf 'one\ntwo\nthree\nfour\nfive\nsix\nseven\n' > "$T/hs/launch-container.sh"
chmod 755 "$T/hs/launch-container.sh"
echo '{"pid":5,"sessionId":"sid-1","name":"Sim Feints","nameSource":"user"}' > "$T/claude/sessions/5.json"
P() { python3 "$HERE/propose" "$@"; }
R() { python3 "$HERE/host-script-proposals" "$@"; }

# --- the session name, and where the proposal lands
out=$(P launch-container.sh)
check "name from the status file, kebab-cased" '[ -f "$T/queue/sim-feints/launch-container.sh" ]'
check ".base is the starting version, read-only" 'cmp -s "$T/queue/sim-feints/launch-container.sh.base" "$T/hs/launch-container.sh" && [ ! -w "$T/queue/sim-feints/launch-container.sh.base" ]'
check ".why.md created" '[ -f "$T/queue/sim-feints/launch-container.sh.why.md" ]'
echo '{"type":"custom-title","customTitle":"old name"}' > "$T/claude/projects/-x/sid-1.jsonl"
echo '{"type":"custom-title","customTitle":"Renamed Later"}' >> "$T/claude/projects/-x/sid-1.jsonl"
P sub/new-tool >/dev/null
check "transcript's LAST /rename wins over the status file" '[ -f "$T/queue/renamed-later/sub/new-tool" ]'
check "a new file gets an empty .base" '[ -f "$T/queue/renamed-later/sub/new-tool.base" ] && [ ! -s "$T/queue/renamed-later/sub/new-tool.base" ]'
R drop renamed-later/sub/new-tool >/dev/null
check "drop removes the files and the empty dirs" '[ ! -e "$T/queue/renamed-later" ]'
rm "$T/claude/projects/-x/sid-1.jsonl"

# --- rerun never overwrites a proposal in progress
echo edited >> "$T/queue/sim-feints/launch-container.sh"
out=$(P launch-container.sh)
check "rerun keeps the edit and says so" 'tail -1 "$T/queue/sim-feints/launch-container.sh" | grep -q edited && echo "$out" | grep -q "already queued"'

# --- refusals, each with its fix in the message
out=$(P ../etc/passwd 2>&1); check "a path outside host-scripts is refused" 'echo "$out" | grep -q "bad path"'
out=$(CLAUDE_CODE_SESSION_ID=nope P launch-container.sh 2>&1); check "unknown session -> tells you --session NAME" 'echo "$out" | grep -q -- "--session NAME"'
out=$(HOST_SCRIPT_PROPOSALS_QUEUE="$T/none" P launch-container.sh 2>&1); check "no queue mount -> tells you --fresh" 'echo "$out" | grep -q -- "--fresh"'

# --- list / summary
check "summary names the session" 'R --summary | grep -q "1 host-script proposal(s) pending from sim-feints"'
check "list says ready" 'R | grep -q "sim-feints/launch-container.sh .*ready"'
check "diff, piped: the heading comes before the diff" 'R diff sim-feints/launch-container.sh | grep -n -e "^==== the proposed" -e "^+edited" | head -1 | grep -q "the proposed"'
rm -rf "$T/q2"; mkdir "$T/q2"
check "summary is silent on an empty queue" '[ -z "$(HOST_SCRIPT_PROPOSALS=$T/q2 R --summary)" ]'

# --- three-way merge keeps a change landed meanwhile
sed -i 's/^one$/ONE (landed on the host)/' "$T/hs/launch-container.sh"
check "list flags the host change" 'R | grep -q "changed since it was proposed"'
R merge sim-feints/launch-container.sh >/dev/null
check "merge keeps both the host change and the proposal" 'grep -q "ONE (landed" "$T/hs/launch-container.sh" && grep -q "^edited$" "$T/hs/launch-container.sh"'
check "merge keeps the file mode" '[ -x "$T/hs/launch-container.sh" ]'
R drop sim-feints/launch-container.sh >/dev/null

# --- a conflict writes nothing
P launch-container.sh >/dev/null
sed -i 's/^four$/four (proposal)/' "$T/queue/sim-feints/launch-container.sh"
sed -i 's/^four$/four (host)/' "$T/hs/launch-container.sh"
before=$(md5sum < "$T/hs/launch-container.sh")
out=$(R merge sim-feints/launch-container.sh 2>&1)
check "conflict: refuses, says how to resolve, leaves the file alone" 'echo "$out" | grep -q "git merge-file" && [ "$before" = "$(md5sum < "$T/hs/launch-container.sh")" ]'

rm -rf "$T"
[ "$FAIL" -eq 0 ] && echo "all green" || { echo "FAILURES"; exit 1; }
