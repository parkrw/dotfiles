# Next-command routing

Shared by `/handoff`, `/fan`, `/slice`, `/spawn`, `/delib`. When a skill finishes a unit of work and knows what remains, it names **exactly one** command to run next - the cheapest variant that fits the remaining work. Not a menu; a recommendation.

## 1. Read the state (cheap checks only)

| Signal | How to read it |
|---|---|
| Plan store | `~/.local/state/claude/fan/<owner>-<repo>/plan.md` (`gh repo view --json nameWithOwner -q .nameWithOwner`, `/` → `-`) with any row not `landed`/`dropped` → fan-managed. A `TODO/README.md` or `HANDOFF.md` is a handoff store for `/handoff` and `/slice`, not a plan. |
| Ready rows | `status ready` whose deps are all `landed` (or their issue is closed). `inflight`, `review`, `shipped` are not ready. |
| Independence | Two ready rows are independent only if neither depends on the other **and** their `owns` globs are disjoint (containment is overlap). A row with no `owns` counts as not independent. |
| Size | The `est` column (`~S` ≤100, `~M` 100-300, `~L` 300+ lines). |
| Blockers | A report whose line 1 is `STATUS: blocked`, a handoff marked **BLOCKED**, or an open architecture question. |
| Prior guidance | This project's memory (`MEMORY.md` and the files it indexes) and the repo's `CLAUDE.md` / `AGENTS.md`. A recorded preference or a "do X next" note **overrides the table below** - say so in the reason. |

Never spend a subagent or a wide grep on this. If the signals are not already in context, three `Read`s and one `gh` call is the whole budget; when a signal is unreadable, treat it as absent.

## 2. Route

Take the first row that matches.

| State | Recommend |
|---|---|
| Next step is an unresolved architecture or dependency decision | `/delib "<the question>"` |
| Fan-managed, rows `inflight`/`review`/`shipped` await reconciling, or the plan drifted from what the session learned | `/fan --adjust` |
| Fan-managed, ≥2 independent ready rows | `/fan` (or `/fan NN MM` when the pick is already known) |
| Fan-managed, one ready row | `/fan NN` |
| No plan store, remaining work is one PR | `/slice "<task>"` |
| No plan store, several PRs | `/fan "<goal>"` |
| No plan store, real unknowns blocking decomposition | `/delib "<the question>"`, then `/fan` |

### Sizing a batch

`N = min(independent ready rows, 4)`. Drop to 2 when any row in the batch is `~L`, and never batch a single ready row: a worktree plus a supervising head costs more than doing it inline. A batch needs `$TMUX`; without it, recommend `/fan NN` for the first ready row.

### Prefer the cheaper variant

`/fan NN MM` over `/fan` when the pick is already known - it skips re-sizing the batch. Naming the numbers is free and saves the next session a planning round.

## 3. Emit it

One fenced block, last thing before the skill stops:

```
Next: /clear, then /fan 12 15 18
Why: #12, #15, #18 are ready and own disjoint paths.
```

Rules: one command, one reason line of ≤15 words, no alternatives. Omit `/clear` only when the next command is meant to run in the current session with its context intact. If two routes are genuinely tied, pick the cheaper one and name the runner-up in the same reason line - never as a second block.
