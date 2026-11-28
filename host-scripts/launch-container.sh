#!/usr/bin/env bash
#
# launch-container.sh - start or attach to a repo's Claude Code dev container.
#
# One container per repo, with a deterministic name, so you never again have to
# wonder "which of my containers is this, and did it get port mapping?".
#
# What it does:
#   * Derives a stable container name from the repo (<prefix>-<repo-dir-name>).
#   * If that container is ALREADY RUNNING, opens a fresh bash shell inside it
#     (podman exec) instead of starting a second container - and prints the
#     ports that container actually has published.
#   * Otherwise pulls the latest image, then starts a new DETACHED container
#     (podman run -d ... sleep infinity) and opens a bash shell inside it
#     (podman exec), mounting:
#       - the repo at /<repo folder name>, e.g. /diagram (or a container-workdir override)
#       - the host's ~/.claude.json and ~/.claude/ into /home/agent so Claude
#         Code auth, config, skills, and memory persist across containers
#       - this script's own folder (ai-tooling's host-scripts/) READ-ONLY at
#         /host-scripts, and the proposals queue READ-WRITE at
#         /proposed-host-script-updates (see "Host scripts" below)
#       - ~/.local/share/container-clipboard at /clipboard-bridge: the clipboard
#         bridge's drop folder (see host-scripts/clipboard-bridge.py)
#       - the host's Claude socket folder ($XDG_RUNTIME_DIR/cc-socks) at the same
#         path, so sessions here, on the host and in other containers can list
#         and message each other (see "Session messaging" near the mounts;
#         CONTAINER_PEERS=0 turns it off; another-account projects get it too)
#       - any extra host mounts the repo declares (see below)
#       - the project's .volume-overrides/ files, if it has that folder, on top of
#         the Claude config: a per-project Claude account (see "Per-project
#         Claude account" near the mounts)
#     publishing the ports the repo declares, passing the host's sound devices
#     through (see "Audio" below), and apt-installing the packages the repo
#     declares via container-apt.
#
# Because the container name is derived per repo (<prefix>-<repo-dir-name>),
# "already running" only ever matches the SAME repo: launching from gm-assistant
# twice attaches the second time, but launching from a different repo starts its
# own container.
#
# Container lifetime is decoupled from every terminal: PID 1 is `sleep infinity`
# and EVERY shell - including the first launch's - is a podman exec session, so
# exiting or closing any terminal never stops the container or kills the other
# shells. The container runs until explicitly removed (--fresh, or
# `podman rm -f <name>`). There is deliberately no --rm: a container stopped
# from outside (host reboot, podman stop) stays on disk, and the next launch
# restarts and re-attaches it instead of rebuilding from scratch.
#
# Per-repo config lives in the repo's CLAUDE.md as greppable HTML-comment lines.
# Format is HOST:CONTAINER (space-separated for multiples):
#
#   <!-- container-ports: 8080:8080 8091:8090 -->
#   <!-- container-mounts: ..:/host-l7r-repo -->
#   <!-- container-workdir: /gm-assistant -->
#   <!-- container-apt: libmagic1 antiword libcairo2 -->
#   <!-- container-setup: container-scripts/setup-dev-env.sh -->
#
# container-apt (optional) lists apt packages installed as root on a FRESH
# launch, on top of the baseline the script always installs (see "Audio").
# Attaching to an existing container installs nothing, so a changed list takes
# effect on the next --fresh. It is best-effort: a failed update/install warns
# and still drops you into the shell (you may just be offline). Skip it for a
# launch with --no-apt. This is for SYSTEM packages only - language-level deps
# (pip, npm, playwright browsers) belong to the repo's own setup script:
#
# container-setup (optional) names a script, relative to the repo root, that a
# FRESH launch runs inside the container as the default user from the workdir,
# after apt and `claude update`. It is the repo's half of provisioning - pip
# lockfiles, browsers, shell wrappers - and it must be idempotent, since a
# session may run it again by hand. Before this existed (2026-09-08) a rebuilt
# container came up with every mount and port and not one pip package, and the
# GM's `repl` died on its first import. Best-effort like apt; --no-setup skips.
#
# Where the repo is mounted and the shell starts: /<repo folder name> (~/l7r/diagram
# -> /diagram), always, unless the repo overrides it with container-workdir (no repo
# needs to). The name matters beyond tidiness: Claude Code keys each project's memory
# and session history under ~/.claude/projects/ off the cwd path, and ~/.claude is
# shared by every container. Until 2026-10-03 the default was one shared /workspace,
# so every repo without the directive shared one memory - one project's sessions loaded
# another's.
#
# Port convention: first is the repo's primary webapp, second the secondary
# (e.g. a blind-eval webapp). Host and container ports may differ so several
# repos that all serve on 8080 inside the container each get a distinct host port.
#
# Mount HOST paths may be absolute, start with ~ (the invoking user's home), or
# be RELATIVE TO THE REPO ROOT - so "..:/host-l7r-repo" mounts the repo's parent
# directory (where the sibling l7r notes repo lives) at /host-l7r-repo, wherever
# the tree is checked out (~/l7r/<repo>, /data/dev/l7r/<repo>, ...).
#
# Host scripts: this script lives in the ai-tooling repo (~/ai-tooling/host-scripts/, on
# PATH as `launch-container`; it moved out of gm-assistant's scripts/ on 2026-10-03). That
# folder is mounted READ-ONLY at /host-scripts in every container, so a session can read the
# script that launched it, and run /host-scripts/claude-diagnostics/client/host-diag. It is
# read-only because this script, and the sudo-installed diagnostics, run on the HOST as the
# user: a container that could edit them could act as that user, which defeats the container.
# A session that wants a change PROPOSES it instead: `/host-scripts/propose launch-container.sh`
# copies the file into /proposed-host-script-updates/<session-name>/ (the host's
# ~/.local/share/host-script-proposals/, READ-WRITE, shared by every container; override with
# HOST_SCRIPT_PROPOSALS), where a host Claude session reviews it before anything lands. The
# queue's rules are in host-scripts/CLAUDE.md.
#
# Audio: the container gets the host's sound devices (--device /dev/snd, when
# the host has any), alsa-utils, and a generated /etc/asound.conf pointing
# ALSA's "default" at the detected mic and speaker - so Claude Code's /voice can
# record. Since 2026-11-26 the MIC instead comes through the host's one-way pipe
# when the host runs the container-audio service (setup_container_audio; that
# generated config stays as /etc/asound.conf.raw, the fallback):
# host-scripts/container-audio/CLAUDE.md. All three are needed, and each missing piece fails differently:
#   * no device nodes -> /proc is NOT namespaced, so /proc/asound/cards shows
#     the host's mic and voice's availability probe passes; then the capture
#     floods the terminal with "cannot find card '0'" / "Unknown PCM default".
#   * devices but no asound.conf -> "audio open error: No such file or
#     directory", because stock ALSA aims "default" at hw:0,0 (see the
#     generation step near the bottom of this script for why that's wrong).
# This is raw ALSA access, bypassing the host's PulseAudio/PipeWire; that daemon
# suspends idle capture devices, so the mic is normally free, but a host app
# actively recording (a Zoom call) can make it "busy" until it lets go.
#
# Memory: every container gets its own hard cap (--memory, and no swap inside
# the container: an OOM kill is a loud signal that the tests' memory use has
# gone wrong, which is preferable to a silent slowdown into swap), and ALL the
# containers this script launches sit under one parent cgroup with its own,
# higher ceiling, so several containers running expensive tests at once cannot
# take the host down. See "shared memory ceiling" below for how and why; the
# numbers are the CONTAINER_* variables at the top of the script.
#
# Usage:
#   launch-container.sh [--name NAME] [--no-ports] [--no-claude] [--no-pull]
#                       [--no-apt] [--no-update] [--no-setup] [--fresh]
#                       [--no-shell] [--no-tmux] [--resume] [--attach [NAME]]
#                       [--help]
#
# Every shell opens inside a NEW tmux session in the container (--no-tmux gives
# the old plain bash). The reason is the connection, not tmux's features: under
# this laptop's rootless podman a `podman exec -it` session is dropped when the
# terminal falls behind a burst of output - a busy Claude session, or resuming a
# long one, is enough (measured 2026-09-26: `yes | head -c 300000000` through
# `podman exec -it` was cut off early, and a resumed session kept running,
# orphaned, after its tab was dropped). Inside tmux a dropped connection only
# DETACHES: the session keeps running, and the next launch says how many are
# waiting and how to get back to them (--resume). The config it writes (~/.tmux.conf, rewritten on
# every launch since the container's home does not persist) turns on tmux's mouse mode, which
# passes the mouse wheel through to Claude Code (whose fullscreen TUI scrolls the
# conversation), and it draws on the normal screen, so a plain shell's
# scrolled-off lines land in the terminal's own scrollback. Every exec also passes LANG=C.UTF-8
# (and tmux -u): the image sets no locale, and a non-UTF-8 client made tmux draw
# every non-ASCII glyph as "_".
#
# A plain launch always opens a NEW tmux session (one line notes any sessions
# already waiting). --resume instead shows an arrow-key menu over the running
# sessions (Enter alone still starts a new one) listing each one, whether a
# terminal is attached, and its title (Claude Code sets it to the session's name).
# --attach [NAME] reattaches without a menu - to pick a session up from another
# tab (the other tab is detached). With no NAME it takes the only waiting
# session, or the only session at all, and lists them when there are several.
#
# A dropped connection reattaches BY ITSELF (2026-11-26): the launcher stays
# behind the tmux client and, when `podman exec` ends with an error while the
# session is still alive, says so and attaches again (attach_loop). Measured:
# a drop exits 255 and leaves a dead client attached inside the container, a
# deliberate detach (Ctrl+b d) or being taken over by another tab exits 0.
# Before this the tab silently fell back to the host prompt, which looked like
# the session, and the unsent prompt in it, had been lost.
#
# --no-shell makes the script ENSURE the container is running and then return,
# instead of ending in an interactive `podman exec ... bash`. Every other step is
# unchanged - a fresh launch still pulls, mounts, publishes, installs and updates
# exactly as it would otherwise, so the container it leaves behind is the same one
# you would have got by hand; a running or stopped container is attached/started
# and reported on, then left alone. This is the entry point for scripts that need
# the container up before they do their own `podman exec`, which is how
# gm-assistant's `scripts/repl.py` starts the container when the GM runs `repl` on a cold host.
#
# A fresh launch first runs `podman pull` for the latest image; --no-pull skips
# that (offline, or to save time), as --no-apt skips the package install,
# --no-update skips the in-container `claude update` and --no-setup skips the
# repo's container-setup script. Every new shell (fresh container or not) starts
# with `claude --dangerously-skip-permissions` as its newest history entry, so the
# first thing you do is Up-Enter.
# The prompt is agent:/<repo> (not agent@<container id>), and it is also the
# tab title until Claude Code sets its own: a marked block in ~/.bashrc.
# Attaching to a running container never pulls, installs, or updates - except
# tmux, installed on the first launch into a container that predates it.
# --no-claude skips mounting the host ~/.claude.json and ~/.claude/ - use it on a
# shared/work machine so the container does NOT inherit that host's default Claude
# account (you log in fresh inside instead, on your own account). Point at a
# specific config dir with CLAUDE_SRC=/path (defaults to ~). Reusable across
# repos: run from any repo root; it reads the CURRENT repo's CLAUDE.md. Override
# the name prefix with CONTAINER_PREFIX, the image with CONTAINER_IMAGE, the
# per-container cap with CONTAINER_MEMORY, the shared ceiling with
# CONTAINER_SLICE_HIGH / CONTAINER_SLICE_MAX / CONTAINER_SLICE_SWAP_MAX, the CPU/disk priority with
# CONTAINER_SLICE_CPU_WEIGHT / CONTAINER_SLICE_IO_WEIGHT (empty = don't set), and the parent slice's
# name with CONTAINER_SLICE (empty = no shared ceiling, each container on its own cap).

