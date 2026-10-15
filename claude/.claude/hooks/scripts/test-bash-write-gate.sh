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

echo "---"
echo "$pass passed, $fail failed"
exit $((fail > 0))
