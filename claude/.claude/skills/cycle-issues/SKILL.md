---
name: cycle-issues
description: Issue-backed incremental plan-and-execute loop. Same rolling workflow as /cycle but tasks live as GitHub issues, tracked by a pinned tracker issue with linked checkboxes. No TODO/ directory. e.g. /cycle-issues "add user preferences API", /cycle-issues (continue next), /cycle-issues 03 (specific task), /cycle-issues --adjust (replan only), /cycle-issues --spawn (concurrent fan-out in worktrees).
---

## Help

If `$ARGUMENTS` is exactly `--help`, `help`, or `-h`, print the block below
verbatim and **stop — do not execute the skill**.

```
/cycle-issues — rolling plan-and-execute loop backed by GitHub issues

  Issue-backed incremental plan-and-execute loop. Same rolling workflow
  as /cycle but tasks live as GitHub issues, tracked by a pinned tracker
  issue with linked checkboxes. No TODO/ directory.

  /cycle-issues "goal"           seed a new tracker issue and start
  /cycle-issues                  continue next ready task
  /cycle-issues NN               work on task issue #NN
  /cycle-issues --adjust         replan only, no execution
  /cycle-issues --spawn [N]      fan out concurrent tasks in worktrees
  /cycle-issues --help           show this help

  See also:
    /cycle         same workflow backed by TODO/ files
    /delib         settle an architecture question before planning
    /newchat       hand the next task to a fresh session
```

---

# Cycle Issues (`/cycle-issues`)

Same rolling plan-and-execute loop as `/cycle`, but the backing store is
**GitHub issues** instead of a `TODO/` directory. A single **tracker issue**
is the index; each task is its own issue. The head model owns the plan and
git; all repo rules apply unchanged.

## Syntax

```
/cycle-issues ["goal"]       # seed a new tracker issue and start the first task
/cycle-issues                # continue: detail + execute the next ready task
/cycle-issues NN             # work on task issue #NN
/cycle-issues --adjust       # review and adjust the plan — no execution
/cycle-issues --spawn [N]    # concurrent fan-out (same as /cycle --spawn)
```

## Model tiers

Same as `/cycle`:

| Role | Model | Job |
|------|-------|-----|
| Head | session model | Plan, sequence, review, own git and issues. |
| Implementation worker | `model: "opus"` | Execute one sub-task: implement + test. |
| Lookups | default | Greps, quick doc checks. |

Every `Agent()` call passes `model:` explicitly. **Never spawn Fable
subagents.**

## Issue structure

### Tracker issue (the index)

One issue per cycle. Title: `cycle: <goal>`. Body:

```markdown
## Tasks

- [ ] #<issue> — `<slug>` ~M — owns `<globs>`
- [ ] #<issue> — `<slug>` ~S — owns `<globs>` (depends on #<issue>)
- ...

## Refs
- Test command: `<cmd>`
- Build/lint: `<cmd>`
- Key files: <list>
```

