---
name: spawn
description: Open a new interactive Claude Code session in a new tmux window (like prefix+c) of the current tmux session, running this session's model and effort (never max). Seeds it with a handoff pickup (task file's Handoff section, or HANDOFF.md) and a 15%/20% context-budget rule; optional argument appends the task, e.g. /spawn, /spawn "continue task 07c2".
---

## Help

If `$ARGUMENTS` is exactly `--help`, `help`, or `-h`, print the block below
verbatim and **stop — do not execute the skill**.

```
/spawn — open a new Claude Code session in a new tmux window (same model/effort)

  Open a new interactive Claude Code session in a new tmux window (like
  prefix+c) of the current tmux session, running this session's model and
  effort (never max). Seeds it with a handoff pickup (if present) and a 15%/20%
  context-budget rule; optional argument appends the task.

  /spawn                         new session, picks up the existing handoff
  /spawn "continue task 07c2"    new session seeded with a task
  /spawn --help                  show this help

  See also:
    /handoff       write the handoff before spawning
    /fan           fan issues out to concurrent sessions in worktrees
```

---

# Spawn a sibling Claude Code session

Open a fresh interactive `claude` in a **new window of the current tmux session**, running the exact model id this session runs on (or one tier lower — Fable → Opus → Sonnet → Haiku — never Fable) at this session's effort. If the effort is unknown, omit the `--effort` flag. **Never `--effort max`.** Then confirm the window exists.

## 1. Preconditions

- `[ -n "$TMUX" ]` — if unset, stop and tell the user this only works inside tmux.
- Capture the session name: `session=$(tmux display-message -p '#S')`.

## 2. Build the seed prompt

The new session always starts with an initial prompt composed of, in order:

1. **Handoff pickup** — resolve where the handoff lives, in this order:
   - `TODO/README.md` exists → `Read TODO/README.md, follow its Resume pointer
     to the task file, and continue from that file's Handoff section.`
   - else `HANDOFF.md` exists in `$PWD` (`[ -f HANDOFF.md ]`) →
     `Read HANDOFF.md first and continue from it.`
   - else omit this line.
2. **Context budget** — always include, verbatim:

   > Context budget: if any single prompt run reaches 15% of the context
   > window, run /handoff so a fresh session can take over. NEVER exceed 20%
   > total: treat 15% as the signal to gauge remaining work and wind down —
   > finish or checkpoint the current sub-task and leave a concrete next step
   > in the handoff. Never leave a task or sub-task hanging with no plan there.
   > Hard caps: never more than 6 subagents/workers total, never
   > `--effort max`, and do implementation work yourself rather than
   > delegating it.

3. **Next command** — when `$ARGUMENTS` is empty, route via
   `~/.claude/skills/shared/next-command.md` and append the resulting command
   as the task (`Start with: /fan.`). A seeded session that has to
   re-derive which command to run burns context on a decision this session
   already has the state for. Omit only when the routing finds no plan store.
4. **`$ARGUMENTS`** — if non-empty, appended last as the actual task, and it
   overrides the routed command.

## 3. Create the window

Launch with **no positional prompt** — a seed passed as a command argument is
swallowed by tmux's argument handling and the session sits idle at an empty
prompt, with nothing erroring. `-P -F` prints the new pane's id and the window
target for verification:

```bash
read -r pane target <<<"$(tmux new-window -P -F '#{pane_id} #{session_name}:#{window_index}' \
  -n cc -c "$PWD" "claude --model '<model-id>' --effort <effort>")"   # per the rule above; drop --effort if unknown
```

Then deliver the seed by tmux buffer, which has no quoting surface:

```bash
printf '%s' "$seed" > "$SP/seed.txt"          # single line, no embedded newlines
tmux load-buffer -b spawnseed "$SP/seed.txt"
tmux paste-buffer -b spawnseed -t "$pane"
tmux delete-buffer -b spawnseed
sleep 1 && tmux send-keys -t "$pane" Enter
```

- Like `prefix + c`, this switches focus to the new window — that is expected;
  do not add `-d`.
- The seed must be **one line**: a multi-line paste submits at the first newline
  and strands the rest in an empty prompt. Join step 2's parts with spaces
  before writing the file.

## 4. Confirm

Verify the printed target is in the **same session** and still alive (a failed
`claude` launch closes its window immediately):

```bash
tmux list-windows -t "$session" -F '#{session_name}:#{window_index} #{window_name}'
```

- The target from step 2 must appear in this list. If it does not, report the
  failure — re-run the launch command in the current pane's shell context to
  surface the error, don't silently retry.
- Report to the user: window target (e.g. `dotfiles:3`), window name, and the
  model launched.
