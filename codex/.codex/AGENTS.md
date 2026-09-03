# Global Agent Instructions

## Subagents

- Default model for all Agent tool calls: `claude-sonnet-4-6[1m]`. Always pass `model: "sonnet"` unless a specific task demands a stronger model and I approve the upgrade.
- Never more than 6 agents/workers total per session — subagents, tmux workers, and spawned sessions combined. If the work doesn't fit in 6, do it yourself or ask me.
- Never launch anything with `--effort max`. Workers and spawned sessions run at this session's effort (omit the flag if unknown) on this session's model or one tier lower.

## Working agreement

- Do only what was asked. When you spot an adjacent bug or smell, surface it and ask before expanding scope.
- Don't be sycophantic, it's annoying.
- Don't flatter, it's patronizing.
- Avoid happy talk and useless words. Get directly to the point.
- When asked whether a plan or idea is good, give a verdict. Name its load-bearing assumption and say whether it holds; quantify the gap between claimed and real effort; then propose a runnable 1-hour version that tests the value proposition before the full build. A plan I wrote gets no deference for that.
- **Inspect the machine before trusting the plan's framing of what's missing.** Check running processes, installed binaries, and existing hooks/config. The cheap solution is often already installed and unmentioned in the doc.
- We're engineers, keep it succinct, imperative mood
- Don't repeat yourself.
- Before starting a task, read the docs whose trigger matches the work. Do not read all docs up front unless the repo explicitly requires it.
- When citing repo files, include relative file paths with exact line numbers whenever possible. Prefer `path/to/file.ext:123` and use line ranges only when they add clarity.
- **Repo rules win.** When a project's CLAUDE.md/AGENTS.md conflicts with this file, follow the repo.

## Git Safety

- NEVER MAKE CHANGES ON THE MAIN BRANCH OF A GIT REPOSITORY. Before editing files, check the current branch. If the branch is `main`, stop and ask the user to approve creating or switching to a non-main branch.

## Source control

- **Never integrate from a remote.** No `git merge origin/…`, no `git rebase origin/…`, no `git pull` or `git pull --rebase`, no `gh pr merge`. These are denied permanently and no toggle enables them. If one is genuinely needed, stop and tell me the exact command and what it will do to my tree — I will run it.
- All local git mutations — staging, committing, branching, stashing, merging, rebasing — ask before running. Committing on `main`/`master` is denied — branch first.
- Read-only git and gh commands (log, diff, status, show, blame, pr view, issue list, etc.) run without a prompt.
- `git push` and mutating `gh` commands ask every time. `git pull --ff-only` is allowed outright: it advances a branch pointer or fails, so it can neither write a merge commit nor rewrite a sha.
- Never work around a gate. `--no-verify`, a repo-local `core.hooksPath`, and hand-writing or deleting a marker file are all off limits; ask me instead.

### Per-repo toggles

`claude-gate` shows a repo's toggles; `claude-gate <toggle> on|off` flips one and then offers the others, so a stale setting surfaces instead of lingering unnoticed.

| Toggle | Default | On | Off |
| --- | --- | --- | --- |
| `remote` | on | `git push`, `gh` ask | both denied |
| `merge` | on | **local** merge/rebase ask | both denied |
| `review` | off | push denied until the branch diff passes a fresh-context review | no review required |

`remote` and `merge` are on unless the repo root carries an opt-out marker — `.claude-remote-off` or `.claude-merge-off` — so turning one off writes a file and turning it back on removes it. `review` is the reverse: off unless the repo is listed in `~/.claude/hooks/review-gate-repos`.

The markers are per checkout, so a worktree tightens separately from its parent; the review toggle keys off the main checkout instead and is shared with its worktrees. `~/.config/git/ignore` covers the markers, so they never reach a repo's tracked tree or show up in `git status`.

### The enforcement layers

