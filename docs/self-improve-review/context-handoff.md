# Context handoff at 25%

Once a session has used 25% of its context window, it hands the task to a fresh session in a new pane of the same tmux window and closes itself, so the new pane takes over the window. The new session starts from a prompt that carries only what it couldn't learn from the repo, the issues or the docs.

## tmux is required

`/spawn`, `/fan` and `/newchat --spawn` open new tmux windows or panes. If Claude Code isn't running inside tmux, `/spawn` and `/fan` stop and say so. At 25% the hook only prints a warning.

```
brew install tmux        # macOS
sudo apt install tmux    # Debian/Ubuntu/WSL
tmux new -s work         # then start claude inside it
```

## How it works

1. **Status line:** each time it renders, it writes the context-used percentage to `~/.claude/hooks/state/ctx-<session_id>`. A Stop hook's input has no context data, so this file is how the hook gets the number.
2. **`ctx-handoff-nudge.sh` (Stop hook):** at the end of each turn it reads that file. At 25% or more, it acts once per session:
   - **In tmux:** it blocks the stop, and its message becomes Claude's next instruction: finish or checkpoint the current sub-task, wait for any background review, build or test run, then run `/newchat --spawn --replace "continue: <task>"`.
   - **Outside tmux:** it shows a warning and does nothing else.
   - **Mid-rebase or mid-merge:** it stays quiet and checks again at the next turn.
3. **`/newchat --spawn`:** writes the handoff prompt to `~/.local/state/claude/newchat/<repo>-<timestamp>.md`, naming the feature branch and checkout the work is on, then `/spawn --cwd <checkout> --fresh` opens a new window in that checkout, so the tmux status line shows it, running the same model and effort, seeded with that file.
4. **`--replace`:** passes `--pane` to `/spawn`, so the successor opens as a new pane in the same window; once it is confirmed alive, it kills the old pane and the new one fills the window. If the spawn failed, the old session stays open.

Sessions opened by `/spawn` are also told the rule directly: hand off at 25%, never go past 30%. A `/fan` lead and its workers use the same budget.

## Install

This needs the [ftl-ship](ftl-ship.md) install first: it copies `ctx-handoff-nudge.sh`, `/newchat` and `/spawn`. Then:

```
mkdir -p ~/.claude/hooks/state
src=$(mktemp -d) && git clone --depth 1 https://github.com/pwilliams-ck/dotfiles "$src"
cp "$src"/claude/.claude/statusline-command.sh ~/.claude/
rm -rf "$src"
```

Merge into `~/.claude/settings.json`:

```json
{
  "statusLine": { "type": "command", "command": "bash ~/.claude/statusline-command.sh" },
  "hooks": {
    "Stop": [
      { "matcher": "", "hooks": [
        { "type": "command", "command": "~/.claude/hooks/scripts/ctx-handoff-nudge.sh", "timeout": 5 } ] }
    ]
  }
}
```

If you already have your own status line, keep it and add this to it instead of copying mine (`$input` is the JSON on stdin):

```bash
used=$(jq -r '.context_window.used_percentage // empty' <<<"$input")
session_id=$(jq -r '.session_id // empty' <<<"$input")
[ -n "$used" ] && [ -n "$session_id" ] && printf '%s\n' "$used" > "$HOME/.claude/hooks/state/ctx-$session_id"
```

## Tuning

- `CTX_NUDGE_USED=40`: changes the threshold. Set it in the shell that launches `claude`.
- `touch ~/.claude/hooks/.no-ctx-handoff-nudge`: turns this hook off.
- `/newchat` with no `--spawn` prints the handoff prompt for you to paste anywhere. Outside tmux, `--spawn` saves the file and prints `@<path>` to send after `/clear`.
