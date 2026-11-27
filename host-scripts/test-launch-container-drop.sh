#!/usr/bin/env bash
# REAL test of launch-container's reattach after a dropped connection (attach_loop), against a running
# container. test-launch-container.sh only fakes the 255 exit; this one makes rootless podman really
# drop a `podman exec -it`: a throwaway tmux session floods output for 12 s while the terminal reads
# nothing for 14 s. podman then prints "Error: timed out waiting for file .../exit/..." and exits 255
# with the session alive. The flood has to start within a few seconds of the attach: starting it
# 6+ s later never dropped (tmux throttles a client that is already far behind). It is bounded by
# time, not size: a 300 MB flood crawls once a client is attached and kept dropping every reattach.
#
# Run from the project folder of a RUNNING container:  cd ~/some-project && test-launch-container-drop.sh
# Takes about a minute. Touches only its own tmux session ("droptest"); exit 0 = all green.
set -u
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
C="${1:-claude-$(basename "$PWD")}"
podman exec "$C" true 2>/dev/null || { echo "no running container '$C' (run this from its project folder, or pass the name)"; exit 2; }
LOG="$(mktemp)"; FAIL=0
check() { if eval "$2"; then echo "ok   - $1"; else echo "FAIL - $1"; FAIL=1; fi; }
has() { tr -d '\r' < "$LOG" | grep -a -q "$1"; }
podman exec "$C" tmux kill-session -t =droptest 2>/dev/null
# The launcher needs about 4 s before its client attaches, so the flood starts at 6 s.
podman exec "$C" tmux new-session -d -s droptest 'sleep 6; timeout 12 yes; sleep 120'
# Ctrl+b d at 50 s is the deliberate detach that must END the loop.
script -qec "bash '$HERE/launch-container.sh' --attach droptest; echo LAUNCHER-RC=\$?" /dev/null \
  < <(sleep 40; podman exec "$C" tmux show-options -w -t '=droptest:' window-size > "$LOG.size" 2>&1; sleep 10; printf '\x02d'; sleep 3) \
  | { sleep 14; cat > "$LOG"; }
check "the connection really dropped (podman's own error)" 'has "Error: timed out waiting for file"'
check "the launcher said so and reattached"                'has "dropped; session .droptest. kept running.*Reattaching"'
check "it did not give up"                                 '! has "giving up"'
check "a deliberate detach ended it cleanly"               'has "\[detached (from session droptest)\]" && has "LAUNCHER-RC=0"'
check "it said how to return"                              'has "launch-container --attach droptest"'
check "the repaint nudge left the window following the terminal's size (window-size not manual)" '[ -e "$LOG.size" ] && ! grep -q manual "$LOG.size"'
check "no dead client is left on the session"              '[ -z "$(podman exec "$C" tmux list-clients -t =droptest 2>/dev/null)" ]'
podman exec "$C" tmux kill-session -t =droptest 2>/dev/null
rm -f "$LOG" "$LOG.size"
[ "$FAIL" -eq 0 ] && echo "all green" || { echo "FAILURES"; exit 1; }
