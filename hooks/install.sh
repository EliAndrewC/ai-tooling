#!/usr/bin/env bash
# install.sh: copy this folder's hooks into ~/.claude/hooks/, where settings.json runs them.
#
#   hooks/install.sh           install (only files that differ; prints each one)
#   hooks/install.sh --force   install even over a live file that was edited by hand since the last install
#   hooks/install.sh --check   report drift and exit 1 if any file differs or is missing
#
# Why copies, not a symlink: dev containers mount ~/.claude and run "$HOME/.claude/hooks/...", so a
# symlink out of ~/.claude would dangle inside them. And a hook file must never be missing, even for a
# moment: `python3 missing.py` exits 2, which Claude Code treats as a BLOCK, so a hook with no matcher
# (usage_cap.py on PreToolUse) would refuse every tool call. Each file is therefore written to a temp
# file in the destination folder and renamed over the old one, which is atomic.
#
# Edit hooks here, in the repo, then run this. A session that can't see this repo (a container) can
# still edit ~/.claude/hooks/ directly, so install never silently overwrites such an edit: it keeps the
# sha256 of what it last installed in ~/.claude/hooks/.installed.sha256, and a live file whose hash no
# longer matches is refused until you copy the edit back here (or pass --force).
set -euo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
DEST="${CLAUDE_HOOKS_DIR:-$HOME/.claude/hooks}"
MANIFEST="$DEST/.installed.sha256"
MODE=install
case "${1:-}" in --check) MODE=check ;; --force) MODE=force ;; "") ;; *) echo "usage: $0 [--check|--force]" >&2; exit 2 ;; esac

sha() { sha256sum "$1" | cut -d' ' -f1; }
recorded() { [ -f "$MANIFEST" ] && awk -v n="$1" '$2 == n { print $1 }' "$MANIFEST" || true; }

drift=0 refused=0
mkdir -p "$DEST"
declare -A NEW
for src in "$HERE"/*.py "$HERE"/*.sh; do
  name="$(basename "$src")"
  [ "$name" = install.sh ] && continue
  dst="$DEST/$name"
  if [ -f "$dst" ] && cmp -s "$src" "$dst"; then NEW[$name]="$(sha "$src")"; continue; fi
  hand_edit=0
  if [ -f "$dst" ]; then
    last="$(recorded "$name")"
    [ -n "$last" ] && [ "$last" != "$(sha "$dst")" ] && hand_edit=1
  fi
  if [ "$MODE" = check ]; then
    if [ ! -f "$dst" ]; then echo "missing: $dst"
    elif [ "$hand_edit" = 1 ]; then echo "edited in place since the last install: $dst (diff $src $dst)"
    else echo "differs: $dst (diff $src $dst)"; fi
    drift=1; continue
  fi
  if [ "$hand_edit" = 1 ] && [ "$MODE" != force ]; then
    echo "REFUSED: $dst was edited in place since the last install. Copy the edit into $src" >&2
    echo "  (diff $src $dst), commit it, and re-run; or pass --force to discard it." >&2
    refused=1; [ -n "$(recorded "$name")" ] && NEW[$name]="$(recorded "$name")"; continue
  fi
  tmp="$(mktemp "$DEST/.$name.XXXXXX")"
  cp "$src" "$tmp"
  chmod --reference="$src" "$tmp"
  mv -f "$tmp" "$dst"
  NEW[$name]="$(sha "$src")"
  echo "installed: $dst"
done

if [ "$MODE" = check ]; then
  [ "$drift" = 0 ] && echo "hooks: ~/.claude/hooks matches the repo" || echo "fix: run $HERE/install.sh (or copy a hand edit back into $HERE first)"
  exit "$drift"
fi
tmp="$(mktemp "$DEST/.installed.XXXXXX")"
for n in "${!NEW[@]}"; do echo "${NEW[$n]} $n"; done | sort -k2 >"$tmp"
mv -f "$tmp" "$MANIFEST"
exit "$refused"
