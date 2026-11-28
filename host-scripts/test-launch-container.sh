#!/usr/bin/env bash
# Tests for launch-container.sh's mounts, against a FAKE podman that records `podman run`'s
# arguments (no container is started). Run: host-scripts/test-launch-container.sh  (exit 0 = all green)
# Covers the workdir (/<folder name>), the /host-scripts mounts, session messaging (shared socket folder, pid slots, another-account projects included; private registry with CONTAINER_PEERS=0) and the .volume-overrides/ account override.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)"
FAIL=0
ok()  { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; FAIL=1; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# Fake podman: no container exists or runs; `run` records its args one per line; the rest succeed quietly.
mkdir -p "$T/bin"
cat > "$T/bin/podman" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  container) exit 1 ;;                         # container exists -> no
  ps|port|inspect|info) exit 0 ;;
  run) shift; printf '%s\n' "$@" > "$FAKE_RUN_ARGS"
       # Like real podman: two mounts at one destination is an error (this bit us, 2026-10-03).
       dup=$(grep -A1 -x -- --volume "$FAKE_RUN_ARGS" | grep -v -x -e --volume -e -- | cut -d: -f2 | sort | uniq -d)
       [ -z "$dup" ] || { echo "Error: $dup: duplicate mount destination" >&2; exit 125; }
       echo fakeid ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$T/bin/podman"
export PATH="$T/bin:$PATH" CONTAINER_SLICE="" CLAUDE_SRC="$T/home" HOST_SCRIPT_PROPOSALS="$T/proposals" CONTAINER_CLIPBOARD="$T/clipboard"
mkdir -p "$T/home/.claude"
export XDG_RUNTIME_DIR="$T/run"; mkdir -p "$XDG_RUNTIME_DIR"
echo '{"oauthAccount":{"emailAddress":"host@example.com"},"hasCompletedOnboarding":true}' > "$T/home/.claude.json"

newrepo() { # newrepo <name>: a git repo with a CLAUDE.md, ignoring .volume-overrides/ unless told not to
  local r="$T/$1"; mkdir -p "$r"; git -C "$r" init -q
  echo '# test repo' > "$r/CLAUDE.md"
  [ "${2:-}" = noignore ] || echo '.volume-overrides/' > "$r/.gitignore"
}
launch() { # launch <repo>: run the launcher there; output in $OUT, run args in $T/<repo>.args
  export FAKE_RUN_ARGS="$T/$1.args"; : > "$FAKE_RUN_ARGS"
  OUT=$(cd "$T/$1" && bash "$HERE/launch-container.sh" --no-pull --no-apt --no-update --no-setup --no-shell --no-ports 2>&1)
}
vols() { grep -A1 -x -- --volume "$T/$1.args" | grep -v -x -e --volume -e --; }

# --- set_git_identity (runs only on the shell path, so tested on its own): the container gets the
# HOST's global git identity, passed as env, never a hardcoded one; no host identity sets nothing.
gid() ( # gid <name> <email>: run the function with a stub podman; prints the exec args, one per line
  eval "$(sed -n '/^set_git_identity() {/,/^}/p' "$HERE/launch-container.sh")"
  podman() { printf '%s\n' "$@"; }
  export GIT_CONFIG_GLOBAL="$T/gitconfig-$RANDOM"; : > "$GIT_CONFIG_GLOBAL"
  [ -n "$1" ] && git config --global user.name "$1" && git config --global user.email "$2"
  NAME=fakebox set_git_identity
)
GID=$(gid "Test Person" "test@example.com")
check "git identity: the host's name and email are passed to the container" 'grep -qx "GIT_ID_NAME=Test Person" <<<"$GID" && grep -qx "GIT_ID_EMAIL=test@example.com" <<<"$GID"'
check "git identity: no hardcoded identity in the launcher" '! grep -q "user.email [a-z]*@" "$HERE/launch-container.sh"'
check "git identity: unset on the host -> no podman exec at all" '[ -z "$(gid "" "")" ]'

