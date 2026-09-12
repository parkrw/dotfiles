---
name: fan
description: Fan GitHub issues out to concurrent Claude sessions, one issue per git worktree, one tmux pane per worker, batched by disjoint write scopes. Built for shared repos - the plan, briefs, and reports live outside the repo, and GitHub sees only ordinary issues, branches, and PRs in the repo's own measured conventions. e.g. /fan "goal" (plan, create issues, first batch), /fan (fan out the ready batch), /fan NN (one issue inline), /fan NN MM (exactly these, in worktrees), /fan --adjust (reconcile and replan), /fan --help.
---

## Help

If `$ARGUMENTS` is exactly `--help`, `help`, or `-h`, print the block below verbatim and **stop - do not execute the skill**.

```
/fan - fan GitHub issues out to worktrees, in the repo's own voice

  Plans in a private state dir, writes issues and PRs the way the repo's
  lead does, and runs one Claude session per issue in a sibling worktree:
  one tmux window per batch, one pane per worker, in this tmux session.
  Nothing on GitHub or in the repo tree marks the work as tool-driven.
  State is one lane per head, so two sessions can fan the same repo at once.

  /fan "goal"          plan: decompose, create the issues, run the first batch
  /fan                 fan out the ready batch (disjoint write scopes, cap 4)
  /fan NN              one issue, inline in this checkout - no worktree
  /fan NN MM [..]      exactly these issues, one worktree each (cap 5)
  /fan --adjust        reconcile landed PRs, prune worktrees, replan; adopts a
                       dead head's lane when this session has none
  /fan --help          show this help

  See also:
    /slice         one task, one PR, no plan store
    /ftl           work a repo you don't own with the human running git and gh
    /spawn         one sibling session, no plan
```

---

# Fan (`/fan`)

Concurrent issue-driven work in a repo other people read. The head (this session) plans, creates issues, cuts worktrees, spawns one worker per issue, reviews each worker's diff before it is pushed, and reconciles. Workers implement.

Two invariants hold in every mode:

- **Nothing private touches the repo or GitHub.** The plan, briefs, and reports live in `$FAN` (below). The repo tree gets only the change itself - no `TODO/`, `HANDOFF.md`, reports, or markers. Worktrees are siblings of the checkout, never inside it.
- **Everything public is in the repo's voice.** Issue titles and bodies, labels, branch names, commit subjects, PR titles and bodies follow what is measured from the lead's own work (§ Voice), not this skill's vocabulary. A reader of the repo sees a teammate at work.

All repo rules and the user's git gates apply. This skill sequences them and never relaxes them. `$SP` below is this session's scratchpad directory.

## State

```bash
repo=$(gh repo view --json nameWithOwner -q .nameWithOwner)   # owner/name
LANES=~/.local/state/claude/fan/${repo/\//-}                   # one lane per head
FAN=$LANES/${FAN_LANE:-${CLAUDE_CODE_SESSION_ID:?}}; mkdir -p "$FAN"/{briefs,reports}
others() {   # other heads' live rows: lane, issue, owns, status
  for p in "$LANES"/*/plan.md; do
    [ "$p" = "$FAN/plan.md" ] && continue
    lane=${p%/plan.md}; lane=${lane##*/}
    grep -E '\| (inflight|review|shipped) \|' "$p" | cut -d'|' -f2,5,7 | sed "s/^/ ${lane%%-*} |/"
  done 2>/dev/null
}
```

Two heads on one repo share nothing in `$LANES`: neither renames the other's markers or completes a batch on the other's rows. They do share the tree, so a pick is checked against `others` (Fan out 1) the same way it is checked against its own batch, and `others` is printed with every guard and pick. A lane outlives its session: `--adjust` adopts one, and the `newchat` prompt at the context ceiling carries `$FAN` so the next head adopts this one.

| File | Holds |
| --- | --- |
| `$FAN/plan.md` | goal, Voice block, Refs, the task table, an append-only log |
| `$FAN/briefs/NN.md` | the worker's full brief for issue NN - everything the issue body must not say |
| `$FAN/reports/NN.md` + markers | the worker's report; `NN.done` means "reported", `NN.shipped` means "PR open" |

