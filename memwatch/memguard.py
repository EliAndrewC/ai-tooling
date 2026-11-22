#!/usr/bin/env python3
"""memguard: kill the biggest process in the Claude containers when they thrash at their memory cap,
and tell the Claude session that started it. Run by memwatch-events.sh (user service `memwatch`)
when the slice's memory.pressure "full" stays high; see CLAUDE.md, "memguard".

Why: at the cap with no swap, the kernel evicts the containers' program code over and over instead
of killing anything, the disk jams, and the desktop freezes (2026-10-02: 18 min, hard reset). The
kernel's own OOM killer then mostly picks tiny chrome-headless processes.

What it does, in one run:
  1. Picks the process in the slice with the most anonymous memory, never `claude` itself or the
     container plumbing (EXCLUDE).
  2. Finds the Claude session(s) behind it: CLAUDE_CODE_SESSION_ID / CLAUDE_PID in the environment
     of the process and its ancestors in the same container (every command a session runs inherits
     them, even after nohup), and any `claude` ancestor.
  3. If one of those sessions already had a memguard kill 1-15 minutes ago (its work refilled the
     cap: a kill-and-relaunch loop), kills the victim's whole command (its Unix session, which is
     one Bash tool call) unless that would include a `claude`; otherwise just the victim.
  4. Writes a memwatch event: events/<seq>.txt for every session, and events/<seq>.mine.txt with
     events/<seq>.to (match keys "sid:<id>" / "pid:<pidns>:<pid>") for the responsible sessions.
     ~/.claude/hooks/memwatch-hook.sh picks the right text per session.
Only memwatch-events.sh runs this, one run at a time, so the event sequence needs no lock.
"""
import argparse, json, os, re, signal, subprocess, sys, time

EXCLUDE = {"claude", "conmon", "catatonit", "tini", "podman", "slirp4netns", "pasta", "pasta.avx2",
           "rootlessport", "rootlessport-ch", "tmux: server", "systemd", "(sd-pam)", "dbus-daemon"}
EPISODE_GAP = int(os.environ.get("MEMGUARD_EPISODE_GAP", 60))       # kills closer than this: same episode
REPEAT_WINDOW = int(os.environ.get("MEMGUARD_REPEAT_WINDOW", 900))  # escalate within this

ap = argparse.ArgumentParser()
ap.add_argument("--slice", required=True)
ap.add_argument("--dir", required=True)
ap.add_argument("--label", default="")
ap.add_argument("--stall", type=float, required=True)  # % of time the slice was fully stalled
ap.add_argument("--ws", type=int, default=0)  # the slice's memory in use (memlib.sh inuse) in bytes, for the messages
ap.add_argument("--dry-run", action="store_true")
a = ap.parse_args()


def read(path):
    try:
        with open(path, "rb") as f:
            return f.read().decode(errors="replace")
    except OSError:
        return ""


def stat(pid):  # (comm, ppid, pgid, sid) as the host sees them
    s = read("/proc/%d/stat" % pid)
    if not s:
        return None
    rest = s[s.rindex(")") + 2:].split()
    return s[s.index("(") + 1:s.rindex(")")], int(rest[1]), int(rest[2]), int(rest[3])


def status(pid):
    d = {}
    for line in read("/proc/%d/status" % pid).splitlines():
        k, _, v = line.partition(":")
        d[k] = v.strip()
    return d


def kb(d, k):
    try:
        return int(d.get(k, "0 kB").split()[0])
    except ValueError:
        return 0


def gb(kib):
    return "%.1f" % (kib / 1048576)


def is_claude(pid, comm):
    # Claude Code started by its versioned path (.../claude/versions/2.1.321, e.g. a --resume'd fork or
    # a child) has comm "2.1.321", not "claude": 2026-11-19 the dry run picked one as its victim.
    if comm == "claude" or re.fullmatch(r"\d+\.\d+\.\d+", comm or ""):
        return True
    try:
        return "/claude/versions/" in os.readlink("/proc/%d/exe" % pid)
    except OSError:
        return False


def environ(pid):
    return dict(e.split("=", 1) for e in read("/proc/%d/environ" % pid).split("\0") if "=" in e)


