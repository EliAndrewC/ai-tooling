#!/usr/bin/env bash
# End-to-end test of container-audio against a RUNNING container (no sudo, about 30 s):
#   cd ~/some-project && ~/ai-tooling/host-scripts/container-audio/test-container-audio.sh [container]
# Checks the host service, the container's wiring, that a stalled reader gets no POLLERR (the bug this
# fixes), that a recording starts live (no stale backlog), and that it is silence while space is up.
# It never opens the microphone. The real-mic check is by hand (CLAUDE.md, "Test").
set -u
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
C="${1:-claude-$(basename "$PWD")}"
FAIL=0
check() { if eval "$2"; then echo "ok   - $1"; else echo "FAIL - $1"; FAIL=1; fi; }
inside() { podman exec "$C" sh -c "$1" 2>&1; }
podman exec "$C" true 2>/dev/null || { echo "no running container '$C'"; exit 2; }

check "host service running" 'systemctl --user is-active -q container-audio'
check "host pipe exists for $C" '[ -p "$HERE/pipes/$C.fifo" ]'
check "container ALSA capture goes through hostmic" 'inside "grep -q \"capture.pcm \\\"hostmic\\\"\" /etc/asound.conf"'
check "container PulseAudio, relay and drain alive" 'inside "for f in pid relay.pid drain.pid; do kill -0 \$(cat /tmp/container-audio/\$f) || exit 1; done"'
OUT=$(inside "timeout 30 python3 -I /host-scripts/test-capture-stall.py default 2" | tail -1)
check "reader stalled 2 s: no POLLERR, stream running ($OUT)" 'grep -q " 0 POLLERR" <<<"$OUT" && grep -q "state=3" <<<"$OUT"'
T=$(inside 's=$(date +%s%N); arecord -q -D default -f S16_LE -c1 -r16000 -d 2 -t raw /tmp/cat-test.raw; echo $(( ($(date +%s%N) - s) / 1000000 ))')
check "a 2 s recording takes ~2 s, so it starts live (took ${T} ms)" '[ "${T:-0}" -ge 1800 ] 2>/dev/null'
[ "$(cat ~/.claude/voice-corrections/spacebar 2>/dev/null)" = 0 ] \
  || check "silence while space is up (mic closed)" 'inside "python3 -c \"import sys; sys.exit(any(open(\\\"/tmp/cat-test.raw\\\",\\\"rb\\\").read()))\""'
[ "$FAIL" -eq 0 ] && echo "all green" || { echo "FAILURES"; exit 1; }
