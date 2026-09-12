---
name: handoff
description: End-of-session handoff — write state into the current task file's Handoff section (TODO/taskNN-*.md), or HANDOFF.md if the repo has no TODO/, and print a paste-ready prompt for the next Claude session. Routes durable knowledge to TODO/notes/ and unowned problems to ISSUES.md. Subcommands via argument: (none) = general handoff, NN = force a task target, "merged" = PR merged, "stash" = work stashed. e.g. /handoff, /handoff 03, /handoff merged, /handoff stash.
---

## Help

If `$ARGUMENTS` is exactly `--help`, `help`, or `-h`, print the block below
verbatim and **stop — do not execute the skill**.

```
/handoff — write session state into the live task file + paste-ready prompt

  Writes the handoff into the Handoff section of the task file being
  worked on (or the next one) under TODO/, falling back to HANDOFF.md in
  repos with no TODO/. Marks the task COMPLETE / IN PROGRESS / NEEDS
  REVISIT / BLOCKED, replaces the stale handoff rather than appending,
  and routes recurring knowledge out to TODO/notes/ and unowned problems
  to ISSUES.md. Ends by recommending the one command to run next
  (e.g. /fan), picked from the plan's remaining task graph.

  /handoff                       handoff into the live task file
  /handoff NN                    force task NN as the target
  /handoff merged                PR merged, prompt targets next task
  /handoff stash                 work stashed, prompt includes stash ref
  /handoff --help                show this help

  See also:
    /spawn         open a new session that picks up the handoff
    /slice         invokes /handoff at end of each slice
```

---

# Session Handoff

Produce two artifacts, in this order: an updated handoff **in the task file**,
then a paste-ready prompt. The **file is the source of truth**; the prompt is a
pointer plus the first action. Assume the next session starts with zero context.

## 1. Resolve the target (in this order)

1. **Task id in `$ARGUMENTS`** (`03`, `task03`) → that task file.
2. **`TODO/` exists** → the task this session actually worked on. If it worked on
   none: the in-flight task (`[~]` in `TODO/README.md`), else the next ready
   task (`[ ]`, deps satisfied). If the chosen task has no file yet (index-only
   title), write into a `## Handoff` section near the top of `TODO/README.md`
   instead — do not fabricate a task file.
3. **No `TODO/`** → `HANDOFF.md` at the repo root (or the project's existing
   handoff location, if it has one).

State the resolved target in one line before writing it.

## 2. Gather state (read-only)

- `git branch --show-current`, `git status --short`, `git stash list`.
- The target task file, `TODO/README.md`, and any existing `HANDOFF.md`.
- Open PR, if any: `gh pr view --json number,url,state` (best effort).

## 3. Write the Handoff section

Every task file ends with a `## Handoff` section. **Replace its body — never
append.** The previous session's handoff is a liability once its facts are in
git history and the sub-task checkboxes; carrying it forward makes the next
session read three sessions of scar tissue to find one next action.

```markdown
## Handoff

**Status:** COMPLETE | IN PROGRESS | NEEDS REVISIT | BLOCKED
**Branch:** <branch>  **PR:** #N (open|merged) or none  **Updated:** <YYYY-MM-DD>

- **Landed:** <what now works, in behavior terms, 1-3 bullets>
- **Repo state:** <uncommitted files / stash name / clean>
- **Next:** <one concrete first action — file:line or command>
- **Gotchas:** <only what is not derivable from the code or CLAUDE.md>
```

Status rules:

- **COMPLETE** — sub-tasks all ticked, verify commands green, nothing owed.
  `Next:` names the *next task*, not this one.
- **IN PROGRESS** — stopped mid-task. Name the sub-task number to resume at.
- **NEEDS REVISIT** — shipped but something must be re-examined. Say **what**
  and **why** in one line each; a bare flag is useless.
- **BLOCKED** — cannot proceed. Name the blocker and who or what unblocks it.

Pruning rules, applied every time:

1. Delete anything now visible in `git log`, the diff, or a ticked checkbox.
2. Delete decisions that are now just how the code works.
3. Keep it under ~15 lines. If it wants to be longer, the extra belongs in
   `TODO/notes/` or `ISSUES.md` (§4).

Then update `TODO/README.md`: set the task's status marker and put a single
resume pointer near the top so a zero-context session finds the live handoff
without opening every task file:

```markdown
**Resume:** `TODO/task03-oidc-callback.md` → Handoff (IN PROGRESS)
```

Committing: if the only unstaged changes are the files this handoff touched,
offer an approval-gated commit of exactly those files (one-line `docs(todo):`
subject) — an uncommitted handoff does not survive a `/clear`, a worktree
spawn, or a stray checkout. If the tree carries any other changes, leave
everything uncommitted for the user or the next session; never sweep task WIP
into a handoff commit. Never push — remote-write policy is out of scope here.

## 4. Route what does not belong in the handoff

Three targets, decided by lifetime:

| Fact | Lifetime | Goes to |
|------|----------|---------|
| What the next session does next | this task | task `## Handoff` |
| A problem nobody is fixing right now | until fixed | `ISSUES.md` |
| Something true in a month regardless of task | durable | `TODO/notes/<topic>.md` |

**`ISSUES.md`** (repo root) — bugs found in passing, flaky tests, upstream bugs,
deferred cleanups. Never a task-tracker duplicate: if it is planned work it is a
task, not an issue. Newest first, one block each:

```markdown
## <slug> — <one-line symptom>
**Status:** open | fixed YYYY-MM-DD | wontfix  **Found:** taskNN, YYYY-MM-DD
<2-4 lines: where it shows, what is known, cheapest next probe.>
```

Before adding: grep `ISSUES.md` for the slug. Update the existing block rather
than adding a second one, and flip `Status:` when a session fixes it.

**`TODO/notes/<topic>.md`** — the third time a fact gets re-derived, it is a
note, not a gotcha. Environment quirks, how to run a thing locally, an
upstream API's real shape, a debugging recipe. Write it, then reference it from
the task file (`see TODO/notes/keycloak-realm-import.md`) rather than restating
it. Link the note from `TODO/README.md`'s Refs block so later sessions pick it
up.

## 5. Print the paste-ready prompt

Emit a fenced code block the user can copy verbatim into a new session:

```
Read <target file> — its Handoff section first. We are in <repo path> on branch <branch>.
<one sentence: state — e.g. "task03 COMPLETE, PR #12 merged" / "work is stashed as <stash>">.
Next: <task id / concrete first action>. <one session-specific constraint not derivable from the task file or CLAUDE.md, if any>.
```

Rules: no restating global `CLAUDE.md` policy (the next session loads it
anyway); no narrative; ≤5 lines.

## 6. Recommend the next command

Read `~/.claude/skills/shared/next-command.md` and follow it: pick the one
command the next session should run, and emit its fenced `Next:` / `Why:`
block after the paste-ready prompt. The prompt's own `Next:` line must name
that same command — the two must not disagree.

## Subcommands (`$ARGUMENTS`)

- **(none)** — general handoff as above.
- **`NN`** / **`taskNN`** — force that task file as the target.
- **`merged`** — assume the PR just merged. Verify with `gh pr view` if
  possible; note main needs a pull (don't run it). Mark the finished task
  **COMPLETE**, then write the handoff into the *next* task's file and name
  that task explicitly in the prompt.
- **`stash`** — work is being stashed for a restart. Confirm the stash exists in
  `git stash list` and reference it by name in both the file and the prompt. If
  no stash exists yet, show the `git stash push -m "<slug>"` command for the
  user to approve — never assume it ran.

After printing the prompt, stop. Do not start the next task.
