---
name: ftl
description: Follow the leader. Working method for a repo someone else owns, derived from that repo at run time - its rules file, its docs, its CI, and the lead's own commits. `/ftl <task>` orients - for a change, first creates and enters a worktree when on the default branch or a detached HEAD, then indexes docs/ by heading, reads only the sections the task touches, measures the lead's commit and CHANGELOG conventions. `/ftl` alone is the pre-handoff checklist - definition of done, docs, CHANGELOG line, commit subject, commit, then the push and gh commands for the human to run. `/ftl ship` creates and enters a worktree when on the default branch or a detached HEAD, fetches, commits, runs `claude-review` in a loop until it reports zero findings, then rebases when behind and prints the push and `gh pr create` commands. `/ftl ship --integrate` also runs `pull --ff-only` in the default checkout, the rebase or merge itself, resolves conflicts, then pushes and opens a draft PR. `/ftl <task> --ship` does all of it in one command - orient, build, then ship --integrate - stopping only for a decision the build cannot make alone. Local git writes run as the write gate allows; push and gh run only in Ship --integrate. e.g. /ftl "zerto logout url #282", /ftl, /ftl ship, /ftl ship --integrate, /ftl "fix the logout redirect #301" --ship, /ftl --help.
---

## Help

If `$ARGUMENTS` is exactly `--help`, `help`, or `-h`, print the block below verbatim and **stop - do not execute the skill**.

```
/ftl - follow the leader: work the way the repo's lead does

  Derives the conventions from the repo you are in: rules file, docs index,
  CI, the lead's commits. Runs local git writes itself, as the write
  gate allows. Push and gh pr create --draft run only in --integrate.

  Workflows
    simple task:   /ftl "<task>" --ship          -> draft PR; mark it ready
    steered task:  /ftl "<task>", build together,
                   then /ftl ship --integrate     -> draft PR; mark it ready

  /ftl <task>     orient: worktree for a change (created on
                   main/detached, then entered), index docs/ by
                   heading, read the sections the task touches, list
                   past review findings and edge cases, read the plan
                   the task or a memory names, measure the lead's
                   conventions, print state
  /ftl            pre-handoff checklist on the staged diff (falls back to
                   the working tree), commit, then push and gh pr create
                   for the human
  /ftl ship       worktree (created on main/detached), fetch, check,
                   commit, then claude-review (opus, xhigh)
                   in a loop - run each runtime proof's test,
                   fix each finding it does not refute as a class,
                   rerun the checks except the suite, commit,
                   re-review - until zero findings; the full suite
                   runs before round 1 and after the last round;
                   then rebase when behind and print
                   cd, push and gh pr create
  /ftl ship --integrate
                  ship, but integrate the default branch itself
                   (pull --ff-only, then rebase if unpushed or merge
                   if pushed), resolve conflicts, review, then push
                   and open a draft PR, even if the default branch
                   moved during the review
  /ftl <task> --ship
                  orient, build, then ship --integrate; stops only
                   for a decision the build cannot make alone
  /ftl --help     show this help
```

---

Run from the repo root. Every step prints the line that shows its result, so the next step can rely on what is on screen. `$ARGUMENTS` of exactly `ship` runs Ship, and exactly `ship --integrate` runs Ship with Integrate; empty runs Check; anything else ending in ` --ship` runs Task to PR with the rest as the task; anything else is the task for Orient.

# Orient - `/ftl <task>`

## 0. Worktree

A task that changes files - a fix, a feature, a refactor, a doc edit - runs Ship step 1 before anything else, naming the worktree from the task, since there is no diff yet. The rest of Orient, and the build, run in `worktree`. When it carries uncommitted work over, print Ship step 5's restore and clean line for the human now: the worktree holds the work, and a later hand-off may not know it was carried.

A question, an investigation or a review that edits nothing stays in the current checkout. One that turns into an edit runs this step before its first edit.

## 1. Rules

