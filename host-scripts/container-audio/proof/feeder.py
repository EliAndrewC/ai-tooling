"""Real-time source: frame i carries i (low 16 bits left, high 16 bits right). Writes NONBLOCKING:
when the pipe is full the chunk is dropped, as the real host relay must (a mic never waits).
Writes its start time to T0FILE so a reader can compute latency."""
import fcntl, os, struct, sys, time
path, t0file = sys.argv[1], sys.argv[2]
fd = os.open(path, os.O_WRONLY)              # blocks until the container side opens it
fcntl.fcntl(fd, fcntl.F_SETFL, os.O_NONBLOCK)
if len(sys.argv) > 3: print("pipe size", fcntl.fcntl(fd, 1031, int(sys.argv[3])), file=sys.stderr)  # F_SETPIPE_SZ
t0 = time.time(); open(t0file, "w").write(repr(t0)); n = 0; dropped = 0
while True:
    due = int((time.time() - t0) * 48000) - n
    if due < 240: time.sleep(0.002); continue
    chunk = b"".join(struct.pack("<HH", i & 0xFFFF, (i >> 16) & 0xFFFF) for i in range(n, n + due))
    try:
        w = os.write(fd, chunk)
        if w < len(chunk): dropped += (len(chunk) - w) // 4   # partial: rest dropped (frame-aligned in practice)
    except BlockingIOError:
        dropped += due
    n += due
