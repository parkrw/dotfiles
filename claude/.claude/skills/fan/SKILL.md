---
name: fan
description: Fan tasks out to concurrent Claude sessions, one task per git worktree, one tmux pane per worker, batched by disjoint write scopes. Tasks are tasklog (cklog) rows by default; GitHub issues only after the user says yes. Built for shared repos - the plan, briefs, and reports live outside the repo, and GitHub sees only ordinary branches and PRs (and issues, when approved) in the repo's own measured conventions. e.g. /fan "goal" (plan, write tasklog rows, first batch), /fan --plan <slug> (fan a tasklog plan), /fan (fan out the ready batch; adopts the repo's open tasklog plan when this lane has none), /fan NN (one task inline), /fan NN MM (exactly these, in worktrees), /fan --adjust (reconcile and replan), /fan --help.
---

## Help

If `$ARGUMENTS` is exactly `--help`, `help`, or `-h`, print the block below verbatim and **stop - do not execute the skill**.

```
/fan - fan tasks out to worktrees, in the repo's own voice

  Plans in tasklog (cklog) and a private state dir - GitHub issues only
  after you say yes - writes PRs the way the repo's lead does, and runs
  one Claude session per task in a sibling worktree:
  one tmux window per batch, one pane per worker, in this tmux session.
  Nothing on GitHub or in the repo tree marks the work as tool-driven.
  State is one lane per head, so two sessions can fan the same repo at once.

  /fan "goal"          plan: decompose, write tasklog rows, run the first batch
  /fan --plan <slug>   adopt a tasklog plan's open rows as the table, then fan
  /fan                 fan out the ready batch (disjoint write scopes, cap 4);
                       with no lane yet, adopts the repo's open tasklog plan
  /fan NN              one task (row code), inline in this checkout - no worktree
  /fan NN MM [..]      exactly these tasks, one worktree each (cap 5)
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

Concurrent task-driven work in a repo other people read. The head (this session) plans, writes tasklog rows, cuts worktrees, spawns one worker per task, reviews each worker's diff before it is pushed, and reconciles. Workers implement.

Two invariants hold in every mode:

- **Nothing private touches the repo or GitHub.** The plan, briefs, and reports live in `$FAN` (below). The repo tree gets only the change itself - no `TODO/`, `HANDOFF.md`, reports, or markers. Worktrees are siblings of the checkout, never inside it.
- **Tasks live in tasklog, not GitHub issues.** `tasklog` (`cklog` in CloudKey repos) is the task store by default. GitHub issues - creating, reading, searching, linking - are used only after the user says yes to one question, `Use GitHub issues for <repo>'s tasks in this lane?`, recorded on Refs' `issues:` line (§ Issues).
- **Everything public is in the repo's voice.** Issue titles and bodies, labels, branch names, commit subjects, PR titles and bodies follow what is measured from the lead's own work (§ Voice), not this skill's vocabulary. A reader of the repo sees a teammate at work.

All repo rules and the user's git gates apply. This skill sequences them and never relaxes them. `$SP` below is this session's scratchpad directory.

## State

```bash
repo=$(gh repo view --json nameWithOwner -q .nameWithOwner)   # owner/name
LANES=~/.local/state/claude/fan/${repo/\//-}                   # one lane per head
FAN=$LANES/${FAN_LANE:-${CLAUDE_CODE_SESSION_ID:?}}; mkdir -p "$FAN"/{briefs,reports}
others() {   # live rows this lane does not run, any plan, any session: plan, code, issue, owns, state
  mine=$(awk -F'|' 'NR > 2 && $2 ~ /[^ ]/ { gsub(/ /, "", $2); print $2 }' <(sed -n '/^| code |/,/^$/p' "$FAN/plan.md" 2>/dev/null))
  tasklog show --json | jq -r --arg me "$PLAN" --arg mine "$mine" \
    '.[] | .code as $c | select(.state == "building" or .state == "review")
         | select(.plan != $me or ($mine | split("\n") | index($c)) == null)
         | "\(.plan) | \(.code) | #\(.issue // "-") | \(.owns // "?") | \(.state)"'
}
```

`$PLAN` is Refs' `tasklog` plan; `mine` is the codes in `plan.md`'s table. In a repo no log owns (`tasklog` exits 2, Refs `tasklog: none`), `others` greps the other lanes' `plan.md` tables for `inflight`, `review` and `shipped` rows instead.