`plan.md`:

```markdown
# owner/repo - <goal>

## Voice
<the measured lines, § Voice>

## Refs
install: <cmd>  test: <cmd>  lint/build: <cmd>  merge style: squash|merge|rebase

| issue | slug | est | owns | deps | status | branch | worktree | pane |
|---|---|---|---|---|---|---|---|---|
| #12 | token-refresh | ~M | src/auth/** | - | ready | | | |

## Log
- 2026-09-12 seeded from "<goal>"
```

`est`: `~S` ≤100 lines, `~M` 100-300, `~L` 300+. `status`: `ready`, `inflight`, `review`, `shipped` (PR open), `landed` (PR merged), `dropped`. `owns` is the write scope: the globs the worker may touch. A file outside them is a rework trigger even when the code is right.

## Model tiers

| Role | Runs as | Model |
| --- | --- | --- |
| Head | this session | session model |
| Worker | `claude` CLI in a tmux pane | `<worker-model>`: this session's model or one tier lower (Fable → Opus → Sonnet → Haiku), never Fable. `<worker-effort>`: this session's effort, omit the flag if unknown, never `max`. |
| Reviewer, lookups | `Agent()` | `model: "sonnet"` |

Hard cap, all modes: never more than 6 agents and workers live at once, and every worker seed carries the cap. The reviewer runs one at a time and takes one slot, so a batch is at most 5 workers.

## Voice - measure once per repo

Read-only. Record the result as the `## Voice` block. Re-measure when the block is missing or the lead has 20+ commits newer than it.

| Measure | Command | Record |
| --- | --- | --- |
| rules | `AGENTS.md`, `CLAUDE.md`, `CONTRIBUTING.md`, `.github/ISSUE_TEMPLATE/*`, `.github/pull_request_template.md` | the template to fill; anything the rules say about issues, branches, PRs |
| lead | `git shortlog -sn --no-merges \| head -3` | the login to measure |
| issues | `gh issue list --author <lead> --state all --limit 20 --json title,body,labels,assignees` | title case and length; body shape (paragraph, headings, checklist); labels in use; whether any body holds `- [ ] #N` (then a tracking issue is in voice; otherwise never) |
| labels | `gh label list` | the set; a label the lead does not put on similar issues is not used |
| PRs | `gh pr list --author <lead> --state merged --limit 20 --json title,body,headRefName,mergeCommit` | title shape; body shape; how the issue is linked (`closes #N`, `fixes #N`, `#N` in the title, none); branch naming; squash or merge |
| commits | `git log --author=<lead> --no-merges --format='%s%n%b%n---' -30` | subject case, length, prefix; body prose or bullets; issue reference form |
| done | rules file, else `grep -hE '^\s+run:' .github/workflows/*.yml`, else `Makefile` / `package.json` scripts | the install, test, and lint commands for Refs |

Everything the skill writes publicly is checked against this block before the command is shown. Words that never appear in public text: the names of this skill, its files, its sections, and its roles - `fan`, `batch`, `worker`, `supervisor`, `brief`, `owns`, `sub-task`, `verify`, `done when`, `tracker`. No `Co-authored-by`, no `Claude-Session`, no generated-by line. Workers inherit all of this through the seed.

## Never

- Create a label, pin an issue, add a milestone the repo does not have, or assign anyone, yourself included. Several self-assignments in one minute is the tell a PR is not. When the gate asks about an unassigned issue at worktree creation, approve.
- Comment on an issue or PR for progress, status, or reports. The only comment is the one a teammate would leave: a one-line reason when closing an issue without a PR.
- Close an issue that has a PR. The PR closes it, in the measured form, when the lead merges. Never `gh pr merge`.
- Put `Owns`, `Deps`, `Tracker`, `Branch`, `Verify`, or `Done when` lines in an issue body. They live in the brief.
- Push before the head has reviewed. A PR appears once, finished.
- Spell the default branch's name in a git or gh command. Use `origin/HEAD` and defaults. If `origin/HEAD` is unset, `git remote set-head origin -a` first.

