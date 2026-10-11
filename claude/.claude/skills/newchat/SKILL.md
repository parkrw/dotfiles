---
name: newchat
description: Compose a paste-ready prompt for starting a task in a fresh Claude session, centered on a "Context a fresh read won't give you" section. Use when asked to "prompt a new chat", "draft a prompt for a new session", or hand a task to another session. `--spawn` also saves the prompt to a file and opens it in a new tmux window via /spawn; `--spawn --replace` then ends this session, for a context handoff.
---

Produce exactly one fenced code block the user can paste into a new session. Nothing after the block, except what `--spawn` adds below.

Structure, in order:

1. **The task** — one line, imperative, with issue/PR numbers and where to read them (`gh issue view N`). Name the parent epic if there is one.
2. **"Context a fresh read won't give you:"** — the payload. Only facts the new session cannot derive from the repo, the issues, or the docs:
   - decisions settled in conversation, stated as settled (with the why in one clause, e.g. "no palette value changes — values are #261's, blocked on the brand owner")
   - exact values, measurements, or names established during the session
   - traps discovered: things that look like X but are Y ("the two token blocks share names but are deliberately different themes")
   - file:line anchors for the places the work starts
   - invariants to preserve that aren't written down anywhere
3. **Gates** — the tests/lint/checks that define done.
4. **Standing rules** — keep output as concise as possible: lead with the result, no preamble, no recaps, shortest response that fully answers. Branch first, never work on main. git and gh reads are fine without asking; every git write and every mutating gh command needs the user's approval individually.
5. **After-merge reminders** — comments to post, people to ping, follow-up issues.

Rules:
- Every bullet must earn its place: if a fresh session would find it within 30 seconds of reading the issue, cut it.
- No restating the issue body, no filler, no open questions the user already answered — state the answer.
- Write values inline (hex codes, px, paths); never "see above" or "as discussed".

## `--spawn`

When `$ARGUMENTS` starts with `--spawn`, drop the flag (and a following `--replace`) from the task text, compose the block as above, then:

1. Write the block's contents, without the fences, to `$HOME/.local/state/claude/newchat/<repo>-<YYYYMMDD-HHMMSS>.md` (`mkdir -p` the directory). `<repo>` is `basename "$(git rev-parse --show-toplevel)"`, or `basename "$PWD"` outside a repo. The file lives outside the repo so nothing lands in the tracked tree, and it survives a `/clear`.
2. If `$TMUX` is set, invoke the `spawn` skill with the argument `--fresh Read <absolute file path> and do the task in it.` `--fresh` stops spawn from adding a handoff pickup that would compete with this task. Pass the path, never the prompt: spawn's seed must be one line, and a multi-line prompt either gets joined into one line or submits at its first newline. The spawned session counts toward the 6-worker cap.
3. Print the block, then the file path, then spawn's report: its window target, or its failure. Without `$TMUX`, skip step 2 and print `@<absolute file path>` instead, for the user to send after `/clear`.

## `--replace`

With `--spawn --replace`, this session is being replaced, usually by the context hook. After step 3, end it:

- Only when spawn's step 4 confirmed the new window alive. A failed spawn keeps this session; say so and stop.
- Never while a background task (a review, a build, a test run) is still running, or a rebase or merge is in progress (`git rev-parse --git-path rebase-merge`, `rebase-apply`, `MERGE_HEAD` exist): finish or abort it first.
- Then run `tmux run-shell -b "sleep 3; tmux kill-pane -t $TMUX_PANE"`. tmux runs it after this turn has printed, so the transcript keeps the report; the pane and its `claude` close together.