Two heads on one repo share nothing in `$LANES`: neither renames the other's markers or completes a batch on the other's rows. They do share the tree, so a pick is checked against `others` (Fan out 1) the same way it is checked against its own batch, and `others` is printed with every guard and pick. A lane outlives its session: `--adjust` adopts one, and the `newchat` prompt at the context ceiling carries `$FAN` so the next head adopts this one.

| File | Holds |
| --- | --- |
| `tasklog` plan `$PLAN` | the task table: one row per task, with its state, issue, est, owns, deps, model, effort, branch, worktree, PR |
| `$FAN/plan.md` | goal, Voice block, Refs, each row's slug and pane, an append-only log |
| `$FAN/briefs/NN.md` | the worker's full brief for row `NN` - everything an issue body, when there is one, must not say |
| `$FAN/reports/NN.md` + markers | the worker's report; `NN.done` means "reported", `NN.shipped` means "PR open" |

`plan.md`:

```markdown
# owner/repo - <goal>

## Voice
<the measured lines, § Voice>

## Refs
install: <cmd>  test: <cmd>  lint/build: <cmd>  merge style: squash|merge|rebase
tasklog: <plan>|none
issues: no|yes

| code | issue | slug | pane |
|---|---|---|---|
| T1 | - | token-refresh | |

## Log
- 2026-09-12 seeded from "<goal>"
```

The task table lives in `tasklog` by default; `plan.md` holds only what tasklog has no column for. Read it with `tasklog show $PLAN --all --json`, and write every change to a row with `tasklog state $PLAN <code> <state> [flags]`, so a dead head, another lane, `/ftl` and `/newchat` all see the same rows. `code` is the row's code: `T1`, `T2`, … in a plan fan made (the issue number instead when `issues: yes`), the plan's own code (`L4`, `P5`) in one it adopted. `NN` below is that code. `est` is `--est S|M|L` (`~S` ≤100 lines, `~M` 100-300, `~L` 300+); `owns`, the write scope, is `--owns '<globs>'`: the globs the worker may touch, and a file outside them is a rework trigger even when the code is right; `deps` is `--deps '<codes>'`; globs and codes are space-separated. Write a row's sizing the moment it is sized: `tasklog state $PLAN <code> planned --est S --owns '<globs>' [--deps '<codes>'] [--issue N]`, `--issue` only when `issues: yes`, the row's current state in place of `planned` once it has one. `tasklog state` prints `not fan-ready` for an open row missing est or owns: size it before it can batch. It also sets the row's `model` and `effort` from `est` (§ Model tiers).

Every row also gets a row brief, written before the `state` that sizes it, since that `state` prints `no brief` for a `planned` row without one: `tasklog event $PLAN <code> brief -`, text on stdin, so whichever session builds it (a worker, `/ftl`, a `/newchat` successor, another lane after the head dies) reads it in `tasklog brief $PLAN <code>`. Write it as `newchat`'s step 3 writes a prompt, for a zero-context reader, and only what a fresh read of the repo will not give: the goal and why in one line each; `file:line` anchors where the work starts, grep-verified; decisions settled in planning, stated as settled; traps (looks like X, is Y; an ordering, a guard, an exit code the change must keep); invariants nobody wrote down; the edge cases the change meets (empty, one, many, the boundary, the error path, records written before the change, every consumer of what it renames or removes), each with its expected outcome; the exact gate commands that define done, with the tests they need, by observable outcome. No Voice block, no restated issue, no "see plan.md". A replan that changes the task writes a new brief event; the latest one wins.

A row's status below is its tasklog state:

| status | tasklog state | written by |
| --- | --- | --- |
| `ready` | `planned` | head, when sized |
| `inflight`, `review` | `building` (`review` is only the head reviewing a report) | worker on start and rework; head with `--worktree` at Record |
| `blocked` | `blocked` | worker |
| `shipped` (PR open) | `review` with `--pr` | worker on `ship` |
| `landed` (PR merged) | `merged` | head at `--adjust` |
| `dropped` | `dropped` | head |

With `tasklog: none`, `plan.md` carries the whole table instead, `| code | issue | slug | est | owns | deps | status | branch | worktree | pane |`, and the status words are written there.

## Issues

`issues: no` is the default, and a missing `issues:` line reads as `no`. Under it: no `gh issue` command of any kind, no issue in a brief, branch, commit or PR body, and the PR stands alone with its body in Voice. Rows are tasklog rows, nothing more.

