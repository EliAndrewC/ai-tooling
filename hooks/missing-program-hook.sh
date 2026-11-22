#!/usr/bin/env bash
# missing-program-hook.sh - when a Bash command in a CONTAINER finds a program missing, remind the session that the
# container has passwordless sudo, so it installs the program instead of working around it.
#
# The GM, 2026-10-01 (diagram feature 301): "You have sudo as access in this container specifically so that you can
# install things ... every time you run a command and then get a message about that command not being found ... a
# hook that reminds you" - covering "both which and really just all of the different ways that you would check to see
# whether something exists" - and "ideally the hook would check and see whether or not we are in a container or not.
# Because I do want this hook to apply to all of my projects. In many different directories, in many different
# containers. But all containers have sudo access." Host sessions get nothing: the host is not assumed to have sudo.
#
# Wired in ~/.claude/settings.json on BOTH PostToolUse and PostToolUseFailure, matcher Bash: a missing command exits
# 127 and an empty `which` exits 1, and Claude Code reports a non-zero exit as a failure (the memwatch hook is wired
# on both for the same reason). Fires every time - no once-per-session limit (the GM's "every time").
#
# What counts as "missing":
#   - the shell's own error: `bash: foo: command not found`, `sh: 1: foo: not found`, `env: 'foo': No such file or
#     directory`, `/bin/sh: foo: not found`, `zsh: command not found: foo`;
#   - Python's `ModuleNotFoundError: No module named 'x'` / `No module named x`;
#   - an existence check whose answer is "no": which, command -v, type, hash, whereis, dpkg -s / -l / dpkg-query,
#     apt list --installed, apt-cache policy, pip show / pip list | grep / python -m pip show, test -x / [ -x ] / ls on
#     a program path (/bin, /sbin, /usr/bin, /usr/local/bin, /opt, ~/.local/bin).
#
# Self-test: ~/.claude/hooks/test-missing-program-hook.sh. Never fails a hook: every path exits 0.
# Test seams: MPH_ROOT replaces / for the container markers, and when it is set MPH_CONTAINER_ENV replaces $container.

command -v python3 >/dev/null 2>&1 || exit 0  # a container with no python3: say nothing rather than fail the hook
exec python3 -c '
import json, os, re, shlex, sys

def in_container():
    root = os.environ.get("MPH_ROOT")
    env = os.environ.get("MPH_CONTAINER_ENV", "") if root is not None else os.environ.get("container", "")
    root = root if root is not None else "/"
    if env:
        return True
    for marker in ("run/.containerenv", ".dockerenv"):
        if os.path.exists(os.path.join(root, marker)):
            return True
    try:
        with open(os.path.join(root, "proc/1/cgroup")) as fh:
            return bool(re.search(r"docker|podman|libpod|containerd|kubepods|lxc", fh.read()))
    except OSError:
        return False

SHELL_MISSING = [
    re.compile(r"^(?:[\w./-]*(?:bash|sh|zsh|dash|ksh)|\(eval\)):\s*(?:line \d+:\s*|\d+:\s*)?(?:exec:\s*)?([^\s:]+):\s*(?:command not found|not found|No such file or directory)\s*$", re.M),
    re.compile(r"^zsh: command not found: (\S+)", re.M),
    re.compile(r"^(?:/usr/bin/|/bin/)?env: [\x27‘]?([^\s\x27’:]+)[\x27’]?: No such file or directory", re.M),
    re.compile(r"^([^\s:]+): command not found\s*$", re.M),
]
NO_MODULE = re.compile(r"No module named [\x27\"]?([\w.]+)")
BIN_PATH = re.compile(r"^(?:/usr/local/bin|/usr/bin|/bin|/usr/sbin|/sbin|/opt/\S+|~?/[^\s]*\.local/bin|\$HOME/\.local/bin)/")

