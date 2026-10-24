#!/usr/bin/env python3
# suite-gate.py — PreToolUse(Bash). Denies a full root test run that does not
# go through `suite`, which lets one full suite run machine-wide at a time.
# Parallel sessions running `npm test` at once load the machine until their
# suites go red for reasons no diff caused.
#
# A full run is `npm test`, `npm t` or `npm run test` at a repo's toplevel
# with no argument that scopes it (`-w`, `--workspace`, a file, `-- <args>`).
# `cd <dir> &&` prefixes move the directory it judges.
#
# Fails OPEN: a convenience gate, so a crash lets the command run.
# Kill switch: touch ~/.claude/hooks/.no-suite-gate
import json
import os
import re
import shlex
import subprocess
import sys

HOOKS = os.path.expanduser("~/.claude/hooks")
REASON = "run: suite npm test (in background)"
HEREDOC = re.compile(r"(?:^|[^<])<<-?[ \t]*[\"'\\]?([A-Za-z_][A-Za-z0-9_]*)")
REDIRECT = re.compile(r"^[0-9]*(&?>>?|<)(.*)$")
# Output levels leave the run full, and --workspaces runs every one.
FULL_FLAGS = {"--silent", "-s", "--quiet", "-q", "--workspaces", "-ws", "--if-present"}


def drop_heredocs(cmd):
    """A heredoc body is text a command writes - a file, a PR body - never a command it runs."""
    lines, delim = [], None
    for line in cmd.split("\n"):
        if delim is not None:
            if line.lstrip("\t") == delim:
                delim = None
            continue
        lines.append(line)
        m = HEREDOC.search(line)
        if m:
            delim = m.group(1)
    return lines


def segments(cmd):
    """The command's simple commands: split at && || ; | & and newlines outside
    quotes, with comments dropped and continued lines joined. A newline inside
    quotes becomes a space, so a quoted message is never judged as a command."""
    out, quote = [], None
    buf = []

    def cut():
        out.append("".join(buf))
        buf.clear()

    for line in drop_heredocs(cmd):
        n, i, cont = len(line), 0, False
        while i < n:
            c = line[i]
            nxt = line[i + 1] if i + 1 < n else ""
            if quote:
                if c == "\\" and quote == '"':
                    buf.append(line[i:i + 2])
                    i += 2
                    continue
                if c == quote:
                    quote = None
                buf.append(c)
            elif c in "'\"":
                quote = c
                buf.append(c)
            elif c == "#" and (i == 0 or line[i - 1] in " \t;&|"):
                break
            elif c == "\\" and i == n - 1:
                cont = True
            elif c == "\\":
                buf.append(line[i:i + 2])
                i += 1
            elif c == ";":
                cut()
            elif c == "|":
                cut()
                if nxt == "|":
                    i += 1
            elif c == "&":
                if nxt == "&":
                    cut()
                    i += 1
                # 2>&1 and &> are redirections, not the background operator.
                elif nxt == ">" or (i > 0 and line[i - 1] in "<>"):
                    buf.append(c)
                else:
                    cut()
            else:
                buf.append(c)
            i += 1
        if quote or cont:
            buf.append(" ")
        else:
            cut()
    if buf:
        cut()
    return out


def words(segment):
    try:
        return shlex.split(segment)
    except ValueError:
        return segment.split()


def full_run(w):
    if not w or w[0] != "npm" or len(w) < 2:
        return False
    if w[1] in ("test", "t"):
        i = 2
    elif w[1] in ("run", "run-script") and len(w) > 2 and w[2] == "test":
        i = 3
    else:
        return False
    while i < len(w):
        m = REDIRECT.match(w[i])
        if m:
            # A bare operator takes the next word.
            i += 1 if m.group(2) else 2
            continue
        if w[i] not in FULL_FLAGS:
            return False
        i += 1
    return True


def at_toplevel(d):
    here = os.path.realpath(d)
    if not os.path.isdir(here):
        return False
    p = subprocess.run(["git", "-C", here, "rev-parse", "--show-toplevel"], capture_output=True, text=True)
    return p.returncode == 0 and os.path.realpath(p.stdout.strip()) == here


def denies(cmd, cwd):
    if "npm" not in cmd:
        return False
    d = cwd
    for seg in segments(cmd):
        w = words(seg)
        while w and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", w[0]):
            w = w[1:]
        if not w:
            continue
        if w[0] == "cd":
            target = os.path.expanduser(w[1] if len(w) > 1 else "~")
            d = os.path.join(d, target)
            continue
        if full_run(w) and at_toplevel(d):
            return True
    return False


def main():
    if any(os.path.exists(os.path.join(HOOKS, f)) for f in (".disabled", ".no-suite-gate")):
        return
    data = json.load(sys.stdin)
    cmd = (data.get("tool_input") or {}).get("command") or ""
    if denies(cmd, data.get("cwd") or os.getcwd()):
        json.dump({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                          "permissionDecisionReason": REASON}}, sys.stdout)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