## Plan - `/fan "goal"`

Guard: a `$FAN/plan.md` with any row not `landed`/`dropped` → stop and ask: `--adjust`, or start over (the old plan moves to `plan-<date>.md`). Print `others`; another head's live rows inform the split, they do not block it.

1. Read the rules file; light scan of the tree. Measure Voice if the block is missing.
2. Decompose into tasks with `est` and `owns`. Seek seams: prefer tasks that own disjoint directories, even at the cost of one more task, because disjointness is what makes a batch safe. Stop when the split stops being real: a task carved out for parallelism that then needs a shared signature, one migration, or another task's output is worse than one sequential task. Overlapping globs are legal; they serialize. A file every row must touch (a CHANGELOG, a registry, an index) is shared by design: it stays in every `owns`, each worker adds only its own line, and the head expects every PR merged after the first to need a rebase the human runs.
3. Reuse before creating: `gh issue list --state open --search "<nouns>"`. A task that already has an issue takes that number. A duplicate of a teammate's issue is both noise and a tell.
4. Checkpoint: show the table, one OK.
5. Create the missing issues, one command each, each approval-gated. Title and body in Voice, the template filled if there is one, labels from the measured set only.

   ```bash
   gh issue create --title "<title in voice>" --body-file "$SP/issue-NN.md" [--label <measured>]
   ```

6. Write `plan.md` with the numbers. Fall through to Fan out.

## Fan out - `/fan`, `/fan NN MM [..]`

The head stays in this checkout and does not implement during a batch.

1. **Size.** Issue numbers that have no row yet get one first: read the issue, set `est` and `owns` from it and the code, measure Voice if the block is missing. Ready rows: `status ready`, every dep `landed` or its issue closed (`gh issue view N --json state -q .state`). Batch = ready rows with pairwise-disjoint `owns`; compare the globs, and containment is overlap (`src/api/**` contains `src/api/auth/**`, so those two serialize). `N = min(disjoint ready, 4)`, 2 when any row is `~L`. Explicit numbers override the pick up to 5, never the disjointness rule. Then across lanes: a row whose `owns` overlaps an `inflight` or `review` row in `others` defers the same way, because that file is under another worker's hands right now; a `shipped` row there is an open PR, so it is a rebase for whoever merges second, not a block, exactly as within a lane. One ready row → Inline below, not a batch. Report the pick (`Fanning 3: #12 #15 #18; deferred #14 (dep #12), #16 (owns overlaps #15), #19 (owns overlaps #40, lane 8ae991)`) with `others` under it, one OK.
2. **Brief.** Write `$FAN/briefs/NN.md` per row, for a zero-context reader: goal; the `owns` globs; sub-tasks as behaviors, each with the test it proves and the files; exact verify commands; done-when; the Voice block verbatim; grep-verified names, never assumed ones.
3. **Claim.** Branch `<issue>-<slug>` unless Voice measured another shape. Per row: `git ls-remote --exit-code --heads origin <branch>` exits 2, `gh pr list --search <N> --state open` is empty. The gate re-checks both at worktree creation; doing it here keeps the prompts in one pane.
4. **Worktrees.** `git pull --ff-only` in this checkout (allowed outright; it fetches everything, and the fast-forward applies only to the current branch). Then per row, approval-gated:

   ```bash
   git worktree add ../<repo>-<issue>-<slug> -b <branch> origin/HEAD
   ```

   A fresh worktree has no dependencies. Run Refs' install command in each before spawning, or the worker's first act is diagnosing a test failure that is not its own.