Read `AGENTS.md`, `CLAUDE.md`, and `CONTRIBUTING.md`, whichever exist. A repo rule beats this skill, with one exception the human has accepted: a rule that says to read every doc is met by the index in step 2 plus the sections it selects.

## 2. Docs index

```
grep -n -E '^#{1,3} ' README.md docs/*.md 2>/dev/null
```

The index is a few percent of the docs' size. Then:

- If a doc opens with a table mapping docs to subsystems, read the table.
- Select the docs whose headings or table rows name the task's nouns or the paths it will touch. Read a selected section from its heading line to the line before the next heading of the same or higher level, with `sed -n '<from>,<to>p'`. Read a whole doc only when most of its headings match.
- Print the sections read, `file:from-to`, one per line. The checklist reuses the index against the touched files.

## 2a. Traps

What the reviewer will find, found first. Two lists, both printed:

- Past findings on the paths the task will touch, the latest six per file. `<main-checkout>` is `common=$(git rev-parse --path-format=absolute --git-common-dir)` then `${common%/.git}`, the path the ledger files a worktree's reviews under. `no reviews match`, or no lines: none recorded.

  ```
  claude-review-stats --json --repo <main-checkout> | jq -r '(.runs | map({(.id): .ts}) | add) as $ts | [.findings[] | select(.path | IN($ARGS.positional[]))] | group_by(.path)[] | sort_by($ts[.run]) | .[-6:][] | "\(.path):\(.line // "?") \(.severity) - \(.text)"' --args <path>...
  ```

- Edge cases: the inputs and states the change meets - empty, one, many, equal values, the boundary, the error path, and for UI both color schemes and RTL. Each one gets a test, or a line saying why it cannot occur; in a repo with no tests, a line saying how the change handles it. The build repeats none of the past findings.

## 2b. Plan

A plan of record lives outside the repo, and the task or a loaded memory names its path. Read that file's section for this task and nothing else; never list or glob `~/.claude/plans/`, which holds every repo's plans. Print `plan: <path>`, or `plan: none` when nothing names one.

The plan holds the task's status, and the hand-offs update it. A memory holds the pointer to the plan and the human's decisions, and changes only on a new decision; status never goes in a memory, since two copies drift.

## 3. The lead's conventions, measured

Find the lead: `git shortlog -sn --no-merges | head -3`. Then, with `--author='<lead>' --no-merges`:

| Measure | Command | Record |
| --- | --- | --- |
| subjects | `git log --format=%s -60` | case, length range, prefix pattern, how an issue is closed |
| bodies | `git log --format='%s%n%b%n---' -20` | prose or bullets, trailers, what a squash merge leaves |
| footprint | `git log --format= --shortstat -30` | files per commit; whether tests, docs and the changelog entry land together |
| changelog | `ls changelog.d`; `cat changelog.d/README.md`; `sed -n '1,30p' CHANGELOG.md`; `grep -oE '^- (fix\()?[a-z]+' CHANGELOG.md \| sort \| uniq -c \| sort -rn` | fragment directory and its spec, or its absence; line shape, scopes in use |
| done | the rules file; else `grep -hE '^\s+run:' .github/workflows/*.yml`; else `package.json` scripts or `Makefile` targets | the commands the checklist will run |
| branches | `git branch -r --format='%(refname:short)' \| head -20` | the branch naming the lead pushes |

If memory holds a profile of this lead, correct it where the measurement disagrees. If it holds none, write one.

## 4. State

`git status --short`, `git branch --show-current`, `git fetch origin`, then `git log --oneline HEAD..origin/HEAD`. If `origin/HEAD` is unset, run `git remote set-head origin -a` first.

If the log prints anything the branch is behind. Say by how many commits, and name the files both sides touch (`git diff --name-only HEAD...origin/HEAD` against `git diff --name-only origin/HEAD...HEAD`): those are where a rebase will conflict. Then recommend one, with its consequence:

