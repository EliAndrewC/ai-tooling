#!/usr/bin/env python3
"""readme-guard: README files live only at a git repository's top level (Eli, 2026-10-27).

Why: Claude Code never loads a README on its own, but it loads a folder's CLAUDE.md whenever it works in
that folder. Notes saved in a subfolder README are invisible to the next session; the same notes in that
folder's CLAUDE.md are not. So this PreToolUse hook (all projects, host and containers, through the shared
~/.claude/settings.json) refuses:
  - Write / Edit / MultiEdit / NotebookEdit of a README* file below a repository's top level, new or old;
  - a Bash `git commit` while a README* below the top level is staged as added, renamed or copied.
The refusal message says what to do instead (the folder's CLAUDE.md; `git mv` for an existing README).
Files outside any git repository are left alone.

Input: the hook JSON on stdin. Refusal: exit 2 with the reason on stderr (Claude reads it).
Tests: ~/.claude/hooks/test-readme-guard.sh
"""
import json
import os
import re
import subprocess
import sys

README = re.compile(r"^readme(\.[^/]*)?$", re.I)
EDIT_TOOLS = {"Write", "Edit", "MultiEdit", "NotebookEdit"}


def repo_top(path):
    d = path if os.path.isdir(path) else os.path.dirname(path)
    while d and not os.path.isdir(d):
        d = os.path.dirname(d)
    while True:
        if os.path.exists(os.path.join(d, ".git")):
            return d
        parent = os.path.dirname(d)
        if parent == d:
            return None
        d = parent


def refuse(lines):
    print("\n".join(lines), file=sys.stderr)
    sys.exit(2)


def tip(path, top):
    folder = os.path.dirname(path)
    rel = os.path.relpath(path, top)
    claude_md = os.path.join(os.path.relpath(folder, top), "CLAUDE.md")
    return [
        f"readme-guard: {rel} is a README below the repository's top level, which Eli doesn't allow:",
        "Claude never loads a README, but it loads a folder's CLAUDE.md whenever it works there.",
        f"Put this content in {claude_md} instead (add to it if it exists).",
        f"Converting an existing README: git mv {rel} {claude_md} (merge by hand if that exists),",
        "then point any links at the new name.",
    ]


def check_edit(tool_input, cwd):
    path = tool_input.get("file_path") or tool_input.get("notebook_path") or ""
    if not path or not README.match(os.path.basename(path)):
        return
    path = os.path.normpath(os.path.join(cwd, path))
    top = repo_top(path)
    if top and os.path.dirname(path) != top:
        refuse(tip(path, top))


def check_commit(command, cwd):
    if not re.search(r"\bgit\b[^;&|]*\bcommit\b", command):
        return
    m = re.search(r"\bgit\s+-C\s+(\S+)", command)
    where = os.path.join(cwd, os.path.expanduser(m.group(1).strip("'\""))) if m else cwd
    try:
        top = subprocess.run(["git", "-C", where, "rev-parse", "--show-toplevel"],
                             capture_output=True, text=True, timeout=5).stdout.strip()
        staged = subprocess.run(["git", "-C", where, "diff", "--cached", "--name-only", "--diff-filter=ACR"],
                                capture_output=True, text=True, timeout=5).stdout.split("\n")
    except (OSError, subprocess.SubprocessError):
        return
    bad = [f for f in staged if f and "/" in f and README.match(os.path.basename(f))]
    if top and bad:
        lines = tip(os.path.join(top, bad[0]), top)
        if len(bad) > 1:
            lines.insert(1, "Also staged: " + ", ".join(bad[1:]))
        lines.append(f"Unstage it first: git restore --staged {' '.join(bad)}")
        refuse(lines)


def main():
    try:
        data = json.load(sys.stdin)
    except ValueError:
        return
    tool = data.get("tool_name", "")
    tool_input = data.get("tool_input") or {}
    cwd = data.get("cwd") or os.getcwd()
    if tool in EDIT_TOOLS:
        check_edit(tool_input, cwd)
    elif tool == "Bash":
        check_commit(tool_input.get("command", ""), cwd)


if __name__ == "__main__":
    main()