def stray_path(m):
    """`bash: line 3: /tmp/x/out.log: No such file or directory` is a redirect into a missing directory, not a missing
    program: a path outside the bin directories reported "No such file" is left alone (misfire 2026-10-03)."""
    return "/" in m.group(1) and "No such file" in m.group(0) and not BIN_PATH.match(m.group(1))

def split_unquoted(command):
    """The parts of a shell line between ; && || | and newlines OUTSIDE quotes: a quoted argument is data - a ledger line
    LINE= argument holding "| a | which south side ..." was split on its pipes and read as a which-check (misfire 2026-10-13)."""
    parts, cur, quote, i = [], [], "", 0
    while i < len(command):
        c = command[i]
        if quote:
            cur.append(c)
            if c == quote:
                quote = ""
            elif c == "\\" and quote == "\"" and i + 1 < len(command):
                cur.append(command[i + 1])
                i += 1
        elif c in "\x27\"":
            quote = c
            cur.append(c)
        elif c == "\\" and i + 1 < len(command):
            cur.append(c + command[i + 1])
            i += 1
        elif c in ";\n" or (c == "|") or (c == "&" and command[i + 1:i + 2] == "&"):
            parts.append("".join(cur))
            cur = []
            if command[i + 1:i + 2] in ("|", "&") and c in "|&":
                i += 1
        else:
            cur.append(c)
        i += 1
    parts.append("".join(cur))
    return parts

HEREDOC = re.compile(r"(<<-?[ \t]*[\x27\"]?(\w+)[\x27\"]?[^\n]*)\n.*?\n[ \t]*\2[ \t]*(?=\n|$)", re.S)

def segments(command):
    """Simple commands of a shell line: split on ; && || | and newlines (quotes respected loosely). A heredoc body is data,
    not commands: a prose line beginning "which ..." was read as a which-check and every word reported missing (2026-10-02)."""
    out = []
    command = HEREDOC.sub(r"\1", command)
    for part in split_unquoted(command):
        try:
            words = shlex.split(part, posix=True)
        except ValueError:
            words = part.split()
        while words and re.match(r"^\w+=", words[0]):
            words = words[1:]
        while words and words[0] in ("sudo", "!", "time", "exec", "then", "do", "if", "while", "until", "else", "{", "("):
            words = words[1:]
        if words:
            out.append(words)
    return out

VIEWERS = {"cat", "sed", "head", "tail", "grep", "rg", "less", "awk", "wc", "nl", "cut", "sort", "uniq", "cd"}

def viewing_only(command):
    """A command that only prints files: its output is the text of the files, so an error message quoted in one (a test of
    this hook, read with sed) is a mention, not a failure (misfire 2026-10-03); only the viewer itself can be missing.
    Returns the viewers named, or an empty set when anything else runs."""
    heads = {os.path.basename(w[0]) for w in segments(command)}
    return heads if heads and heads <= VIEWERS else set()

def checks(command):
    """(tool, program) for every existence check in the command."""
    out = []
    segs = segments(command)
    for i, w in enumerate(segs):
        tool, args = w[0].rsplit("/", 1)[-1], [a for a in w[1:] if not a.startswith("-")]
        if tool == "command" and "-v" in w[1:3]:
            out += [("command -v", a) for a in w[w.index("-v") + 1:] if not a.startswith("-")]
        elif tool in ("which", "type", "hash", "whereis"):
            out += [(tool, a) for a in args]
        elif tool in ("dpkg", "dpkg-query") and any(f in w for f in ("-s", "-l", "-W", "--status", "--list", "--show")):
            out += [("dpkg", a) for a in args]
        elif tool == "apt" and "list" in w and "--installed" in w:
            out += [("apt list", a) for a in args if a != "list"]
        elif tool == "apt-cache" and "policy" in w:
            out += [("apt-cache policy", a) for a in args if a != "policy"]
        elif tool in ("pip", "pip3") and "show" in w:
            out += [("pip show", a) for a in args if a != "show"]
        elif tool.startswith("python") and "-m" in w and "pip" in w and "show" in w:
            out += [("pip show", a) for a in args if a not in ("pip", "show")]
        elif tool in ("pip", "pip3") and "list" in w and i + 1 < len(segs) and segs[i + 1][0] == "grep":
            out += [("pip list | grep", a) for a in segs[i + 1][1:] if not a.startswith("-")]
        elif tool in ("test", "[", "[["):
            out += [("test -x", a) for j, a in enumerate(w) if j > 0 and w[j - 1] in ("-x", "-f", "-e") and BIN_PATH.match(a)]
        elif tool == "ls":
            out += [("ls", a) for a in args if BIN_PATH.match(a)]
    return out