Ask before the first use, once per lane, as one yes/no question: `Use GitHub issues for <repo>'s tasks in this lane?` Ask only when issues would come into play: the user names issue numbers or asks for issues, an adopted plan's rows already carry `issue`, or the rules file requires an issue per PR. Never ask otherwise; plan in tasklog. Write the answer to Refs' `issues:` line and do not ask again in this lane. `yes` turns on every step marked *(issues: yes)* below; `no` skips them.

## Model tiers

| Role | Runs as | Model |
| --- | --- | --- |
| Head | this session | session model |
| Worker | `claude` CLI in a tmux pane | The row's `model` and `effort` from tasklog, which `tasklog state` sets from `est`: `S` opus at high; `M`, `L` and unsized opus at xhigh; never below opus at high. A user-set `--model`/`--effort` on the row wins. With `tasklog: none`: this session's exact model and effort, Opus when this session runs Fable. Never `max`. |
| Reviewer, lookups | `Agent()` | `model: "sonnet"` |

Hard cap, all modes: never more than 6 agents and workers live at once, and every worker seed carries the cap. The reviewer runs one at a time and takes one slot, so a batch is at most 5 workers.

## Voice - measure once per repo

Read-only. Record the result as the `## Voice` block. Re-measure when the block is missing or the lead has 20+ commits newer than it.

| Measure | Command | Record |
| --- | --- | --- |
| rules | `AGENTS.md`, `CLAUDE.md`, `CONTRIBUTING.md`, `.github/ISSUE_TEMPLATE/*`, `.github/pull_request_template.md` | the template to fill; anything the rules say about issues, branches, PRs |
| lead | `git shortlog -sn --no-merges \| head -3` | the login to measure |
| issues *(issues: yes)* | `gh issue list --author <lead> --state all --limit 20 --json title,body,labels,assignees` | title case and length; body shape (paragraph, headings, checklist); labels in use; whether any body holds `- [ ] #N` (then a tracking issue is in voice; otherwise never) |
| labels | `gh label list` | the set; a label the lead does not put on similar issues is not used |
| PRs | `gh pr list --author <lead> --state merged --limit 20 --json title,body,headRefName,mergeCommit` | title shape; body shape; how the issue is linked (`closes #N`, `fixes #N`, `#N` in the title, none); branch naming; squash or merge |
| commits | `git log --author=<lead> --no-merges --format='%s%n%b%n---' -30` | subject case, length, prefix; body prose or bullets; issue reference form |
| done | the rules file's commands, plus every command a pull-request job in `.github/workflows/*.yml` runs - read the files, since one `run: \|` block holds several - minus deploys and publishes; with neither, `Makefile` / `package.json` scripts | the install, test, and lint commands for Refs |

Everything the skill writes publicly is checked against this block before the command is shown. Words that never appear in public text: the names of this skill, its files, its sections, and its roles - `fan`, `batch`, `worker`, `supervisor`, `brief`, `owns`, `sub-task`, `verify`, `done when`, `tracker`. No `Co-authored-by`, no `Claude-Session`, no generated-by line. Workers inherit all of this through the seed.

## Never

- Run any `gh issue` command while Refs says `issues: no` or has no `issues:` line. Ask first (§ Issues).
- Create a label, pin an issue, add a milestone the repo does not have, or assign anyone, yourself included. Several self-assignments in one minute is the tell a PR is not. When the gate asks about an unassigned issue at worktree creation, approve.
- Comment on an issue or PR for progress, status, or reports. The only comment is the one a teammate would leave: a one-line reason when closing an issue without a PR.
- Close an issue that has a PR. The PR closes it, in the measured form, when the lead merges. Never `gh pr merge`.
- Put `Owns`, `Deps`, `Tracker`, `Branch`, `Verify`, or `Done when` lines in an issue body. They live in the brief.
- Push before the head has reviewed. A PR appears once, finished.
- Spell the default branch's name in a git or gh command. Use `origin/HEAD` and defaults. If `origin/HEAD` is unset, `git remote set-head origin -a` first.

## Plan - `/fan "goal"`

Guard: a `$FAN/plan.md` whose plan has any row not `landed`/`dropped` → stop and ask: `--adjust`, or start over (the old plan moves to `plan-<date>.md`). Print `others`; another head's live rows inform the split, they do not block it.

