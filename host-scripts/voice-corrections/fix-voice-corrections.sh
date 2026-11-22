#!/usr/bin/env bash
#
# fix-voice-corrections.sh: install spacebar-watch, the system service that tells the voice-corrections
# Claude Code mod whether the space bar is held (so it never rewrites the prompt box mid-dictation).
# Reading keyboards needs the root:input devices; the service runs as eli with `input` as a supplementary
# group, so no other process gains keyboard access. See ~/this-laptop/docs/claude-code/CLAUDE.md
# (Voice corrections) and spacebar-watch.py's docstring.
#
# The script is copied to /opt/voice-corrections/ (root-owned) rather than run from the repo checkout, so a
# process running as eli can't edit code that runs with input-group access. Re-run after changing it.
#
# Run as your normal user; the script calls sudo.
#   fix-voice-corrections.sh           install or update, then start
#   fix-voice-corrections.sh --check   show the service and the state file (no sudo)
#   fix-voice-corrections.sh --undo    stop and remove the service
#
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
STATE_DIR="$HOME/.claude/voice-corrections"
UNIT=spacebar-watch.service

[ "$(id -u)" -eq 0 ] && { echo "Run this as your normal user, not root." >&2; exit 1; }
[ "$(id -un)" = eli ] || { echo "The unit runs as eli; edit User= in $UNIT first." >&2; exit 1; }

check() {
  systemctl is-active "$UNIT" >/dev/null 2>&1 && echo "service: active" || echo "service: NOT active (run fix-voice-corrections.sh)"
  if [ -f "$STATE_DIR/spacebar" ]; then
    v="$(cat "$STATE_DIR/spacebar")"
    if [ "$v" = 0 ]; then echo "space: held"; else echo "space: up since $(date -d "@$((v / 1000))" '+%F %T')"; fi
  else
    echo "state file: missing ($STATE_DIR/spacebar)"
  fi
}

case "${1:-}" in
  --check) check; exit 0 ;;
  --undo)
    sudo -v
    sudo systemctl disable --now "$UNIT" 2>/dev/null || true
    sudo rm -f "/etc/systemd/system/$UNIT"
    sudo rm -rf /opt/voice-corrections
    sudo systemctl daemon-reload
    rm -f "$STATE_DIR/spacebar"
    echo "Removed. The mod falls back to correcting on submit only."
    exit 0 ;;
  "") ;;
  *) echo "usage: $0 [--check|--undo]" >&2; exit 2 ;;
esac

sudo -v
mkdir -p "$STATE_DIR"
sudo install -d -m 755 -o root -g root /opt/voice-corrections
sudo install -m 644 -o root -g root "$HERE/spacebar-watch.py" /opt/voice-corrections/spacebar-watch.py
sudo install -m 644 -o root -g root "$HERE/$UNIT" "/etc/systemd/system/$UNIT"
sudo systemctl daemon-reload
sudo systemctl enable "$UNIT"
sudo systemctl restart "$UNIT"
sleep 1
check
echo "Test: hold space in any window and run 'fix-voice-corrections.sh --check' from another terminal, or watch: journalctl -u $UNIT -f"