set -euo pipefail

IMAGE="${CONTAINER_IMAGE:-docker.io/docker/sandbox-templates:claude-code}"
PREFIX="${CONTAINER_PREFIX:-claude}"
# Per-container hard cap, and the shared ceiling over every container together
# (GM 2026-09-08, on a 15.4 GB laptop whose desktop uses ~4.5 GB and which has
# host swap to absorb the desktop's cold pages while the containers are full).
# The per-container cap went 8g -> 10g because usually only one container is
# running, and then it is the diagram one, whose gate is the expensive thing.
# Shared ceiling went 11G/12G -> 9G/10G on 2026-09-28: with 3 containers full, the desktop
# had ~3.4 GB left, got swapped out, and crawled for 10 min (keys took minutes) until a
# hard reset. The swap bet does not hold once you use the desktop. (The laptop-side memory notes live in a private repo.)
# 2026-09-29: 9G/10G -> 9G/9G. The diagram container sat at the 9G throttle for 3 min, re-reading
# its evicted files nonstop; the disk stall froze the desktop (1.8 GB RAM still free) until another
# hard reset. With HIGH == MAX the kernel OOM-kills inside the container instead of throttling it.
# 2026-09-30: 9G/9G -> 10G/10G, swap 0. With no throttle band the extra gig costs no thrashing, and
# the desktop keeps the ~5.4 GB it had under 9G/10G. SWAP_MAX=0 stops the kernel from pushing the
# containers' memory into host swap at the cap (the same disk thrash by another road).
MEMORY="${CONTAINER_MEMORY:-10g}"
SLICE="${CONTAINER_SLICE-claude-containers.slice}"
SLICE_HIGH="${CONTAINER_SLICE_HIGH:-10G}"
SLICE_MAX="${CONTAINER_SLICE_MAX:-10G}"
SLICE_SWAP_MAX="${CONTAINER_SLICE_SWAP_MAX:-0}"
# 2026-10-02: the desktop also gets priority over the containers for disk and CPU. These are weights,
# not limits, so the containers still get everything the desktop isn't using. That day the diagram
# container thrashed at the cap, and the desktop waited 18 min behind its disk reads (hard reset).
# Default weight is 100, so the desktop's app.slice and session.slice each outweigh the containers
# 5x for CPU and 10x for disk. Set on the TOP slice (claude.slice for claude-containers.slice),
# because weights only compete among siblings. They do nothing until cpu+io are delegated to the
# user manager and the disk runs BFQ: a one-time sudo fix-memory-priority.sh in the private laptop repo.
SLICE_CPU_WEIGHT="${CONTAINER_SLICE_CPU_WEIGHT-20}"
SLICE_IO_WEIGHT="${CONTAINER_SLICE_IO_WEIGHT-10}"

die() { echo "error: $*" >&2; exit 1; }

show_help() {
  sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^#\{0,1\} \{0,1\}//'
  exit 0
}

# ---- parse args ----
NAME=""
PUBLISH_PORTS=1
FRESH=0
MOUNT_CLAUDE=1
PULL=1
APT=1
UPDATE=1
SETUP=1
SHELL_AFTER=1
TMUX_SHELL=1
RESUME=0
ATTACH=""
CLAUDE_SRC="${CLAUDE_SRC:-$HOME}"
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="${2:-}"; shift 2 ;;
    --no-ports) PUBLISH_PORTS=0; shift ;;
    --no-claude) MOUNT_CLAUDE=0; shift ;;
    --no-pull) PULL=0; shift ;;
    --no-apt) APT=0; shift ;;
    --no-update) UPDATE=0; shift ;;
    --no-setup) SETUP=0; shift ;;
    --fresh) FRESH=1; shift ;;
    --no-shell) SHELL_AFTER=0; shift ;;
    --no-tmux) TMUX_SHELL=0; shift ;;
    --resume) RESUME=1; shift ;;
    --attach)
      if [ $# -ge 2 ] && [ "${2#-}" = "$2" ]; then ATTACH="$2"; shift 2; else ATTACH="-"; shift; fi ;;
    -h|--help) show_help ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

command -v podman >/dev/null 2>&1 || die "podman not found on PATH"

# ---- locate the repo and its config ----
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
REPO_NAME="$(basename "$REPO_ROOT")"
[ -n "$NAME" ] || NAME="${PREFIX}-${REPO_NAME}"
CLAUDE_MD="$REPO_ROOT/CLAUDE.md"

# Resolve a declared host path: ~ -> the invoking user's home, relative -> against
# the repo root (so ".." is the repo's parent), absolute kept as-is; canonicalize.
resolve_host_path() {
  local p="$1"
  case "$p" in
    "~") p="$HOME" ;;
    "~/"*) p="$HOME/${p#\~/}" ;;
    /*) : ;;
    *) p="$REPO_ROOT/$p" ;;
  esac
  realpath -m "$p" 2>/dev/null || readlink -f "$p" 2>/dev/null || printf '%s' "$p"
}

# Read a greppable "<!-- key: a:b c:d -->" directive from CLAUDE.md, one token
# per line. Matches the HTML-comment form specifically so prose that merely
# mentions the key (e.g. these docs) is never picked up.
read_directive() {
  [ -f "$CLAUDE_MD" ] || return 0
  grep -m1 "<!-- $1:" "$CLAUDE_MD" 2>/dev/null \
    | sed "s/.*<!-- $1://; s/-->.*//" \
    | tr -s ' \t' '\n' \
    | sed '/^$/d' || true
}