- Behind only in files this branch does not touch: nothing now; rebase before the PR.
- Unpushed branch: `git pull --ff-only` in the checkout holding the default branch, then `git rebase <default>` here. New shas, nothing else changes. Re-run the checkers after, because the rules move.
- Pushed, not yet reviewed: the same, then a `--force-with-lease` push from the human's own terminal. The pre-push hook denies a non-fast-forward push from Claude.
- Pushed and under review: `git merge <default>` instead, so review comments stay anchored to their shas. The squash merge drops the merge commit.

Run the chosen local commands. A force push is the human's: print it and wait.

## 5. The human's rules

These win over the lead's habits.

- Run local git writes yourself - `fetch`, `switch`, `branch`, `worktree add`, `stash`, `add`, `commit`, `pull --ff-only`, a local `rebase` or `merge` - and let the write gate allow, ask or deny. Never print one for the human to run. `push` and `gh` run only in Ship `--integrate` (`git push -u origin <branch>`, `gh pr create --draft`); everywhere else, and for any force push, print the command for the human.
- Stage named paths, from `git status --short`. Never `git add -A`, `git add .` or `commit -a`.
- No `Co-authored-by` and no `Claude-Session` trailer.
- Repo-tracked Claude config (`.claude/`, `CLAUDE.md`, skills) is the lead's decision. Tooling lives in `~/.claude/` and the untracked `.claude/settings.local.json`.
- A runbook is unverified until you have run it. Run a procedure against dev before extending it, and frame the change as "run against dev on <date>, here is what changed".
- Work lands as a PR. An issue writeup gets absorbed into the lead's commits; a PR gets reviewed and stays attributable.

# Task to PR - `/ftl <task> --ship`

For a task that needs no steer. One command from task to draft PR.

1. Orient steps 0, 1, 2, 2a, 2b, 3 and 5 for the task. Skip step 4: Ship fetches and integrates, so nothing is printed for the human and nothing waits. Step 0's restore and clean line waits for Ship step 5, which prints it.
2. Build the task in `worktree` against Orient step 2a's traps. When the task leaves a decision open - scope it does not settle, an amount under the Visual work rules (variants or a slider page), a choice between two behaviors - stop with one question or the variants. After the answer, carry on from here; no second command.
3. Ship from step 2, with `--integrate`.

# Check - `/ftl`

Every item is pass or fail with the output line that shows it. Do not hand off with an open item: fix it, or name it as left out and why.

## 1. Shape

- `git status --short` and `git diff --cached --stat`. The diff is one behavior. A second behavior is a second PR.
- If the repo keeps a CHANGELOG, write its fragment first (section 5). If the line cannot say what a customer or staffer now gets, the change is not shaped yet.
- An adjacent smell becomes one line at the end of the handoff.
- `git fetch origin`, then `git log --oneline HEAD..origin/HEAD`. Output means the branch is behind: apply Orient step 4.

## 2. Definition of done

Run the commands from Orient step 3, from the repo root, each with its pass line. Then:

- `git diff --cached | grep -nE '^\+.*\.(skip|only)\('` prints nothing.
- A bug fix carries a test that failed before the fix. Name the test.
- If the rules file demands a spelling, `git diff --cached | grep -nE '^\+.*\b(licence|colour|behaviour|organis|initialis|centre|cancelled|catalogue|analyse|favour|honour)'` prints nothing for US spelling. A mechanical checker rarely covers spelling; this grep is the spot check.
- If the rules file names a running stack you may restart, restart it and read its log. Paste anything that is not a clean boot.
- If the repo has end-to-end tests (the directory the e2e command from Orient step 3 runs), grep them for every class, role name, label text, test id and option the diff renames, removes or restyles. Each hit is a spec to update on this branch, though it sits outside the diff.

## 3. Docs

`git diff --cached --name-only`, then grep the docs index (Orient step 2) for each touched module's name and for the behavior's nouns. A doc that describes the changed behavior and does not reflect the change fails. An endpoint change updates the API reference if the repo has one.

