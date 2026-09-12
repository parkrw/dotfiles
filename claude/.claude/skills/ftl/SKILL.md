---
name: ftl
description: Follow the leader. Working method for a repo someone else owns, derived from that repo at run time - its rules file, its docs, its CI, and the lead's own commits. `/ftl <task>` orients - indexes docs/ by heading, reads only the sections the task touches, measures the lead's commit and CHANGELOG conventions. `/ftl` alone is the pre-handoff checklist - definition of done, docs, CHANGELOG line, commit subject, then the git and gh commands for the human to run. Read-only - never fetches, commits, pushes, branches, stashes, or calls gh. e.g. /ftl "zerto logout url #282", /ftl, /ftl --help.
---

## Help

If `$ARGUMENTS` is exactly `--help`, `help`, or `-h`, print the block below verbatim and **stop - do not execute the skill**.

```
/ftl - follow the leader: work the way the repo's lead does

  Derives the conventions from the repo you are in: rules file, docs index,
  CI, the lead's commits. Never runs a git write, a fetch, or a gh command.

  /ftl <task>     orient: index docs/ by heading, read the sections the
                   task touches, measure the lead's conventions, print state
  /ftl            pre-handoff checklist on the staged diff (falls back to
                   the working tree), then the commands for the human
  /ftl --help     show this help
```

---

Run from the repo root. Every step prints the line that shows its result, so the next step can rely on what is on screen.

# Orient - `/ftl <task>`

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

## 3. The lead's conventions, measured

Find the lead: `git shortlog -sn --no-merges | head -3`. Then, with `--author='<lead>' --no-merges`:

| Measure | Command | Record |
| --- | --- | --- |
| subjects | `git log --format=%s -60` | case, length range, prefix pattern, how an issue is closed |
| bodies | `git log --format='%s%n%b%n---' -20` | prose or bullets, trailers, what a squash merge leaves |
| footprint | `git log --format= --shortstat -30` | files per commit; whether tests, docs and CHANGELOG land together |
| CHANGELOG | `sed -n '1,30p' CHANGELOG.md`; `grep -oE '^- (fix\()?[a-z]+' CHANGELOG.md \| sort \| uniq -c \| sort -rn` | section shape, line shape, scopes in use |
| done | the rules file; else `grep -hE '^\s+run:' .github/workflows/*.yml`; else `package.json` scripts or `Makefile` targets | the commands the checklist will run |
| branches | `git branch -r --format='%(refname:short)' \| head -20` | the branch naming the lead pushes |

If memory holds a profile of this lead, correct it where the measurement disagrees. If it holds none, write one.

## 4. State

`git status --short`, `git branch --show-current`. Print `git fetch origin` for the human; never run it. Then, against whatever the last fetch left, `git log --oneline HEAD..origin/HEAD`. If `origin/HEAD` is unset, print `git remote set-head origin -a` for the human.

If the log prints anything the branch is behind. Say by how many commits, and name the files both sides touch (`git diff --name-only HEAD...origin/HEAD` against `git diff --name-only origin/HEAD...HEAD`): those are where a rebase will conflict. Then recommend one, with its consequence:

- Behind only in files this branch does not touch: nothing now; rebase before the PR.
- Unpushed branch: `git pull --ff-only` in the checkout holding the default branch, then `git rebase <default>` here. New shas, nothing else changes. Re-run the checkers after, because the rules move.
- Pushed, not yet reviewed: the same, then a `--force-with-lease` push from the human's own terminal. The pre-push hook denies a non-fast-forward push from Claude.
- Pushed and under review: `git merge <default>` instead, so review comments stay anchored to their shas. The squash merge drops the merge commit.

Print the chosen commands as one sequence and wait.

Never edit on the default branch. If you are on it, print `git switch -c <branch>` for the human and wait.

## 5. The human's rules

These win over the lead's habits.

- The human runs every git write and every `gh` command. You produce the diff and print the command. `fetch`, `commit`, `push`, `switch`, `branch`, `stash`, `gh`: never.
- No `Co-authored-by` and no `Claude-Session` trailer.
- Repo-tracked Claude config (`.claude/`, `CLAUDE.md`, skills) is the lead's decision. Tooling lives in `~/.claude/` and the untracked `.claude/settings.local.json`.
- A runbook is unverified until you have run it. Run a procedure against dev before extending it, and frame the change as "run against dev on <date>, here is what changed".
- Work lands as a PR. An issue writeup gets absorbed into the lead's commits; a PR gets reviewed and stays attributable.

# Check - `/ftl`

Every item is pass or fail with the output line that shows it. Do not hand off with an open item: fix it, or name it as left out and why.

## 1. Shape

- `git status --short` and `git diff --cached --stat`. The diff is one behavior. A second behavior is a second PR.
- If the repo keeps a CHANGELOG, write its line first (section 5). If the line cannot say what a customer or staffer now gets, the change is not shaped yet.
- An adjacent smell becomes one line at the end of the handoff.
- Print `git fetch origin` for the human, then `git log --oneline HEAD..origin/HEAD`. Output means the branch is behind: apply Orient step 4.

## 2. Definition of done

Run the commands from Orient step 3, from the repo root, each with its pass line. Then:

- `git diff --cached | grep -nE '^\+.*\.(skip|only)\('` prints nothing.
- A bug fix carries a test that failed before the fix. Name the test.
- If the rules file demands a spelling, `git diff --cached | grep -nE '^\+.*\b(licence|colour|behaviour|organis|initialis|centre|cancelled|catalogue|analyse|favour|honour)'` prints nothing for US spelling. A mechanical checker rarely covers spelling; this grep is the spot check.
- If the rules file names a running stack you may restart, restart it and read its log. Paste anything that is not a clean boot.

## 3. Docs

`git diff --cached --name-only`, then grep the docs index (Orient step 2) for each touched module's name and for the behavior's nouns. A doc that describes the changed behavior and does not reflect the change fails. An endpoint change updates the API reference if the repo has one.

## 4. Code and prose spot check

- Module header states the domain problem and its constraint, if the codebase does that. Every other comment is a WHY: a hidden constraint, an invariant, a workaround for a named bug. Delete a comment that restates the line under it.
- Match the surrounding code's construction style: how classes hide state, how collaborators are injected, where wired objects come from.
- No new dependency. Adding a package is a design decision to raise with the lead before the PR.
- Tests match the neighboring files' runner and fixtures. A test name is a behavior sentence. Assert outcomes; asserting call shape tests the test.
- If the repo has a prose checker, run it. Fix its notes in touched lines even when they do not fail.

## 5. CHANGELOG

Follow the shape measured in Orient step 3: section, line, prefix, scope, issue reference. The line says what the reader can now do or rely on. A scope that is not in the count needs a reason.

## 6. Commit subject and body

- Subject: the measured shape - case, length, prefix. It states what the reader can now rely on. Close the issue from the subject or body the way the lead does.
- Body: the mechanism that was wrong and what now holds, as prose. For a multi-item change the body is the CHANGELOG bullets. One paragraph per line, no hard wrap.
- If CI judges the PR description, write the body under the same prose rules.
- No `Co-authored-by`, no `Claude-Session`.

## 7. Hand off

Print these for the human to run, placeholders filled in. The branch name follows the naming measured in Orient step 3.

```
git switch -c <branch>
git add -A && git commit -m '<subject>' -m '<body>'
git push -u origin <branch>
gh pr create --title '<subject>' --body '<body>'
```

Then one line per adjacent smell found, and nothing else.