def pidns(pid):
    try:
        return os.readlink("/proc/%d/ns/pid" % pid)
    except OSError:
        return ""


# Every process in the slice, with the container (libpod id) it's in.
procs = {}  # pid -> libpod container id, or "other"
for root, dirs, files in os.walk(a.slice):
    if "cgroup.procs" not in files:
        continue
    m = re.search(r"libpod-([0-9a-f]+)\.scope", root)
    where = m.group(1) if m else "other"
    for p in read(os.path.join(root, "cgroup.procs")).split():
        procs[int(p)] = where

cands = []
for pid in procs:
    st, sd = stat(pid), status(pid)
    if not st or st[0] in EXCLUDE or is_claude(pid, st[0]):
        continue
    cands.append((kb(sd, "RssAnon") + kb(sd, "RssShmem"), pid))
if not cands:
    print("memguard: nothing to kill")
    sys.exit(0)
size, victim = max(cands)
vcomm, _, vpgid, vsid = stat(victim)
where = procs[victim]
cmd = read("/proc/%d/cmdline" % victim).replace("\0", " ").strip()
cmd = re.sub(r"\s+", " ", cmd)
cmd = cmd if len(cmd) <= 120 else cmd[:117] + "..."

# The Claude sessions behind it: walk up while still in the victim's container (pid namespace).
ns = pidns(victim)
keys, sids = set(), []
p = victim
while p > 1 and pidns(p) == ns:
    env, st = environ(p), stat(p)
    if env.get("CLAUDE_CODE_SESSION_ID"):
        keys.add("sid:" + env["CLAUDE_CODE_SESSION_ID"])
        if env["CLAUDE_CODE_SESSION_ID"] not in sids:
            sids.append(env["CLAUDE_CODE_SESSION_ID"])
    if env.get("CLAUDE_PID", "").isdigit():
        keys.add("pid:%s:%s" % (ns, env["CLAUDE_PID"]))
    if st and is_claude(p, st[0]):
        nspid = status(p).get("NSpid", "").split()
        if nspid:
            keys.add("pid:%s:%s" % (ns, nspid[-1]))
    if not st:
        break
    p = st[1]

# Kill-and-relaunch loop? Escalate to the victim's whole command.
hist_path = os.path.join(a.dir, "memguard-history.json")
try:
    hist = json.loads(read(hist_path) or "{}")
except ValueError:
    hist = {}
now = time.time()
hist = {k: [t for t in v if now - t <= REPEAT_WINDOW] for k, v in hist.items()}
hist = {k: v for k, v in hist.items() if v}
prev = [t for k in keys for t in hist.get(k, []) if now - t >= EPISODE_GAP]
group = [victim]
if prev:
    for field in (3, 2):  # Unix session (one Bash tool call), else process group
        ident = vsid if field == 3 else vpgid
        members = [q for q in procs if (stat(q) or (None,) * 4)[field] == ident]
        if members and not any(is_claude(q, (stat(q) or ("",))[0]) for q in members):
            group = members
            break
total = sum(kb(status(q), "RssAnon") + kb(status(q), "RssShmem") for q in group)

if not a.dry_run:
    for q in sorted(group, key=lambda q: q != vsid):  # the session leader first, so nothing relaunches
        try:
            os.kill(q, signal.SIGKILL)
        except OSError:
            pass
    for k in keys:
        hist.setdefault(k, []).append(now)
    with open(hist_path + ".tmp", "w") as f:
        json.dump(hist, f)
    os.replace(hist_path + ".tmp", hist_path)

# The event. Container names come from podman, which can be slow while the disk is jammed: only
# after the kill.
where = procs[victim]
try:
    out = subprocess.run(["podman", "ps", "--no-trunc", "--format", "{{.ID}} {{.Names}}"],
                         capture_output=True, text=True, timeout=20).stdout
    for line in out.splitlines():
        cid, _, name = line.partition(" ")
        if cid == where:
            where = re.sub(r"^claude-", "", name)
except Exception:
    pass
if re.fullmatch(r"[0-9a-f]{13,}", where):
    where = where[:12]