Then grep the body of every doc, `git grep -n -w -e '<name>' -- '*.md'`, for each prop, class, component, flag and function name the diff adds, renames or removes. A doc line that names one is a second statement of the fact and moves in the same commit.

A doc line this diff adds states the rule, not the list of callers or cases that follow it: a list goes stale the next time a caller changes. An existing list that has to change is rebuilt from a grep of the callers, not from memory.

## 4. Code and prose spot check

- Module header states the domain problem and its constraint, if the codebase does that. Every other comment is a WHY: a hidden constraint, an invariant, a workaround for a named bug. Delete a comment that restates the line under it.
- Match the surrounding code's construction style: how classes hide state, how collaborators are injected, where wired objects come from.
- No new dependency. Adding a package is a design decision to raise with the lead before the PR.
- Tests match the neighboring files' runner and fixtures. A test name is a behavior sentence. Assert outcomes; asserting call shape tests the test.
- If the repo has a prose checker, run it. Fix its notes in touched lines even when they do not fail.

## 5. Changelog

Never edit `CHANGELOG.md`. The entry is one new fragment file in `changelog.d/`, named and shaped the way `changelog.d/README.md` says; its line follows the shape measured in Orient step 3: prefix, scope, issue reference. The line says what the reader can now do or rely on. A scope that is not in the count needs a reason.

A repo with `CHANGELOG.md` and no fragment tooling gets it set up first, as its own commit ahead of the change, the way CloudKey core does it (`~/Developments/work/ck/programmin/core`: `changelog.d/README.md`, `scripts/changelog/`, the `changelog*` scripts in `package.json`, the CI job in `.github/workflows/ci.yml`): a README spec, an assemble script that folds the fragments into a dated section at release and deletes them, a guard that fails a PR whose `CHANGELOG.md` differs from what assemble writes, and tests for both, in the repo's own language and runner with no new dependency. The hand-off names that commit so the lead can split it out.

## 6. Commit subject

- Subject: the measured shape - case, length, prefix. It states what the reader can now rely on. Close the issue from the subject or the PR body the way the lead does.
- No commit body.
- If CI judges the PR description, write the PR body under the repo's prose rules.
- No `Co-authored-by`, no `Claude-Session`.

## 7. Hand off

Run the local half yourself: `git switch -c <branch>` when on the default branch, named as measured in Orient step 3, then `git add <path>... && git commit -m '<subject>'`. A subject with an apostrophe goes in double quotes and carries no `$` or backtick. Write the PR body to `<body-file>`, as Ship step 5 does, then print the remote half for the human, placeholders filled in:

```
git push -u origin <branch>
gh pr create --title '<subject>' --body-file <body-file>
```

When Orient step 2b printed a plan, update this task's status in it before printing: branch and commit sha.

Then one line per adjacent smell found, and nothing else.

# Ship - `/ftl ship`

Fetch, check, commit, review, fix, repeat, until the reviewer reports no findings. Ship runs every local git write itself, in the worktree resolved in step 1; the write gate allows them without a prompt. Only the push and `gh pr create` are printed for the human at the end.

The order is fixed: CI's full test suite passes, then `claude-review`, then the push, then the PR. The full suite runs twice: before round 1, and after the last round when a fix was committed since round 1. One round that passes runs it once, on the commit it reviewed. A push that skips the review meets it anyway: where the review gate is live, pre-push denies a branch diff without a passing review.

With `--integrate`, Ship also integrates the default branch itself (step 3a), once, before the review, resolves conflicts, then pushes and opens a draft PR; the human marks it ready for review. The push and draft PR run without a prompt only in a repo set to `claude-gate remote auto`; otherwise the gate asks.

## 1. Worktree