# Where to mount the repo and start the shell: /<repo folder name> (see the header), or
# the repo's container-workdir override. A folder name that is not a plain name, or that
# would land on one of the image's own top-level directories, is refused rather than
# mounted over /usr or /home.
WORKDIR="$(read_directive container-workdir | head -n1)"
if [ -z "$WORKDIR" ]; then
  case "$REPO_NAME" in
    bin|boot|dev|etc|home|lib|lib32|lib64|libx32|media|mnt|opt|proc|root|run|sbin|srv|sys|tmp|usr|var)
      die "repo folder '$REPO_NAME' would mount over the container's /$REPO_NAME. Rename the folder, or add <!-- container-workdir: /some-name --> to $CLAUDE_MD" ;;
  esac
  [[ "$REPO_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
    || die "repo folder '$REPO_NAME' is not a plain name for a mount point. Rename the folder, or add <!-- container-workdir: /some-name --> to $CLAUDE_MD"
  WORKDIR="/$REPO_NAME"
fi
case "$WORKDIR" in
  /*) : ;;
  *) die "container-workdir must be an absolute path (got '$WORKDIR')" ;;
esac

# ---- shared memory ceiling over every container (host side) ----
#
# cgroup v2 is hierarchical: a child's limit nests under its parent's, and when
# the parent reaches its own limit the kernel reclaims across every child - each
# container's file cache first, which is the memory that costs nothing to give
# back - before anything is killed. MemoryHigh throttles the group once the
# total crosses it; MemoryMax is the hard stop, where the OOM killer picks the
# largest process anywhere in the group (which can be a claude session rather
# than a test worker). Neither touches a container's own --memory cap, which
# still applies underneath.
#
# The parent is a systemd slice in the invoking user's manager - what rootless
# podman's systemd cgroup manager parents a container's scope under when given
# --cgroup-parent <name>.slice. `systemctl --user set-property` both creates the
# slice and PERSISTS the numbers (a drop-in under ~/.config/systemd/user.control/),
# and applies them at once to a slice that is already live - so it runs on every
# invocation, attach included: change the numbers at the top of the script and
# re-run it, and the ceiling moves under the running containers. A container
# started before the slice existed is outside it until it is recreated (--fresh).
#
# Check from the host:
#   systemctl --user show claude-containers.slice -p MemoryHigh -p MemoryMax -p MemoryCurrent
#   systemd-cgls --user --no-pager | grep -A3 claude-containers
#
# Best-effort, like the apt step: without a systemd cgroup manager on cgroup v2
# or a user manager to talk to, it warns and the containers run on their own
# caps alone.
#
# Raising a RUNNING container's own cap without recreating it (podman 3.4 has
# no `podman update`; the slice membership still needs --fresh): crun keeps the
# processes in a child cgroup named `container` beneath the libpod scope and
# sets --memory THERE, so `systemctl --user set-property libpod-<id>.scope
# MemoryMax=` loosens only the parent and changes nothing (measured 2026-09-08).
# Write the child directly - delegated, so no sudo:
#   echo 10G > /sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/user.slice/libpod-$(podman inspect -f '{{.Id}}' <name>).scope/container/memory.max
# The container sees it at once in its own /sys/fs/cgroup/memory.max; a
# stop/start reverts to the stored 8g/10g from `podman run`.
CGROUP_PARENT=()
if [ -n "$SLICE" ]; then
  # The manager comes from podman; the cgroup version from the kernel itself
  # (cgroup.controllers at the root exists only on the v2 unified hierarchy),
  # because podman's own field for it is spelled differently across versions
  # (CGroupsVersion in 3.x, CgroupsVersion in 4.x) and a Go template names the
  # field literally - the wrong spelling printed 'systemd ' on podman 3.4.
  cg_mgr="$(podman info --format '{{.Host.CgroupManager}}' 2>/dev/null || true)"
  cg_ver=v1; [ -f /sys/fs/cgroup/cgroup.controllers ] && cg_ver=v2
  cg_info="$cg_mgr $cg_ver"
  case "$cg_info" in
    systemd\ v2)
      if systemctl --user set-property "$SLICE" "MemoryHigh=$SLICE_HIGH" "MemoryMax=$SLICE_MAX" "MemorySwapMax=$SLICE_SWAP_MAX"; then
        CGROUP_PARENT=( --cgroup-parent "$SLICE" )
        echo ">> memory: $MEMORY per container; all containers under $SLICE (high $SLICE_HIGH, max $SLICE_MAX, swap $SLICE_SWAP_MAX)"
        top_slice="${SLICE%%-*}"; top_slice="${top_slice%.slice}.slice"
        weights=()
        [ -n "$SLICE_CPU_WEIGHT" ] && weights+=( "CPUWeight=$SLICE_CPU_WEIGHT" )
        [ -n "$SLICE_IO_WEIGHT" ] && weights+=( "IOWeight=$SLICE_IO_WEIGHT" )
        if [ ${#weights[@]} -gt 0 ]; then
          if systemctl --user set-property "$top_slice" "${weights[@]}"; then
            echo ">> priority: $top_slice ${weights[*]} (the desktop's slices have 100)"
          else
            echo ">> warning: could not set ${weights[*]} on $top_slice; the containers compete with the desktop as equals." >&2
          fi
        fi
      else
        echo ">> warning: 'systemctl --user set-property $SLICE' failed (no user systemd manager?);" >&2
        echo "   no shared ceiling - each container keeps only its own --memory cap ($MEMORY)." >&2
      fi
      ;;
    *)
      echo ">> warning: podman reports cgroup manager/version '${cg_info:-unknown}', not 'systemd v2';" >&2
      echo "   no shared ceiling - each container keeps only its own --memory cap ($MEMORY)." >&2
      ;;
  esac
fi

# ---- the interactive shell: a new tmux session (see "Every shell opens" above) ----
TMUX_CONF='# Written by launch-container.sh on every launch; edit the script, not this file.
# Mouse on, so the wheel reaches Claude Code: its fullscreen TUI scrolls the
# conversation itself, and with tmux'"'"'s mouse off the wheel became Up/Down
# (prompt history) instead (2026-10-10). In a plain shell the wheel enters
# tmux'"'"'s scrollback (copy mode; scroll to the bottom or press q to leave), and
# Shift+drag is the terminal'"'"'s own selection. tmux still draws on the normal
# screen (smcup@/rmcup@), so a plain shell'"'"'s output also lands in the
# terminal'"'"'s scrollback.
set -g mouse on
set -ga terminal-overrides ",xterm*:smcup@:rmcup@"
set -g history-limit 100000
# A plain interactive bash, as before tmux, so it reads ~/.bashrc. tmux'"'"'s default is a LOGIN
# shell, which reads ~/.profile instead, and the image has none: from 2026-09-26 to 2026-10-10 tmux
# shells skipped ~/.bashrc, losing the launcher'"'"'s prompt and repos'"'"' blocks (diagram'"'"'s claude()
# wrapper, which adds its standing authorizations to every session).
set -g default-command bash
# What Claude Code expects: truecolor, a prompt Esc, focus events, and extended
# keys so Shift+Enter still inserts a newline.
set -g default-terminal "tmux-256color"
set -as terminal-features ",xterm-256color:RGB:extkeys"
set -g extended-keys on
set -sg escape-time 10
set -g focus-events on
set -g set-clipboard on
# The terminal tab'"'"'s title follows the pane'"'"'s: Claude Code sets it to the
# session'"'"'s name (and again on /rename), and tmux keeps it to itself unless told.
set -g set-titles on
set -g set-titles-string "#{pane_title}"
set -as terminal-features ",xterm-256color:title"
# The tab title follows a change within a second (the default status refresh is 15 s).
set -g status-interval 1'
# Clipboard bridge (2026-10-10): GNOME Terminal ignores OSC 52, so a copy inside tmux never reached the
# desktop clipboard. Every copy also goes to /clipboard-bridge/<name>, which the host's
# clipboard-bridge service puts on the clipboard: Claude Code's copies (load-buffer) and tmux's own
# copy mode (copy-command). See host-scripts/clipboard-bridge.py. "; true" keeps a container without
# the mount quiet.
CLIP_CMD="sh /host-scripts/clipboard-to-host $NAME"
TMUX_CONF+="
set-hook -g after-load-buffer 'run-shell -b \"$CLIP_CMD --tmux-buffer; true\"'
set-hook -g after-set-buffer 'run-shell -b \"$CLIP_CMD --tmux-buffer; true\"'
set -s copy-command '$CLIP_CMD'"

# An arrow-key menu over the running tmux sessions: "Start a new session" first
# and highlighted, so Enter alone starts one as a plain launch would; Up/Down (or k/j)
# move, Enter picks. Sets PICKED to the chosen session's name, or "" for new.
# Printed rather than just listed because tmux clears the screen the moment it
# starts, so a list printed before it could never be read (GM 2026-09-26).
pick_session() {
  local -a names=("") labels=("Start a new session")
  local line name title state active
  while IFS=$'\t' read -r name title state active; do
    [ -n "$name" ] || continue
    names+=( "$name" )
    labels+=( "$(printf 'Attach to %-8s %-28.28s %s %s' "$name" "$title" "$state" "$active")" )
  done <<< "$1"
  local n=${#labels[@]} sel=0 key i
  echo ">> tmux sessions are already running in '$NAME' (a dropped tab leaves its session WAITING)."
  echo "   Up/Down to choose, Enter to go:"
  while :; do
    for ((i = 0; i < n; i++)); do
      if [ "$i" -eq "$sel" ]; then printf '\e[2K  \e[7m> %s\e[0m\n' "${labels[i]}"
      else printf '\e[2K    %s\n' "${labels[i]}"; fi
    done
    IFS= read -rsn1 key || break
    case "$key" in
      "") break ;;
      $'\e') IFS= read -rsn2 -t 0.1 key || true
             case "$key" in
               "[A") [ "$sel" -gt 0 ] && sel=$((sel - 1)) || true ;;
               "[B") [ "$sel" -lt $((n - 1)) ] && sel=$((sel + 1)) || true ;;
             esac ;;
      k) [ "$sel" -gt 0 ] && sel=$((sel - 1)) || true ;;
      j) [ "$sel" -lt $((n - 1)) ] && sel=$((sel + 1)) || true ;;
    esac
    printf '\e[%dA' "$n"
  done
  PICKED="${names[sel]}"
}

# The first command in a shell is nearly always Claude Code with permission prompts off, so make it
# the NEWEST history entry before every new shell (2026-10-10; it used to be seeded only into a fresh
# container, and shells exiting later pushed their own commands after it). An interactive bash reads
# $HISTFILE at startup, so Up-Enter runs it. Older copies of the line are removed first, so it doesn't
# pile up. Rewritten in place as the container's default user (agent): a root-owned or replaced
# ~/.bash_history would silently stop later shells from saving their history.
HISTORY_SEED='claude --dangerously-skip-permissions'
seed_history() {
  podman exec "$NAME" bash -c 'h="$HOME/.bash_history"; touch "$h" &&
      { grep -vxF -- "$1" "$h" > "$h.seed-tmp"; cat "$h.seed-tmp" > "$h"; rm -f "$h.seed-tmp"; } &&
      printf "%s\n" "$1" >> "$h"' _ "$HISTORY_SEED" \
    || echo ">> warning: could not seed bash history; type the command by hand." >&2
}

# The prompt, and the tab title before Claude Code sets one (2026-10-10). The image's prompt was
# agent@<container id>:/repo, and a tab showed no title until Claude Code started, so tabs of
# different containers looked alike. Now the prompt is agent:/repo, and every prompt also sets the
# pane title to it, which tmux (set-titles) passes to the tab. A marked block in ~/.bashrc, replaced
# on every launch the way repos add their own blocks; new shells pick it up. It also loads the
# voice-corrections mod (2026-10-27), so a running container gets it on the next launch, no --fresh.
PROMPT_BLOCK='# >>> launch-container prompt >>>
# Written by launch-container on every launch; edit the script, not this block.
PS1='"'"'\[\e]0;\u:\w\a\]\u:\w\$ '"'"'
# The voice-corrections mod (host-scripts/voice-corrections/CLAUDE.md), as on the host.
[ -d /host-scripts/voice-corrections/mod ] && export CLAUDE_CODE_PLUGIN_DIRS=/host-scripts/voice-corrections/mod
# <<< launch-container prompt <<<'
write_prompt() {
  podman exec "$NAME" bash -c 'f="$HOME/.bashrc"; touch "$f" &&
      sed "/^# >>> launch-container prompt >>>\$/,/^# <<< launch-container prompt <<<\$/d" "$f" > "$f.prompt-tmp" &&
      cat "$f.prompt-tmp" > "$f" && rm -f "$f.prompt-tmp" && printf "%s\n" "$1" >> "$f"' _ "$PROMPT_BLOCK" \
    || echo ">> warning: could not write the prompt block into ~/.bashrc." >&2
}

# Clipboard bridge pieces that need container root, redone on every launch so a running container
# gets them without --fresh (2026-10-10). wl-paste goes in /usr/local/bin, not a PATH entry, so
# Claude Code sessions that are already running find it on their next right-click paste. A container
# made before the /clipboard-bridge mount gets that path as a symlink into its ~/.claude mount, a
# folder the host service also watches (LEGACY_DIR in clipboard-bridge.py).
setup_clipboard() {
  mkdir -p "$CLAUDE_SRC/.claude/container-clipboard" 2>/dev/null || true
  podman exec --user root "$NAME" sh -c '
    [ -x /host-scripts/container-bin/wl-paste ] && ln -sfn /host-scripts/container-bin/wl-paste /usr/local/bin/wl-paste
    if [ ! -e /clipboard-bridge ] && [ -d /home/agent/.claude/container-clipboard ]; then
      ln -sfn /home/agent/.claude/container-clipboard /clipboard-bridge
    fi' >/dev/null 2>&1 \
    || echo ">> warning: could not set up the clipboard bridge inside '$NAME'." >&2
}

# Commits made in a container (including in new clones) carry the host user's git identity, copied
# from the host's global git config on every launch so no session needs telling (2026-10-27; the repos'
# own .git/config already had it, new clones didn't). No host identity: nothing is set.
set_git_identity() {
  local gname gemail
  gname=$(git config --global user.name 2>/dev/null) || true
  gemail=$(git config --global user.email 2>/dev/null) || true
  [ -n "$gname" ] && [ -n "$gemail" ] || return 0
  podman exec -e GIT_ID_NAME="$gname" -e GIT_ID_EMAIL="$gemail" "$NAME" sh -c 'command -v git >/dev/null || exit 0
    git config --global user.name "$GIT_ID_NAME" && git config --global user.email "$GIT_ID_EMAIL"' \
    || echo ">> warning: could not set the git identity inside '$NAME'." >&2
}

# Attach this terminal to tmux session $1 and keep it attached across dropped connections (see "A
# dropped connection" in the header). Never returns. -d detaches every other client of the session:
# a dropped tab's dead client stays attached inside the container and would otherwise pin the window
# to its size. Don't go back to `exec podman exec`: nothing is then left to notice the drop.
# Gives up after 3 attaches in a row that each ended within 5 s, so a broken container can't spin.
attach_loop() {
  local target="$1" rc fast=0 t0
  while :; do
    t0=$SECONDS; rc=0
    podman exec -it --env LANG=C.UTF-8 "$NAME" tmux -u attach -d -t "=$target" || rc=$?
    if [ "$rc" -eq 0 ]; then
      # The shell exited, or a deliberate detach (also: another tab took the session over).
      if podman exec "$NAME" tmux has-session -t "=$target" 2>/dev/null; then
        echo ">> session '$target' is still running in '$NAME'; to return: launch-container --attach $target"
      fi
      exit 0
    fi
    # The dead client never restored the terminal: leave mouse reporting and the alternate screen.
    [ -t 1 ] && printf '\e[?1000l\e[?1002l\e[?1003l\e[?1006l\e[?2004l\e[?1049l\e[?25h'
    [ -t 0 ] && stty sane 2>/dev/null || true
    podman exec "$NAME" tmux has-session -t "=$target" 2>/dev/null || exit "$rc"   # session or container gone
    [ -t 0 ] || exit "$rc"                                                         # no terminal to come back to
    if [ $((SECONDS - t0)) -lt 5 ]; then fast=$((fast + 1)); else fast=0; fi
    if [ "$fast" -ge 3 ]; then
      echo ">> the connection to '$NAME' keeps dropping; giving up. Session '$target' is still running," >&2
      echo "   with anything typed into it. To return: launch-container --attach $target" >&2
      exit "$rc"
    fi
    echo ">> the connection to '$NAME' dropped; session '$target' kept running (an unsent prompt is still in its box). Reattaching..."
    sleep 1
    # Whatever flooded the terminal may have painted over a fullscreen program (2026-11-26: error lines
    # over Claude Code), and tmux redraws that garbage faithfully. Only a real size change makes the
    # program repaint (SIGWINCH alone does not), so once attached: one column narrower, then back.
    # Back means UNSETTING window-size: resize-window sets it to manual and `resize-window -A` leaves
    # it there, so the window would stop following the terminal's size (measured 2026-11-26).
    ( sleep 3
      w="$(podman exec "$NAME" tmux display -p -t "=$target:" '#{window_width} #{window_height}' 2>/dev/null)" || exit 0
      [ "${w% *}" -gt 20 ] 2>/dev/null || exit 0
      podman exec "$NAME" tmux resize-window -t "=$target:" -x "$(( ${w% *} - 1 ))" -y "${w#* }" 2>/dev/null || true
      sleep 0.5
      podman exec "$NAME" tmux set-option -w -u -t "=$target:" window-size 2>/dev/null ) </dev/null >/dev/null 2>&1 &
  done
}

# Voice through the host's one-way mic pipe (2026-11-26; host-scripts/container-audio/CLAUDE.md). The
# raw device overran whenever a busy container held Claude Code's recording thread up 100 ms, and its
# capture library then flooded the screen with POLLERR lines and dropped the tab. The host-owned FIFO
# lives in the read-only /host-scripts mount, so the container can read it and nothing else. Only when
# the host service is installed; a container made before this gets its packages here once (like tmux).
# container-side.sh falls back to the raw device whenever anything is missing.
setup_container_audio() {
  [ -f "$HOME/.config/systemd/user/container-audio.service" ] || return 0
  # The folder THIS container mounts at /host-scripts (an older container may mount an older path).
  local src dir
  src="$(podman inspect -f '{{range .Mounts}}{{if eq .Destination "/host-scripts"}}{{.Source}}{{end}}{{end}}' "$NAME" 2>/dev/null)"
  [ -n "$src" ] && [ -d "$src" ] || return 0
  dir="$(readlink -f "$src" || true)/container-audio/pipes"   # never abort the launch (set -e) over audio
  [ "$dir" != /container-audio/pipes ] || return 0
  mkdir -p -m 700 "$dir" && { [ -p "$dir/$NAME.fifo" ] || mkfifo -m 600 "$dir/$NAME.fifo"; } \
    || { echo ">> warning: could not create the container-audio pipe for '$NAME'." >&2; return 0; }
  if ! podman exec "$NAME" sh -c 'command -v pulseaudio && command -v parec && [ -e /usr/lib/x86_64-linux-gnu/alsa-lib/libasound_module_pcm_pulse.so ]' >/dev/null 2>&1; then
    echo ">> installing pulseaudio into '$NAME' for voice through the host's mic pipe (once)."
    podman exec --user root --env DEBIAN_FRONTEND=noninteractive "$NAME" bash -c \
      'apt-get install -y -qq --no-install-recommends pulseaudio pulseaudio-utils libasound2-plugins >/dev/null 2>&1 \
       || { apt-get update -qq && apt-get install -y -qq --no-install-recommends pulseaudio pulseaudio-utils libasound2-plugins >/dev/null; }' \
      || echo ">> warning: installing pulseaudio failed (offline?); voice stays on the raw device." >&2
  fi
  podman exec --user root "$NAME" sh /host-scripts/container-audio/container-side.sh "$NAME" agent 2>&1 \
    | grep -E '^>>' || true
}

open_shell() {
  write_prompt
  set_git_identity
  setup_clipboard
  # A container launched before the tmux step (2026-09-26) has no tmux: install it
  # now, as container root like the package step, whatever the attach path - the
  # one exception to "attaching installs nothing", because every shell depends on
  # it. The index is refreshed only if the plain install fails (a stale image).
  if [ "$TMUX_SHELL" -eq 1 ] && ! podman exec "$NAME" sh -c 'command -v tmux' >/dev/null 2>&1; then
    echo ">> installing tmux into '$NAME' (it predates the launch script's tmux step)."
    podman exec --user root --env DEBIAN_FRONTEND=noninteractive "$NAME" bash -c \
      'apt-get install -y -qq --no-install-recommends tmux >/dev/null 2>&1 \
       || { apt-get update -qq && apt-get install -y -qq --no-install-recommends tmux >/dev/null; }' \
      || echo ">> warning: installing tmux failed (offline?)." >&2
  fi
  if [ "$TMUX_SHELL" -eq 1 ] && podman exec "$NAME" sh -c 'command -v tmux' >/dev/null 2>&1; then
    podman exec "$NAME" sh -c 'printf "%s\n" "$1" > "$HOME/.tmux.conf"' _ "$TMUX_CONF" \
      || echo ">> warning: could not write ~/.tmux.conf; tmux runs on its defaults." >&2
    # A tmux server already running reads the config only at its start: reload it into that one.
    podman exec "$NAME" sh -c 'tmux source-file "$HOME/.tmux.conf"' >/dev/null 2>&1 || true
    local sessions detached
    # LANG as for attach: without a UTF-8 locale tmux 3.6 prints the tabs below
    # (and the title's ✳) as "_", so the whole line became the session name.
    sessions="$(podman exec --env LANG=C.UTF-8 "$NAME" tmux list-sessions \
      -F '#{session_name}	#{pane_title}	#{?session_attached,attached in a terminal,WAITING - no terminal attached}	(last active #{t/p:session_activity})' 2>/dev/null || true)"  # no server yet = no sessions, not an error (set -e)
    detached="$(printf '%s' "$sessions" | grep -F 'WAITING' || true)"
    if [ -n "$ATTACH" ]; then
      local target="$ATTACH"
      if [ "$target" = "-" ]; then
        # No session waiting but exactly one running: take that one. "Attached" may be a dropped
        # tab's dead client (2026-11-26: --attach opened a NEW session beside the one Eli wanted).
        local pool="$detached"
        [ -n "$pool" ] || pool="$sessions"
        case "$(printf '%s' "$pool" | grep -c .)" in
          0) echo ">> --attach: no tmux session is running in '$NAME'; opening a new one." ;;
          1) target="$(printf '%s' "$pool" | cut -f1)" ;;
          *) echo ">> --attach: several tmux sessions are $([ -n "$detached" ] && echo waiting || echo running) in '$NAME'; name one:" >&2
             printf '%s\n' "$pool" | sed 's/^/     /' >&2
             echo "   $0 --attach <name>" >&2
             exit 1 ;;
        esac
      fi
      if [ "$target" != "-" ]; then
        echo ">> reattaching to tmux session '$target'."
        attach_loop "$target"
      fi
    elif [ "$RESUME" -eq 1 ] && [ -n "$sessions" ] && [ -t 0 ]; then
      pick_session "$sessions"
      if [ -n "$PICKED" ]; then
        echo ">> attaching to tmux session '$PICKED'."
        attach_loop "$PICKED"
      fi
    elif [ "$RESUME" -eq 1 ]; then
      [ -n "$sessions" ] || echo ">> --resume: no tmux session is running in '$NAME'."
    elif [ -n "$detached" ]; then
      echo ">> $(printf '%s\n' "$detached" | grep -c .) tmux session(s) WAITING in '$NAME' (dropped tabs); to pick one: launch-container --resume"
    fi
    seed_history
    echo ">> opening a new tmux session (if this terminal drops, the session keeps running and this tab reattaches)."
    # Created detached so its name is known, then attached through attach_loop. At this terminal's
    # size, so the shell doesn't start at 80x24 and redraw.
    local created size
    size="$(stty size 2>/dev/null || true)"
    case "$size" in [1-9]*\ [1-9]*) ;; *) size="" ;; esac   # "0 0" (a pty with no size set): tmux refuses -x 0
    created="$(podman exec --env LANG=C.UTF-8 "$NAME" tmux -u new-session -d -P -F '#{session_name}' \
      ${size:+-x "${size#* }" -y "${size% *}"} 2>/dev/null || true)"
    [ -z "$created" ] || attach_loop "$created"
    echo ">> warning: could not create the session detached; attaching directly (no automatic reattach)." >&2
    exec podman exec -it --env LANG=C.UTF-8 "$NAME" tmux -u new-session
  fi
  [ -z "$ATTACH" ] && [ "$RESUME" -eq 0 ] || die "--attach/--resume need tmux in '$NAME' (and not --no-tmux)"
  if [ "$TMUX_SHELL" -eq 1 ]; then
    echo ">> warning: tmux is still not installed in '$NAME'; plain bash instead." >&2
    echo "   Install it inside with: sudo apt-get install -y tmux" >&2
  fi
  seed_history
  exec podman exec -it --env LANG=C.UTF-8 "$NAME" bash
}

# A container created before the host-scripts mounts existed (2026-10-03) keeps running without
# them; say so on attach, since only a recreate adds a mount.
note_missing_host_scripts() {
  local mounts
  mounts="$(podman inspect -f '{{range .Mounts}}{{.Destination}} {{end}}' "$NAME" 2>/dev/null)"
  if ! grep -qw /host-scripts <<<"$mounts"; then
    echo ">> note: '$NAME' predates the /host-scripts and /proposed-host-script-updates mounts;"
    echo "   relaunch with --fresh to get them (this removes the container, so finish its work first)."
  fi
  # A container made under the old shared /workspace default (before 2026-10-03) keeps it.
  local have
  have="$(podman inspect -f '{{.Config.WorkingDir}}' "$NAME" 2>/dev/null)"
  if [ -n "$have" ] && [ "$have" != "$WORKDIR" ]; then
    echo ">> note: '$NAME' works in $have; a fresh launch would use $WORKDIR (and that path's Claude"
    echo "   memory and /resume history). Relaunch with --fresh to move it (finish its work first)."
  fi
  # Same for a project that gained .volume-overrides/ after its container was made: until it is
  # recreated it runs as the host's account, which is the thing the overrides exist to prevent.
  if [ -d "$REPO_ROOT/.volume-overrides" ] && ! grep -q '/home/agent/.claude/.credentials.json' <<<"$mounts"; then
    echo ">> WARNING: '$NAME' does not have this project's .volume-overrides/ mounted, so it runs as the"
    echo "   HOST's Claude account. Relaunch with --fresh to apply them (finish its work first)."
  fi
  # A container made before session messaging (2026-11-26) has no shared socket folder: it either
  # has its own session list or shares the host's without a pid offset (see peer_after_start).
  # (An another-account project made before 2026-11-28 is in the same state: it got no socket folder.)
  if grep -q ' /home/agent/\.claude ' <<<" $mounts " && ! grep -q '/cc-socks ' <<<"$mounts " \
      && [ "${CONTAINER_PEERS:-1}" = 1 ]; then
    echo ">> note: '$NAME' was made without session messaging, so its Claude sessions can't list or message"
    echo "   the host's or other containers' sessions. Relaunch with --fresh to enable it (finish its work first)."
  fi
}

# A stopped container whose bind-mount source has since moved or been deleted cannot start:
# podman fails with "error stat'ing file ...: OCI runtime attempted to invoke a command that was
# not found", which names no fix (2026-11-24: host-scripts/ had moved to ai-tooling; the running
# containers kept their mounts until a reboot stopped them). Mounts are fixed at creation, so the
# choices are a symlink at the old path or a recreate. Say which, before podman's error.
check_mount_sources() {
  local src dst bad=0 here
  here="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"   # HOST_SCRIPTS_DIR is only set further down
  while IFS='|' read -r src dst; do   # not a tab: podman's formatter turns tabs into padding
    [ -n "$src" ] || continue
    [ -e "$src" ] && continue
    bad=1
    echo ">> ERROR: '$NAME' cannot start: its mount source $src (mounted at $dst) no longer exists." >&2
    if [ "$dst" = /host-scripts ]; then
      echo "   The host scripts moved. Link the old path to them, then launch again:" >&2
      echo "     ln -s '$here' '$src'" >&2
    else
      echo "   Put it back (or symlink the old path to its new place: ln -s NEW '$src'), then launch again." >&2
    fi
  done < <(podman inspect -f '{{range .Mounts}}{{.Source}}|{{.Destination}}{{"\n"}}{{end}}' "$NAME" 2>/dev/null)
  if [ "$bad" -eq 1 ]; then
    echo "   (launch-container --fresh also works, but it deletes the container and everything stored in it.)" >&2
    exit 1
  fi
}

# ---- session messaging: the shared socket folder and the per-container pid offset ----
#
# peer_socks_of: the host folder an existing container mounts as its Claude socket folder ('' if
# none). It lives on the tmpfs /run/user/<uid>, so it is gone after a reboot: recreate it before
# `podman start`, or the start fails on the missing mount source.
peer_socks_of() {
  podman inspect -f '{{range .Mounts}}{{.Source}}|{{.Destination}}{{"\n"}}{{end}}' "$NAME" 2>/dev/null \
    | awk -F'|' '$2 ~ /\/cc-socks$/ { print $1; exit }' || true
}

# pid_slot: this container's slot (1, 2, ...) in $CLAUDE_SRC/.claude/container-pid-slots ("slot name"
# lines). A slot is kept for as long as its container exists; the lowest free one is handed out.
pid_slot() {
  local f="$CLAUDE_SRC/.claude/container-pid-slots" s n keep="" used=" " mine=""
  mkdir -p "$CLAUDE_SRC/.claude"; touch "$f"
  {
    if command -v flock >/dev/null 2>&1; then flock 9; fi
    while read -r s n; do
      [ -n "$n" ] || continue
      if [ "$n" = "$NAME" ]; then mine="$s"
      elif ! podman container exists "$n" 2>/dev/null; then continue
      fi
      keep+="$s $n"$'\n'; used+="$s "
    done < "$f"
    if [ -z "$mine" ]; then
      mine=1; while [[ "$used" == *" $mine "* ]]; do mine=$((mine + 1)); done
      keep+="$mine $NAME"$'\n'
    fi
    printf '%s' "$keep" > "$f"
  } 9>"$f.lock"
  echo "$mine"
}

# peer_after_start <socket folder>: run after every create, start and attach of a container that
# shares the session list ('' = it doesn't; nothing to do). Makes the runtime folder the agent's
# (podman creates the mount's parent as root) and moves the container's pid counter up to
# slot * PID_SLOT_SIZE by forking that many empty subshells (~0.25 ms each), so that two containers
# started together don't both run their first Claude session as pid 31 and fight over one registry
# record. Nothing to do once the counter is past the base. It removes the systematic collision; two
# long-lived sessions landing on the same pid by chance stays possible and very unlikely.
PID_SLOT_SIZE="${CONTAINER_PID_SLOT_SIZE:-5000}"
peer_after_start() {
  local socks="$1" slot
  [ -n "$socks" ] || return 0
  slot="$(pid_slot)"
  podman exec --user root "$NAME" sh -c '
    d=$(dirname "$1"); chown 1000:1000 "$d" 2>/dev/null; chmod 700 "$d" 2>/dev/null
    last=$(cat /proc/sys/kernel/ns_last_pid 2>/dev/null) || exit 0
    n=$(( $2 - last )); while [ "$n" -gt 0 ]; do (:); n=$((n - 1)); done' _ "$socks" "$((slot * PID_SLOT_SIZE))" \
    || echo ">> warning: could not set '$NAME' pid offset (slot $slot); a session there may collide with another container's in the session list." >&2
}

# ---- if a container of this name exists, attach (or recreate with --fresh) ----
if [ "$FRESH" -eq 1 ] && podman container exists "$NAME" 2>/dev/null; then
  echo ">> --fresh: removing existing container '$NAME'"
  podman rm -f "$NAME" >/dev/null
fi

if [ -n "$(podman ps -q -f "name=^${NAME}$" 2>/dev/null)" ]; then
  if [ "$SHELL_AFTER" -eq 1 ]; then
    echo ">> '$NAME' is already running; opening a new shell inside it."
  else
    echo ">> '$NAME' is already running; --no-shell, so nothing else to do."
  fi
  echo ">> ports published by the running container:"
  podman port "$NAME" 2>/dev/null | sed 's/^/     /' || true
  note_missing_host_scripts
  peer_after_start "$(peer_socks_of)"
  setup_container_audio
  [ "$SHELL_AFTER" -eq 1 ] || exit 0
  open_shell
fi

if podman container exists "$NAME" 2>/dev/null; then
  if [ "$SHELL_AFTER" -eq 1 ]; then
    echo ">> '$NAME' exists but is stopped; starting it and attaching."
  else
    echo ">> '$NAME' exists but is stopped; starting it (--no-shell)."
  fi
  STARTED_SOCKS="$(peer_socks_of)"
  [ -z "$STARTED_SOCKS" ] || mkdir -p -m 700 "$STARTED_SOCKS" 2>/dev/null || true   # tmpfs: gone after a reboot
  check_mount_sources
  podman start "$NAME" >/dev/null
  peer_after_start "$STARTED_SOCKS"
  note_missing_host_scripts
  setup_container_audio
  [ "$SHELL_AFTER" -eq 1 ] || exit 0
  open_shell
fi

# ---- build a fresh run ----
#
# The uid/gid maps make the container's `agent` user (uid 1000) write files that
# the host sees as owned by YOU - without which everything the container touched
# in the bind-mounted repo would land owned by some subuid and need chown'ing.
#
# They do NOT hard-code your UID. Under ROOTLESS podman the middle field of
# CONTAINER:HOST:SIZE is not a real host id but a slot in the intermediate user
# namespace podman sets up, where slot 0 is the invoking user (whatever their UID
# is - 1000, 3000, 5000) and slots 1..65536 are their /etc/subuid range. So
# "1000:0:1" means "container uid 1000 -> the invoking user", and the script
# never has to know the number. The other two lines park container root (0..999)
# and everything above 1000 in the subuid range so they can't collide with it.
#
# What this DOES depend on is the SIZE of the subuid/subgid allocation: the maps
# reach intermediate slot 1001+64536-1 = 65536, and the near-universal default
# allocation is exactly 65536 entries - a perfect fit with zero headroom. A host
# handing out a smaller range makes `podman run` fail outright. Check with:
#   grep "^$USER:" /etc/subuid /etc/subgid    # third field must be >= 65536
#
# All of the above is rootless-only. Under `sudo podman` the middle field means a
# REAL host id, so "1000:0:1" would map the agent user to actual root and
# /etc/subuid is not consulted - do not run this script with sudo.
RUN_ARGS=(
  --detach
  --name "$NAME"
  --uidmap 0:1:1000 --uidmap 1000:0:1 --uidmap 1001:1001:64536
  --gidmap 0:1:1000 --gidmap 1000:0:1 --gidmap 1001:1001:64536
  --env HOME=/home/agent
  --workdir "$WORKDIR"
  --memory "$MEMORY" --memory-swap "$MEMORY"
  ${CGROUP_PARENT[@]+"${CGROUP_PARENT[@]}"}
  --volume "${REPO_ROOT}:${WORKDIR}:Z"
)

# The host's time zone, so Claude Code's timestamps ("done 10:45 AM") and `date` show local time
# instead of the image's UTC. Every `podman exec` inherits it. Override with CONTAINER_TZ.
HOST_TZ="${CONTAINER_TZ:-$(timedatectl show -p Timezone --value 2>/dev/null || true)}"
[ -n "$HOST_TZ" ] || HOST_TZ="$(readlink /etc/localtime 2>/dev/null | sed -n 's|.*/zoneinfo/||p')"
[ -n "$HOST_TZ" ] && RUN_ARGS+=( --env "TZ=$HOST_TZ" )

# Host sound devices, so Claude Code's /voice can record (see "Audio" above).
# Access comes from the uidmap: container uid 1000 IS the invoking user, and
# /dev/snd/* carries a logind ACL granting the seat user rw - verified by
# reading the nodes from inside, where they show up as nobody:nogroup with a
# trailing '+' (the ACL) and are still readable/writable. Conditional because
# `--device` on a missing path is a hard `podman run` failure: a host with no
# sound card at all (headless server, minimal VM) must still get a container.
AUDIO=0
if [ -d /dev/snd ]; then
  RUN_ARGS+=( --device /dev/snd )
  AUDIO=1
else
  echo ">> note: no /dev/snd on this host; container gets no audio (voice input won't work)."
fi

# Host Claude Code config, mounted so auth, settings, skills, and per-project
# memory persist across container recreations. The host paths are created if
# missing so even the very first launch persists - otherwise an in-container
# login would be written container-internally and lost when the container is
# removed (an empty {} is a valid starting config). Uses the shared SELinux relabel (:z), not the private
# :Z used for the workspace. Skip with --no-claude (e.g. on a work machine, so
# the container does not inherit that host's default Claude account); CLAUDE_SRC
# overrides where it is read from.
if [ "$MOUNT_CLAUDE" -eq 1 ]; then
  mkdir -p "$CLAUDE_SRC/.claude"
  [ -e "$CLAUDE_SRC/.claude.json" ] || echo '{}' > "$CLAUDE_SRC/.claude.json"
  RUN_ARGS+=( --volume "$CLAUDE_SRC/.claude.json:/home/agent/.claude.json:z" )
  RUN_ARGS+=( --volume "$CLAUDE_SRC/.claude:/home/agent/.claude:z" )
  # Session messaging (2026-11-26): Claude Code sessions find each other through the registry
  # (~/.claude/sessions/<pid>.json) and talk over Unix sockets in $XDG_RUNTIME_DIR/cc-socks, so a
  # container on the HOST's Claude account shares both: the registry (it is inside the ~/.claude
  # mount) and the host's socket folder, mounted at the SAME path with XDG_RUNTIME_DIR pointing at
  # it (a record holds the socket's absolute path, which must resolve on every side). ListAgents
  # and SendMessage then work host <-> container and container <-> container, with no networking,
  # capability or shared pid namespace. A different pid namespace does not stop Claude Code listing
  # a peer; an unreachable socket does (read in 2.1.332's bundle, then tested).
  #
  # The cost of the shared registry: records are named by bare pid and a session deletes its own on
  # exit, and every container numbers its processes from 1. After a restart the first session in two
  # containers was pid 31 in both, and one's exit deleted the other's record (2026-11-25: the tab
  # fell back to its folder name, /rename said "the session list couldn't be updated"). So each
  # container starts its pids at its own offset: peer_after_start below. Don't share the registry
  # without that offset.
  #
  # A project on ANOTHER person's account (.volume-overrides/) shares both too (since 2026-11-28;
  # before that it was kept apart): the two accounts' sessions on this machine can then hand each
  # other work, e.g. a host session doing device access for that container. A registry record
  # carries no account, and only the credentials differ. CONTAINER_PEERS=0 keeps a container apart.
  #
  # A launch with CONTAINER_PEERS=0 or without XDG_RUNTIME_DIR keeps its own registry and gets no
  # socket folder: its sessions neither see nor message the others.
  if [ "${CONTAINER_PEERS:-1}" = 1 ] && [ -n "${XDG_RUNTIME_DIR:-}" ]; then
    PEER_SOCKS="$XDG_RUNTIME_DIR/cc-socks"
    mkdir -p -m 700 "$PEER_SOCKS"
    RUN_ARGS+=( --volume "$PEER_SOCKS:$PEER_SOCKS:z" --env "XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR" )
    echo ">> session messaging: sharing the session list and $PEER_SOCKS with the host and the other containers"
  else
    mkdir -p "$CLAUDE_SRC/.claude/container-sessions/$NAME"
    chmod 700 "$CLAUDE_SRC/.claude/container-sessions/$NAME" 2>/dev/null || true
    RUN_ARGS+=( --volume "$CLAUDE_SRC/.claude/container-sessions/$NAME:/home/agent/.claude/sessions:z" )
    echo ">> session messaging: off for '$NAME' (its own session list; CONTAINER_PEERS=0 or no XDG_RUNTIME_DIR)"
  fi
  echo ">> Claude config: mounting from $CLAUDE_SRC (created if missing, so login persists)"
else
  echo ">> --no-claude: NOT mounting host Claude config; log in fresh inside the"
  echo "   container to keep it separate from this host's default account."
fi

# Per-project Claude account (.volume-overrides/, 2026-10-03; for a project that must always
# run as a different person's Claude account). A project folder holding .volume-overrides/ gets
# the allowlisted files in it mounted ON TOP of the Claude config above: the directory mirrors
# the container's home, so .volume-overrides/.claude/.credentials.json lands on
# /home/agent/.claude/.credentials.json (and .claude.json REPLACES the host's .claude.json
# mount, since podman refuses two mounts at one destination). Both files are needed: .credentials.json holds the
# OAuth token (it decides billing) and .claude.json the profile; overriding only .claude.json
# shows the other account while billing this one. These mounts come AFTER the ~/.claude
# directory mount so they shadow the file inside it.
#
# Missing files are created first (a missing bind source makes podman create a DIRECTORY
# there): .credentials.json as {} (logged out: run /login inside), .claude.json as a copy of
# the host's with oauthAccount removed (keeps onboarding state, drops the other person's
# profile). Claude Code's credential writes fall back to writing in place when a temp-file
# rename is impossible, which is what a single-file mount needs (read in 2.1.288's bundle).
#
# Symlinks are REFUSED, anywhere on the path: the repo is mounted read-write into its own
# container, so a session there could point .claude.json at ~/.ssh/id_ed25519 and have the
# next launch mount it in. Anything not on the allowlist is ignored with a warning.
OVERRIDE_ALLOW=( .claude.json .claude/.credentials.json )
OVERRIDES_DIR="$REPO_ROOT/.volume-overrides"
if [ -L "$OVERRIDES_DIR" ]; then
  echo ">> warning: $OVERRIDES_DIR is a symlink; ignoring it (no account override applied)." >&2
elif [ -d "$OVERRIDES_DIR" ]; then
  if git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1 \
      && ! git -C "$REPO_ROOT" check-ignore -q .volume-overrides/; then
    echo ">> warning: .volume-overrides/ is NOT gitignored in $REPO_NAME, and it holds a Claude login." >&2
    echo "   Fix: echo '.volume-overrides/' >> $REPO_ROOT/.gitignore" >&2
  fi
  chmod 700 "$OVERRIDES_DIR"
  applied=()
  for rel in "${OVERRIDE_ALLOW[@]}"; do
    src="$OVERRIDES_DIR/$rel"
    parent="$(dirname "$src")"
    if [ -L "$src" ] || { [ "$parent" != "$OVERRIDES_DIR" ] && [ -L "$parent" ]; }; then
      echo ">> warning: .volume-overrides/$rel (or its folder) is a symlink; not mounting it." >&2
      continue
    fi
    if [ -e "$src" ] && [ ! -f "$src" ]; then
      echo ">> warning: .volume-overrides/$rel is not a regular file; not mounting it. Remove it and relaunch to recreate it." >&2
      continue
    fi
    if [ ! -e "$src" ]; then
      mkdir -p "$parent" && chmod 700 "$parent"
      case "$rel" in
        .claude.json)
          python3 - "$CLAUDE_SRC/.claude.json" "$src" <<'PY' 2>/dev/null || (umask 077; echo '{}' > "$src")
import json, os, sys
d = json.load(open(sys.argv[1]))
d.pop("oauthAccount", None)
fd = os.open(sys.argv[2], os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, "w") as f:
    json.dump(d, f, indent=2)
PY
          ;;
        *) (umask 077; echo '{}' > "$src") ;;
      esac
      echo ">> volume-overrides: created .volume-overrides/$rel; run /login inside the container to set its account."
    fi
    chmod 600 "$src"
    # A file INSIDE the mounted ~/.claude may be shadowed by a later mount, but podman refuses two
    # mounts at the SAME destination ("duplicate mount destination", 2026-10-03), so the host's
    # own ~/.claude.json mount is dropped before its override is added.
    kept=()
    for ((i = 0; i < ${#RUN_ARGS[@]}; i++)); do
      if [ "${RUN_ARGS[i]}" = --volume ] && [[ "${RUN_ARGS[i+1]:-}" == *":/home/agent/${rel}:"* ]]; then
        i=$((i + 1)); continue
      fi
      kept+=( "${RUN_ARGS[i]}" )
    done
    RUN_ARGS=( "${kept[@]}" )
    RUN_ARGS+=( --volume "${src}:/home/agent/${rel}:z" )
    applied+=( "$rel" )
  done
  while IFS= read -r f; do
    case " ${OVERRIDE_ALLOW[*]} " in
      *" $f "*) ;;
      *) echo ">> warning: ignoring .volume-overrides/$f (not on the allowlist: ${OVERRIDE_ALLOW[*]})." >&2 ;;
    esac
  done < <(cd "$OVERRIDES_DIR" && find . -mindepth 1 \( -type f -o -type l \) | sed 's|^\./||' | sort)
  if [ "${#applied[@]}" -gt 0 ]; then
    list="$(printf '%s, ' "${applied[@]}")"
    echo ">> volume-overrides: ${list%, } (from $REPO_NAME)"
  fi
fi

# This script's folder, read-only, and the proposals queue, read-write (see "Host scripts" at the
# top). Shared relabel (:z) for the same reason as the Claude config: both are used on the host too.
HOST_SCRIPTS_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
PROPOSALS_DIR="${HOST_SCRIPT_PROPOSALS:-$HOME/.local/share/host-script-proposals}"
mkdir -p "$PROPOSALS_DIR"
RUN_ARGS+=( --volume "${HOST_SCRIPTS_DIR}:/host-scripts:ro,z" )
RUN_ARGS+=( --volume "${PROPOSALS_DIR}:/proposed-host-script-updates:z" )
echo ">> mount: ${HOST_SCRIPTS_DIR} -> /host-scripts (read-only); proposals queue ${PROPOSALS_DIR} -> /proposed-host-script-updates"
# The clipboard bridge's drop folder (see TMUX_CONF): write-only in effect, since the host service only
# reads it and nothing in it comes back to the container.
CLIPBOARD_DIR="${CONTAINER_CLIPBOARD:-$HOME/.local/share/container-clipboard}"
mkdir -p "$CLIPBOARD_DIR"
RUN_ARGS+=( --volume "${CLIPBOARD_DIR}:/clipboard-bridge:z" )

# Extra host mounts declared by the repo. The HOST side may be absolute, ~-based,
# or relative to the repo root (so ".." is the repo's parent directory).
#
# Existence alone is a weak check for a RELATIVE source: ".." always exists, so a
# repo cloned somewhere unexpected (~/projects/gm-assistant) would silently mount
# the wrong directory and only fail much later, when something looks for a file
# that isn't there. So a mount may also declare marker paths that must be present
# under the source for it to count as the right directory - here setting/ and
# rules/ identify the l7r notes repo. Missing markers means we skip the mount and
# say so, rather than mounting a lookalike.
mount_markers() {
  case "$1" in
    /host-l7r-repo) echo "setting rules" ;;
    *) : ;;
  esac
}

