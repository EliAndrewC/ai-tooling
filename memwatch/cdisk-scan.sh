#!/bin/bash
# cdisk-scan: measure how much disk each Claude container's own files take, for cmem's Disk section.
# Run by the user timer cdisk-scan.timer (hourly); takes ~2-4 min on a 200 GB layer.
#
# It must never be what slows the laptop down (the desktop freezes here have been disk stalls, not CPU):
#   - idle I/O class (works because the disk's scheduler is bfq; under "none" ionice does nothing)
#     and nice 19;
#   - skips the scan if the disk is already contended (PSI io "full" avg60 >= CDISK_SKIP_FULL, default 5%);
#   - while running, SIGSTOPs du whenever io "full" avg10 >= CDISK_PAUSE_FULL (default 5%) and resumes it
#     below half that; gives up after CDISK_MAX_SECS (default 1800) and keeps the previous figures.
#
# What it measures: rootless podman storage (~/.local/share/containers/storage/overlay). A container's
# writable layer (overlay/<id>/diff) holds everything it wrote outside its bind mounts (its /tmp,
# ~/.cache, build caches); every other overlay dir is an image layer. The files belong to the
# containers' mapped UIDs, so a plain du skips them: it has to run under `podman unshare`.
# A live du on every cmem call is far too slow (111 s on 2026-11-25), hence this cache.
#
# Output: one line per scan per item appended to $CDISK_HISTORY (default ~/.cache/cmem/disk-history.tsv):
#   <epoch> TAB <name> TAB <MB>
# names: each container (without "claude-"), "_images" (all other overlay dirs), "_used" (df used on
# the storage filesystem at scan time). Lines older than 8 days are dropped.
set -u
HIST="${CDISK_HISTORY:-$HOME/.cache/cmem/disk-history.tsv}"
STORAGE="${CDISK_STORAGE:-$HOME/.local/share/containers/storage}"
mkdir -p "$(dirname "$HIST")"
exec 9>"$HIST.lock"
flock -n 9 || { echo "cdisk-scan: another scan is running"; exit 0; }

declare -A LAYER  # overlay dir name -> container name
while read -r name upper; do
  [ -n "$upper" ] || continue
  id=${upper%/diff}; id=${id##*/}
  LAYER[$id]=${name#claude-}
done < <(for c in $(podman ps -aq 2>/dev/null); do
  podman inspect --format '{{.Name}} {{.GraphDriver.Data.UpperDir}}' "$c" 2>/dev/null
done)

SKIP=${CDISK_SKIP_FULL:-5}; PAUSE=${CDISK_PAUSE_FULL:-5}; MAX=${CDISK_MAX_SECS:-1800}
iofull() {  # io "full" stall %, field avg10 or avg60, as an integer
  awk -v f="$1" '$1=="full"{for(i=2;i<=NF;i++) if (split($i,kv,"=")==2 && kv[1]==f) printf "%d", kv[2]}' /proc/pressure/io
}
if [ "$(iofull avg60)" -ge "$SKIP" ]; then
  echo "cdisk-scan: disk busy (io full avg60 $(iofull avg60)% >= $SKIP%); skipped, keeping the last figures"
  exit 0
fi

now=$(date +%s)
out=$(mktemp "$HIST.du.XXXXXX")
# One du over the whole overlay dir, so a file hardlinked between layers is counted once.
( cd "$STORAGE" && exec podman unshare ionice -c3 nice -n 19 du -x --block-size=1M -d 1 overlay ) > "$out" 2>/dev/null &
scan=$!
paused=0; start=$SECONDS
dupids() {  # this scan's own du (a descendant of $scan), never another scan's or anyone else's
  local p=$scan kids
  while kids=$(pgrep -P "$p"); [ -n "$kids" ]; do
    for p in $kids; do [ "$(cat /proc/$p/comm 2>/dev/null)" = du ] && { echo "$p"; return; }; done
    p=${kids%%$'\n'*}
  done
}
while kill -0 "$scan" 2>/dev/null; do
  if (( SECONDS - start > MAX )); then
    kill -CONT $(dupids) 2>/dev/null; kill $(dupids) 2>/dev/null
    echo "cdisk-scan: gave up after ${MAX}s (paused for disk pressure too long); keeping the last figures"
    rm -f "$out"; exit 0
  fi
  f=$(iofull avg10)
  if (( ! paused && f >= PAUSE )); then kill -STOP $(dupids) 2>/dev/null && paused=1
  elif (( paused && f * 2 < PAUSE )); then kill -CONT $(dupids) 2>/dev/null && paused=0
  fi
  sleep 2
done
wait "$scan" || { echo "cdisk-scan: du failed under podman unshare" >&2; rm -f "$out"; exit 1; }
sizes=$(cat "$out"); rm -f "$out"
used=$(df --block-size=1M --output=used "$STORAGE" | tail -1 | tr -d ' ')

tmp=$(mktemp "$HIST.XXXXXX")
cutoff=$(( now - 8 * 86400 ))
[ -f "$HIST" ] && awk -F'\t' -v c="$cutoff" '$1 >= c' "$HIST" > "$tmp"
total=0; images=0
while read -r mb path; do
  d=${path#overlay}; d=${d#/}
  if [ -z "$d" ]; then total=$mb; continue; fi
  if [ -n "${LAYER[$d]:-}" ]; then
    printf '%s\t%s\t%s\n' "$now" "${LAYER[$d]}" "$mb" >> "$tmp"
  else
    images=$(( images + mb ))
  fi
done <<< "$sizes"
printf '%s\t_images\t%s\n%s\t_used\t%s\n' "$now" "$images" "$now" "$used" >> "$tmp"
mv "$tmp" "$HIST"
echo "cdisk-scan: overlay ${total} MB (containers' layers + ${images} MB images), df used ${used} MB"
