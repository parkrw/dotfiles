#!/bin/sh
# Shared helpers for the pre-rebase and pre-merge-commit gates. Not a hook —
# git only runs files named after a hook, so this name is inert in hooksPath.
# (pre-push predates this file and stays self-contained; it needs none of it.)

# cg_is_local_branch <name> — true when the name resolves to refs/heads/*.
cg_is_local_branch() {
    case "$(git rev-parse --symbolic-full-name "$1" 2>/dev/null)" in
        refs/heads/*) return 0 ;;
    esac
    return 1
}

# cg_is_remote_ref <ref-or-sha>
# True when the argument names, or resolves to, something on a remote:
# a remote-tracking ref, FETCH_HEAD, or a bare URL. Commits reached by sha
# alone — which is what `git pull` hands its subcommands — are matched by
# asking which refs point at them. A local branch name is local even when its
# tip equals a remote-tracking ref, as it does right after `pull --ff-only`.
cg_is_remote_ref() {
    case "$1" in
        FETCH_HEAD | *://* | *@*:*) return 0 ;;
    esac
    case "$(git rev-parse --symbolic-full-name "$1" 2>/dev/null)" in
        refs/remotes/*) return 0 ;;
        refs/heads/*) return 1 ;;
    esac
    sha=$(git rev-parse --verify --quiet "$1^{commit}" 2>/dev/null) || return 1
    [ -n "$(git for-each-ref --points-at "$sha" --format='%(refname)' refs/remotes 2>/dev/null)" ]
}

# cg_remote_ref_name <sha> — a refs/remotes ref pointing at <sha>, if any.
cg_remote_ref_name() {
    git for-each-ref --points-at "$1" --format='%(refname)' refs/remotes 2>/dev/null | head -1
}

# cg_opted_out <marker> — true when the repo root carries the named opt-out
# marker. Local merge/rebase is allowed by default; a marker tightens one repo.
# --show-toplevel, matching bash-write-gate.sh, so a worktree opts out
# independently of its parent checkout.
cg_opted_out() {
    root=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
    [ -n "$root" ] && [ -f "$root/$1" ]
}
