#!/usr/bin/env python3
"""spacebar-watch: publish whether the space bar is held, for the voice-corrections mod.

Why: Claude Code's voice dictation records while space is held, and Eli pauses for 10+ seconds mid-sentence
while holding it. The voice-corrections mod must never rewrite the prompt box during a recording, and no
timer can tell a thinking pause from the end of a recording. Wayland gives apps no global key state, so
this reads the kernel's keyboard devices directly.

Security: the input devices are root:input. Rather than put Eli in the `input` group (every process of his
could then log every key, passwords included), this one process runs as the installing user with `input` as a
supplementary group (spacebar-watch.service), watches KEY_SPACE only, and publishes only that.

State file: ~/.claude/voice-corrections/spacebar (under ~/.claude so dev containers see it through their
~/.claude mount). Written atomically (temp + rename), only on a transition:
    0                  space is down on some keyboard
    <epoch ms>         every keyboard's space is up; the time of the last release
The mod reads it on every poll tick: "0" = recording may be in progress; a timestamp = released at that time.

Keyboards: every /dev/input/event* whose key capabilities include KEY_SPACE (laptop keyboard, USB and
Bluetooth keyboards, ydotoold's virtual one). Rescanned every 2 s for hotplug; a device that errors is dropped
(and its space counted as up). On (re)open, EVIOCGKEY gives the current state, so a key already held counts.

Run by spacebar-watch.service (installed by fix-voice-corrections.sh). Foreground test, as root or with
input access:  spacebar-watch.py --state /tmp/spacebar-test --verbose
"""
import argparse
import fcntl
import glob
import os
import select
import struct
import sys
import time

EV_KEY = 1
KEY_SPACE = 57
KEY_MAX = 0x2FF
EVENT = struct.Struct("llHHi")  # struct input_event on 64-bit: timeval, type, code, value
KEYBITS_LEN = KEY_MAX // 8 + 1
EVIOCGKEY = (2 << 30) | (KEYBITS_LEN << 16) | (ord("E") << 8) | 0x18
RESCAN_SECONDS = 2.0


def has_space_key(event_path):
    """True if the device's key capability bitmap includes KEY_SPACE (from sysfs; no device access needed)."""
    name = os.path.basename(event_path)
    try:
        with open(f"/sys/class/input/{name}/device/capabilities/key") as f:
            words = f.read().split()
    except OSError:
        return False
    # Space-separated hex words, most significant first; each word is one unsigned long (64 bits here).
    bits = 0
    for word in words:
        bits = (bits << 64) | int(word, 16)
    return bool(bits >> KEY_SPACE & 1)


def space_down_now(fd):
    buf = bytearray(KEYBITS_LEN)
    fcntl.ioctl(fd, EVIOCGKEY, buf)
    return bool(buf[KEY_SPACE // 8] >> (KEY_SPACE % 8) & 1)


class Watcher:
    def __init__(self, state_path, verbose=False):
        self.state_path = state_path
        self.verbose = verbose
        self.devices = {}  # path -> fd
        self.down = set()  # paths whose space is held
        self.published = None

    def log(self, msg):
        if self.verbose:
            print(msg, file=sys.stderr, flush=True)

    def rescan(self):
        for path in sorted(glob.glob("/dev/input/event*")):
            if path in self.devices or not has_space_key(path):
                continue
            try:
                fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
            except OSError as e:
                self.log(f"skip {path}: {e}")
                continue
            self.devices[path] = fd
            try:
                if space_down_now(fd):
                    self.down.add(path)
            except OSError:
                pass
            self.log(f"watching {path}")

    def drop(self, path):
        os.close(self.devices.pop(path))
        self.down.discard(path)
        self.log(f"dropped {path}")

    def publish(self):
        value = "0" if self.down else None
        if value is None:
            if self.published not in (None, "0"):
                return  # still up; keep the original release time
            value = str(int(time.time() * 1000))
        if value == self.published:
            return
        tmp = self.state_path + ".tmp"
        with open(tmp, "w") as f:
            f.write(value + "\n")
        os.replace(tmp, self.state_path)
        self.published = value
        self.log(f"published {value}")

    def read_events(self, path):
        fd = self.devices[path]
        try:
            data = os.read(fd, EVENT.size * 64)
        except BlockingIOError:
            return
        except OSError:
            self.drop(path)
            return
        if not data:
            self.drop(path)
            return
        for off in range(0, len(data) - EVENT.size + 1, EVENT.size):
            _, _, etype, code, value = EVENT.unpack_from(data, off)
            if etype == EV_KEY and code == KEY_SPACE:
                if value == 0:
                    self.down.discard(path)
                else:  # 1 press, 2 autorepeat
                    self.down.add(path)

    def run(self):
        os.makedirs(os.path.dirname(self.state_path), exist_ok=True)
        self.rescan()
        self.publish()
        next_scan = time.monotonic() + RESCAN_SECONDS
        while True:
            fds = {fd: path for path, fd in self.devices.items()}
            timeout = max(0.0, next_scan - time.monotonic())
            ready, _, _ = select.select(list(fds), [], [], timeout)
            for fd in ready:
                if fds[fd] in self.devices:
                    self.read_events(fds[fd])
            if time.monotonic() >= next_scan:
                self.rescan()
                next_scan = time.monotonic() + RESCAN_SECONDS
            self.publish()


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--state", default=os.path.expanduser("~/.claude/voice-corrections/spacebar"))
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()
    Watcher(args.state, args.verbose).run()


if __name__ == "__main__":
    main()