# Shared SELinux relabel (:z), not the private :Z used for the workspace: these
# are host directories used OUTSIDE the container too (the GM edits l7r.md from
# their laptop), and :Z would relabel them container-private and lock the host
# out. On non-SELinux distros both are no-ops.
while IFS= read -r m; do
  [ -n "$m" ] || continue
  host_raw="${m%%:*}"
  container_path="${m#*:}"
  host="$(resolve_host_path "$host_raw")"
  if [ ! -e "$host" ]; then
    echo ">> warning: mount source '$host_raw' -> '$host' does not exist; skipping." >&2
    continue
  fi
  missing=""
  for marker in $(mount_markers "$container_path"); do
    [ -d "$host/$marker" ] || missing="$missing $marker"
  done
  if [ -n "$missing" ]; then
    echo ">> warning: '$host' is missing${missing}/ so it does not look like the" >&2
    echo "   expected ${container_path} content; skipping that mount." >&2
    continue
  fi
  RUN_ARGS+=( --volume "${host}:${container_path}:z" )
  echo ">> mount: ${host} -> ${container_path}"
done < <(read_directive container-mounts)

# Ports declared by the repo.
if [ "$PUBLISH_PORTS" -eq 1 ]; then
  found_ports=0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$p" in
      [0-9]*:[0-9]*) : ;;
      *) echo ">> warning: ignoring malformed port '$p' (want HOST:CONTAINER)" >&2; continue ;;
    esac
    RUN_ARGS+=( --publish "$p" )
    echo ">> publish: host ${p%%:*} -> container ${p##*:}"
    found_ports=1
  done < <(read_directive container-ports)
  [ "$found_ports" -eq 1 ] || echo ">> note: no 'container-ports:' in CLAUDE.md; nothing published."