# --- no .volume-overrides/: nothing extra, no override line
newrepo plain
launch plain
check "launches (fake run recorded)" '[ -s "$T/plain.args" ]'
check "host-scripts mounted read-only" 'vols plain | grep -q ":/host-scripts:ro,z$"'
check "proposals queue mounted read-write" 'vols plain | grep -q ":/proposed-host-script-updates:z$"'
check "clipboard bridge folder mounted" 'vols plain | grep -qx "$T/clipboard:/clipboard-bridge:z"'
check "session messaging: host socket folder mounted at the same path" 'vols plain | grep -qx "$T/run/cc-socks:$T/run/cc-socks:z" && [ "$(stat -c %a "$T/run/cc-socks")" = 700 ]'
check "session messaging: XDG_RUNTIME_DIR passed so sessions put their sockets there" 'grep -A1 -x -- --env "$T/plain.args" | grep -qx "XDG_RUNTIME_DIR=$T/run"'
check "session messaging: registry shared (no private one mounted over it)" '! vols plain | grep -q ":/home/agent/.claude/sessions:"'
check "session messaging: launch says so" 'grep -q "session messaging: sharing the session list" <<<"$OUT"'
check "pid slot recorded for the container" 'grep -qx "1 claude-plain" "$T/home/.claude/container-pid-slots"'
check "no override mounts without the folder" '! vols plain | grep -q "volume-overrides"'
check "no override line without the folder" '! grep -q "volume-overrides" <<<"$OUT"'

# --- the workdir is /<folder name>, never a shared /workspace
check "workdir defaults to /<folder name>" 'grep -A1 -x -- --workdir "$T/plain.args" | tail -1 | grep -qx /plain'
check "repo mounted at /<folder name>" 'vols plain | grep -qx "$T/plain:/plain:Z"'
newrepo overridden; echo '<!-- container-workdir: /elsewhere -->' >> "$T/overridden/CLAUDE.md"
launch overridden
check "container-workdir still overrides" 'grep -A1 -x -- --workdir "$T/overridden.args" | tail -1 | grep -qx /elsewhere'
newrepo usr
launch usr
check "a folder named like a system dir is refused, with the fix" '[ ! -s "$T/usr.args" ] && grep -q "would mount over the container.s /usr" <<<"$OUT" && grep -q "container-workdir: /some-name" <<<"$OUT"'
mkdir -p "$T/odd name"; git -C "$T/odd name" init -q; echo '# x' > "$T/odd name/CLAUDE.md"
export FAKE_RUN_ARGS="$T/odd.args"; : > "$FAKE_RUN_ARGS"
OUT=$(cd "$T/odd name" && bash "$HERE/launch-container.sh" --no-pull --no-apt --no-update --no-setup --no-shell --no-ports 2>&1)
check "a folder name with a space is refused, with the fix" '[ ! -s "$T/odd.args" ] && grep -q "not a plain name" <<<"$OUT"'

