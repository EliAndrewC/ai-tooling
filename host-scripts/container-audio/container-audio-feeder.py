#!/usr/bin/env python3
"""container-audio feeder: the host end of the one-way microphone pipe into dev containers.

Every container launched by launch-container gets a host-owned FIFO, pipes/<container>.fifo beside
this script (mounted read-only in the container at /host-scripts/container-audio/pipes/). This service
writes a real-time raw audio stream (s16le, 48 kHz, stereo) into each FIFO whose container end is open:

- silence, except while the space bar is held (Claude Code's push-to-talk);
- once space has been held HOLD_MS, the host's default PulseAudio source (the built-in mic, or a
  headset if one is the default), until TAIL_MS after release. So the mic, and GNOME's mic indicator,
  is on only while dictating. Claude Code itself starts recording only after the key repeat begins
  (500 ms here), so the mic's ~150 ms cold start lands before it listens.

Writes are NONBLOCKING and atomic (<= PIPE_BUF): when a container stops reading, its 1 MB pipe (~5 s)
fills and further audio is DROPPED for it, never queued, so a container can't make the host wait and
never gets minutes-old audio. Nothing is ever read from a container. Why this exists and every
alternative that failed: CLAUDE.md beside this script.

Test mode: CONTAINER_AUDIO_FORCE_MIC=1 keeps the mic on regardless of the space bar.
"""
import errno
import fcntl
import os
import signal
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.realpath(__file__))
PIPES = os.environ.get("CONTAINER_AUDIO_PIPES", os.path.join(HERE, "pipes"))
SPACE = os.path.expanduser(os.environ.get("CONTAINER_AUDIO_SPACEBAR", "~/.claude/voice-corrections/spacebar"))
FORCE_MIC = os.environ.get("CONTAINER_AUDIO_FORCE_MIC") == "1"
RATE, FRAME = 48000, 4                  # s16le stereo
TICK = 0.01
CHUNK = 4096                            # PIPE_BUF: a nonblocking write this size is all-or-nothing
PIPE_SIZE = 1 << 20
HOLD_MS, TAIL_MS = 150, 1500
MAX_LAG = int(RATE * 0.05)              # pad with silence when the mic falls this far behind the clock
F_SETPIPE_SZ = 1031


def log(msg):
    print(msg, file=sys.stderr, flush=True)


class Outputs:
    """The open FIFOs, by name. Opened when the container end is reading; closed when it goes away."""

    def __init__(self):
        self.fds = {}
        self.dropped = {}
        self.next_scan = 0.0

    def scan(self, now):
        if now < self.next_scan:
            return
        self.next_scan = now + 1.0
        try:
            names = [n for n in os.listdir(PIPES) if n.endswith(".fifo")]
        except FileNotFoundError:
            return
        for name in names:
            if name in self.fds:
                continue
            path = os.path.join(PIPES, name)
            try:
                fd = os.open(path, os.O_WRONLY | os.O_NONBLOCK)
            except OSError as e:
                if e.errno not in (errno.ENXIO, errno.ENOENT):   # ENXIO: no reader yet
                    log(f"{name}: cannot open: {e}")
                continue
            try:
                fcntl.fcntl(fd, F_SETPIPE_SZ, PIPE_SIZE)
            except OSError as e:
                log(f"{name}: pipe stays at its default size: {e}")
            self.fds[name] = fd
            self.dropped[name] = 0
            log(f"{name}: container end open, streaming")

    def write(self, data):
        for name, fd in list(self.fds.items()):
            for i in range(0, len(data), CHUNK):
                piece = data[i:i + CHUNK]
                try:
                    os.write(fd, piece)
                except BlockingIOError:
                    self.dropped[name] += len(piece) // FRAME       # container not reading: drop
                except OSError:                                     # EPIPE: container end closed
                    os.close(fd)
                    del self.fds[name]
                    log(f"{name}: container end closed ({self.dropped.pop(name)} frames dropped while it lagged)")
                    break


class Mic:
    def __init__(self):
        self.proc = None
        self.buf = b""

    def on(self):
        if self.proc:
            return
        self.proc = subprocess.Popen(
            ["parec", "--device=@DEFAULT_SOURCE@", "--raw", "--format=s16le", f"--rate={RATE}",
             "--channels=2", "--latency-msec=20", "--client-name=container-audio"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        os.set_blocking(self.proc.stdout.fileno(), False)
        self.buf = b""
        log("mic on")

    def off(self):
        if not self.proc:
            return
        self.proc.kill()
        self.proc.wait()
        self.proc = None
        self.buf = b""
        log("mic off")

    def read(self):
        if not self.proc:
            return b""
        if self.proc.poll() is not None:
            log(f"parec exited ({self.proc.returncode}); retrying next hold")
            self.proc = None
            return b""
        try:
            while True:
                more = os.read(self.proc.stdout.fileno(), 65536)
                if not more:
                    break
                self.buf += more
        except BlockingIOError:
            pass
        whole = len(self.buf) - len(self.buf) % FRAME
        out, self.buf = self.buf[:whole], self.buf[whole:]
        return out


def space_state():
    """(held, last_release_ms) from spacebar-watch: '0' while held, else the epoch ms of the release."""
    try:
        v = int(open(SPACE).read().strip() or "-1")
    except (OSError, ValueError):
        return False, 0
    return v == 0, max(v, 0)


def main():
    os.makedirs(PIPES, exist_ok=True)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    outs, mic = Outputs(), Mic()
    held_since = None
    base, sent = time.monotonic(), 0              # the stream's clock: frames owed since base
    mic_wanted = False
    log(f"container-audio feeder: pipes in {PIPES}{' (FORCE_MIC)' if FORCE_MIC else ''}")
    try:
        while True:
            now = time.monotonic()
            outs.scan(now)
            held, released = space_state()
            if held:
                held_since = held_since if held_since is not None else now
            else:
                held_since = None
            if FORCE_MIC or (held and now - held_since >= HOLD_MS / 1000):
                mic_wanted = True
            elif mic_wanted and not held and time.time() * 1000 - released > TAIL_MS:
                mic_wanted = False
            if mic_wanted and outs.fds:
                mic.on()
            else:
                mic.off()

            due = int((now - base) * RATE) - sent
            data = mic.read()
            frames = len(data) // FRAME
            # Mic off: silence, every tick. Mic on but behind (starting up): pad, so the container's
            # reader never waits on an empty pipe (it then blocks, measured 2026-11-26).
            if due > 0 and (not mic.proc or frames < due - MAX_LAG):
                data += b"\0" * ((due - frames) * FRAME)
                frames = due
            sent += frames
            if sent > int((now - base) * RATE) + RATE:   # mic ran ahead of the clock: rebase
                base, sent = now, 0
            if data and outs.fds:
                outs.write(data)
            time.sleep(TICK)
    finally:
        mic.off()


if __name__ == "__main__":
    main()
