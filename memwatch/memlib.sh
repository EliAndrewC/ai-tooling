# Sourced by memwatch-events.sh and cmem.sh, so both use the same measure of memory in use.
#
# inuse <cgroup dir>: bytes the kernel can't simply drop under pressure:
#   memory.current - inactive_file - active_file - slab_reclaimable + file_mapped
# i.e. process memory (anon, shmem), kernel memory (stacks, page tables, unreclaimable slab, sockets)
# and the file pages that are mapped into processes (program code: evicting them is the 2026-10-02
# thrash, so they count as in use). Everything else is file cache and the dentry/inode cache, which the
# kernel frees on demand before it kills anything. Missing fields count as 0, which errs towards a
# higher figure (the old measure).
#
# Don't go back to subtracting only inactive_file: on 2026-11-19 a container that stat'ed ~1.7 million
# files had 5.4 GB of slab_reclaimable and 2 GB of active_file against 1.7 GB of anon, memwatch warned
# for hours, and memguard's near-cap gate stood open with ~2.6 GB really in use.
inuse() {
  local cur
  cur=$(cat "$1/memory.current" 2>/dev/null) || return 1
  awk -v cur="$cur" '
    $1=="inactive_file" || $1=="active_file" || $1=="slab_reclaimable" { drop += $2 }
    $1=="file_mapped" { mapped = $2 }
    END { v = cur - drop + mapped; if (v < 0) v = 0; if (v > cur) v = cur; printf "%.0f\n", v }  # not %d: mawk caps it at 2^31
  ' "$1/memory.stat" 2>/dev/null || echo "$cur"
}
