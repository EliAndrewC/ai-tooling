#!/bin/bash
# cmem: how much of the Claude containers' shared memory cap is in use, and how much is left.
# Uses the same measure as memwatch (memlib.sh: in use = memory.current less file and dentry/inode
# caches the kernel frees on demand; mapped program code counts as in use), so
# "left before warning" matches when sessions get the LOW MEMORY WARNING. Also shows the laptop's
# own free RAM, since the containers can't use more than the host has. No root needed.
#   cmem                   one snapshot
#   cmem --watch [SECS]    refresh every SECS s (default 10; -w works too), Ctrl-C to stop.
#                          The terminal's title is "cmem" meanwhile and goes back afterwards.
set -u
if [ "${1:-}" = "-w" ] || [ "${1:-}" = "--watch" ]; then
  secs=${2:-10}
  [[ "$secs" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "cmem: --watch takes seconds, e.g. cmem --watch 5" >&2; exit 2; }
  if [ -t 1 ]; then
    # Push the current title on the terminal's title stack (XTPUSHTITLE), set ours, pop it on exit.
    printf '\e[22;0t\e]0;cmem\a'
    trap 'printf "\e[23;0t"' EXIT
    trap 'exit 130' INT TERM  # no exec: the shell must outlive watch to restore the title
  fi
  watch -n "$secs" -t "$0"
  exit
fi

U=$(id -u)
SLICE="${MEMWATCH_SLICE:-/sys/fs/cgroup/user.slice/user-$U.slice/user@$U.service/claude.slice/claude-containers.slice}"
WARN_BELOW=$(( ${MEMWATCH_WARN_BELOW_CAP_MB:-1024} * 1048576 ))

gb() { awk -v b="$1" 'BEGIN{printf "%5.1f", b/1073741824}'; }
. "$(dirname "$(readlink -f "$0")")/memlib.sh"  # inuse <cgroup dir>
claudes() {  # "3 sessions" or "3 sessions + 2 headless": claude processes in a cgroup tree.
  # Sessions Eli started run in a terminal; ones a script launched (claude -p) have no tty.
  local i=0 h=0 p rest
  for p in $(cat $(find "$1" -name cgroup.procs 2>/dev/null) 2>/dev/null); do
    [ "$(cat /proc/$p/comm 2>/dev/null)" = claude ] || continue
    rest=$(sed 's/.*) //' /proc/$p/stat 2>/dev/null) || continue
    set -- $rest  # $5 is tty_nr; 0 means no controlling terminal
    if [ "${5:-0}" != 0 ]; then i=$((i + 1)); else h=$((h + 1)); fi
  done
  echo "$i sessions$( ((h)) && echo " + $h headless")"
}

if [ ! -d "$SLICE" ]; then
  echo "No containers slice ($SLICE); no containers running?"; exit 1
fi

cap=""
for f in memory.max memory.high; do
  v=$(cat "$SLICE/$f" 2>/dev/null); [[ "$v" =~ ^[0-9]+$ ]] && { cap=$v; break; }
done
used=$(inuse "$SLICE"); raw=$(cat "$SLICE/memory.current")
host_avail=$(( $(awk '$1=="MemAvailable:"{print $2}' /proc/meminfo) * 1024 ))
host_total=$(( $(awk '$1=="MemTotal:"{print $2}' /proc/meminfo) * 1024 ))

declare -A NAME
while read -r id name; do NAME[$id]=${name#claude-}; done \
  < <(podman ps --no-trunc --format '{{.ID}} {{.Names}}' 2>/dev/null)

cache=$(( raw - used ))
if [ -n "$cap" ]; then
  echo "Claude containers: $(gb "$cap" | tr -d ' ') GB cap, $(claudes "$SLICE" | sed "s/sessions/Claude sessions/")"
else
  echo "Claude containers: no cap set, $(claudes "$SLICE" | sed "s/sessions/Claude sessions/")"
fi
printf "  %-20s %s GB\n" "in use" "$(gb "$used")"
for d in "$SLICE"/libpod-*.scope; do
  [ -d "$d" ] || continue
  case "$d" in */libpod-conmon-*) continue ;; esac
  id=${d##*/libpod-}; id=${id%.scope}
  m=$(inuse "$d") || continue
  printf "    %-18s(%s GB, %s)\n" "${NAME[$id]:-${id:0:12}}" "$(gb "$m" | tr -d ' ')" "$(claudes "$d")"
done
printf "  %-20s %s GB   (file + directory caches; freed automatically when needed)\n" "+ caches" "$(gb "$cache")"
if [ -n "$cap" ]; then
  # Round in/cache to 0.1 GB first and derive unused from them, so the printed column adds up.
  t() { echo $(( ($1 * 10 + 536870912) / 1073741824 )); }  # bytes -> tenths of a GB
  unused=$(( ($(t "$cap") - $(t "$used") - $(t "$cache")) * 107374182 )); (( unused < 0 )) && unused=0
  left=$(( cap - used )); warn_left=$(( cap - WARN_BELOW - used ))
  (( warn_left < 0 )) && warn_left=0
  printf "  %-20s %s GB\n" "+ unused" "$(gb "$unused")"
  printf "  %-20s %s GB\n" "= cap" "$(gb "$cap")"
  echo
  printf "  %-20s %s GB   (unused + caches; %s GB before the memwatch warning)\n" "AVAILABLE" "$(gb $(( unused + $(t "$cache") * 107374182 )))" "$(gb "$warn_left" | tr -d ' ')"
fi
echo
echo "Laptop"
printf "  %-20s %s GB of %s GB   (free + file cache)\n" "available" "$(gb "$host_avail")" "$(gb "$host_total")"
if [ -n "$cap" ] && (( host_avail < left )); then
  echo "  NOTE: the host has less free than the containers' cap allows; host RAM is the real limit."
fi