else
  echo ">> --no-ports: nothing published."
fi

if [ "$PULL" -eq 1 ]; then
  echo ">> pulling latest image: $IMAGE"
  podman pull "$IMAGE" || echo ">> warning: pull failed; using the local image if present." >&2
else
  echo ">> --no-pull: not pulling; using the local image."
fi

# Detached, with `sleep infinity` as PID 1, so that no terminal is special:
# every shell - this first one included - is an exec session, and exiting any
# of them leaves the container and the other shells running. (The old design
# ran bash as PID 1 with --rm, so a clean `exit` in the original terminal
# stopped the container and killed every other attached shell with it.)
# Teardown is explicit: --fresh or `podman rm -f`.
echo ">> starting '$NAME' detached (workdir $WORKDIR) from $IMAGE"
podman run "${RUN_ARGS[@]}" "$IMAGE" sleep infinity >/dev/null
peer_after_start "${PEER_SOCKS:-}"

# ---- system packages (fresh containers only) ----
#
# Baseline alsa-utils gives /voice a working `arecord` (its first-choice
# recorder after the bundled native one, and the way to debug the mic by hand:
# `arecord -l`), plus whatever the repo declares via container-apt. Runs as
# container root rather than `sudo` inside the agent user, so it does not
# depend on the image keeping passwordless sudo. `apt-get update` first because
# a freshly pulled image can carry a stale index. Best-effort by design: a
# broken install should not cost you the shell, so it warns and continues.
if [ "$APT" -eq 1 ]; then
  PACKAGES=(alsa-utils tmux)  # tmux: every shell opens in it (see "Every shell opens")
  PACKAGES+=(pulseaudio pulseaudio-utils libasound2-plugins)  # voice through the host's one-way mic pipe (setup_container_audio)
  while IFS= read -r pkg; do
    [ -n "$pkg" ] || continue
    PACKAGES+=( "$pkg" )
  done < <(read_directive container-apt)
  echo ">> installing packages: ${PACKAGES[*]}"
  if ! podman exec --user root --env DEBIAN_FRONTEND=noninteractive "$NAME" \
       bash -c 'apt-get update -qq && apt-get install -y -qq --no-install-recommends "$@"' \
       _ "${PACKAGES[@]}"; then
    echo ">> warning: package install failed (offline? stale mirror?); continuing." >&2
    echo "   Retry by hand inside the container with: sudo apt-get install -y ${PACKAGES[*]}" >&2
  fi