# --- .volume-overrides/ present but empty: both files created, mounted after ~/.claude
newrepo other
mkdir "$T/other/.volume-overrides"
launch other
V="$T/other/.volume-overrides"
check "launch line names both overrides" 'grep -qx ">> volume-overrides: .claude.json, .claude/.credentials.json (from other)" <<<"$OUT"'
check "credentials created as {} (logged out)" '[ "$(cat "$V/.claude/.credentials.json")" = "{}" ]'
check ".claude.json seeded from the host's, minus oauthAccount" 'python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if \"oauthAccount\" not in d and d.get(\"hasCompletedOnboarding\") else 1)" "$V/.claude.json"'
check "files are regular files, mode 600; folders 700" '[ -f "$V/.claude.json" ] && [ "$(stat -c %a "$V/.claude.json" "$V/.claude/.credentials.json" "$V" "$V/.claude" | tr "\n" " ")" = "600 600 700 700 " ]'
check "another account: session messaging shared like any project (socket folder, XDG_RUNTIME_DIR, no private registry)" 'vols other | grep -qx "$T/run/cc-socks:$T/run/cc-socks:z" && grep -A1 -x -- --env "$T/other.args" | grep -qx "XDG_RUNTIME_DIR=$T/run" && ! vols other | grep -q ":/home/agent/.claude/sessions:" && grep -q "session messaging: sharing the session list" <<<"$OUT"'
check "another account: gets a pid slot (the shared registry needs the offset)" 'grep -qx "[0-9]* claude-other" "$T/home/.claude/container-pid-slots"'
CONTAINER_PEERS=0 launch other
check "CONTAINER_PEERS=0: own session registry (mode 700), after ~/.claude, and no socket folder" '[ "$(vols other | grep -n -e ":/home/agent/.claude:z$" | cut -d: -f1)" -lt "$(vols other | grep -n -x -e "$T/home/.claude/container-sessions/[^:]*:/home/agent/.claude/sessions:z" | cut -d: -f1)" ] && [ "$(stat -c %a "$T"/home/.claude/container-sessions/*)" = 700 ] && ! vols other | grep -q cc-socks && ! grep -q "XDG_RUNTIME_DIR" "$T/other.args" && grep -q "session messaging: off for" <<<"$OUT"'
launch other
check "override mounts come after the ~/.claude mount" '[ "$(vols other | grep -n -e ":/home/agent/.claude:z$" | cut -d: -f1)" -lt "$(vols other | grep -n -e "credentials.json:/home/agent/.claude/.credentials.json:z$" | cut -d: -f1)" ]'
check "override .claude.json REPLACES the host's mount (one mount there, no duplicate)" '[ "$(vols other | grep -c ":/home/agent/.claude.json:")" = 1 ] && vols other | grep -q "volume-overrides/.claude.json:/home/agent/.claude.json:z$" && ! grep -q "duplicate mount" <<<"$OUT"'
check "host config untouched" 'grep -q oauthAccount "$T/home/.claude.json" && [ ! -e "$T/home/.claude/.credentials.json" ]'

# --- existing files are kept, not reseeded
echo '{"claudeAiOauth":{"accessToken":"x"}}' > "$V/.claude/.credentials.json"
launch other
check "an existing login is kept" 'grep -q accessToken "$V/.claude/.credentials.json" && ! grep -q "volume-overrides: created" <<<"$OUT"'

# --- a stray file is ignored, with a warning
touch "$V/.bashrc"
launch other
check "stray file: warned and not mounted" 'grep -q "ignoring .volume-overrides/.bashrc (not on the allowlist" <<<"$OUT" && ! vols other | grep -q bashrc'
rm "$V/.bashrc"

# --- symlinks are refused (a container could otherwise point one at the host's SSH key)
echo secret > "$T/home/id_ed25519"
rm "$V/.claude.json"; ln -s "$T/home/id_ed25519" "$V/.claude.json"
launch other
check "symlinked file: warned, not mounted" 'grep -q ".volume-overrides/.claude.json (or its folder) is a symlink" <<<"$OUT" && ! vols other | grep -q "id_ed25519\|volume-overrides/.claude.json"'
check "symlinked file: the other override still applies" 'grep -qx ">> volume-overrides: .claude/.credentials.json (from other)" <<<"$OUT"'
rm "$V/.claude.json"
mv "$V/.claude" "$T/realclaude"; ln -s "$T/realclaude" "$V/.claude"
launch other
check "symlinked folder: credentials not mounted" '! vols other | grep -q "credentials.json:/home/agent"'
rm "$V/.claude"; mv "$T/realclaude" "$V/.claude"
newrepo linked; ln -s "$V" "$T/linked/.volume-overrides"
launch linked
check "symlinked .volume-overrides/: ignored entirely" 'grep -q "is a symlink; ignoring it" <<<"$OUT" && ! vols linked | grep -q volume-overrides'

# --- not gitignored: warned, with the fix
newrepo leaky noignore
mkdir "$T/leaky/.volume-overrides"
launch leaky
check "not gitignored: warning carries the fix" 'grep -q "NOT gitignored" <<<"$OUT" && grep -q "echo .\.volume-overrides/. >> " <<<"$OUT"'

# --- a directory where a file belongs (podman's failure mode) is refused
newrepo dirbug
mkdir -p "$T/dirbug/.volume-overrides/.claude.json"
launch dirbug
check "directory in place of a file: warned, not mounted" 'grep -q "not a regular file" <<<"$OUT" && ! vols dirbug | grep -q "volume-overrides/.claude.json:"'

