#!/usr/bin/env bash
# Tests for clipboard-bridge.py's folder watching, with --sink standing in for the clipboard (no GTK).
# Run: host-scripts/test-clipboard-bridge.sh  (exit 0 = all green)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)"
FAIL=0
ok()  { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; FAIL=1; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
D="$T/drop"; mkdir -p "$D"
echo "old text" > "$D/claude-old"                  # present at start: must not be copied
python3 "$HERE/clipboard-bridge.py" --dir "$D" --sink "cat > '$T/clip'; echo x >> '$T/count'" > "$T/log" 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null; rm -rf "$T"' EXIT
sleep 0.6
check "a file already there at start is not copied" '[ ! -e "$T/clip" ]'

printf 'héllo ✳ from the container' > "$D/.claude-a.tmp"; sleep 0.6
check "the writer's temp (dot) file is ignored" '[ ! -e "$T/clip" ]'
mv "$D/.claude-a.tmp" "$D/claude-a"; sleep 0.6
check "a new file is copied, UTF-8 intact" '[ "$(cat "$T/clip")" = "héllo ✳ from the container" ]'
sleep 0.6
check "an unchanged file is not copied again" '[ "$(wc -l < "$T/count")" = 1 ]'

printf 'second copy' > "$D/claude-a"; sleep 0.6
check "rewriting the same file copies again" '[ "$(cat "$T/clip")" = "second copy" ]'

echo secret > "$T/outside"; ln -s "$T/outside" "$D/claude-link"; sleep 0.6
check "a symlink is not followed" '[ "$(cat "$T/clip")" = "second copy" ]'

head -c 1100000 /dev/zero | tr '\0' a > "$D/claude-big"; sleep 0.6
check "over 1 MiB is refused, with a log line" '[ "$(cat "$T/clip")" = "second copy" ] && grep -q "claude-big: .* over the" "$T/log"'
check "the log never holds the copied text" '! grep -q "second copy\|héllo" "$T/log"'

# --- the host -> container direction: save_host_clipboard
H="$T/hostdir"; mkdir -p "$H"
hc() { python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import importlib; m = importlib.import_module("clipboard-bridge"); m.save_host_clipboard(sys.argv[2], sys.argv[3])' "$HERE" "$H" "$1"; }
hc 'copied on the host ✳'
check "host clipboard saved as .host-clipboard, mode 600" '[ "$(cat "$H/.host-clipboard")" = "copied on the host ✳" ] && [ "$(stat -c %a "$H/.host-clipboard")" = 600 ]'
hc ''
check "an empty (or non-text) clipboard removes the file" '[ ! -e "$H/.host-clipboard" ]'
check "the container-side wl-paste refuses image/primary requests" '! sh "$HERE/container-bin/wl-paste" --list-types && ! sh "$HERE/container-bin/wl-paste" --primary --no-newline'

[ "$FAIL" -eq 0 ] && echo "all green" || { echo "FAILURES"; exit 1; }