- `hooks/scripts/bash-write-gate.sh` — inspects command text before the tool runs. Fails closed: a crash denies the command.
- `~/.config/git/hooks/{pre-push,pre-rebase,pre-merge-commit}` — run inside git, so they also catch operations buried in Makefiles, npm scripts, and `git pull`, which command-text inspection cannot see. They act only when `CLAUDECODE` is set, so my own terminal is unaffected.
- `~/.config/git/hooks/pre-push` — the human-side review gate, now pre-PR rather than pre-commit. Runs for ALL pushes (no `CLAUDECODE` guard) in repos opted into `review`, so both Claude and terminal pushes meet the same turnstile. The reviewed unit is the branch diff a PR would show, and the approval is keyed by that diff's own sha256, so a new commit or a rebase expires it and each worktree carries its own. `~/.claude/hooks/scripts/review-branch.sh` is the only writer of an approval. A terminal push runs `claude-review` inline — diff summary, then a choice of reviewer (`claude -p`, `codex exec`, or no) — and proceeds if the review passes; under `CLAUDECODE` the hook only names the command, because an agent has no terminal to answer on. Kill switches: `~/.claude/hooks/.disabled`, `~/.claude/hooks/.no-review-gate`. `pre-commit` is now only a chainer to a repo's own hook.

Whatever the toggles say, `pre-push` denies pushes to `main`/`master`, tags, branch deletions, and non-fast-forward pushes, deciding from the ref list on stdin rather than the current branch — so `git push origin HEAD:master` is caught from a feature branch. Known gaps, accepted: `--no-verify` skips all git hooks (the write gate denies that flag), a repo-local `core.hooksPath` such as husky overrides the global one, and a fast-forward merge writes no commit so `pre-merge-commit` never sees it.

### Uncommitted work and worktrees

Switching or creating a branch with a dirty tree drags the uncommitted changes onto the branch you arrive at. When that happens the gate asks first and suggests a `git worktree add` command — take the worktree unless the changes are genuinely meant to move.

## Comments

- Prefer self-documenting code: a better name beats a comment.
- Keep only WHY comments: a hidden constraint, an invariant, a workaround for a specific bug, or an RFC citation that explains otherwise-surprising behavior.
- Delete WHAT comments that restate the code, and comments that narrate history or audit findings. If a rename makes a comment redundant, delete it rather than updating it.

## Testing

- Test real behavior and observable outcomes: `results`, return codes, emitted headers, side effects, not how a function was called. Asserting call shape (`calledWith`, arity, call counts) tests the test and hides signature drift.
- Mocks/stubs are a smell. Prefer real inputs; when you must isolate a dependency, inject a seam and assert the outcome. Never leave a stub that neuters the path under test: that yields green tests proving nothing.
- For bug fixes, add a failing test first, then fix.
- Every feature ships with meaningful tests. A `.skip` is a coverage hole: fix it or delete it.

## Markdown & prose

- Do not hard-wrap prose. Write one paragraph per line, with a semantic line break only at a real paragraph boundary, and let the reader's editor soft-wrap at whatever width they choose. This applies to Markdown docs, chat replies, commit messages, and PR bodies.
- A fixed wrap column like 72, 80, or 100 bakes in one width and reads awkwardly at every other one. Never insert newlines mid-sentence to hit a column.
- Exceptions that legitimately keep newlines: fenced code blocks, tables, and list items, one line per item.

## Read These Docs — When Triggered

Do not read all docs up front unless the repo explicitly says to. Read the specific doc when its trigger matches.

| When you are... | Read first |
| --- | --- |
| Starting a numbered task from `docs/todo/` | `docs/todo/README.md`, then the task file |
| Writing code in a language with local examples or conventions | The repo's code examples, style guide, or language-specific doc |
| Working on schema, types, files, formats, or state transitions | The repo's schema, data-model, or state-machine doc |
| Writing or modifying error handling | The repo's error-handling doc |
| Writing, sequencing, or debugging tests | The repo's TDD, testing, or build-sequence doc |
| Unsure how to test something | The repo's testing guide for that language or subsystem |
| Questioning whether architecture should change | The repo's architecture, scaling-threshold, or design-decision doc |
| Working on Docker, CI/CD, release, hosting, or deployment | The repo's deployment, operations, or CI/CD doc |
| Working inside a documented subsystem | That subsystem's README or architecture doc |
