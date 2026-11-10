---
name: fan
description: Fan tasks out to concurrent Claude sessions, one task per git worktree, one tmux pane per worker, batched by disjoint write scopes. Tasks are tasklog (cklog) rows, each with its section in the plan file and a brief; GitHub issues only after the user says yes. Built for shared repos - the plan file and the rows live outside the repo, and GitHub sees only ordinary branches and PRs (and issues, when approved) in the repo's own measured conventions. Works the list to the end: each worker is one /ftl --row <plan> <code> --ship, to a green PR, and the head watches open PRs with pr-wait, re-ships stale ones, and fans the next batch as merges unblock it. e.g. /fan "goal" (plan, write tasklog rows, first batch), /fan --plan <slug> (fan a tasklog plan), /fan (fan out the ready batch; adopts the repo's open tasklog plan when this lane has none), /fan NN (one task inline), /fan NN MM (exactly these, in worktrees), /fan --adjust (reconcile and replan), /fan --help.
---

## Help

If `$ARGUMENTS` is exactly `--help`, `help`, or `-h`, print the block below verbatim and **stop - do not execute the skill**.

```
/fan - fan tasks out to worktrees, in the repo's own voice

  Plans in tasklog (cklog), every row with its plan-file section and a
  brief - GitHub issues only after you say yes - and runs one Claude
  session per task in a sibling worktree, started with one line,
  /ftl --row <plan> <code> --ship:
  one tmux window per batch, one pane per worker, in this tmux session.
  Nothing on GitHub or in the repo tree marks the work as tool-driven.
  State is one lane per head, so two sessions can fan the same repo at once.
  Works the list to the end: workers ship with ftl (review loop, PR,
  CI green), the head watches open PRs with pr-wait, re-ships stale ones,
  queues merge commands for you, and fans the next batch as merges land.

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

Concurrent task-driven work in a repo other people read. The head (this session) plans, writes tasklog rows, cuts worktrees, starts one worker per task as `/ftl --row <plan> <code> --ship`, checks each PR it opens, and reconciles. Workers implement and ship.

Two invariants hold in every mode:

- **Nothing private touches the repo or GitHub.** The plan file lives in `$FAN` (below); rows, briefs and reports live in tasklog. The repo tree gets only the change itself - no `TODO/`, `HANDOFF.md`, reports, or markers. Worktrees are siblings of the checkout, never inside it.
- **Every task is a planned tasklog row.** `tasklog` (`cklog` in CloudKey repos) is the task store, in every plan, and every row has its section in the plan's file (`ref`) and a row brief; `tasklog state` refuses a row without them. A repo no log owns (`tasklog` exits 2) is not fanned. A row that lacks one is never filled in after the fact: it stays out of every batch. GitHub issues - creating, reading, searching, linking - are used only after the user says yes to one question, `Use GitHub issues for <repo>'s tasks in this lane?`, recorded on Refs' `issues:` line (§ Issues).
- **Everything public is in the repo's voice.** Issue titles and bodies, labels, branch names, commit subjects, PR titles and bodies follow what is measured from the lead's own work (§ Voice), not this skill's vocabulary. A reader of the repo sees a teammate at work.

All repo rules and the user's git gates apply. This skill sequences them and never relaxes them. `$SP` below is this session's scratchpad directory.

## State

```bash
repo=$(gh repo view --json nameWithOwner -q .nameWithOwner)   # owner/name
LANES=~/.local/state/claude/fan/${repo/\//-}                   # one lane per head
FAN=$LANES/${FAN_LANE:-${CLAUDE_CODE_SESSION_ID:?}}; mkdir -p "$FAN"
others() {   # live rows this lane does not run, any plan, any session: plan, code, issue, owns, state
  mine=$(awk -F'|' 'NR > 2 && $2 ~ /[^ ]/ { gsub(/ /, "", $2); print $2 }' <(sed -n '/^| code |/,/^$/p' "$FAN/plan.md" 2>/dev/null))
  tasklog show --json | jq -r --arg me "$PLAN" --arg mine "$mine" \
    '.[] | .code as $c | select(.state == "building" or .state == "review")
         | select(.plan != $me or ($mine | split("\n") | index($c)) == null)
         | "\(.plan) | \(.code) | #\(.issue // "-") | \(.owns // "?") | \(.state)"'
}
```

