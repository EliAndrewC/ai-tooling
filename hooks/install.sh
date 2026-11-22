#!/usr/bin/env bash
# install.sh: copy this folder's hooks into ~/.claude/hooks/, where settings.json runs them.
#
#   hooks/install.sh           install (only files that differ; prints each one)
#   hooks/install.sh --check   report drift and exit 1 if any file differs or is missing
#
# Why copies, not a symlink: dev containers mount ~/.claude and run "$HOME/.claude/hooks/...", so a
# symlink out of ~/.claude would dangle inside them. And a hook file must never be missing, even for a
# moment: `python3 missing.py` exits 2, which Claude Code treats as a BLOCK, so a hook with no matcher
# (usage_cap.py on PreToolUse) would refuse every tool call. Each file is therefore written to a temp
# file in the destination folder and renamed over the old one, which is atomic.
#
# Edit hooks here, in the repo, then run this. Hand edits in ~/.claude/hooks/ show up in --check.
set -euo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
DEST="${CLAUDE_HOOKS_DIR:-$HOME/.claude/hooks}"
MODE=install
[ "${1:-}" = --check ] && MODE=check

drift=0
mkdir -p "$DEST"
for src in "$HERE"/*.py "$HERE"/*.sh; do
  name="$(basename "$src")"
  [ "$name" = install.sh ] && continue
  dst="$DEST/$name"
  if [ -f "$dst" ] && cmp -s "$src" "$dst"; then continue; fi
  if [ "$MODE" = check ]; then
    if [ -f "$dst" ]; then echo "differs: $dst (diff $src $dst)"; else echo "missing: $dst"; fi
    drift=1
    continue
  fi
  tmp="$(mktemp "$DEST/.$name.XXXXXX")"
  cp "$src" "$tmp"
  chmod --reference="$src" "$tmp"
  mv -f "$tmp" "$dst"
  echo "installed: $dst"
done

if [ "$MODE" = check ]; then
  [ "$drift" = 0 ] && echo "hooks: ~/.claude/hooks matches the repo" || echo "fix: run $HERE/install.sh (or copy a hand edit back into $HERE first)"
  exit "$drift"
fi