- `worktree=$(git rev-parse --show-toplevel)` and `branch=$(git branch --show-current)`. Print both.
- Empty `branch` (detached HEAD) or `main`/`master`: create the worktree.
  - `name`: a 2-4 word kebab-case slug of the change in the diff. Print it. `name` already a branch or `../<repo>-<name>` already exists: stop and ask.
  - `git worktree add -b <name> ../<repo>-<name> HEAD`. `worktree` is the absolute path of `../<repo>-<name>`; `branch` is `name`.
  - Uncommitted work in the original checkout: carry it over, tracked then untracked - `git diff --binary HEAD | git -C "$worktree" apply --index`, then `git ls-files -z -o --exclude-standard | rsync -a --from0 --files-from=- ./ "$worktree"/`. Either fails: stop, and leave both checkouts as they are.
  - Never clean the original checkout. Its copy of the changes stays; step 5 tells the human to discard it once the worktree is verified.
- `git worktree list`: if `branch` is checked out at another path, that path is `worktree`. One checkout holds the files, the commits and the review.
- `worktree` differs from the session cwd: `cd <worktree>`, literal path, without asking the human; entering is part of Ship, not a decision. Then run `pwd` in a separate call and print it. The harness keeps a `cd` only inside the session's working directories - the launch directory plus `permissions.additionalDirectories` - and resets it after the call otherwise; inside them, Edit and Write on `worktree` run without a prompt too. `pwd` is not `worktree`: the `cd` was reset, so call the `EnterWorktree` tool with `path: "$worktree"` (load it via ToolSearch first), which asks the human once whatever the allow rules say, then `pwd` again; anything other than `worktree`: stop.
- From here every command is still `git -C "$worktree" …` and `claude-review -C "$worktree" …`. No bare `git`: if the cwd drifts, `-C` keeps each command on the right checkout.

## 2. Fetch

Before any edit:

```
git -C "$worktree" fetch origin
git -C "$worktree" log --oneline HEAD..origin/HEAD
```

If `origin/HEAD` is unset, apply Orient step 4's `set-head` line first. No output from the log: up to date, go on. Output: the branch is behind. Say by how many commits, then compare `git -C "$worktree" diff --name-only HEAD...origin/HEAD` with `git -C "$worktree" diff --name-only origin/HEAD...HEAD`.

With `--integrate`, skip the rest of this step: step 3a integrates before the first review, so the review judges the integrated code.

Drop from both lists every file where `git -C "$worktree" check-attr merge -- <file>` prints `merge: union`: git merges those line by line and never stops on them.

- No file on both lists: go on. The rebase in step 5 applies cleanly.
- A file on both lists: a review of this diff would judge code the rebase is about to change. Integrate now, as step 3a does, then go on.
- `CHANGELOG.md` on this branch's list: the entry belongs in a fragment (Check section 5). Move it there and commit before going on.

## 3. Check and commit

Run Check sections 1 to 6 against the working tree and fix what fails. Then:

```
git -C "$worktree" add <path>... && git -C "$worktree" commit -m '<subject>'
```

`<path>...` is every path `git -C "$worktree" status --short` lists that belongs to this change, named one by one. The review reads `<base>...HEAD`, so an uncommitted fix is invisible to it. Every round commits before it reviews.

## 3a. Integrate - `--integrate` only

Resolve `<default>` and `<default-checkout>` as step 5 does.

The review judges integrated code. When `<default-checkout>` is absent from `git worktree list`, run the one command that unblocks it, then go on. When `pull --ff-only` fails - uncommitted paths in `<default-checkout>` overlap the incoming commits, or its `<default>` has diverged from origin - do not stop: back in the worktree, integrate against local `<default>` as it stands, and keep `integrated against local <default>, <N> behind origin/<default>: <git's error line>` for step 5, `<N>` from `git -C "$worktree" rev-list --count <default>..origin/<default>`. Never review first and hand the human a rebase after.

