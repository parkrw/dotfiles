---
name: slice
description: Implement a scoped task as a vertical slice — feature-branch commits, a PR offer, and a handoff note. Works in any repo; honours the project's own CLAUDE.md, git policy, and test/build tooling. Pass the task id or a pointer to its spec as the argument, e.g. /slice 07c2 or /slice "add rate limiting". --contest runs one task competitively: a spec agent writes red acceptance tests, two workers implement independently, winner by test count — one linear feature branch either way.
---

## Help

If `$ARGUMENTS` is exactly `--help`, `help`, or `-h`, print the block below
verbatim and **stop — do not execute the skill**.

```
/slice — implement a scoped task as a vertical slice

  Implement a scoped task as a vertical slice — feature-branch commits,
  a PR offer, and a handoff note.
  Works in any repo; honours the project's own CLAUDE.md, git policy,
  and test/build tooling. Pass the task id or a pointer to its spec as
  the argument.

  /slice "add rate limiting"     implement by description
  /slice 07c2                    implement by task id
  /slice --contest "task"|NN     one task, 3 agents: spec tests, two builds, winner by test count
  /slice --help                  show this help

  See also:
    /handoff       invoked at end of each slice
    /delib         deliberate a decision before implementing
    /fan           issue-per-worktree fan-out for multi-task work
```

---

# Vertical Slice

Implement the task named in the argument (`$ARGUMENTS`) end to end. **All of the
current repo's rules — its `CLAUDE.md`, git policy, and conventions — apply.**
This skill *sequences* them; it does not relax them (git stays approval-gated
per command).

If `$ARGUMENTS` starts with `--contest`, run §1 on the rest of the argument,
then jump to the `## --contest flow` at the end of this file — it replaces
§2-3; §4-5 apply to the winning branch.

## 1. Scope

- Locate the task spec: the id/title in `$ARGUMENTS` points at a task doc,
  issue, or tracker entry — find it in whatever this repo uses (a `docs/` tree,
  an issue tracker, a TODO/handoff file). Read any prior handoff note first.
- Read the repo's `CLAUDE.md` and any docs it tells you to read for this kind of
  work.
- Verify every API method, struct field, route, or config key the plan relies
  on by grepping the real code — quote what you found. Never plan on assumed
  names.
- If a genuine scope or architecture fork exists, ask the 1–2 questions now, in
  one batch. Otherwise state the plan in a few lines and proceed.

## 2. Branch

- Confirm cwd is the repo root and run `git branch --show-current`.
- Propose `git switch -c <type>/<kebab-task-name>` (approval-gated), following
  the repo's branch-naming convention — never work on the default branch.

## 3. Implement

Discover the project's test and build/lint commands first (a Makefile,
`package.json` scripts, `pyproject`, etc.). Then for each increment:

- Implement the change. Write tests if the repo has a test suite for the area
  you're touching.
- Document exported symbols as you go, per the repo's conventions.
- Run the full test/lint check and show it green before each commit.
- Propose the iteration commit (approval-gated). Subject per the repo's commit
  convention.

## 4. Finish the slice

- Update the project's docs (README / changelog / etc.) as the task requires.
- Write or refresh the handoff where the project keeps it — the task file's
  `## Handoff` section if this repo has a `TODO/`, else a `HANDOFF.md`, the
  tracker, or chat: status, what just landed (branch, files), open decisions,
  gotchas, and the next slice. Assume the next session starts with zero context.
- Re-run the full check; show green.
- Re-verify branch and cwd, propose the final commit. Bundle the doc + handoff
  updates into it — never a standalone handoff- or doc-only commit.
- Tell the user the task is complete and offer to push the feature branch and
  open a PR (`git push -u origin <branch>` / `gh pr create` — show the exact
  commands, wait for approval, never merge) **if the repo's rules permit it**.

## 5. Handoff

Invoke the `handoff` skill (argument `merged` if the PR merged this session,
none otherwise) — it refreshes the handoff file, prints the paste-ready prompt,
and emits the `Next:` block naming the one command to resume with. **Do not**
start the next task. After any PR is opened, note its number so the handoff
folds it in.

That `Next:` block almost always leads with `/clear` — the handoff is written
for zero context on purpose; a fresh context implements and reviews better than
a compacted one carrying this slice's assumptions. It may name something other
than `/slice`: with several related tasks left, per
`~/.claude/skills/shared/next-command.md`, a `/fan` is cheaper than slicing
them one at a time. Let the routing decide; don't override it here.

## `--contest` flow (competitive selection)

One task, three agents, one surviving branch. A spec agent writes acceptance
tests first; workers A and B implement independently against them; the head
selects by test count. No agent judges its own work, and the feature still
lands as a single linear branch of atomic commits: tests first, then the
winning implementation.

