---
name: review-insights
description: The claude-review ledger as one HTML artifact — verdicts, spend, rounds per branch, findings by area and cause, what is still listed, hotspots, and every finding searchable — led by 3-5 recommendations written from that evidence on what to change so the findings stop recurring. Republishes to the same artifact each run. e.g. /review-insights, /review-insights --since 2026-10-01, /review-insights --repo ~/Developments/work/ck/programmin/core.
allowed-tools: Bash(claude-review-stats --json:*), Bash(node ~/.claude/skills/review-insights/render.mjs:*)
---

# review-insights

`$ARGUMENTS` passes through to `claude-review-stats`: `--since <YYYY-MM-DD>` and `--repo <path>` only. Anything else: print the usage examples from the description and stop.

`<dir>` is the session scratchpad.

## 1. Data

```
claude-review-stats --json $ARGUMENTS > <dir>/review-ledger.json
```

Like every run of `claude-review-stats`, it first imports new reviewer transcripts into `~/.claude/review-ledger/`. `no reviews match`: say so and stop.

## 2. Render and read the digest

```
node ~/.claude/skills/review-insights/render.mjs <dir>/review-ledger.json --out <dir>/review-insights.html
```

stdout is the digest: the page's numbers as text, with the most severe findings under each cause. Read all of it. It is the only evidence step 3 may cite.

## 3. Recommendations

Write `<dir>/review-insights-notes.json`:

```json
{
  "summary": "Two sentences: where the findings come from, and the one change with the most leverage.",
  "recommendations": [
    {
      "cause": "<a cause key from the digest>",
      "title": "<the change, imperative, under 70 characters>",
      "change": "<what to edit and how, specific enough to act on>",
      "where": "<the file, hook, skill or CLAUDE.md section it lands in>",
      "why": "<digest numbers and one or two of its findings that justify it>"
    }
  ]
}
```

- 3 to 5, ordered by leverage: a cause's share, weighted up when the fix is mechanical. A cause under 5% earns one only for its blockers.
- Each names one concrete change: a hook, a gate test, a rule moved up or rewritten in a named CLAUDE.md or AGENTS.md, a step added to a named skill, a CI check. Read the file a change names before naming it, so the change fits what is there. "Be more careful" is not a change.
- Start from the cause's remedy in the digest, then make it specific with its findings: which repo, which kind of file, which rule.
- `why` cites only numbers the digest prints.
- When the digest's `categorized through` date is older than the newest change the ledger reflects, the summary says so: the cause shares describe the period before that change, and `WEEKS` is the only evidence for what came after.
- Plain prose: no hedging, no first person.

## 4. Final render

Rerun step 2's command with `--notes <dir>/review-insights-notes.json`. The digest is unchanged; skip it.

## 5. Publish

`render.mjs` wrote the page from this skill's `page.html` and step 1's ledger; the digest is its content as text.

`~/.claude/review-ledger/insights-url` holds the artifact's URL once it has been published.

- The file exists: `Artifact` with `action: "read"` on that URL, then publish `<dir>/review-insights.html` with `url` set to it.
- No file, or the read says the artifact is gone: publish `<dir>/review-insights.html` with `icon: "chart"` and the description `Where claude-review findings come from, and what to change so they stop recurring.` Then write the returned URL to that file.

## 6. Reply

The link, then each recommendation's title, one per line. When the digest counts uncategorized findings, one more line: `claude-review-stats --categorize` files them under an area and cause, and asks before it spends. Never run it unasked.