After a `cd`, run both lines below from the worktree. After the `EnterWorktree` fallback, the session sits in the worktree it isolated, and that isolation refuses any git aimed outside it, `-C` included. Leave it for the pull: `ExitWorktree` with `action: "keep"`, then the pull, then `EnterWorktree` with `path: "<worktree>"`, then the rebase.

```
git -C <default-checkout> pull --ff-only
git -C "$worktree" rebase <default>
```

Type both paths and `<default>` as literals, unquoted: the write gate cannot expand a variable, and a line it cannot resolve asks. `rebase` when the branch is unpushed (`git -C "$worktree" rev-parse --abbrev-ref @{u}` fails and `git -C "$worktree" ls-remote --exit-code --heads origin <branch>` exits 2); `git -C "$worktree" merge <default>` otherwise, so review comments keep their shas.

A conflict: resolve it. For each file in `git -C <worktree> diff --name-only --diff-filter=U`:

- Read base, ours and theirs (`git -C <worktree> show :1:<file>`, `:2:`, `:3:`) and the default-branch commits that touched it (`git -C <worktree> log -p <merge-base>..<default> -- <file>`). In a rebase `:2:` is the default side and `:3:` this branch's commit; in a merge, the reverse.
- Write a result that keeps both sides' behavior. Adapt this branch's change to the default side's; never drop the default side's change to make this one apply.
- `git -C <worktree> add <file>`, then `git -C <worktree> -c core.editor=true rebase --continue` (or `merge --continue`). A rebase can stop again on a later commit: repeat.

Abort instead (`rebase --abort` or `merge --abort`) and stop, naming the conflicted files, when a conflicted file is binary, generated or a lockfile, or when the two sides change the same behavior in different directions - that choice is the lead's.

After the last `--continue`: `git -C <worktree> diff <default> | grep -nE '^\+(<{7}|>{7})( |$)'` prints nothing (a rebase runs no pre-commit hook), then rerun Check step 2's commands and fix and commit what fails.

Then `git -C "$worktree" diff --name-only <default> -- CHANGELOG.md` prints nothing: the change's entry is its fragment.

## 4. Review loop

Before round 1, Check step 2's commands, the full test suite among them, have passed on HEAD. Round 1 of at most 10:

```
claude-review -C "$worktree" --yes --engine claude --model opus --effort xhigh
```

Run it in the background and wait for it; a review takes minutes and a foreground timeout would kill it mid-run. It prints the report, then a `review-branch: PASS` or `FAIL` line naming the report file.

- `## Findings` is exactly `none`: the loop is done. `VERDICT: PASS` alone is not enough, since PASS can carry minors. `## Adjacent smells` never counts: it is advisory, outside the diff, and not this PR's to fix.
- `already approved`: this exact diff passed earlier. Read the report file (`~/.claude/hooks/state/review-branch-<key>.md`); if its `diff sha256` matches the one printed and its findings are `none`, done. Otherwise fix those findings; the next commit changes the hash and the next round reviews afresh.
- Anything else: print `round N: <count> findings`. The reviewer writes a runtime finding's test but never runs it, so run it before fixing anything. For each `Proof: runtime` finding, paste its test into the test file its neighbors use and run that file at HEAD. Adapt only the harness - imports, fixtures, render helpers - never the input or the expected value. Print `proof <path:line>: confirmed|disputed|unrun`:
  - The assertion on the proof's expected value fails: confirmed. Keep the test; it is the finding's regression test.
  - The test passes: disputed. Remove the test and treat the finding as wrong, with the reason `proof test passes`.
  - The test errors before that assertion and the harness cannot be fixed, or the repo has no runner for that file: unrun. Judge the finding by reading, as one without a runtime proof.

  Then fix each finding that is not disputed in `"$worktree"`, most severe first, as a class, not an instance - most later-round findings land in a file an earlier round flagged:
  - Grep `git -C "$worktree" diff origin/<default>...HEAD`, the diff the reviewer reads, for the same pattern and fix every occurrence, not only the line cited.
  - Add the test that fails without the fix, if the repo has tests; for a confirmed finding, that is its proof test. A doc or prose finding needs none.
  - A finding that is wrong gets no code change. Keep it, as `path:line - defect - reason`, for the PR body's `Disputed findings` section: the human sees every finding the author dismissed.

  Then `git -C "$worktree" add <path>...` and rerun Check step 2's commands on what is staged, except the full suite: a fix is new code the checkers have not seen. In its place run the test files the fix touched; the suite waits for the last round. Fix what fails and add those paths again, or name it as left out and why, as Check allows. Then `git -C "$worktree" commit -m '<fix subject>'` and start round N+1.