5. **Spawn.** Requires `$TMUX`; if unset, stop and say so. One new window in the caller's tmux session per batch, one pane per worker, `claude` launched with no positional prompt and no `--allowedTools`:

   ```bash
   m="claude --model <worker-model> --effort <worker-effort>"   # drop --effort if unknown
   win=$(tmux new-window -P -F '#{window_id}' -n "fan-${CLAUDE_CODE_SESSION_ID%%-*}" -c ../<wt-1> "$m")
   p1=$(tmux list-panes -t "$win" -F '#{pane_id}')
   p2=$(tmux split-window -P -F '#{pane_id}' -t "$win" -c ../<wt-2> "$m")
   w=$(tmux display-message -t "$win" -p '#{window_width}')
   [ "$w" -ge $((80 * N)) ] && tmux select-layout -t "$win" even-horizontal || tmux select-layout -t "$win" even-vertical
   ```

   Seed each pane once its prompt is up, by buffer. A file plus a buffer has no quoting surface, and a seed passed as a command argument is silently swallowed by tmux:

   ```bash
   printf '%s' "$seed" > "$SP/seed-NN.txt"     # ONE line: a multi-line paste submits at the first newline
   tmux load-buffer -b sNN "$SP/seed-NN.txt"; tmux paste-buffer -b sNN -t "$pane"; tmux delete-buffer -b sNN
   sleep 1 && tmux send-keys -t "$pane" Enter
   ```

   The seed, with `<FAN>`, `NN`, and `<branch>` substituted and joined into one line:

   > Read `<FAN>/briefs/NN.md`, then `gh issue view NN`. Write only inside the brief's owns globs; a change needed outside them goes in the report, not the tree. Commit per sub-task, approval-gated, subjects in the brief's Voice. Do not push, open a PR, or touch the issue until told `ship`. Never comment on, edit, label, or close an issue; never write anything into the repo tree but the change; no `Co-authored-by` or `Claude-Session` trailers, no generated-by line anywhere. Run the brief's verify command last and record its real exit code. Then write `<FAN>/reports/NN.md`: line 1 exactly `STATUS: green|blocked - <8 words or fewer>` (a non-zero exit is `blocked`, never green), line 2 exactly `VERIFY: <command> exit <code>`, then branch, commits, files touched, full verify output, surprises. Then `touch <FAN>/reports/NN.done` whatever the status: it means "I have reported", not "I succeeded", and withholding it on failure hangs the batch in silence. Rework arrives in this pane; address it, overwrite the report, touch `NN.done` again. On `ship`: push the branch `<branch>` to origin, open the PR with a title and body in the brief's Voice that links the issue the way Voice says, append the PR number to the report, and `touch <FAN>/reports/NN.shipped`. Context budget: 15% nudge, never exceed 20%. Hard caps: never more than 6 subagents/workers total, never `--effort max`, do the implementation yourself.

   The seed names no git or gh write command literally. The gate reads the `printf` that writes the seed file, and a `git push` inside that text is denied before the file exists.

   Name panes for the human only (`tmux select-pane -t <pane> -T NN-<slug>`); Claude Code overwrites its pane title within seconds, so nothing keys off it. Confirm with `tmux list-panes -t "$win" -F '#{pane_id} #{pane_dead} #{pane_current_path}'`: N panes, right worktrees, `pane_dead` 0. Report the issue → pane → worktree → branch mapping to the user, with `prefix + z` to zoom a pane.
6. **Record.** Rows → `inflight` with branch, worktree, pane. `plan.md` is the safety net if the head dies mid-batch; `--adjust` rebuilds from it.
7. **Supervise.** Empty `$FAN/reports` first. Then one persistent `Monitor`: a line per report and per pane that dies silent, keyed off `pane_id`:

   ```bash
   cd "$FAN/reports"; panes="12:%12 15:%13 18:%14"
   while true; do
     for f in *.done *.shipped; do [ -e "$f" ] || continue; mv "$f" "$f.seen"; echo "REPORT ${f%.*} ${f##*.}"; done
     if live=$(tmux list-panes -t "$win" -F '#{pane_id} #{pane_dead}' 2>/dev/null); then
       for tp in $panes; do t=${tp%%:*}; id=${tp#*:}
         [ -e "$t.shipped.seen" ] || [ -e "$t.gone" ] && continue
         case "$live" in *"$id 0"*) continue ;; esac
         touch "$t.gone"; echo "PANE GONE $t"; done
     fi
     [ "$(ls *.shipped.seen *.gone 2>/dev/null | wc -l)" -ge N ] && { echo "BATCH COMPLETE"; break; }
     sleep 20
   done
   ```

   A tmux failure skips the liveness sweep rather than reading as N dead workers. Stay resident until `BATCH COMPLETE`; each event re-invokes the head.