# --- the shell on a RUNNING container: plain launch = new tmux session; --resume = the menu
mkdir -p "$T/runbin"
cat > "$T/runbin/podman" <<'EOF2'
#!/usr/bin/env bash
case "$1" in
  ps) echo runid ;;                            # running
  exec) shift
        if [ "$1" = -it ]; then echo "EXEC-IT: $*"                # the final interactive exec
          # FAKE_DROPS: that many attaches end like a dropped connection (255) before one ends cleanly
          n=$(cat "$FAKE_DROPS" 2>/dev/null || echo 0); [ "$n" -gt 0 ] || exit 0
          echo $((n - 1)) > "$FAKE_DROPS"; exit 255; fi
        case "$*" in *has-session*) [ ! -e "$FAKE_SESSION_GONE" ]; exit ;; *"new-session -d"*) echo 7; exit ;; esac
        if [ "$2" = bash ] && [ "$3" = -c ]; then shift 3; HOME="$FAKE_HOME" bash -c "$@"; exit; fi  # history seeding
        case "$*" in *list-sessions*) [ -z "${FAKE_SESSIONS:-}" ] || { printf "$FAKE_SESSIONS"; exit; }; printf '0\tclaude-a\tWAITING - no terminal attached\t(x)\n1\tclaude-b\tWAITING - no terminal attached\t(y)\n' ;; esac ;;
  *) exit 0 ;;
