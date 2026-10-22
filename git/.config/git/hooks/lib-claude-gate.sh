#!/bin/sh
# Shared helpers for the pre-rebase and pre-merge-commit gates. Not a hook —
# git only runs files named after a hook, so this name is inert in hooksPath.
# (pre-push predates this file and stays self-contained; it needs none of it.)

# cg_opted_out <marker> — true when the repo root carries the named opt-out
# marker. Local merge/rebase is allowed by default; a marker tightens one repo.
# --show-toplevel, matching bash-write-gate.sh, so a worktree opts out
# independently of its parent checkout.
cg_opted_out() {
    root=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
    [ -n "$root" ] && [ -f "$root/$1" ]
}
