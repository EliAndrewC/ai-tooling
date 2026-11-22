#!/bin/bash
# Watch the Claude containers' shared memory cgroup and write an event for Claude sessions when
# (a) the containers get close to their cap (warn) or (b) the kernel OOM-kills a process in them
# (kill). "Close" is measured on memory in use (memlib.sh: memory.current less file and dentry/inode
# caches, which the kernel frees on demand; mapped program code counts as in use). The
# Claude Code hook ~/.claude/hooks/memwatch-hook.sh delivers the events to every session (in the
# containers and on the host, which all share ~/.claude). See CLAUDE.md, "memwatch".
#
# Events: $MW_DIR/events/<seq>.txt (the message text) and $MW_DIR/latest ("<seq> <epoch>"),
# written after the event file so a reader never sees a seq without its text. Only this script
# writes them. No root needed. Runs as the user service `memwatch` (enabled, starts at login).
#
# memguard: every MEMGUARD_INTERVAL s it also reads the slice's memory.pressure. When the slice has
# been fully stalled on memory >= MEMGUARD_FULL_PCT % of the time for MEMGUARD_SAMPLES samples in a
# row (thrashing at the cap, which freezes the desktop), it runs memguard.py, which kills the biggest
# process and tells the session behind it. MEMGUARD_DRY_RUN=1 only logs what it would kill.
# It kills only when memory in use is within MEMGUARD_NEAR_CAP_MB of the cap: a disk/swap storm
# (2026-10-03: a Claude Code update, containers at 6.3 of 10 GB) stalls the slice on memory too, and
# so does reclaiming a huge dentry/inode cache at the cap (2026-11-19: 36% stalls with 2.6 GB in use);
# killing a container process does nothing for either.
#
# Test without touching the real slice (events are prefixed "TEST"):
#   MEMWATCH_SLICE=<cgroup dir> MEMWATCH_LABEL=TEST MEMWATCH_INTERVAL=2 ./memwatch-events.sh
set -u
HERE=$(dirname "$(readlink -f "$0")")
U=$(id -u)
SLICE="${MEMWATCH_SLICE:-/sys/fs/cgroup/user.slice/user-$U.slice/user@$U.service/claude.slice/claude-containers.slice}"
MW_DIR="${MEMWATCH_DIR:-$HOME/.claude/memwatch}"
INTERVAL="${MEMWATCH_INTERVAL:-10}"
G_INTERVAL="${MEMGUARD_INTERVAL:-2}"
G_PCT="${MEMGUARD_FULL_PCT:-10}"
G_SAMPLES="${MEMGUARD_SAMPLES:-3}"
G_NEAR_MB="${MEMGUARD_NEAR_CAP_MB:-1024}"
LABEL="${MEMWATCH_LABEL:+$MEMWATCH_LABEL: }"
mkdir -p "$MW_DIR/events" "$MW_DIR/seen"

gb() { awk -v b="$1" 'BEGIN{printf "%.1f", b/1073741824}'; }

. "$HERE/memlib.sh"  # inuse <cgroup dir>: memory in use, without caches the kernel frees on demand

cap_bytes() {  # the kill point: memory.max, else memory.high; empty when neither is set
  local v
  for f in memory.max memory.high; do
    v=$(cat "$SLICE/$f" 2>/dev/null)
    [[ "$v" =~ ^[0-9]+$ ]] && { echo "$v"; return; }
  done
}