else
  echo ">> --no-apt: not installing packages."
fi

# ---- ALSA default device (fresh containers only) ----
#
# Passing /dev/snd through is necessary but NOT sufficient. ALSA's built-in
# "default" PCM is hw:0,0, and on plenty of modern cards device 0 is not a
# capture device at all - this laptop's SOF/soundwire card puts the mic on 0,4
# and the speaker on 0,2, with 0,3 being an amp-feedback loopback. So `arecord`
# with no -D, which is exactly what Claude Code's voice probe and its bundled
# libasound recorder use, dies with "audio open error: No such file or
# directory" even though `arecord -D plughw:0,4` records perfectly. It never
# bites on the host because PulseAudio/PipeWire ships an asound.conf aiming
# default at the sound server, which knows the right device.
#
# So generate one. Device numbers are DETECTED, not hardcoded: /proc/asound/pcm
# is readable in the container (that path is not namespaced) and names each
# device, so prefer a capture device that looks like a mic over a feedback or
# loopback, and a playback device that looks like speakers over HDMI. `plug`
# wraps both so voice's 16 kHz mono is resampled to whatever the hardware
# demands. Runs even under --no-apt: the native recorder links libasound
# directly and needs this whether or not alsa-utils is installed.
if [ "$AUDIO" -eq 1 ]; then
  echo ">> configuring ALSA default device"
  podman exec -i --user root "$NAME" bash -s <<'PROVISION_ALSA' || \
    echo ">> warning: could not configure ALSA default; /voice may fail to open the mic." >&2