Label: `cycle-tracker`. Pin it if the repo supports pinning
(`gh issue pin <number>` — best effort, don't fail if unsupported).

**Adjustments** are posted as comments on the tracker issue (append-only
log, same role as `TODO/README.md`'s adjustments log).

### Task issues

One issue per task. Title: `<slug>`. Body:

```markdown
**Goal:** <one sentence>  **Branch:** <type>/<kebab>  **Deps:** #<issue> or none
**Owns:** <write-scope globs — `--spawn` batches issues whose globs are disjoint>
Tracker: #<tracker-number>

## Sub-tasks
- [ ] 1. <behavior> — test: <what the failing test proves>; files: <list>
- [ ] 2. ...

## Verify
<exact commands>

## Done when
<observable acceptance criteria>
```

Label: `cycle-task`. Assign to self if `gh` auth allows.

## Phase 0 — Seed (first invocation with a goal)

1. Read repo `CLAUDE.md` and scan the codebase (same lightweight pass as
   `/cycle`).
2. State the goal; decompose into a rough task list with size estimates and
   `Owns` globs — seek seams, same rule as `/cycle` phase 0.
3. **Checkpoint:** show the task list, get one OK.
4. Create the task issues (title + one-line body only — no sub-tasks yet):

   ```bash
   gh issue create --title "<slug>" --label "cycle-task" --body "<one-line goal>"
   ```

5. Create the tracker issue with the checkbox list linking to the task
   issues. Label `cycle-tracker`.
6. Pin the tracker (best effort).
7. Fall through to phase 1 for the first task.

**Guard:** before seeding, check for an open `cycle-tracker` issue:
`gh issue list --label cycle-tracker --state open --limit 1`. If one exists,
stop and ask:

> Tracker #NN is open. Use `--adjust` to modify it, or confirm starting a
> new cycle (the old tracker stays open).

## Phase 1 — Detail (each iteration)

1. Read the tracker issue body to find the next ready task (unchecked,
   deps closed).
2. Flesh out the task issue body with sub-tasks, verify block, and done-when
   criteria (`gh issue edit <number> --body "..."`). Show the edit before
   running.
3. Verify names by grepping the codebase — same rule as `/cycle`.

## Phase 2 — Execute

Same implementation loop as `/cycle`. One addition: reference the task issue in commit
messages where natural (e.g. `feat/auth: add token refresh (ref #42)`). Don't
force it — only when it fits the commit convention.

Branch handling: if already on a feature branch, stay on it. Otherwise
propose `git switch -c <type>/<slug>`.

## Phase 3 — Checkpoint

After completing a task:

1. Close the task issue with a comment summarizing what landed:

   ```bash
   gh issue close <number> --reason completed --comment "Landed in <branch>. PR: #<pr> (if opened)."
   ```

2. Update the tracker issue body — check the completed task's box. Use
   `gh issue edit <tracker> --body "..."` with the updated checkbox list.
3. **Adjust the plan** — if lessons learned warrant changes, add a comment
   to the tracker and update the body (reorder, resize, add/drop tasks;
   create new task issues if adding).
4. Offer push + `gh pr create` per repo git policy.
5. **Bugs found in passing** — the tracker is the only backing store, so a
   problem nobody is fixing now becomes its own GitHub issue instead of an
   `ISSUES.md` block. Print the `gh issue create` line; don't run it unasked.
6. **Decision point** — same as `/cycle`: route via
   `~/.claude/skills/shared/next-command.md` and propose exactly one of
   continue, `--spawn`, or `newchat`. Recommendations name issue numbers, not
   task file ids.

## `--adjust` flow

1. Read the tracker issue and all open task issues.
2. Propose changes — show a before/after of the tracker body. One OK.
3. Apply edits to tracker body. Add a comment explaining the adjustment.
4. Create/close task issues as needed.

## `--spawn` flow (concurrent fan-out)

Same as `/cycle --spawn` — auto-size from the task graph, create worktrees,
spawn one tmux window with a pane per worker, then supervise via the report
drop + `Monitor` + `tmux send-keys` rework loop. Differences: spawned sessions
read their task from the GitHub issue instead of a `TODO/taskNN-*.md` file, and
report by commenting on the issue *and* dropping `<main>/.cycle-reports/NN.done`
so the head's monitor fires. Seed prompt:

```
Read issue #<number> (gh issue view <number>). Execute all sub-tasks (approval-gated
commits). When done: push the branch, offer gh pr create, and
close the issue with a summary comment.
Then report to the supervisor: comment on the issue with branch, commits, files
touched, verify output, surprises, PR number — then, only once that comment is
posted, touch <main-path>/.cycle-reports/NN.done. If the supervisor sends
rework, address it, re-comment, and re-touch the marker.
Context budget: 15% nudge, never exceed 20%.
```

A worker writes no prompt of its own: the report comment is its handoff, and
only the head opens the next session.

Reconvene: `/cycle-issues --adjust` reconciles — checks which task issues
are closed, updates the tracker, cleans up worktrees.

`--contest NN` routes the same way: run `/cycle`'s `--contest` flow with issue #NN as the task spec and report markers named by issue number.

## Closing a cycle

When all task checkboxes are checked and all task issues are closed:

1. Add a final comment to the tracker: `Cycle complete — all tasks landed.`
2. Close the tracker issue (`--reason completed`).
3. Invoke **`newchat`**. The tracker and its closed issues are the durable
   record, so the prompt carries only what reading them misses. Its task line
   is the command step 6 routed to — `/cycle-issues NN`, the next tracker, or
   the next goal.

## Context budget

Same as `/cycle` — 15% nudge, never exceed 20%. At the budget, invoke
`newchat` mid-cycle. The tracker's checkboxes already hold the resume point,
so the prompt needs only the task line and the facts the tracker cannot state.

## When NOT to use

- Repo doesn't use GitHub (no `gh` CLI configured) — use `/cycle`.
- Tasks are too small to warrant individual issues — use `/cycle`.
- Single-PR work — `/slice`.
- Architecture decisions — `/delib` first, feed the result in.