1. Read the rules file; light scan of the tree. Measure Voice if the block is missing.
2. Decompose into tasks with `est` and `owns`. Seek seams: prefer tasks that own disjoint directories, even at the cost of one more task, because disjointness is what makes a batch safe. Stop when the split stops being real: a task carved out for parallelism that then needs a shared signature, one migration, or another task's output is worse than one sequential task. Overlapping globs are legal; they serialize. A file every row must touch (a registry, an index) is shared by design: it stays in every `owns`, each worker adds only its own line, and the head expects every PR merged after the first to need a rebase the human runs. A changelog entry is the task's own `changelog.d/` fragment, never a shared `CHANGELOG.md` line.
3. *(issues: yes)* Reuse before creating: `gh issue list --state open --search "<nouns>"`. A task that already has an issue takes that number. A duplicate of a teammate's issue is both noise and a tell.
4. Checkpoint: show the table, one OK.
5. *(issues: yes)* Create the missing issues, one command each, each approval-gated. Title and body in Voice, the template filled if there is one, labels from the measured set only.

   ```bash
   gh issue create --title "<title in voice>" --body-file "$SP/issue-NN.md" [--label <measured>]
   ```

6. `tasklog plan add fan-<lane> --path $FAN/plan.md --title "<goal>"` unless `tasklog plan list` already lists `fan-<lane>`, a lane's earlier goal, which this one reuses; `<lane>` is `${FAN##*/}`, whole, so no two lanes share a plan. Write each row into it, sized and briefed (§ State), code `T1`, `T2`, … (the issue number when `issues: yes`). Then `plan.md`, with `fan-<lane>` on Refs' `tasklog` line and the `issues:` line. `tasklog` exits 2 when no log owns this repo's origin: write `none` and the full table into `plan.md`. Fall through to Fan out.

## Adopt - `/fan --plan <slug>`, or `/fan` with no `$FAN/plan.md`

A plan another session wrote into `tasklog` (`/ftl`, a plan file, a seed) becomes this lane's plan, in place: its rows stay where they are and the lane works them. Same guard as Plan.

0. `/fan` with no `$FAN/plan.md`: `tasklog plan list`, and take the plans whose `open` is above 0 and that no other lane's `plan.md` names on its `tasklog` line. One → adopt it. Several → ask which, one question. None → stop: `/fan "goal"` plans new work. `tasklog` exits 2 → stop the same way.
1. `tasklog show <slug> --json`; no row → stop and say so. Measure Voice if the block is missing.
2. `planned` rows are this lane's `ready` work. Rows in `building` or `review` are another session's work in flight: list them and leave them to it; `others` already carries them. `blocked` rows stay out until the user says the block is cleared, then the head writes them back to `planned`. A dep is satisfied when its row is `merged` or `dropped`.
3. A `planned` row missing `est` or `owns`: size it from `tasklog brief <slug> <code>`, the plan file it names, and the code, then write the sizing back (§ State), and a row brief when `tasklog brief` prints `None recorded.` under it. *(issues: yes)* A row missing `issue`: Plan steps 3 and 5 for it — reuse or create the issue in Voice, approval-gated — then write `--issue` back. Rows that already carry `issue` are the cue to ask (§ Issues); `no` leaves the numbers in tasklog untouched and unused.
4. Checkpoint: show the table (`tasklog show <slug>`), one OK. Write `plan.md` with Refs' `tasklog` line set to `<slug>` and the `issues:` line, so workers log to the rows that already exist. Fall through to Fan out.

## Fan out - `/fan`, `/fan NN MM [..]`

The head stays in this checkout and does not implement during a batch.

