#!/usr/bin/env python3
"""Clipboard bridge: text copied inside a dev container's tmux lands on the host's desktop clipboard.

Why: inside a container, Claude Code (and tmux copy mode) can only copy into tmux's buffer. tmux then
asks the outer terminal to set the clipboard with OSC 52, which GNOME Terminal (VTE) ignores by design.
So launch-container mounts ~/.local/share/container-clipboard at /clipboard-bridge, and its tmux config
runs /host-scripts/clipboard-to-host on every copy, writing /clipboard-bridge/<container name>.

This user service (clipboard-bridge.service) polls that folder every 250 ms and puts each changed
file's text on the CLIPBOARD selection.

The other way (2026-10-10, for right-click paste): whenever the host clipboard changes, its text is
saved to <folder>/.host-clipboard (mode 600; a dotfile, so the poll above ignores it). In a container,
Claude Code pastes on right-click by running `wl-paste`; /host-scripts/container-bin/wl-paste (on the
container's PATH via launch-container's ~/.bashrc block) prints that file. Eli accepted that every
container can read the clipboard (personal projects only).

It owns the clipboard through GTK on the X11 backend (Xwayland), which needs no window or focus;
mutter mirrors the X11 clipboard to Wayland apps. Don't switch to `wl-copy`: it is not installed
(needs sudo), and on GNOME it must briefly take keyboard focus to set the selection.

Containers made before the mount (claude-diagram) get /clipboard-bridge as a symlink into their
~/.claude mount instead (launch-container does it on every launch, so no --fresh): that folder is
LEGACY_DIR here, watched and mirrored exactly like the main one.

Skips dotfiles (the writer's temp files), symlinks, non-regular files and anything over 1 MiB.
Logs name and size only, never the text: journalctl --user -u clipboard-bridge

Test mode: --sink CMD pipes each new text to CMD instead of the clipboard, with no GTK (see
test-clipboard-bridge.sh).
"""
import argparse
import os
import stat
import subprocess
import sys
import time

DEFAULT_DIR = os.path.expanduser("~/.local/share/container-clipboard")
LEGACY_DIR = os.path.expanduser("~/.claude/container-clipboard")
MAX_BYTES = 1 << 20
POLL_MS = 250
HOST_FILE = ".host-clipboard"


def log(msg):
    print(f"clipboard-bridge: {msg}", flush=True)


def scan(folder):
    """{name: (mtime_ns, size)} of the regular, non-hidden files in folder."""
    out = {}
    try:
        entries = list(os.scandir(folder))
    except FileNotFoundError:
        return out
    for e in entries:
        if e.name.startswith("."):
            continue
        try:
            st = e.stat(follow_symlinks=False)
        except FileNotFoundError:
            continue
        if stat.S_ISREG(st.st_mode):
            out[e.name] = (st.st_mtime_ns, st.st_size)
    return out


def save_host_clipboard(folder, text):
    """Atomically write the host clipboard's text for containers to paste; empty/huge = remove it."""
    path = os.path.join(folder, HOST_FILE)
    if not text or len(text.encode()) > MAX_BYTES:
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass
        return
    tmp = path + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, path)


def read_text(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, "rb") as f:
        return f.read(MAX_BYTES + 1).decode("utf-8", errors="replace")


class Bridge:
    def __init__(self, folder, write):
        self.folder = folder
        self.write = write
        self.seen = scan(folder)  # what's already there at start is not re-copied

    def poll(self):
        cur = scan(self.folder)
        changed = [n for n, v in cur.items() if self.seen.get(n) != v]
        self.seen = cur
        # Several changed in one tick: the newest copy wins.
        for name in sorted(changed, key=lambda n: cur[n][0])[-1:]:
            size = cur[name][1]
            if size > MAX_BYTES:
                log(f"{name}: {size} bytes is over the {MAX_BYTES}-byte limit; not copied")
                continue
            try:
                text = read_text(os.path.join(self.folder, name))
            except OSError as e:
                log(f"{name}: unreadable ({e}); not copied")
                continue
            self.write(text)
            log(f"{name}: copied {len(text)} characters to the clipboard")
        return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", action="append", help="folder to watch (repeatable); default: both")
    ap.add_argument("--sink", help="test mode: pipe each text to this command instead")
    args = ap.parse_args()
    dirs = args.dir or [os.environ.get("CONTAINER_CLIPBOARD", DEFAULT_DIR), LEGACY_DIR]
    for d in dirs:
        os.makedirs(d, exist_ok=True)

    if args.sink:
        sink = lambda t: subprocess.run(args.sink, shell=True, input=t.encode())
        bridges = [Bridge(d, sink) for d in dirs]
        while True:
            time.sleep(POLL_MS / 1000)
            for b in bridges:
                b.poll()

    os.environ["GDK_BACKEND"] = "x11"
    import gi
    gi.require_version("Gtk", "3.0")
    gi.require_version("Gdk", "3.0")
    from gi.repository import Gdk, GLib, Gtk

    if not Gtk.init_check(sys.argv)[0]:
        sys.exit("clipboard-bridge: no X11 display (DISPLAY unset, or Xwayland not running)")
    clipboard = Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD)

    def write(text):
        clipboard.set_text(text, -1)
        clipboard.store()

    bridges = [Bridge(d, write) for d in dirs]
    GLib.timeout_add(POLL_MS, lambda: all(b.poll() for b in bridges))

    def mirror(*_):
        clipboard.request_text(lambda _c, text: [save_host_clipboard(d, text) for d in dirs])

    clipboard.connect("owner-change", mirror)  # any app's copy (mutter mirrors Wayland copies to X11)
    mirror()
    log(f"watching {', '.join(dirs)}")
    Gtk.main()


if __name__ == "__main__":
    main()
