# review-insights

Every `claude-review` run is recorded. `/review-insights` turns that record into 3–5 changes to make, so the same findings stop coming back. The [ftl-ship](ftl-ship.md) install already copies everything it needs.

## Run it

```
claude-review-stats --categorize            # label new findings by area and cause with haiku; asks before spending
/review-insights                            # inside Claude Code
/review-insights --since 2026-10-01 --repo ~/src/core
claude-review-stats [--since <date>] [--repo <path>]   # the same numbers as text
```

`/review-insights` publishes a private claude.ai artifact and republishes to that same URL every run. The URL is stored in `~/.claude/review-ledger/insights-url`. Delete that file to start a new page.

## The ledger

- `~/.claude/review-ledger/runs/` holds one `<id>.json` and one `<id>.md` per review.
- Gate runs are written by `review-branch.sh`. They carry shas, so their outcomes are exact.
- Every run of `claude-review-stats` also imports the reviewer transcripts from `~/.claude/projects`. Those runs have no shas, so a finding that went away can only be called `resolved`.
- Claude Code deletes transcripts after `cleanupPeriodDays`, which defaults to 30. Run the stats more often than that, or raise the setting in `settings.json`.
- Area and cause labels live in `categories.json`. Findings without labels are left out of the area and cause tables.

## Reading it

A finding's outcome is judged against the next review of the same branch:

| Outcome | Meaning | Signal |
| --- | --- | --- |
| `fixed` | gone, and its file changed | the loop works |
| `repeated` | reported again | the fix covered one instance, not the whole class |
| `dropped` | gone with nothing changed | the reviewer changed its mind: closest thing to a false positive |
| `open` | the branch's last review failed with it | a stalled branch |
| `shipped` | the last review passed with it still listed | an accepted minor |

A **late find** is a finding no earlier review of the branch raised. One that appears with nothing changed was missed earlier, which is a coverage gap in the reviewer. Try `claude-review --bump` or `--engine codex`.

**Flaky** counts unchanged diffs that were reviewed twice and got different verdicts.

**Rounds by what they follow**: a first round judges the task, a round after a FAIL judges a fix, and a round after a PASS judges new commits on a branch that had already passed. The digest also counts FAIL rounds that listed one minor and nothing else, the rounds a cleaner first commit would have saved, and prints the date categorization last ran: the cause and area tables stop there.

## Acting on it

Each cause comes with a default remedy. A recommendation makes that remedy concrete, naming one file to change:

| Cause | Change |
| --- | --- |
| `edge-case` | name the edge cases in the task and ask for them in the plan |
| `rule-ignored` | a mechanical rule becomes a hook; a judgement rule moves up in CLAUDE.md |
| `stale-duplicate` | single-source the fact, or add a check that both copies agree |
| `untested` | make the test part of the task's definition of done |
| `shell-pitfall` | run shellcheck from a PostToolUse hook on shell edits |
| `contract-break` | grep the callers before changing a signature or format |
| `scope` | one behaviour per branch |
| `wrong-assumption` | run the behaviour before relying on it |

1. Apply the top one or two recommendations.
2. A week later, rerun with `--since <the date you applied them>`. Check whether that cause's share went down.
3. Look at **Hotspots** and **Longest review loops** on the page. A file that keeps getting flagged needs a rule or test written for that file, not a broader one.