esac
EOF2
chmod +x "$T/runbin/podman"
newrepo running
export FAKE_HOME="$T/agenthome"; mkdir -p "$FAKE_HOME"
export FAKE_DROPS="$T/drops" FAKE_SESSION_GONE="$T/session-gone"
echo 'alias mine=1' > "$FAKE_HOME/.bashrc"
printf '%s\n' 'ls' 'claude --dangerously-skip-permissions' 'make test' 'claude --dangerously-skip-permissions --continue' > "$FAKE_HOME/.bash_history"
shell() { OUT=$(cd "$T/running" && PATH="$T/runbin:$PATH" bash "$HERE/launch-container.sh" "$@" 2>&1); }
OUT=$(cd "$T/running" && printf '\n' | PATH="$T/runbin:$PATH" script -qec "bash '$HERE/launch-container.sh'" /dev/null 2>&1)  # a tty, so the old menu would show
check "plain launch opens a NEW tmux session, no menu" 'grep -q "EXEC-IT: .*tmux -u attach -d -t =7" <<<"$OUT" && ! grep -q "Up/Down" <<<"$OUT"'
check "plain launch notes the waiting sessions and --resume" 'grep -q "2 tmux session(s) WAITING.*launch-container --resume" <<<"$OUT"'
OUT=$(cd "$T/running" && printf '\e[B\n' | PATH="$T/runbin:$PATH" script -qec "bash '$HERE/launch-container.sh' --resume" /dev/null 2>&1)
check "--resume shows the menu; Down+Enter attaches the first session" 'grep -q "Up/Down" <<<"$OUT" && grep -q "EXEC-IT: .*tmux -u attach -d -t =0" <<<"$OUT"'
check "a new shell makes the claude command the newest history entry, once" '[ "$(tail -1 "$FAKE_HOME/.bash_history")" = "claude --dangerously-skip-permissions" ] && [ "$(grep -cxF "claude --dangerously-skip-permissions" "$FAKE_HOME/.bash_history")" = 1 ]'
check "the rest of the history is kept, in order" '[ "$(head -3 "$FAKE_HOME/.bash_history" | tr "\n" "|")" = "ls|make test|claude --dangerously-skip-permissions --continue|" ]'
shell --no-tmux   # a second launch: the prompt block is replaced, not added again
cat > "$T/ps1.expected" <<'PS1EOF'
PS1='\[\e]0;\u:\w\a\]\u:\w\$ '
PS1EOF
check "~/.bashrc gets one prompt block (agent:/repo, sets the title), its own lines kept" '[ "$(grep -c ">>> launch-container prompt >>>" "$FAKE_HOME/.bashrc")" = 1 ] && grep "^PS1=" "$FAKE_HOME/.bashrc" | cmp -s - "$T/ps1.expected" && grep -qx "alias mine=1" "$FAKE_HOME/.bashrc"'
echo 'vim notes' >> "$FAKE_HOME/.bash_history"
shell --attach 1
check "attaching to a running session leaves the history alone" '[ "$(tail -1 "$FAKE_HOME/.bash_history")" = "vim notes" ]'
check "--attach NAME still attaches directly" 'grep -q "EXEC-IT: .*tmux -u attach -d -t =1" <<<"$OUT"'
check "a clean end with the session still there says how to return, and attaches once" 'grep -q "still running.*launch-container --attach 1" <<<"$OUT" && [ "$(grep -c EXEC-IT <<<"$OUT")" = 1 ]'
# A dropped connection (exit 255, session alive) reattaches by itself; a tty is needed to come back to.
tty_shell() { OUT=$(cd "$T/running" && PATH="$T/runbin:$PATH" script -qec "bash '$HERE/launch-container.sh' $*" /dev/null 2>&1 </dev/null); }
echo 2 > "$FAKE_DROPS"; tty_shell --attach 1
check "dropped connection: says so and reattaches until an attach ends cleanly" '[ "$(grep -c "EXEC-IT: .*attach -d -t =1" <<<"$OUT")" = 3 ] && [ "$(grep -c "dropped; session .1. kept running" <<<"$OUT")" = 2 ]'
echo 9 > "$FAKE_DROPS"; tty_shell --attach 1
check "dropped connection: gives up after 3 fast failures, with the command to return" '[ "$(grep -c EXEC-IT <<<"$OUT")" = 3 ] && grep -q "keeps dropping; giving up" <<<"$OUT" && grep -q "launch-container --attach 1" <<<"$OUT"'
echo 9 > "$FAKE_DROPS"; shell --attach 1
check "dropped connection without a terminal: no reattach" '[ "$(grep -c EXEC-IT <<<"$OUT")" = 1 ]'
echo 9 > "$FAKE_DROPS"; : > "$FAKE_SESSION_GONE"; tty_shell --attach 1; rm -f "$FAKE_SESSION_GONE" "$FAKE_DROPS"
check "an error with the session gone: no reattach" '[ "$(grep -c EXEC-IT <<<"$OUT")" = 1 ] && ! grep -q "Reattaching" <<<"$OUT"'
# Bare --attach: the only waiting session; else the only session, even one a dead client holds attached.
FAKE_SESSIONS='0\tclaude-a\tattached in a terminal\t(x)\n' shell --attach
check "--attach alone takes the only session even when it counts as attached (dropped tab)" 'grep -q "EXEC-IT: .*attach -d -t =0" <<<"$OUT"'
FAKE_SESSIONS='0\tclaude-a\tattached in a terminal\t(x)\n1\tclaude-b\tWAITING - no terminal attached\t(y)\n' shell --attach
check "--attach alone prefers the only WAITING session" 'grep -q "EXEC-IT: .*attach -d -t =1" <<<"$OUT"'
FAKE_SESSIONS='0\tclaude-a\tattached in a terminal\t(x)\n1\tclaude-b\tattached in a terminal\t(y)\n' shell --attach
check "--attach alone with several running and none waiting lists them, opens nothing" 'grep -q "several tmux sessions are running" <<<"$OUT" && ! grep -q EXEC-IT <<<"$OUT"'

# --- a STOPPED container whose mount source is gone: refused before `podman start`, with the fix
mkdir -p "$T/stopbin" "$T/still-here"
cat > "$T/stopbin/podman" <<EOF3
#!/usr/bin/env bash
case "\$1" in
  container) exit 0 ;;                         # exists
  ps) exit 0 ;;                                # not running
  inspect) case "\$*" in *Mounts*Source*) printf '%s|%s\n' "$T/still-here" /repo "\$FAKE_GONE" "\$FAKE_GONE_DST" ;; esac ;;
  start) echo started >> "$T/started" ;;
  *) exit 0 ;;