`$PLAN` is Refs' `tasklog` plan; `mine` is the codes in `plan.md`'s table.

Two heads on one repo share nothing in `$LANES`: neither renames the other's markers or completes a batch on the other's rows. They do share the tree, so a pick is checked against `others` (Fan out 1) the same way it is checked against its own batch, and `others` is printed with every guard and pick. A lane outlives its session: `--adjust` adopts one, and the `newchat` prompt at the context ceiling carries `$FAN` so the next head adopts this one.

| File | Holds |
| --- | --- |
| `tasklog` plan `$PLAN` | the task table: one row per task, with its state, issue, est, owns, deps, model, effort, branch, worktree, PR |
| `$FAN/plan.md` | goal, Voice block, Refs, a `### <code> <slug>` section per row (the rows' `ref`), each row's slug and pane, an append-only log; the plan file of a plan fan made |
| `tasklog event`s on the row | its brief, its worker's `blocked` stops and `handoff`s (PR URL and verdict), progress at a context ceiling |

`plan.md`:

```markdown
# owner/repo - <goal>

## Voice
<the measured lines, § Voice>

## Refs
install: <cmd>  test: <cmd>  lint/build: <cmd>  merge style: squash|merge|rebase
tasklog: <plan>
issues: no|yes

| code | issue | slug | pane |
|---|---|---|---|
| T1 | - | token-refresh | |

## Log
- 2026-09-12 seeded from "<goal>"
```

The task table lives in `tasklog`; `plan.md` holds only what tasklog has no column for. Read it with `tasklog show $PLAN --all --json`, and write every change to a row with `tasklog state $PLAN <code> <state> [flags]`, so a dead head, another lane, `/ftl` and `/newchat` all see the same rows. `code` is the row's code: `T1`, `T2`, … in a plan fan made (the issue number instead when `issues: yes`), the plan's own code (`L4`, `P5`) in one it adopted. `NN` below is that code. `est` is `--est S|M|L` (`~S` ≤100 lines, `~M` 100-300, `~L` 300+); `owns`, the write scope, is `--owns '<globs>'`: the globs the worker may touch, and a file outside them is a rework trigger even when the code is right; `deps` is `--deps '<codes>'`; globs and codes are space-separated; `ref` is `--ref '<heading>'`, text matching exactly one heading of the plan file, the row's section there. Write a row's sizing the moment it is sized: `tasklog state $PLAN <code> planned --ref '<heading>' --est S --owns '<globs>' [--deps '<codes>'] [--issue N]`, `--issue` only when `issues: yes`, the row's current state in place of `planned` once it has one. `tasklog state` refuses (exit 1) to create a row, or move one to an open state, while its plan has no file, the row has no `ref` or one that no longer matches exactly one heading, or it has no row brief; `tasklog gaps $PLAN` lists every row that lacks one. `tasklog state` prints `not fan-ready` for an open row missing est or owns: size it before it can batch. It also sets the row's `model` and `effort` from `est` (§ Model tiers).

Every row also gets a row brief, written before the `state` that creates it, which refuses a row without one: `tasklog event $PLAN <code> brief -`, text on stdin, so whichever session builds it (a worker, `/ftl`, a `/newchat` successor, another lane after the head dies) reads it in `tasklog brief $PLAN <code>`. With the row's plan section, it is all a worker gets: `/ftl --row` prints both, and nothing else is pasted or written for it. Write it as `newchat`'s step 3 writes a prompt, for a zero-context reader, and only what a fresh read of the repo will not give: the goal and why in one line each; `file:line` anchors where the work starts, grep-verified; decisions settled in planning, stated as settled; traps (looks like X, is Y; an ordering, a guard, an exit code the change must keep); invariants nobody wrote down; sub-tasks as behaviors, each with the test that proves it; the edge cases the change meets (empty, one, many, the boundary, the error path, records written before the change - imported, legacy, missing the new field - what the change reads back on its next run, every consumer of what it renames or removes, and for UI both color schemes and RTL), each with its expected outcome or a line saying why it cannot occur; the exact gate commands that define done, with the tests they need, by observable outcome. No Voice block, no restated issue, no "see plan.md". A replan that changes the task writes a new brief event; the latest one wins.

A row's status below is its tasklog state:

| status | tasklog state | written by |
| --- | --- | --- |
| `ready` | `planned` | head, when sized |
| `inflight` | `building` | head with `--worktree` at Record; worker's `ftl` on start and when it resumes |
| `blocked` | `blocked`, with a `blocked` event saying why | worker's `ftl`, at every stop |
| `shipped` (PR open) | `review` with `--pr`, `ready` once CI is green, with a `handoff` event | worker's `ftl` Ship |
| `landed` (PR merged) | `merged` | head at `--adjust` |
| `dropped` | `dropped` | head |

## Issues

`issues: no` is the default, and a missing `issues:` line reads as `no`. Under it: no `gh issue` command of any kind, no issue in a brief, branch, commit or PR body, and the PR stands alone with its body in Voice. Rows are tasklog rows, nothing more.

Ask before the first use, once per lane, as one yes/no question: `Use GitHub issues for <repo>'s tasks in this lane?` Ask only when issues would come into play: the user names issue numbers or asks for issues, an adopted plan's rows already carry `issue`, or the rules file requires an issue per PR. Never ask otherwise; plan in tasklog. Write the answer to Refs' `issues:` line and do not ask again in this lane. `yes` turns on every step marked *(issues: yes)* below; `no` skips them.

## Model tiers

| Role | Runs as | Model |
| --- | --- | --- |
| Head | this session | session model |
| Worker | `claude` CLI in a tmux pane | The row's `model` and `effort` from tasklog, which `tasklog state` sets from `est`: `S` opus at high; `M`, `L` and unsized opus at xhigh; never below opus at high. A user-set `--model`/`--effort` on the row wins. Never `max`. |
| Lookups | `Agent()` | `model: "sonnet"` |

Hard cap, all modes: never more than 6 agents and workers live at once. The head keeps one slot for its lookups, so a batch is at most 5 workers.

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

Everything the skill writes publicly is checked against this block before the command is shown. Words that never appear in public text: the names of this skill, its files, its sections, and its roles - `fan`, `batch`, `worker`, `supervisor`, `brief`, `owns`, `sub-task`, `verify`, `done when`, `tracker`. No `Co-authored-by`, no `Claude-Session`, no generated-by line. Workers' `ftl` measures the same lead and keeps the same rules; the head checks each PR against this block (On each event 3).

## Never

- Run any `gh issue` command while Refs says `issues: no` or has no `issues:` line. Ask first (§ Issues).
- Create a label, pin an issue, add a milestone the repo does not have, or assign anyone, yourself included. Several self-assignments in one minute is the tell a PR is not. When the gate asks about an unassigned issue at worktree creation, approve.
- Comment on an issue or PR for progress, status, or reports. The only comment is the one a teammate would leave: a one-line reason when closing an issue without a PR.
- Close an issue that has a PR. The PR closes it, in the measured form, when the lead merges. Never `gh pr merge`.
- Put `Owns`, `Deps`, `Tracker`, `Branch`, `Verify`, or `Done when` lines in an issue body. They live in the brief.
- Paste a seed or a brief into a worker's pane. A worker starts from one line, `/ftl --row $PLAN <code> --ship`; what it needs is on the row.
- Write a missing plan file, `ref` or brief for a row that already exists. `tasklog gaps` lists it; it stays out of every batch.
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

6. Write `plan.md` first, with `fan-<lane>` on Refs' `tasklog` line, the `issues:` line, and a `## Tasks` section holding one `### <code> <slug>` heading per row, its goal and why in a line each under it: each row's `ref` is its `<code> <slug>`. Then `tasklog plan add fan-<lane> --path $FAN/plan.md --title "<goal>"` unless `tasklog plan list` already lists `fan-<lane>`, a lane's earlier goal, which this one reuses; `<lane>` is `${FAN##*/}`, whole, so no two lanes share a plan. Write each row into it, briefed, then sized with its `--ref` (§ State), code `T1`, `T2`, … (the issue number when `issues: yes`). `tasklog` exits 2 when no log owns this repo's origin: stop and say so; fan runs only on tasklog rows. Fall through to Fan out.

## Adopt - `/fan --plan <slug>`, or `/fan` with no `$FAN/plan.md`

A plan another session wrote into `tasklog` (`/ftl`, a plan file, a seed) becomes this lane's plan, in place: its rows stay where they are and the lane works them. Same guard as Plan.

0. `/fan` with no `$FAN/plan.md`: `tasklog plan list`, and take the plans whose `open` is above 0 and that no other lane's `plan.md` names on its `tasklog` line. One → adopt it. Several → ask which, one question. None → stop: `/fan "goal"` plans new work. `tasklog` exits 2 → stop the same way.
1. `tasklog show <slug> --json`; no row → stop and say so. Measure Voice if the block is missing.
2. `planned` rows are this lane's `ready` work. Rows in `building` or `review` are another session's work in flight: list them and leave them to it; `others` already carries them. `blocked` rows stay out until the user says the block is cleared, then the head writes them back to `planned`. A dep is satisfied when its row is `merged` or `dropped`.
3. `tasklog gaps <slug>`. A row it lists as missing the plan file, `ref` or `brief` is out: list it with what it lacks and leave it; nothing here writes them for a row that exists, and `tasklog state` refuses to move it to `building`. No row left → stop and say so. A row missing only `est` or `owns`: size it from `tasklog brief <slug> <code>` and the code. Write them back (§ State). *(issues: yes)* A row missing `issue`: Plan steps 3 and 5 for it — reuse or create the issue in Voice, approval-gated — then write `--issue` back. Rows that already carry `issue` are the cue to ask (§ Issues); `no` leaves the numbers in tasklog untouched and unused.
4. Checkpoint: show the table (`tasklog show <slug>`), one OK. Write `plan.md` with Refs' `tasklog` line set to `<slug>` and the `issues:` line, so workers log to the rows that already exist. Fall through to Fan out.

## Fan out - `/fan`, `/fan NN MM [..]`

The head stays in this checkout and does not implement during a batch.

1. **Size.** No `$FAN/plan.md` → Adopt first. Refs with no `tasklog` line gets one first, as Plan step 6 writes it. An explicit argument that is no row's code: with `issues: no`, stop and say so, or ask (§ Issues) when the user is plainly naming issues; *(issues: yes)* it is an issue number and gets a row first: read the issue, set `est` and `owns` from it and the code, write the row (§ State), measure Voice if the block is missing. Ready rows: `tasklog show $PLAN --json` rows in `planned`, sized, not listed by `tasklog gaps $PLAN`, every dep `merged`/`dropped`, or *(issues: yes)* its issue closed (`gh issue view N --json state -q .state`). Batch = ready rows with pairwise-disjoint `owns`; compare the globs, and containment is overlap (`src/api/**` contains `src/api/auth/**`, so those two serialize). `N = min(disjoint ready, 4)`, 2 when any row is `~L`. Explicit numbers override the pick up to 5, never the disjointness rule. Then across plans: a row whose `owns` overlaps a `building` row in `others`, or one whose `owns` is `?`, defers the same way, because that file is under another session's hands right now; a `review` row there is an open PR, so it is a rebase for whoever merges second, not a block, exactly as within a lane. One ready row → Inline below, not a batch. Report the pick (`Fanning 3: T1 T3 T5; deferred T2 (dep T1), T4 (owns overlaps T3), T6 (owns overlaps chat-parts L4)`) with `others` under it, one OK.
2. **Brief.** `tasklog brief $PLAN NN` per row: it is the worker's whole hand-off. A brief that would leave a zero-context reader guessing - no done-when, an unverified name, an edge case with no outcome - gets a new brief event now (§ State); the latest wins.
3. **Claim.** Branch `<code>-<slug>` (`<issue>-<slug>` when `issues: yes`) unless Voice measured another shape; lowercase the code if the lead's branches are lowercase. Per row: `git ls-remote --exit-code --heads origin <branch>` exits 2, `gh pr list --head <branch> --state open` is empty, and *(issues: yes)* `gh pr list --search <issue> --state open` is empty. The gate re-checks both at worktree creation; doing it here keeps the prompts in one pane.
4. **Worktrees.** `git pull --ff-only` in this checkout (allowed outright; it fetches everything, and the fast-forward applies only to the current branch). Then per row, approval-gated:

   ```bash
   git worktree add ../<repo>-<branch> -b <branch> origin/HEAD
   ```

   A fresh worktree has no dependencies. Run Refs' install command in each before spawning, or the worker's first act is diagnosing a test failure that is not its own.
5. **Record.** Per row, `tasklog state $PLAN <code> building --branch <branch> --worktree <abs worktree>`. Tasklog is the safety net if the head dies mid-batch; `--adjust` rebuilds from it.
6. **Spawn.** Requires `$TMUX`; if unset, stop and say so. One new window in the caller's tmux session per batch, one pane per worker, `claude` launched with no positional prompt and no `--allowedTools`:

   ```bash
   m="claude --model <row model> --effort <row effort>"   # per pane, from the row (§ Model tiers)
   win=$(tmux new-window -P -F '#{window_id}' -n "fan-${CLAUDE_CODE_SESSION_ID%%-*}" -c ../<wt-1> "$m")
   p1=$(tmux list-panes -t "$win" -F '#{pane_id}')
   p2=$(tmux split-window -P -F '#{pane_id}' -t "$win" -c ../<wt-2> "$m")
   w=$(tmux display-message -t "$win" -p '#{window_width}')
   [ "$w" -ge $((80 * N)) ] && tmux select-layout -t "$win" even-horizontal || tmux select-layout -t "$win" even-vertical
   ```

   Start each worker once its prompt is up, with one line and nothing else:

   ```bash
   tmux send-keys -t "$pane" -l "/ftl --row $PLAN NN --ship"; sleep 1; tmux send-keys -t "$pane" Enter
   ```

   `ftl --row` reads the row's plan section, brief and latest progress from tasklog, works in the pane's worktree on the row's branch, writes only inside its `owns`, measures the lead's voice itself, logs every stop to the row as `blocked` with a `blocked` event, and ships: review loop, PR, CI green, then `handoff` with the PR URL and verdict.

   Name panes for the human only (`tmux select-pane -t <pane> -T NN-<slug>`); Claude Code overwrites its pane title within seconds, so nothing keys off it. Confirm with `tmux list-panes -t "$win" -F '#{pane_id} #{pane_dead} #{pane_current_path}'`: N panes, right worktrees, `pane_dead` 0. Write each row's pane in `plan.md`. Report the code → pane → worktree → branch mapping to the user, with `prefix + z` to zoom a pane.
7. **Supervise.** One persistent `Monitor` over the rows' tasklog events: a line per new `handoff` or `blocked` event, and per pane that dies, keyed off `pane_id`:

   ```bash
   cd "$FAN"; rm -rf batch; mkdir batch; rows="T1:%12 T3:%13 T5:%14"   # code:pane
   since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
   while :; do
     live=$(tmux list-panes -t "$win" -F '#{pane_id} #{pane_dead}' 2>/dev/null) || live=
     for rp in $rows; do c=${rp%%:*}; id=${rp#*:}
       [ -e "batch/$c.closed" ] && continue
       out=$(tasklog log "$PLAN" "$c" --since "$since") || continue
       n=$(printf '%s\n' "$out" | grep -cE "^[^ ]+  $c  (handoff|blocked)( |\$)")
       [ "$n" = "$(cat "batch/$c" 2>/dev/null || echo 0)" ] || { echo "$n" > "batch/$c"; echo "ROW $c"; continue; }
       [ -n "$live" ] || continue
       case "$live" in *"$id 0"*) ;; *) touch "batch/$c.closed"; echo "PANE GONE $c" ;; esac
     done
     [ "$(ls batch/*.closed 2>/dev/null | wc -l)" -ge N ] && { echo "BATCH COMPLETE"; break; }
     sleep 20
   done
   ```

   A tasklog or tmux failure skips that sweep rather than reading as an event or N dead workers. The head touches `batch/<code>.closed` when it is done with a row (On each event). Stay resident until `BATCH COMPLETE`; each line re-invokes the head.

### On each event

1. `tasklog brief $PLAN NN`: its state and its last events. `PANE GONE` with the row still `building` → read the events, then re-open the pane as Spawn does, or hand the row to the human.
2. **Blocked.** The `blocked` event says why. Answer it in the pane, one line: `tmux send-keys -t <pane> -l '<answer>'`, `sleep 1`, `tmux send-keys -t <pane> Enter`. Or re-scope (a new brief event, then the answer), or take the row back: `tmux kill-pane -t <pane>`, `tasklog state $PLAN NN planned`, touch `batch/NN.closed`. `context ceiling` → kill the pane and open a fresh one in the row's worktree as Spawn does, same line; it resumes from the row's `progress` event.
3. **Handoff.** The event holds the PR URL and verdict. Scope: `git -C <wt> diff --name-only origin/HEAD...HEAD` against `owns`; a file outside is rework even when correct, since it voids the disjointness the batch was sized on. Voice: `gh pr view <url> --json title,body` against the Voice block and the never-list, `gh pr edit` (approval-gated) if off. Rework: one line in the pane, `<what and why>, then /ftl ship`.
4. **Verdict.** `ready` → `gh pr merge <url> --squash --match-head-commit <sha>` (sha from `gh pr view <url> --json headRefOid -q .headRefOid`) joins the merge queue (§ Run), the pane closes (`tmux kill-pane -t <pane>`), freeing its slot, and `batch/NN.closed`. Any other verdict → hand that row to the human and touch `batch/NN.closed`; the rest of the run goes on. Landing is the human's; the row turns `merged` at the next reconcile.

## Inline - `/fan NN`

One task, in this session. Check its brief (Fan out 2) and claim it (3), then invoke the `ftl` skill with `--row $PLAN NN --ship`; ftl makes the worktree, and its stops are this session's to answer. Then On each event 3 and 4 for its PR; then § Run.

## Run - after every batch, until the list is done

`BATCH COMPLETE`, or an inline task shipped: do not stop. Loop:

1. **Reconcile**: `--adjust` step 1. A merged row's pane, if still open, closes.
2. **Fan**: ready rows exist → Fan out from step 1, without its OK: the user approved the run at the first pick. Print the pick and `others` anyway.
3. **Wait**: no row to fan, but rows are `review` or `ready` → their PRs gate what is left. Print the merge queue for the human: one `gh pr merge <url> --squash --match-head-commit <sha>` per ready PR, rows that others depend on first. Then one persistent `Monitor` over the open PRs and the rows being re-shipped, a line per change, ending at the first merge or close, since step 1 rebuilds the list:

   ```bash
   cd "$FAN"; urls="<url> <url>"; rows="<codes being re-shipped>"; since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
   while :; do
     for c in $rows; do
       out=$(tasklog log "$PLAN" "$c" --since "$since") || continue
       n=$(printf '%s\n' "$out" | grep -cE "^[^ ]+  $c  (handoff|blocked)( |\$)")
       [ "$n" = "$(cat "run-$c" 2>/dev/null || echo 0)" ] || { echo "$n" > "run-$c"; echo "ROW $c"; }
     done
     for u in $urls; do
       s=$(gh pr view "$u" --json state,mergeStateStatus,headRefOid -q '"\(.state) \(.mergeStateStatus) \(.headRefOid)"' 2>/dev/null) || continue
       case $s in MERGED*|CLOSED*) echo "PR $s $u"; exit ;; "OPEN DIRTY "*|"OPEN BEHIND "*) ;; *) continue ;; esac
       k=pr-${u##*/}; [ "$(cat "$k" 2>/dev/null)" = "$s" ] && continue
       echo "$s" > "$k"; echo "PR $s $u"
     done
     sleep 120
   done
   ```

   - `MERGED` → back to 1. `CLOSED` → ask about that row, then back to 1.
   - `OPEN DIRTY` or `OPEN BEHIND` → `pr-wait <url>` in the background to confirm; on `1` or `2`, send `/ftl ship` to the row's pane, or, its pane closed, open one in the row's worktree as Fan out 6 does and send `/ftl --row $PLAN NN ship`. Add the code to `rows`; its `ROW` line is handled as On each event.
4. **Stop** only when: every row is `merged` or `dropped` (§ Close); every row left is `blocked`, handed to the human, or waits on a decision; or the context budget is hit. Print what is left per row, and the merge queue.

Never more workers live than the hard cap; a re-ship pane counts.

## `--adjust`

No `plan.md` in `$FAN` → adopt a lane: `head -1 "$LANES"/*/plan.md`, ask which (one whose head still runs is not a candidate), then `FAN=$LANES/<id>`. A `newchat` prompt that names the lane path skips the question.

1. **Reconcile.** Per `building`/`review`/`ready` row with a branch: `gh pr list --head <branch> --state all --json state,number`. `MERGED` → `tasklog state $PLAN <code> merged --pr <n>`; `CLOSED` unmerged → ask. A `landed` row's worktree and local branch go, approval-gated: `git worktree remove ../<wt>`, `git branch -d <branch>`. Remote branches are the lead's or the repo's auto-delete, never yours.
2. **Replan.** Reorder, resize, add, drop, split. A new row is a new tasklog row, sized and briefed; a changed row gets a new row brief; *(issues: yes)* also a new issue in Voice (approval-gated). *(issues: yes)* A dropped row's issue closes only if it is yours and untouched, with a one-line reason in Voice; otherwise it stays open.
3. Log the change. Route next.

## Close

Every row `merged` or `dropped` (`tasklog show $PLAN` prints none): move `plan.md` to `plan-<date>.md`. No GitHub action; with `issues: yes`, the issues closed with their PRs. Invoke `newchat` with the next goal if one is known.

## Decision point

When § Run stops, and at close: route via `~/.claude/skills/shared/next-command.md` and emit exactly one `Next:` block.

## Context budget

At 25% of the context window, wind down: finish the current step and make sure `plan.md` says what is in flight. At 30%, the ceiling, invoke `newchat`. The plan holds the resume point, so the prompt carries the task line, `$FAN` for the next head to adopt, and what the plan cannot state.

## When not to use

- The repo's rules keep agents off `gh` entirely → `/ftl`, where the human runs every issue and PR command.
- One PR of work, no plan worth keeping → `/slice`.
- No `gh` auth for this remote → fix auth first, or `/slice`.