**When to recommend it:** the task is a genuine design fork (two plausible
architectures — seeing both built beats arguing about them), or it is
underspecified (the spec agent's test suite forces the acceptance criteria to
be pinned down before implementation). **Not** for well-specified small tasks:
two Opus runs on a clear spec produce low-variance output — 2x tokens for a
coin flip.

1. **Preflight.** Requires `$TMUX` and a runnable test command (do §3's
   tooling discovery now); if either is missing, stop and say so — selection
   is mechanical and cannot run without a test runner. Then fix the **task
   spec** every seed prompt below opens with: if §1 resolved the argument to
   a task file (`TODO/taskNN-<slug>.md` or wherever this repo keeps specs),
   the spec is `Read <task-file>` — workers read it themselves.
   Otherwise distil §1's scope pass into a **task brief**
   (goal, acceptance criteria, grep-verified names) and embed it verbatim.
2. **Branch + spec agent — alone, first.** Propose `git switch -c
   <type>/<slug>` (approval-gated); this is the feature branch, and the spec
   agent's tests become its first commit(s). `<worker-model>` = this session's
   model, or one tier lower (Fable → Opus → Sonnet → Haiku); never Fable.
   `<worker-effort>` = `--effort <this session's effort>`, dropped entirely when
   that effort is unknown. **Never `--effort max`.** Spawn it in the main
   worktree:

   ```bash
   mkdir -p .git/contest
   win=$(tmux new-window -P -F '#{window_id}' -n contest -c "$PWD" \
     "claude --model '<worker-model>' <worker-effort>")
   spec_pane=$(tmux list-panes -t "$win" -F '#{pane_id}')
   tmux select-pane -t "$spec_pane" -T <slug>-spec   # readability only, never logic
   ```

   Launch with **no positional prompt** and no `--allowedTools` flags — local
   `git add` / `git commit` already run unprompted under the user's gates, and
   an unquoted flag string re-splits on whitespace and corrupts tmux's argument
   handling, which swallows the seed. Deliver the seed by tmux buffer instead —
   a file plus a buffer has no quoting surface at all:

   ```bash
   printf '%s' "$seed" > "$SP/seed-spec.txt"   # single line, no embedded newlines
   tmux load-buffer -b sspec "$SP/seed-spec.txt"
   tmux paste-buffer -b sspec -t "$spec_pane"
   tmux delete-buffer -b sspec
   sleep 1 && tmux send-keys -t "$spec_pane" Enter
   ```

   The seed must be **one line**: a multi-line paste submits at the first
   newline and strands the rest in an empty prompt. Join the prompt below into
   a single line before writing the file.

   Spec seed prompt:
   > <task spec> — You are on branch `<type>/<slug>`. Write acceptance tests
   > ONLY, verifying the task's observable behavior — results, exit codes,
   > side effects, never call shapes. Do NOT implement the feature. Every
   > test must fail (red) against the current branch; a test that passes
   > before implementation tests nothing — delete and rewrite it. Run the
   > suite and confirm all red. When done: commit (approval-gated), write
   > `<main-path>/.git/contest/spec.md` (test file paths, the exact command
   > that runs them, the red-run output), and only then
   > `touch <main-path>/.git/contest/spec.done`. Context budget: 15% nudge,
   > never exceed 20%.
3. **Checkpoint the spec.** Monitor for the report (step 6 loop, markers =
   `spec`, N=1). On `REPORT`: re-run the reported test command and confirm
   every test is red — a green test goes back as rework via `tmux send-keys
   -t <pane>` (first confirm `tmux display-message -p -t <pane>
   '#{pane_dead}'` prints `0`). Then show the user the test names as the
   pinned acceptance criteria and get one OK before any implementation
   starts — this checkpoint is the task file slice never had.
4. **Create both worktrees from the spec HEAD** so A and B inherit the
   tests — no push needed, worktrees share the object store:

   ```bash
   spec_head=$(git rev-parse HEAD)
   git worktree add ../$(basename "$PWD")-<slug>-a -b <type>/<slug>-a "$spec_head"
   git worktree add ../$(basename "$PWD")-<slug>-b -b <type>/<slug>-b "$spec_head"
   ```

   Then run the project's install command in **both** worktrees — a fresh
   worktree has no `node_modules` or vendor dir, and neither worker can run the
   spec tests without one.