1. **Size.** No `$FAN/plan.md` → Adopt first. Refs with no `tasklog` line gets one first, as Plan step 6 writes it. An explicit argument that is no row's code: with `issues: no`, stop and say so, or ask (§ Issues) when the user is plainly naming issues; *(issues: yes)* it is an issue number and gets a row first: read the issue, set `est` and `owns` from it and the code, write the row (§ State), measure Voice if the block is missing. Ready rows: `tasklog show $PLAN --json` rows in `planned`, sized, every dep `merged`/`dropped`, or *(issues: yes)* its issue closed (`gh issue view N --json state -q .state`). Batch = ready rows with pairwise-disjoint `owns`; compare the globs, and containment is overlap (`src/api/**` contains `src/api/auth/**`, so those two serialize). `N = min(disjoint ready, 4)`, 2 when any row is `~L`. Explicit numbers override the pick up to 5, never the disjointness rule. Then across plans: a row whose `owns` overlaps a `building` row in `others`, or one whose `owns` is `?`, defers the same way, because that file is under another session's hands right now; a `review` row there is an open PR, so it is a rebase for whoever merges second, not a block, exactly as within a lane. One ready row → Inline below, not a batch. Report the pick (`Fanning 3: T1 T3 T5; deferred T2 (dep T1), T4 (owns overlaps T3), T6 (owns overlaps chat-parts L4)`) with `others` under it, one OK.
2. **Brief.** Write `$FAN/briefs/NN.md` per row, for a zero-context reader, starting from the row brief in `tasklog brief $PLAN NN`: goal; the `owns` globs; sub-tasks as behaviors, each with the test it proves, the files, and its edge cases - records written before the change (imported, legacy, missing the new field), what the change reads back on its next run, every consumer of what it renames or removes, and for UI both color schemes and RTL - each paired with a test the verify command runs, or a line saying why it cannot occur; exact verify commands; done-when; Refs' `tasklog` plan and the row's `code`; the row's issue number *(issues: yes)*, else none; the Voice block verbatim; grep-verified names, never assumed ones.
3. **Claim.** Branch `<code>-<slug>` (`<issue>-<slug>` when `issues: yes`) unless Voice measured another shape; lowercase the code if the lead's branches are lowercase. Per row: `git ls-remote --exit-code --heads origin <branch>` exits 2, `gh pr list --head <branch> --state open` is empty, and *(issues: yes)* `gh pr list --search <issue> --state open` is empty. The gate re-checks both at worktree creation; doing it here keeps the prompts in one pane.
4. **Worktrees.** `git pull --ff-only` in this checkout (allowed outright; it fetches everything, and the fast-forward applies only to the current branch). Then per row, approval-gated:

   ```bash
   git worktree add ../<repo>-<branch> -b <branch> origin/HEAD
   ```

   A fresh worktree has no dependencies. Run Refs' install command in each before spawning, or the worker's first act is diagnosing a test failure that is not its own.
