# Self-improving review

Claude writes a change. A second Claude, in a fresh context, reviews it. Every finding the reviewer raises is recorded, and that record shows what to change in your rules, hooks and skills so the next change arrives cleaner. Each loop through ship, review, measure and adjust leaves fewer findings for the next one.

## Jump right in

- [ftl-ship.md](ftl-ship.md): install, then ship a task to a reviewed draft PR.
- [context-handoff.md](context-handoff.md): hand off to a fresh session at 25% context. Needs tmux.
- [review-insights.md](review-insights.md): read the review record and decide what to change.

## A work in progress

The tools here change every week. Rerun the install in [ftl-ship.md](ftl-ship.md) to pick up new versions; it overwrites any edits you've made to the copies.

Claude Code will ask you to approve some commands. That's deliberate: a push, a `gh` command, a rebase or a new worktree asks unless you've opened that gate with `claude-gate`. Read the command before you approve it. A denial means a gate did its job, so don't work around it with `--no-verify` or by editing a hook. Ask Claude why the command was denied.

## Where to start

Take it in this order. Each step works without the ones after it.

| Level | Piece | What you get |
| --- | --- | --- |
| Start | git hooks + `bash-write-gate.sh` + `claude-gate` | a safety net: no writes on main, no bulk staging, no force-push, no push without a review |
| Start | `/ftl "<task>"`, then `/ftl` | orients on the repo's rules and the lead's conventions, then runs a pre-handoff checklist. Read-only |
| Core | `/ftl ship --integrate` | the full loop: worktree, commit, rebase, review until zero findings, draft PR |
| Advanced | `claude-review-stats`, `/review-insights` | where findings come from and what to change |
| Advanced | tmux, `/spawn`, `/newchat`, the 25% handoff | long tasks across fresh sessions |
| Advanced | `/fan` | several issues at once, one worktree and tmux pane each |

## The reviewer: headless `claude -p`

`claude-review` calls `review-branch.sh`, which runs the review as a separate, non-interactive Claude Code process:

```
cd <worktree> && claude -p "<review prompt>" --model opus --effort <level> \
  --allowedTools Read Grep Glob "Bash(git diff:*)" "Bash(git log:*)" "Bash(git show:*)" "Bash(git status:*)"
```

- **Fresh context.** The reviewer never sees the session that wrote the code: no conversation, no reasoning, no excuses. It reads the branch diff a PR would show (`<base>...HEAD`), the repo's CLAUDE.md/AGENTS.md, and the docs that diff touches, then judges the code on what's there.
- **Read-only.** Its tools are limited to reading files and running read-only git commands. It can't edit the tree it is judging, and it can't run tests or CI. It reads the workflows and judges whether the diff would pass them. With `--engine codex`, `codex exec -s read-only` gives the same guarantee through an OS sandbox.
- **Stronger than the author.** It runs on opus by default, one effort level above the author's and capped at `xhigh`. `--bump` adds one more level, and `CLAUDE_REVIEW_MODEL` or `--model` overrides the model.
- **Bounded.** At most 25 tool calls. Its output is a fixed shape (`## Findings`, `## Adjacent smells`, `## Unverified`, and a last-line `VERDICT: PASS|FAIL`). A missing or garbled verdict counts as FAIL.
- **Your account, your cost.** Each run is billed like any other Claude Code use. `claude-review --status` shows the diff size before you spend anything. A diff that has already passed isn't reviewed again.
- **On the record.** Headless runs leave transcripts in `~/.claude/projects` like any session. That's what `claude-review-stats` imports into the ledger.

## How review-insights works

1. `review-branch.sh` runs each review headless, as described above. It records the verdict, cost and findings in `~/.claude/review-ledger/`. It is the only thing that can write a push approval, so the author never approves its own work.
2. `claude-review-stats` also imports the reviewer's transcripts, then follows each finding into the next review of the same branch: was it fixed, repeated, dropped, or did it ship still listed?
3. `claude-review-stats --categorize` has haiku label each finding with:
   - an **area**: what kind of defect it is, such as correctness, tests or docs.
   - a **cause**: why the change let it through, such as an edge case, an ignored rule, or a fact stated in two places with only one updated.
4. `/review-insights` renders the numbers as a page. Claude then writes 3–5 recommendations, each one a concrete change to a named file, citing only numbers the page shows. Each run republishes to the same private claude.ai link.

### Ask Claude to help you optimize

The page tells you what is wrong. Claude can make the fix. After a run, try prompts like:

- "Read my latest review insights and implement the top recommendation. Show me the diff before you change anything."
- "`edge-case` is my biggest cause. Add an edge-case step to how I start tasks."
- "`<file>` is my top hotspot. Draft a repo rule or a check that would have caught those findings."
- "Which `rule-ignored` findings could be a hook instead of a CLAUDE.md line?"

A week later, run `/review-insights --since <the date you changed it>` and see whether that cause's share went down. If it didn't, the change didn't work: try a stronger one.

## Why hooks in some places and skills in others

**Hooks** are scripts Claude Code or git runs on every matching event, whatever the model remembers. They can deny a command outright. Use a hook for a rule that must never be broken and can be checked mechanically:

- `bash-write-gate.sh` reads each shell command before it runs. Writes on main, `git add -A` and `--no-verify` never get through. If the gate itself crashes, it denies the command.
- `pre-push` runs inside git. It catches pushes that command-text inspection can't see, such as one buried in a Makefile or an npm script. It applies to pushes from your own terminal too.
- `outcome-assert-gate.sh` rejects mocks and call-shape assertions as they're written, not after review.

**Skills** are instructions Claude loads when you invoke them. Use a skill for work that needs judgement and several steps:

- Orient on a repo's conventions.
- Fix a finding everywhere its pattern occurs.
- Write a handoff prompt.
- Plan which issues can run in parallel.

A skill can adapt to the repo in front of it. A hook can't, and shouldn't.

The two meet in review-insights. When `rule-ignored` keeps showing up, ask whether the rule is mechanical. If it is, it graduates from a CLAUDE.md line to a hook. If it needs judgement, move it higher in CLAUDE.md or into the skill step where it applies.

## Why tmux

Claude Code can't open another interactive Claude session by itself. Inside tmux it can:
- open a new window or pane,
- type a prompt into it,
- check whether the session in it is still alive,
- close it.

That is how `/spawn` starts a successor, how `/fan` runs one worker per issue side by side, and how the context handoff replaces a full session with a fresh one. As a bonus, sessions survive a closed terminal or a dropped SSH connection.

Without tmux, everything else still works. `/newchat` prints the handoff prompt and you paste it into a new session yourself.

## Why there's a context handoff

Every turn re-sends the whole conversation, so a long session costs more per turn. Details from an hour ago also crowd out the step in front of it. When the window fills, Claude Code compacts on its own schedule, and that summary can drop things.

The handoff makes that moment deliberate:
- At 25%, at a turn boundary, Claude finishes the current step.
- It writes a prompt holding only what a fresh session couldn't learn from the repo, the issues or the docs.
- A new session picks the work up.

Each session stays focused, and you can read exactly what was carried over. 25% is a budget, not a law; tune it with `CTX_NUDGE_USED`.
