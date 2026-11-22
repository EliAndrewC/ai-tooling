#!/usr/bin/env bash
# SessionStart: warn, visibly, when this session runs without the voice-corrections mod, so a dictation
# rule that "doesn't work" is never really a session that never loaded the mod (2026-10-27: the
# character-sheet and diagram sessions ran without it for hours after it shipped, unnoticed).
# The mod loads from CLAUDE_CODE_PLUGIN_DIRS, which the shell sets when it starts: host ~/.bash_aliases,
# containers launch-container's ~/.bashrc block. See host-scripts/voice-corrections/CLAUDE.md in the ai-tooling repo.
case "${CLAUDE_CODE_PLUGIN_DIRS:-}" in *voice-corrections*) exit 0 ;; esac
if [ "$HOME" = /home/agent ]; then
  how="On the host, run launch-container for this repo, then start claude in a NEW tmux window (old shells keep the old environment)."
else
  how="Open a new terminal (or run: source ~/.bash_aliases), then restart claude (claude --resume to keep this conversation)."
fi
msg="voice-corrections mod NOT loaded in this session: dictation rules won't be applied here. $how"
printf '{"systemMessage": %s}\n' "$(printf '%s' "$msg" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')"