cap = read(os.path.join(a.slice, "memory.max")).strip()
cap = gb(int(cap) / 1024) if cap.isdigit() else "?"
ws = gb(a.ws / 1024)
hm = time.strftime("%H:%M")
L = a.label + (": " if a.label else "")
what = "%s in the %s container (%s GB)" % (vcomm, where, gb(size))
why = ("The Claude containers were at their shared %s GB memory cap (%s GB in use, not counting caches) and fully stalled "
       "on memory %.0f%% of the time. That state jams the laptop's disk and freezes the whole desktop (on "
       "2026-10-02 it froze for 18 minutes and needed a hard reset)" % (cap, ws, a.stall))
if len(group) > 1:
    first = time.strftime("%H:%M", time.localtime(max(prev)))
    mine = (L + "MEMGUARD KILLED YOUR WHOLE COMMAND at %s: %d processes in the %s container, %s GB in all "
            "(the biggest: %s, %s GB; command: `%s`). %s. It had already killed one of your processes at "
            "%s, and your work filled the cap again: that kill-and-relaunch loop is what freezes the laptop. "
            "Do not restart it until you have cut its memory use (fewer parallel jobs, smaller batches, one "
            "at a time), and tell the user what was stopped and what you changed."
            % (hm, len(group), where, gb(total), vcomm, gb(size), cmd, why, first))
else:
    mine = (L + "MEMGUARD KILLED ONE OF YOUR PROCESSES at %s: %s in the %s container (%s GB; command: `%s`). "
            "%s, so memguard kills "
            "the biggest process in the containers, and that was yours. It was not a bug in your code. Do "
            "NOT re-run it as it was, and do not let a script, pool or queue relaunch it at the same size: "
            "cut the parallelism or batch size at least in half, or wait for other work to finish. If your "
            "work fills the cap again, memguard kills the whole command it belongs to, not just one "
            "process. If you can't make it smaller, stop and tell the user."
            % (hm, vcomm, where, gb(size), cmd, why))
killed = what if len(group) == 1 else "a whole command (%d processes, %s GB) in the %s container" % (
    len(group), gb(total), where)
owner = "which belongs to another Claude session" if keys else "which no Claude session could be traced to"
general = (L + "MEMGUARD at %s: the Claude containers were stalled at their shared %s GB memory cap "
           "(%s GB in use, not counting caches; fully stalled on memory %.0f%% of the time, which freezes the laptop's desktop), so memguard "
           "killed %s, %s. Nothing of yours was killed. Hold off on starting memory-heavy work "
           "(parallel jobs, test browsers, big data loads) until usage drops."
           % (hm, cap, ws, a.stall, killed, owner))

log = "memguard%s: %s %s pid %d (%s, %s GB%s; slice in use %s of %s GB) sessions %s keys %s" % (
    " DRY RUN" if a.dry_run else "", "would kill" if a.dry_run else "killed", vcomm, victim, where,
    gb(size), "; whole command, %d procs %s GB" % (len(group), gb(total)) if len(group) > 1 else "",
    ws, cap,
    ",".join(sids) or "-", " ".join(sorted(keys)) or "-")
print(log)
if a.dry_run:
    sys.exit(0)

ev = os.path.join(a.dir, "events")
os.makedirs(ev, exist_ok=True)
try:
    seq = int(read(os.path.join(a.dir, "latest")).split()[0]) + 1
except (IndexError, ValueError):
    seq = 1
for suffix, text in ((".to", "\n".join(sorted(keys)) + "\n"), (".mine.txt", mine + "\n"), (".txt", general + "\n")):
    with open(os.path.join(ev, "%d%s.tmp" % (seq, suffix)), "w") as f:
        f.write(text)
    os.replace(os.path.join(ev, "%d%s.tmp" % (seq, suffix)), os.path.join(ev, "%d%s" % (seq, suffix)))
with open(os.path.join(a.dir, "latest.tmp"), "w") as f:
    f.write("%d %d\n" % (seq, int(now)))
os.replace(os.path.join(a.dir, "latest.tmp"), os.path.join(a.dir, "latest"))
print("event %d: %s" % (seq, mine))