5. **Spawn A and B concurrently** — split the contest window with
   `tmux split-window -P -F '#{pane_id}' -t "$win" -c <worktree>`, one pane per
   worker, capturing each `pane_id`. Titles `<slug>-a` / `<slug>-b` are **for
   humans only** — Claude Code overwrites its own pane title to `✳ Claude Code`
   within seconds, so no logic may key off `#{pane_title}`. Layout from the
   window's actual width, ~80 cols per pane:
   `w=$(tmux display-message -t "$win" -p '#{window_width}')`; wide enough →
   `even-horizontal`, else `even-vertical`. Deliver both seeds by tmux buffer
   as in step 2 — one line each, never as a command argument. Seed prompts are
   **identical** (`a`/`b` differ only in report paths):
   > <task spec> — Implement it end to end in atomic, approval-gated
   > commits, per this repo's CLAUDE.md. Run the existing tests in <test
   > paths from spec.md> as part of your verify step and include their
   > output in your report. When done: run /handoff so the task file's
   > Handoff section (or HANDOFF.md if this repo has no TODO/) carries what
   > landed and any surprises, then write
   > `<main-path>/.git/contest/a.md` (commits, files touched, verify
   > commands + their output, surprises), and only once it is fully written:
   > `touch <main-path>/.git/contest/a.done`. If rework arrives, address it
   > and re-report the same way (overwrite both files). Context budget: 15%
   > nudge, never exceed 20%.

   Neither prompt mentions the other worker, the spec agent, or a contest —
   a worker told it is competing optimizes for winning, not for the task.
6. **Supervise** — first write the interim handoff, the safety net if the
   head dies mid-contest: refresh the task file's `## Handoff` (or
   `HANDOFF.md`) with the feature branch, spec HEAD, both worktree paths +
   pane ids, and `reports land in .git/contest/` — enough for a fresh
   session to reconvene. Then arm one persistent monitor emitting a line per
   report and per pane that dies without reporting (silence must not look
   like success):

   ```bash
   seen=""
   panes="<marker:pane_id pairs>"   # e.g. a:%12 b:%13 — pane_id, never pane_title
   while true; do
     # a tmux failure must not read as N dead workers — skip the sweep instead
     live=$(tmux list-panes -t "$win" -F '#{pane_id} #{pane_dead}' 2>/dev/null) \
       || live=""
     for mp in $panes; do
       m=${mp%%:*}; id=${mp#*:}
       case " $seen " in *" $m "*) continue ;; esac
       if [ -e ".git/contest/$m.done" ]; then seen="$seen $m"; echo "REPORT $m"
       elif [ -n "$live" ]; then
         case "$live" in *"$id 0"*) continue ;; esac
         seen="$seen $m"; echo "PANE GONE $m — died without reporting"
       fi
     done
     [ $(echo $seen | wc -w) -ge N ] && { echo "ALL IN"; break; }
     sleep 20
   done
   ```

   Liveness keys off `#{pane_id}`, which nothing can overwrite. Never off
   `#{pane_title}` — Claude Code renames its own pane, the match misses every
   worker, and the first pass reports both workers dead ~20s after spawn.

   Markers = `a b`, N=2. On each `REPORT`: re-run the worker's verify
   commands and the spec tests in its worktree — trust that output over the
   report — and delegate the diff read to a review agent (the harness's
   code-review agent if one is listed in the available agent types, otherwise
   `general-purpose` briefed as a code reviewer in the prompt) pointed at the
   worktree (`git diff <spec_head>...<branch>`, task spec as the yardstick);
   the diff lands in the reviewer's context, not the head's.
   Rework goes back via `tmux send-keys` (alive check as in step 3). Before
   re-arming the monitor for a re-report, **`rm .git/contest/<m>.done` first**:
   the monitor has already exited on `ALL IN` and the first report's `.done`
   still exists, so a fresh monitor armed over a stale marker fires `REPORT`
   instantly, on every pass, forever.
   Selection starts only after both report; a `PANE GONE` forfeits that
   side — the survivor still has to pass selection step 1.

**Selection** — a decision procedure, not a judgment call. Run in order; stop
at the first decisive step.

1. Run the spec agent's test command in each worktree. Take pass/fail counts
   from the runner's summary output, never from the workers' reports.
2. Counts differ → more passes wins.
3. Tied → run the project's lint/typecheck in both worktrees. One clean, one
   not → clean wins.
4. Still tied → two review agents (the harness's code-review agent if one is
   listed, otherwise `general-purpose` briefed as a code reviewer), one per
   diff, the task spec as the yardstick; ask each for a readability read and
   pick from the two reports. The only subjective step, and the last resort.

**Land the winner.** In the main worktree — still on `<type>/<slug>` at the
spec HEAD — propose `git merge --ff-only <type>/<slug>-<winner>`
(approval-gated). The feature is now one linear branch: the tests-first
commit(s), then the winner's atomic commits. Report to the user: winner, test
counts (`A 7/9, B 9/9`), the specific tests that differentiated them and what
the loser got wrong, lint results if step 3 decided it. Then, approval-gated:
`git worktree remove` both worktrees, delete both `-a`/`-b` branches, and
`rm -rf .git/contest` (scratch inside the git dir — it can never be
committed). Continue at §4 on the feature branch — §5 then invokes the
`handoff` skill as with any slice, replacing the interim handoff with the
contest outcome: winner, both test counts, and the next slice.
