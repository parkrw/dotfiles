#!/usr/bin/env python3
# lint-on-edit.py - PostToolUse(Edit|Write|MultiEdit). Runs the repo's own
# prettier and eslint on the edited file and hands their failures back, so a
# CI format or lint job fails at the edit instead of in review or on the PR.
#
# Uses only binaries the repo installed (node_modules/.bin), never npx, which
# would download a tool the repo does not pin.
#
# Fails OPEN: an advisory check, so a crash or timeout says nothing.
# Kill switch: touch ~/.claude/hooks/.no-lint-on-edit
import json
import os
import subprocess
import sys

HOOKS = os.path.expanduser("~/.claude/hooks")
TIMEOUT = 25
LIMIT = 3000
ESLINT_EXT = {".js", ".jsx", ".mjs", ".cjs", ".ts", ".tsx", ".mts", ".cts"}
PRETTIER_CONFIGS = [
    ".prettierrc", ".prettierrc.json", ".prettierrc.json5", ".prettierrc.yaml", ".prettierrc.yml",
    ".prettierrc.toml", ".prettierrc.js", ".prettierrc.cjs", ".prettierrc.mjs", ".prettierrc.ts",
    "prettier.config.js", "prettier.config.cjs", "prettier.config.mjs", "prettier.config.ts",
]
ESLINT_CONFIGS = ["eslint.config." + e for e in ("js", "mjs", "cjs", "ts", "mts", "cts")]


def tool_root(path, name):
    """The nearest directory at or above path, inside its git checkout, that installs name."""
    d = os.path.dirname(path)
    while True:
        if os.access(os.path.join(d, "node_modules", ".bin", name), os.X_OK):
            return d
        if os.path.exists(os.path.join(d, ".git")) or os.path.dirname(d) == d:
            return None
        d = os.path.dirname(d)


def has_prettier_config(root):
    if any(os.path.exists(os.path.join(root, c)) for c in PRETTIER_CONFIGS):
        return True
    try:
        with open(os.path.join(root, "package.json")) as f:
            return "prettier" in json.load(f)
    except (OSError, ValueError):
        return False


def run(root, argv):
    try:
        p = subprocess.run(argv, cwd=root, capture_output=True, text=True, timeout=TIMEOUT)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return p.returncode, (p.stdout + p.stderr).strip()[:LIMIT]


def check(path):
    notes = []

    root = tool_root(path, "prettier")
    if root and has_prettier_config(root):
        rel = os.path.relpath(path, root)
        r = run(root, [os.path.join(root, "node_modules/.bin/prettier"), "--check", "--ignore-unknown", path])
        if r and r[0] == 1:
            notes.append(f"prettier --check fails on {rel}; run `npx prettier --write {rel}` from {root}.")

    root = tool_root(path, "eslint")
    if root and os.path.splitext(path)[1] in ESLINT_EXT and any(os.path.exists(os.path.join(root, c)) for c in ESLINT_CONFIGS):
        rel = os.path.relpath(path, root)
        # Exit 1 is lint errors; 2 is a config or crash, which is not this edit's to fix.
        r = run(root, [os.path.join(root, "node_modules/.bin/eslint"), "--no-warn-ignored", path])
        if r and r[0] == 1:
            notes.append(f"eslint fails on {rel}:\n{r[1]}")
    return notes


def main():
    if os.path.exists(os.path.join(HOOKS, ".disabled")) or os.path.exists(os.path.join(HOOKS, ".no-lint-on-edit")):
        return
    data = json.load(sys.stdin)
    path = (data.get("tool_input") or {}).get("file_path") or ""
    if not os.path.isabs(path) or not os.path.isfile(path):
        return
    notes = check(path)
    if notes:
        print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": "\n\n".join(notes)}}))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