set -eu
[ -r /proc/asound/pcm ] || { echo "no /proc/asound/pcm; skipping" >&2; exit 0; }

# Emit "card,device" for the best match in one direction, or nothing.
pick() {
  awk -F: -v want="$1" -v prefer="$2" -v avoid="$3" '
    BEGIN { best = -1 }
    {
      has = 0
      for (i = 4; i <= NF; i++) if ($i ~ want) has = 1
      if (!has) next
      split($1, a, "-"); nm = tolower($2)
      score = 1
      if (avoid  != "" && nm ~ avoid)  score = 0
      if (prefer != "" && nm ~ prefer) score = 2
      if (score > best) { best = score; res = (a[1] + 0) "," (a[2] + 0) }
    }
    END { if (best >= 0) print res }
  ' /proc/asound/pcm
}

capture=$(pick capture 'mic' 'feedback|loopback|monitor')
playback=$(pick playback 'speaker|analog|headphone' 'hdmi')

if [ -z "$capture" ]; then
  echo "no capture device found in /proc/asound/pcm; leaving ALSA default alone" >&2
  exit 0
fi
[ -n "$playback" ] || playback="$capture"

cat > /etc/asound.conf <<EOF
# Generated by launch-container.sh. ALSA's stock default is hw:0,0, which is
# not a capture device on every card; these were detected from
# /proc/asound/pcm at container-create time.
pcm.!default {
    type asym
    playback.pcm "plughw:${playback%,*},${playback#*,}"
    capture.pcm "plughw:${capture%,*},${capture#*,}"
}
ctl.!default {
    type hw
    card ${capture%,*}
}
EOF
echo "   capture -> plughw:${capture%,*},${capture#*,}   playback -> plughw:${playback%,*},${playback#*,}"
PROVISION_ALSA
fi