# "libpod-<id>" -> container name (claude- prefix dropped), for every running container
declare -A NAME
container_names() {
  NAME=()
  while read -r id name; do NAME[$id]=${name#claude-}; done \
    < <(podman ps --no-trunc --format '{{.ID}} {{.Names}}' 2>/dev/null)
}

per_container() {  # " (diagram 7.9, character-sheet 0.3)", or nothing
  local out="" d id m
  for d in "$SLICE"/libpod-*.scope; do
    [ -d "$d" ] || continue
    case "$d" in */libpod-conmon-*) continue ;; esac
    id=${d##*/libpod-}; id=${id%.scope}
    m=$(inuse "$d") || continue
    out+="${NAME[$id]:-${id:0:12}} $(gb "$m"), "
  done
  [ -n "$out" ] && echo " (${out%, })"
}

top_procs() {  # the 4 biggest processes in the slice: "python3 in diagram 2.1 GB; ..."
  local d id pids
  for d in $(find "$SLICE" -name cgroup.procs 2>/dev/null); do
    id=$(grep -o 'libpod-[0-9a-f]*' <<<"$d" | head -1); id=${id#libpod-}
    pids=$(tr '\n' ',' < "$d"); pids=${pids%,}
    if [ -n "$id" ]; then c=${NAME[$id]:-${id:0:12}}; else c=other; fi
    [ -n "$pids" ] && ps -o rss=,comm= -p "$pids" 2>/dev/null | sed "s|\$| $c|"
  done | sort -rn | head -4 | awk '{printf "%s%s in %s %.1f GB", (NR>1?"; ":""), $2, $3, $1/1048576}'
}

emit() {  # emit <text>
  local seq
  seq=$(( $(cut -d' ' -f1 "$MW_DIR/latest" 2>/dev/null || echo 0) + 1 ))
  printf '%s\n' "$1" > "$MW_DIR/events/$seq.txt.tmp" && mv "$MW_DIR/events/$seq.txt.tmp" "$MW_DIR/events/$seq.txt"
  echo "$seq $(date +%s)" > "$MW_DIR/latest.tmp" && mv "$MW_DIR/latest.tmp" "$MW_DIR/latest"
  echo "event $seq: $1"
}

full_us() { awk '$1=="full"{for(i=2;i<=NF;i++) if(sub(/^total=/,"",$i)) print $i}' "$SLICE/memory.pressure" 2>/dev/null; }

kills() { awk '$1=="oom_kill"{print $2}' "$SLICE/memory.events" 2>/dev/null || echo 0; }

last_kills=$(kills)
last_check=$(date +%s)
warned=0
g_last=$(full_us); g_t=$(date +%s%N); hot=0; hot_sum=0
while :; do
  sleep "$G_INTERVAL"

  # memguard: share of the last interval in which every task in the slice was stalled on memory,
  # in tenths of a percent.
  g=$(full_us); t=$(date +%s%N)
  if [ -n "$g" ] && [ -n "$g_last" ] && [ "$t" -gt "$g_t" ]; then
    stall=$(( (g - g_last) * 1000000 / (t - g_t) ))
    if [ "$stall" -ge $(( G_PCT * 10 )) ]; then
      hot=$((hot + 1)); hot_sum=$((hot_sum + stall))
      g_cap=$(cap_bytes); g_ws=$(inuse "$SLICE" || echo 0); g_raw=$(cat "$SLICE/memory.current" 2>/dev/null || echo 0)
      echo "memguard: slice fully stalled on memory $((stall / 10))% ($hot/$G_SAMPLES); in use $(gb "$g_ws") of $(gb "${g_cap:-0}") GB, $(gb "$g_raw") GB with caches (anon $(gb "$(awk '$1=="anon"{print $2}' "$SLICE/memory.stat" 2>/dev/null)"), active_file $(gb "$(awk '$1=="active_file"{print $2}' "$SLICE/memory.stat" 2>/dev/null)"), slab_reclaimable $(gb "$(awk '$1=="slab_reclaimable"{print $2}' "$SLICE/memory.stat" 2>/dev/null)")); laptop $(awk '$1=="MemAvailable:"{printf "%.1f", $2/1048576}' /proc/meminfo) GB available"
    else
      [ "$stall" -ge 20 ] && echo "memguard: slice fully stalled on memory $((stall / 10)).$((stall % 10))%"
      hot=0; hot_sum=0
    fi
    if [ "$hot" -ge "$G_SAMPLES" ] && [ -n "${g_cap:-}" ] && [ "$g_ws" -lt $(( g_cap - G_NEAR_MB * 1048576 )) ]; then
      echo "memguard: NOT killing: memory in use $(gb "$g_ws") GB is more than ${G_NEAR_MB} MB below the $(gb "$g_cap") GB cap, so this stall is disk/swap pressure or the kernel reclaiming caches, not processes filling the cap"
      hot=0; hot_sum=0
    elif [ "$hot" -ge "$G_SAMPLES" ]; then
      python3 "$HERE/memguard.py" --slice "$SLICE" --dir "$MW_DIR" --label "${MEMWATCH_LABEL:-}" \
        --stall "$(awk -v s="$hot_sum" -v n="$hot" 'BEGIN{printf "%.1f", s/n/10}')" --ws "$g_ws" \
        ${MEMGUARD_DRY_RUN:+--dry-run}
      hot=0; hot_sum=0
      g=$(full_us); t=$(date +%s%N)  # judge the next interval from after the kill
    fi
  fi
  g_last=$g; g_t=$t

  now=$(date +%s)
  [ $(( now - last_check )) -ge "$INTERVAL" ] || continue
  cap=$(cap_bytes)
  raw=$(cat "$SLICE/memory.current" 2>/dev/null || echo 0)
  cur=$(inuse "$SLICE" || echo 0)
  k=$(kills)

  if [ "${k:-0}" -gt "${last_kills:-0}" ]; then
    container_names
    # oom-kill:...,task_memcg=/.../libpod-<id>.scope/...,task=python3,pid=123,...  and
    # Memory cgroup out of memory: Killed process 123 (python3) total-vm:..., anon-rss:2345678kB, ...
    what=$(journalctl -k --since "@$((last_check - 5))" -o cat --no-pager 2>/dev/null | awk -v names="$(for i in "${!NAME[@]}"; do printf '%s=%s ' "$i" "${NAME[$i]}"; done)" '
      BEGIN { n = split(names, a, " "); for (i = 1; i <= n; i++) { split(a[i], kv, "="); nm[kv[1]] = kv[2] } }
      /oom-kill:/ && match($0, /libpod-[0-9a-f]+/) { id = substr($0, RSTART + 7, RLENGTH - 7); where[++w] = (id in nm ? nm[id] : substr(id, 1, 12)) }
      /Killed process/ && match($0, /\([^)]*\)/) {
        name = substr($0, RSTART + 1, RLENGTH - 2); rss = ""
        if (match($0, /anon-rss:[0-9]+/)) rss = sprintf(", %.1f GB", substr($0, RSTART + 9, RLENGTH - 9) / 1048576)
        out = out (out ? "; " : "") name " in the " (where[w] ? where[w] : "?") " container" rss
      }
      END { print out }')
    n=$((k - last_kills))
    emit "${LABEL}OUT-OF-MEMORY KILL at $(date +%H:%M): the Claude containers hit their shared $(gb "${cap:-0}") GB memory cap and the kernel killed $n process(es): ${what:-details not in the kernel log}. If a command, background job or subagent of yours died with \"Killed\", exit code 137 or SIGKILL, this is why: it was not a bug in your code. Do not just re-run it at the same size. Use fewer parallel jobs or smaller batches, or wait for other work to finish. Memory in use now: $(gb "$cur") of $(gb "${cap:-0}") GB$(per_container)."
    last_kills=$k
    warned=1  # a kill implies the warning; re-arm only once usage drops back
  elif [ -n "$cap" ]; then
    warn_at=$(( cap - ${MEMWATCH_WARN_BELOW_CAP_MB:-1024} * 1048576 ))
    if [ "$warned" = 0 ] && [ "$cur" -ge "$warn_at" ]; then
      container_names
      emit "${LABEL}LOW MEMORY WARNING at $(date +%H:%M): the Claude containers' processes and kernel are using $(gb "$cur") of their shared $(gb "$cap") GB memory cap$(per_container), plus $(gb "$(( raw - cur ))") GB of file and directory caches the kernel frees on demand (not counted). At $(gb "$cap") GB processes in them get killed: by memguard, which takes the biggest one and tells the session that started it, or by the kernel. Biggest now: $(top_procs). Nothing has been killed yet. If you started memory-heavy work (parallel jobs, test browsers, big data loads), consider scaling it down or waiting, and watch for commands dying with \"Killed\" / exit 137."
      warned=1
    elif [ "$warned" = 1 ] && [ "$cur" -lt $(( warn_at - 512 * 1048576 )) ]; then
      warned=0
    fi
  fi
  last_check=$now

  # Housekeeping: drop events and per-session "seen" markers older than a week.
  find "$MW_DIR/events" "$MW_DIR/seen" -type f -mtime +7 -delete 2>/dev/null
done