After round 10 with findings still open, or a round where every finding is wrong - nothing to commit, so the next round would judge the same diff - stop: print each open finding as `path:line - defect`, with the reason for each one judged wrong, then hand off anyway. The human decides.

However the loop ends, when a fix was committed since round 1, run the full suite on HEAD before handing off. It passes: hand off. It fails: fix each failure as a finding, commit, and start round N+1, since the commit changed the diff the last round approved. Past round 10, print the failures with the open findings and hand off anyway.

## 5. Hand off

Without `--integrate`, first rerun step 2's `fetch`, then `git -C "$worktree" rev-list --count HEAD..origin/HEAD`, since the review loop can outlast a merge to the default branch. Count above `0` - behind: run `git -C <default-checkout> pull --ff-only`, then `git -C <worktree> rebase <default>`, literal paths; a conflict is resolved, or aborted, as step 3a does. The human pastes the block below into a shell that sits in some other directory and has no `$worktree`, so every path is a literal absolute path and the block opens with `cd`. Print it, placeholders filled, and nothing else - no smell line, no summary.

Before any block is printed or `--integrate` pushes, write the PR body with the Write tool to `<body-file>`: `ftl-pr-body-<repo>-<branch-slug>.md` in the session's scratchpad directory, or in `$TMPDIR` when the session has none. It sits outside the tree, and outside `.git`, which an `EnterWorktree` session may not write; `<branch-slug>` is `<branch>` with each `/` as `-`, so no two branches share one. The body ends with `Disputed findings` when step 4 judged any wrong, and `Closes #N` when it finishes an issue. It never mentions conflicts, their resolution, or the rebase or merge: integration is plumbing, not the change. Every `gh pr create` reads it with `--body-file`: finding text carries apostrophes and backticks that a quoted `--body` breaks on.

```
cd <worktree>
git push -u origin <branch>
gh pr create --title '<subject>' --body-file <body-file>
```

With `--integrate`, no fetch, no second rebase or merge and no re-review: push the branch as reviewed, even when `<default>` has moved since step 3a. Instead of printing a block:

- `git -C <worktree> push -u origin <branch>`, then `cd <worktree> && gh pr create --draft --title '<subject>' --body-file <body-file>`. Literal paths. Single-quote the title; one with an apostrophe goes in double quotes and carries no `$` or backtick.
- Print the PR URL and nothing else - plus step 3a's `integrated against local` line when its pull failed, and, when step 1 carried work over, the restore and clean line below for the human.

Do not push when the loop stopped with findings open (round 10, or every finding judged wrong), step 3a stopped, or the gate or pre-push refuses: print the block for the human, as plain Ship does.

When Orient step 2b printed a plan, update this task's status in it as the last write before printing: branch, head sha, and the draft PR URL when `--integrate` opened one, or why it stopped.

`<default>` is `git symbolic-ref --short refs/remotes/origin/HEAD` with the `origin/` dropped; `<default-checkout>` is the path `git worktree list` shows for it. A branch already under review takes `git merge <default>` in place of `git rebase <default>`. When step 1 carried uncommitted work over, the block's second line is `git -C <original-checkout> restore --staged --worktree . && git -C <original-checkout> clean -fd`, which discards the original copy; it discards work, so it stays the human's. The subject follows Check step 6; a PR that finishes an issue ends its body with `Closes #N`.
