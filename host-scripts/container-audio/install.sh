#!/usr/bin/env bash
# Install (or check) the host end of container-audio: the user service that feeds the mic into each
# dev container's read-only pipe while space is held. No sudo. Containers pick it up on their next
# launch-container (or --attach).   install.sh [--check]
set -eu
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
UNIT="$HOME/.config/systemd/user/container-audio.service"
if [ "${1:-}" = --check ]; then
  ok=1
  [ -f "$UNIT" ] && echo "ok   - unit installed" || { echo "FAIL - unit not installed: run $0"; ok=0; }
  systemctl --user is-active -q container-audio && echo "ok   - service running" \
    || { echo "FAIL - service not running: systemctl --user restart container-audio; journalctl --user -u container-audio -n 20"; ok=0; }
  [ -s "$HOME/.claude/voice-corrections/spacebar" ] && echo "ok   - space-bar state present" \
    || { echo "FAIL - no space-bar state: the mic never opens. Install spacebar-watch: fix-voice-corrections.sh (sudo)"; ok=0; }
  for f in "$HERE"/pipes/*.fifo; do [ -p "$f" ] && echo "     pipe: $(basename "$f")"; done
  [ "$ok" = 1 ]; exit
fi
mkdir -p -m 700 "$HERE/pipes" "$(dirname "$UNIT")"
cp "$HERE/container-audio.service" "$UNIT"
systemctl --user daemon-reload
systemctl --user enable --now container-audio
systemctl --user restart container-audio
"$0" --check