5. **Spawn.** Requires `$TMUX`; if unset, stop and say so. One new window in the caller's tmux session per batch, one pane per worker, `claude` launched with no positional prompt and no `--allowedTools`:

   ```bash
   m="claude --model <row model> --effort <row effort>"   # per pane, from the row (§ Model tiers)
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

   The seed, with `<FAN>`, `NN`, `<row>` (the row's `code`), and `<branch>` substituted and joined into one line:

   > Read `<FAN>/briefs/NN.md`, and when it names an issue, `gh issue view` that number. Write only inside the brief's owns globs; a change needed outside them goes in the report, not the tree. Commit per sub-task, approval-gated, subjects in the brief's Voice. Do not push, open a PR, or touch the issue until told `ship`. When the brief names a `tasklog` plan other than `none`, log to it as code `<row>`: `tasklog state <plan> <row> building --branch <branch>` now, `tasklog event <plan> <row> report -` with the report's line 1 on stdin each time you report, plus `tasklog state <plan> <row> blocked` when it is blocked and `tasklog state <plan> <row> building` when rework starts, and `tasklog state <plan> <row> review --pr <number>` on `ship`; text goes on stdin, never as an argument. Never comment on, edit, label, or close an issue; never write anything into the repo tree but the change; no `Co-authored-by` or `Claude-Session` trailers, no generated-by line anywhere. Run the brief's verify command last and record its real exit code. Then write `<FAN>/reports/NN.md`: line 1 exactly `STATUS: green|blocked - <8 words or fewer>` (a non-zero exit is `blocked`, never green), line 2 exactly `VERIFY: <command> exit <code>`, then branch, commits, files touched, full verify output, surprises. Then `touch <FAN>/reports/NN.done` whatever the status: it means "I have reported", not "I succeeded", and withholding it on failure hangs the batch in silence. Rework arrives in this pane; address it, overwrite the report, touch `NN.done` again. On `ship`: push the branch `<branch>` to origin, open the PR with a title and body in the brief's Voice, linking the brief's issue the way Voice says when it names one and naming no issue otherwise, append the PR number to the report, and `touch <FAN>/reports/NN.shipped`. Context budget: wind down at 25%, hand off at 30%, never exceed 30%. Hard caps: never more than 6 subagents/workers total, never `--effort max`, do the implementation yourself.

   The seed names no git or gh write command literally. The gate reads the `printf` that writes the seed file, and a `git push` inside that text is denied before the file exists.

   Name panes for the human only (`tmux select-pane -t <pane> -T NN-<slug>`); Claude Code overwrites its pane title within seconds, so nothing keys off it. Confirm with `tmux list-panes -t "$win" -F '#{pane_id} #{pane_dead} #{pane_current_path}'`: N panes, right worktrees, `pane_dead` 0. Report the code → pane → worktree → branch mapping to the user, with `prefix + z` to zoom a pane.
6. **Record.** Per row, `tasklog state $PLAN <code> building --branch <branch> --worktree <abs worktree>`, and its pane in `plan.md`. Tasklog is the safety net if the head dies mid-batch; `--adjust` rebuilds from it.
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
4. **Review.** Delegate to an `Agent()` (`model: "sonnet"`) pointed at the worktree, so the diff lands in the reviewer's context and not the head's. Goal: approve the diff, but only if it is fit for release; search the whole scope as if a defect is there. Scope, in order: correctness; security, data integrity, reliability; the repo's rules and the docs whose trigger matches the diff, with naming and style a finding only when a written rule states them; tests that assert outcomes, not call shape, with no stub that neuters the path under test, no skipped test, and a bug-fix test that fails without the fix; whether the diff clears each CI job, judged by reading the workflows, never by running them; docs that state a changed limit or flag. Proof or drop it: a runtime defect carries a failing test case (exact input, expected vs actual, and a test the author runs; the reviewer writes it, never runs it), and any other defect quotes the diff line and what it breaks, each with `path:line`. Output: `path:line - blocker|major|minor - defect` with `Proof:` and `Effect:` lines, then `VERDICT: PASS|FAIL`; one proven finding of any severity is FAIL. A missing verdict reads as FAIL. Cap 25 tool calls.
5. **Voice.** `git -C <wt> log --format=%s origin/HEAD..HEAD` against the Voice block and the never-list. Off → rework now; a local reword is cheap, and after a push it needs the human's force-push.
6. Rework: log it, then one line via `tmux send-keys -t <pane> '<what and why>' Enter`. Pass: send `ship`. On `shipped`: `gh pr view <n> --json title,body` against Voice, `gh pr edit` (approval-gated) if off, row → `shipped`. Landing is the lead's; the row turns `landed` at the next `--adjust`.

## Inline - `/fan NN`

One task, no worktree. Brief it (Fan out 2), claim it (3), `git switch -c <branch>` here (approval-gated), implement against the brief yourself, logging to Refs' `tasklog` plan as the seed tells a worker to, self-review with On each report 2-5, then offer the push and the PR in Voice. Row → `shipped`.

## `--adjust`

No `plan.md` in `$FAN` → adopt a lane: `head -1 "$LANES"/*/plan.md`, ask which (one whose head still runs is not a candidate), then `FAN=$LANES/<id>`. A `newchat` prompt that names the lane path skips the question.

1. **Reconcile.** Per `building`/`review` row with a branch: `gh pr list --head <branch> --state all --json state,number`. `MERGED` → `tasklog state $PLAN <code> merged --pr <n>`; `CLOSED` unmerged → ask. A `landed` row's worktree and local branch go, approval-gated: `git worktree remove ../<wt>`, `git branch -d <branch>`. Remote branches are the lead's or the repo's auto-delete, never yours.
2. **Replan.** Reorder, resize, add, drop, split. A new row is a new tasklog row, sized and briefed; a changed row gets a new row brief; *(issues: yes)* also a new issue in Voice (approval-gated). *(issues: yes)* A dropped row's issue closes only if it is yours and untouched, with a one-line reason in Voice; otherwise it stays open.
3. Log the change. Route next.

## Close

Every row `merged` or `dropped` (`tasklog show $PLAN` prints none): move `plan.md` to `plan-<date>.md`. No GitHub action; with `issues: yes`, the issues closed with their PRs. Invoke `newchat` with the next goal if one is known.

## Decision point

After a batch completes, after an inline task ships, and at close: route via `~/.claude/skills/shared/next-command.md` and emit exactly one `Next:` block.

## Context budget

At 25% of the context window, wind down: finish the current step and make sure `plan.md` says what is in flight. At 30%, the ceiling, invoke `newchat`. The plan holds the resume point, so the prompt carries the task line, `$FAN` for the next head to adopt, and what the plan cannot state.

## When not to use

- The repo's rules keep agents off `gh` entirely → `/ftl`, where the human runs every issue and PR command.
- One PR of work, no plan worth keeping → `/slice`.
- No `gh` auth for this remote → fix auth first, or `/slice`.
