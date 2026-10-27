#!/usr/bin/env bash
# Pipe-test suite for ~/.claude/hooks/scripts/bash-write-gate.sh
# Builds throwaway repos: repoA on main, repoB on feat/x, and repoC and repoD
# sharing a bare origin. HOOK overrides the gate under test.
set -u
HOOK="${HOOK:-$HOME/.claude/hooks/scripts/bash-write-gate.sh}"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

mkrepo() { # $1=dir $2=branch
  git init -q -b main "$1"
  git -C "$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  [[ "$2" != main ]] && git -C "$1" switch -q -c "$2"
}
mkrepo "$T/repoA" main
mkrepo "$T/repoB" feat/x

pass=0; fail=0
check() { # $1=desc $2=cwd $3=cmd $4=expected decision (deny|ask|allow|defer)
  out=$(jq -n --arg c "$3" --arg w "$2" '{tool_input:{command:$c},cwd:$w}' | "$HOOK")
  got=$(echo "$out" | jq -r '.hookSpecificOutput.permissionDecision // "defer"' 2>/dev/null)
  [[ -z "$out" ]] && got="defer"
  if [[ "$got" == "$4" ]]; then pass=$((pass+1)); echo "PASS: $1"
  else fail=$((fail+1)); echo "FAIL: $1 — expected $4, got $got"; fi
}

# Regressions that must keep working
check "commit on main (plain) denied"            "$T/repoA" 'git commit -m "x: y"'                     deny
check "push from main denied"                    "$T/repoA" 'git push'                                 deny
check "push explicit main denied"                "$T/repoB" 'git push origin main'                     deny
check "local merge allowed by default"            "$T/repoB" 'git merge feat/y'                         allow
check "remote merge denied"                      "$T/repoB" 'git merge origin/feat/y'                  deny
check "remote rebase denied"                     "$T/repoB" 'git rebase origin/feat/y'                 deny
check "plain pull denied"                        "$T/repoB" 'git pull'                                 deny
check "tag create denied"                        "$T/repoB" 'git tag v1.0.0'                           deny
check "force push denied"                        "$T/repoB" 'git push --force'                         deny
check "read-only git allowed"                    "$T/repoB" 'git status'                               allow
check "git -C main commit denied"                "$T/repoB" "git -C $T/repoA commit -m 'x: y'"         deny

# The misfire class from insights: cd-prefixed compounds must resolve against
# the cd target, not the session cwd.
check "cd main && commit denied (no miss)"       "$T/repoB" "cd $T/repoA && git commit -m 'x: y'"      deny

# A read chained to a line that would ask is sent back to be split, so the
# read runs unprompted and only the write asks.
check "read && push sent back to split"         "$T/repoB" 'git status --short && git push'   deny
check "read; push sent back to split"            "$T/repoB" 'git log --oneline -3 | head -1; git push' deny
check "split counts cd and echo as no read"      "$T/repoB" "cd $T/repoB && echo --- && git push" ask
check "a write piped to a filter asks"           "$T/repoB" 'git push 2>&1 | tail -3'          ask
check "a read redirected to a file is no read"   "$T/repoB" "git log > $T/repoB/log.txt && git push" ask
check "a loop is never split"                    "$T/repoB" 'for b in feat/y; do git status; git push; done' ask
check "a substitution is never split"            "$T/repoB" 'git status && git push $(echo origin)'  ask
check "reads alone stay allowed"                 "$T/repoB" 'git status && git log -3 | head -1'      allow

# Worktrees are local writes; only a forced removal, which discards the
# worktree's uncommitted work, asks. The empty bare origin answers ls-remote
# with exit 2 (no such branch).
git init -q --bare "$T/origin.git"
for r in repoC repoD; do
  mkrepo "$T/$r" main
  git -C "$T/$r" remote add origin "$T/origin.git"
done
git -C "$T/repoC" branch taken
mkdir "$T/exists"

check "worktree add -b allowed"                  "$T/repoC" "git worktree add -b wt-new $T/repoC-wt-new HEAD"        allow
check "worktree add -b to a sibling path allowed" "$T/repoC" "git worktree add -b wt-r ../repoC-wt-r HEAD"             allow
check "worktree add -b via -C allowed"           "$T/repoB" "git -C $T/repoC worktree add -b wt-c $T/repoC-wt-c"     allow
check "worktree add -b off a local branch"        "$T/repoC" "git worktree add -b wt-l $T/repoC-wt-l taken"           allow
check "worktree add -b in another repo allowed"   "$T/repoD" "git worktree add -b wt-new $T/repoD-wt-new HEAD"        allow
check "worktree add -B allowed"                   "$T/repoC" "git worktree add -B wt-new $T/repoC-wt-new HEAD"        allow
check "worktree add --force allowed"              "$T/repoC" "git worktree add --force -b wt-new $T/repoC-wt-new"     allow
check "worktree add onto existing path allowed"   "$T/repoC" "git worktree add -b wt-new $T/exists HEAD"              allow
check "worktree add of a taken branch allowed"    "$T/repoC" "git worktree add -b taken $T/repoC-taken HEAD"          allow
check "worktree add off a remote ref allowed"     "$T/repoC" "git worktree add -b wt-new $T/repoC-wt-new origin/main" allow
check "worktree add then remove --force asks"     "$T/repoC" "git worktree add -b wt-new $T/repoC-wt-new HEAD && git worktree remove --force $T/exists" ask

# In a repo with changelog fragments, the PR title is the branch's fragment
# line, word for word, at most 50 characters.
mkrepo "$T/repoE" main
mkdir "$T/repoE/changelog.d" && echo spec > "$T/repoE/changelog.d/README.md"
git -C "$T/repoE" add changelog.d/README.md
git -C "$T/repoE" -c user.email=t@t -c user.name=t commit -q -m readme
git -C "$T/repoE" update-ref refs/remotes/origin/main main
git -C "$T/repoE" switch -q -c feat/frag
check "pr title without a fragment denied"        "$T/repoE" "gh pr create --title 'web: x' --body-file /tmp/b.md" deny
echo 'web: Overview leads with what needs you' > "$T/repoE/changelog.d/frag.md"
git -C "$T/repoE" add changelog.d/frag.md
git -C "$T/repoE" -c user.email=t@t -c user.name=t commit -q -m frag
check "pr title = fragment line allowed"          "$T/repoE" "gh pr create --title 'web: Overview leads with what needs you' --body-file /tmp/b.md" allow
check "pr title in double quotes allowed"         "$T/repoE" 'gh pr create --title "web: Overview leads with what needs you" --body-file /tmp/b.md' allow
check "pr title = commit subject denied"          "$T/repoE" "gh pr create --title 'web: Platform overview, storage, data centers table' --body-file /tmp/b.md" deny
check "pr title over 50 denied"                   "$T/repoE" "gh pr create -t 'web: Overview leads with what needs you, and much more' --body-file /tmp/b.md" deny
check "pr create without --title denied"          "$T/repoE" 'gh pr create --fill' deny
check "pr edit to another title denied"           "$T/repoE" "gh pr edit 7 --title 'web: something else'" deny
check "pr edit to the fragment line asks"         "$T/repoE" "gh pr edit 7 --title 'web: Overview leads with what needs you'" ask
check "pr edit of the body alone asks"            "$T/repoE" 'gh pr edit 7 --body-file /tmp/b.md' ask
check "pr create in a repo without fragments"     "$T/repoB" "gh pr create --title 'anything goes here, at any length at all, really' --body x" allow

echo "---"
echo "$pass passed, $fail failed"
exit $((fail > 0))