def missing_by_check(tool, prog, text, failed):
    base = re.escape(prog.rsplit("/", 1)[-1])
    p = re.escape(prog)
    if tool in ("which", "command -v"):
        found = re.search(r"(?m)^(?:\S*/)?" + base + r"\s*$", text) or re.search(r"(?m)^(?:alias |function )?" + base + r"\b", text)
        return not found
    if tool == "type":
        return bool(re.search(base + r": not found", text)) or (failed and not re.search(r"(?m)^" + base + r" is ", text))
    if tool == "hash":
        return bool(re.search(base + r": not found", text))
    if tool == "whereis":
        m = re.search(r"(?m)^" + base + r":(.*)$", text)
        return m is None or not m.group(1).strip()
    if tool == "dpkg":
        return bool(re.search(r"(?i)(package [\x27`‘]?" + base + r"[\x27`’]? is not installed|no packages found matching " + base + r"|dpkg-query: no packages found)", text))
    if tool == "apt list":
        return not re.search(r"(?m)^" + base + r"/", text)
    if tool == "apt-cache policy":
        return bool(re.search(r"Installed: \(none\)", text)) or not re.search(r"(?m)^" + base + r":", text)
    if tool in ("pip show", "pip list | grep"):
        return bool(re.search(r"(?i)package\(s\) not found", text)) or (tool == "pip list | grep" and not re.search(r"(?im)^" + base + r"\s", text))
    if tool == "test -x":
        return failed
    if tool == "ls":
        return bool(re.search(r"cannot access [\x27‘]?" + p + r"[\x27’]?: No such file or directory", text))
    return False

def main():
    try:
        inp = json.loads(sys.stdin.read() or "{}")
    except Exception:
        return
    if inp.get("tool_name") != "Bash" or not in_container():
        return
    event = inp.get("hook_event_name") or "PostToolUse"
    command = (inp.get("tool_input") or {}).get("command") or ""
    resp = inp.get("tool_response")
    parts = []
    if isinstance(resp, dict):
        parts += [str(resp.get(k) or "") for k in ("stdout", "stderr", "output")]
    elif resp:
        parts.append(str(resp))
    parts.append(str(inp.get("error") or ""))
    text = "\n".join(parts)
    failed = event == "PostToolUseFailure" or bool(inp.get("error"))
    missing = []
    heads = viewing_only(command)
    for rx in SHELL_MISSING:
        missing += [m.group(1) for m in rx.finditer(text) if not stray_path(m) and (not heads or m.group(1) in heads)]
    if not heads:
        missing += ["python module " + m.group(1) for m in NO_MODULE.finditer(text)]
    missing += [prog for tool, prog in checks(command) if missing_by_check(tool, prog, text, failed)]
    missing = list(dict.fromkeys(m.strip("\x27\"‘’") for m in missing if m))
    if not missing:
        return
    msg = ("Missing: " + ", ".join(missing) + ". This container has passwordless sudo - install what is missing "
           "(sudo apt-get install -y <package>, pip install <package>) rather than working around it or going without. "
           "(Automatic notice from the user-level missing-program hook, ~/.claude/hooks/missing-program-hook.sh.)")
    print(json.dumps({"hookSpecificOutput": {"hookEventName": event, "additionalContext": msg}}))

try:
    main()
except Exception:
    pass
' 2>/dev/null
exit 0