# ---- Claude Code update (fresh containers only) ----
#
# The image ships whatever `claude` build was current when it was published, and
# that binary lives in the CONTAINER's own ~/.local/bin - not in the mounted
# ~/.claude - so it does not persist, and every fresh container starts over from
# the image's version. `podman pull` above cannot fix that either: it refreshes
# the image, which is only rebuilt occasionally. So update in place instead.
#
# Runs as the container's default user (agent), NOT `--user root` like the apt
# step: ~/.local/bin belongs to agent, and as root the update would install into
# root's home where nothing looks for it. Best-effort by design, same as apt - an
# offline host should cost you a warning, not the shell.
if [ "$UPDATE" -eq 1 ]; then
  echo ">> updating Claude Code"
  podman exec "$NAME" bash -c '
    PATH="$HOME/.local/bin:$PATH"
    command -v claude >/dev/null 2>&1 || { echo "   no claude on PATH; skipping"; exit 0; }
    claude update' \
    || echo ">> warning: claude update failed (offline?); using the image's version." >&2
else
  echo ">> --no-update: not updating Claude Code."
fi

# ---- the repo's own setup script (fresh containers only) ----
#
# Everything above is what the image and the host owe the container; this is
# what the REPO owes it - pip lockfiles, a Playwright browser, whatever else its
# container-setup script establishes. A rebuild keeps only the bind mounts and
# ~/.claude, so the packages have to be put back every time, and a launcher that
# promises "the same container a hand launch would build" has to be the thing
# that puts them back. The motivating failure (2026-09-08): gm-assistant's scripts/repl.py on a
# cold host handed off here with --no-shell, got back a container with every
# mount and port and not one pip package, and died on its first import with
# `No module named 'configobj'`. Runs as the container's default user from the
# workdir (the script does its own sudo where it needs root). Best-effort like
# apt: a failed run warns and continues, and --no-setup skips it.
SETUP_SCRIPT="$(read_directive container-setup | head -n1)"
if [ -z "$SETUP_SCRIPT" ]; then
  :
elif [ "$SETUP" -eq 1 ]; then
  echo ">> running the repo's setup script: $SETUP_SCRIPT"
  podman exec --workdir "$WORKDIR" "$NAME" "$WORKDIR/$SETUP_SCRIPT" \
    || echo ">> warning: $SETUP_SCRIPT failed (offline?); rerun it by hand inside the container." >&2
else
  echo ">> --no-setup: not running $SETUP_SCRIPT."
fi

# ---- seed bash history ----
# Last provisioning step, so nothing lands after it; open_shell seeds again before every new shell.
seed_history

setup_container_audio

# --no-shell callers (gm-assistant's scripts/repl.py) want the container up, not a terminal.
if [ "$SHELL_AFTER" -eq 0 ]; then
  echo ">> --no-shell: '$NAME' is up; not opening a shell."
  exit 0
fi

open_shell