esac
EOF3
chmod +x "$T/stopbin/podman"
newrepo stopped
stopped() { OUT=$(cd "$T/stopped" && PATH="$T/stopbin:$PATH" bash "$HERE/launch-container.sh" --no-shell 2>&1); RC=$?; }
export FAKE_GONE="$T/old/host-scripts" FAKE_GONE_DST=/host-scripts
stopped
check "stopped container, host-scripts source gone: refused, not started" '[ "$RC" -ne 0 ] && [ ! -e "$T/started" ]'
check "the error prints the exact ln -s fix" 'grep -qF "ln -s '"'"'$HERE'"'"' '"'"'$T/old/host-scripts'"'"'" <<<"$OUT"'
check "the error warns that --fresh deletes the container" 'grep -q -- "--fresh.*deletes" <<<"$OUT"'
export FAKE_GONE="$T/old/data" FAKE_GONE_DST=/data
stopped
check "another missing source: named, generic fix" '[ "$RC" -ne 0 ] && grep -qF "$T/old/data (mounted at /data)" <<<"$OUT" && grep -q "ln -s NEW" <<<"$OUT"'
export FAKE_GONE="$T/still-here" FAKE_GONE_DST=/data
stopped
check "all sources present: the container is started" '[ "$RC" -eq 0 ] && [ -s "$T/started" ]'

# --- pid slots and the pid offset (session messaging): the functions on their own, with a stub podman
slots() ( # slots <container name> <existing containers...>: prints the slot (or runs $SLOT_CALL $SLOT_ARG)
  eval "$(sed -n '/^pid_slot() {/,/^}/p; /^PID_SLOT_SIZE=/p; /^peer_after_start() {/,/^}/p' "$HERE/launch-container.sh")"
  NAME="$1"; shift; EXISTING=" $* "
  podman() { case "$1" in container) [[ "$EXISTING" == *" $3 "* ]] ;; exec) printf '%s\n' "$@" > "$T/offset.args" ;; esac; }
  CLAUDE_SRC="$T/slots"; "${SLOT_CALL:-pid_slot}" ${SLOT_ARG+"$SLOT_ARG"}
)
rm -rf "$T/slots"
check "pid slots: first container gets 1, second gets 2, each keeps its own" '[ "$(slots claude-a)" = 1 ] && [ "$(slots claude-b claude-a)" = 2 ] && [ "$(slots claude-a claude-b)" = 1 ] && [ "$(slots claude-b claude-a)" = 2 ]'
check "pid slots: a removed container's slot is handed out again" '[ "$(slots claude-c claude-b)" = 1 ] && ! grep -q claude-a "$T/slots/.claude/container-pid-slots"'
SLOT_CALL=peer_after_start SLOT_ARG=/run/user/7/cc-socks slots claude-b claude-c
check "pid offset: runs as root with the socket folder and slot * 5000" 'grep -qx -- --user "$T/offset.args" && grep -qx claude-b "$T/offset.args" && [ "$(tail -2 "$T/offset.args" | tr "\n" " ")" = "/run/user/7/cc-socks 10000 " ]'
rm -f "$T/offset.args"; SLOT_CALL=peer_after_start SLOT_ARG="" slots claude-b claude-c
check "pid offset: nothing to do for a container without the socket folder" '[ ! -e "$T/offset.args" ]'
OFFSET_SH="$(sed -n "/^peer_after_start() {/,/^}/p" "$HERE/launch-container.sh" | sed -n "/sh -c '/,/done'/p" | sed "1s/.*sh -c '//; \$s/'.*//")"
mkdir -p "$T/rt/cc-socks"; BASE=$(( $(cat /proc/sys/kernel/ns_last_pid) + 300 )); sh -c "$OFFSET_SH" _ "$T/rt/cc-socks" "$BASE"
check "pid offset: the in-container command forks up to the base (real sh, this pid namespace)" '[ "$(cat /proc/sys/kernel/ns_last_pid)" -ge "$BASE" ] && [ "$(stat -c %a "$T/rt")" = 700 ]'

rm -rf "$T"
[ "$FAIL" -eq 0 ] && echo "all green" || { echo "FAILURES"; exit 1; }