### On each report

1. `head -2 "$FAN/reports/NN.md"`. `blocked` → read the whole report, then rework, re-scope, or take the row back. A `shipped` marker → step 6. `green` with exit 0 → continue.
2. **Scope.** `git -C <wt> diff --name-only origin/HEAD...HEAD` against `owns`. A file outside is rework even when correct: it voids the disjointness the batch was sized on.
3. **Verify.** Re-run the brief's verify command in the worktree; trust its output over the report.
4. **Review.** Delegate to an `Agent()` (`model: "sonnet"`) pointed at the worktree, so the diff lands in the reviewer's context and not the head's. Scope, in order: correctness, a concrete failure per finding; security, data integrity, reliability; the repo's rules and the docs whose trigger matches the diff; the surrounding code's patterns; tests that assert outcomes, with no stub that neuters the path under test; whether the diff clears each CI job, judged by reading the workflows, never by running them; docs that state a changed limit or flag. Output: `path:line - blocker|major|minor - defect` with `Evidence:` and `Effect:` lines, then `VERDICT: PASS|FAIL`. A missing verdict reads as FAIL. Cap 25 tool calls.
5. **Voice.** `git -C <wt> log --format=%s origin/HEAD..HEAD` against the Voice block and the never-list. Off → rework now; a local reword is cheap, and after a push it needs the human's force-push.
6. Rework: log it, then one line via `tmux send-keys -t <pane> '<what and why>' Enter`. Pass: send `ship`. On `shipped`: `gh pr view <n> --json title,body` against Voice, `gh pr edit` (approval-gated) if off, row → `shipped`. Landing is the lead's; the row turns `landed` at the next `--adjust`.

## Inline - `/fan NN`

One issue, no worktree. Brief it (Fan out 2), claim it (3), `git switch -c <branch>` here (approval-gated), implement against the brief yourself, self-review with On each report 2-5, then offer the push and the PR in Voice. Row → `shipped`.

## `--adjust`

No `plan.md` in `$FAN` → adopt a lane: `head -1 "$LANES"/*/plan.md`, ask which (one whose head still runs is not a candidate), then `FAN=$LANES/<id>`. A `newchat` prompt that names the lane path skips the question.

1. **Reconcile.** Per `inflight`/`review`/`shipped` row: `gh pr list --head <branch> --state all --json state,number`. `MERGED` → `landed`; `CLOSED` unmerged → ask. A `landed` row's worktree and local branch go, approval-gated: `git worktree remove ../<wt>`, `git branch -d <branch>`. Remote branches are the lead's or the repo's auto-delete, never yours.
2. **Replan.** Reorder, resize, add, drop, split. A new row is a new issue in Voice (approval-gated). A dropped row's issue closes only if it is yours and untouched, with a one-line reason in Voice; otherwise it stays open.
3. Log the change. Route next.

## Close

Every row `landed` or `dropped`: move `plan.md` to `plan-<date>.md`. No GitHub action; the issues closed with their PRs. Invoke `newchat` with the next goal if one is known.

## Decision point

After a batch completes, after an inline issue ships, and at close: route via `~/.claude/skills/shared/next-command.md` and emit exactly one `Next:` block.

## Context budget

15% of the context window is the nudge, 20% the ceiling. At the nudge, finish the current step, make sure `plan.md` says what is in flight, and invoke `newchat`. The plan holds the resume point, so the prompt carries the task line, `$FAN` for the next head to adopt, and what the plan cannot state.

## When not to use

- The repo's rules keep agents off `gh` entirely → `/ftl`, where the human runs every issue and PR command.
- One PR of work, no plan worth keeping → `/slice`.
- No `gh` auth for this remote → fix auth first, or `/slice`.
