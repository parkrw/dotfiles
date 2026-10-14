# ftl ship --integrate

Task to draft PR in one command: worktree, commit, rebase, a review loop until zero findings, push. Git hooks and Claude hooks gate each step.

## Install

The install copies the files into your home directory. After that they're yours to change, and nothing updates them. Running the install again picks up newer versions, but it overwrites anything you've edited. On WSL, run everything inside WSL.

macOS:

```
brew install jq gh tmux node
```

Debian/Ubuntu/WSL (`perl` provides `shasum`; take node 20+ from nvm if apt's is older):

```
sudo apt install git jq gh tmux perl nodejs
```

Both:

```
curl -fsSL https://claude.ai/install.sh | bash
src=$(mktemp -d) && git clone --depth 1 https://github.com/pwilliams-ck/dotfiles "$src"
mkdir -p ~/.local/bin ~/.config/git/hooks ~/.claude/hooks/scripts ~/.claude/hooks/state ~/.claude/skills
cp "$src"/scripts/.local/bin/claude-{gate,review,review-stats} ~/.local/bin/
cp "$src"/git/.config/git/hooks/* ~/.config/git/hooks/
cp "$src"/claude/.claude/hooks/scripts/* ~/.claude/hooks/scripts/
cp -R "$src"/claude/.claude/skills/{ftl,newchat,spawn,fan,review-insights} ~/.claude/skills/
rm -rf "$src"
git config --global core.hooksPath ~/.config/git/hooks
printf '%s\n' .claude-merge-off .claude-remote-off .claude-merge-auto .claude-remote-auto >> ~/.config/git/ignore
```

Merge into `~/.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [
        { "type": "command", "command": "~/.claude/hooks/scripts/bash-write-gate.sh", "timeout": 5 },
        { "type": "command", "command": "~/.claude/hooks/scripts/pr-size-gate.sh", "timeout": 10 } ] },
      { "matcher": "Edit|Write|MultiEdit", "hooks": [
        { "type": "command", "command": "~/.claude/hooks/scripts/outcome-assert-gate.sh", "timeout": 5 } ] },
      { "matcher": "Skill", "hooks": [
        { "type": "command", "command": "~/.claude/hooks/scripts/ftl-mode.sh", "timeout": 5 } ] }
    ],
    "UserPromptExpansion": [
      { "matcher": "", "hooks": [
        { "type": "command", "command": "~/.claude/hooks/scripts/ftl-mode.sh", "timeout": 5 } ] }
    ],
    "Stop": [
      { "matcher": "", "hooks": [
        { "type": "command", "command": "~/.claude/hooks/scripts/ftl-stop-gate.sh", "timeout": 15 } ] }
    ]
  }
}
```

Then, in each repo: `claude-gate merge auto && claude-gate remote auto`.

- `core.hooksPath` is machine-wide. A repo's own `.git/hooks` stop running, except `pre-commit`, which chains to it.
- Reviews run `claude -p` on your account. `codex` is optional, for `--engine codex`.
- `~/.local/bin` must be on `PATH`.

## Toggles

`claude-gate` shows a repo's toggles; `claude-gate <toggle> <state>` flips one.

| Toggle | on | off | auto |
| --- | --- | --- | --- |
| `merge` | ask | deny | local rebase/merge from a clean tree, and `worktree add -b` |
| `remote` | ask | deny | push of your own branch and `gh pr create --draft`; turns `review` on |
| `review` | push denied until the branch diff passes review | no review | — |

Always denied: `gh pr merge`, `git pull` (except `--ff-only`), and merging or rebasing from a remote.

## Loop

1. Run `/ftl "<task>" --ship`. For a task you want to steer, run `/ftl "<task>"`, build it together, then `/ftl ship --integrate`.
2. Ship works in a worktree. It fetches, checks, commits, pulls with `--ff-only` and rebases. It then loops `claude-review` (opus, xhigh) until there are zero findings, pushes, and opens a draft PR.
3. Mark the PR ready.
4. Every week or so, run `/review-insights`. See [review-insights.md](review-insights.md).

## What blocks what

- `bash-write-gate.sh`: writes on main, bulk staging, `--no-verify`, and integrating from a remote.
- `pre-push`: pushes to main, force-pushes, and any push without a review approval for the diff's sha256.
- `outcome-assert-gate.sh`: mocks, call-shape asserts, and `.skip` in tests.
- `ftl-stop-gate.sh`: a ship turn that ends without its hand-off (clean tree, subject-only commits, a passing review, the PR body file, a PR URL or the push block), unless it ends on a question, open findings or a running review. It logs to `~/.claude/hooks/logs/ftl-stop-gate.jsonl` and blocks only after `touch ~/.claude/hooks/.ftl-stop-gate-enforce`. `ftl-mode.sh` tells it which `/ftl` mode the session is in.

## Extras

- `claude-review --status`: whether this diff is already approved, without running a review.
- `/fan <issues>`: one worktree and tmux pane per issue. `/fan`, `/spawn` and `/newchat --spawn` need Claude Code running inside tmux.
- [context-handoff.md](context-handoff.md): hand off to a fresh session at 25% context.
- `git worktree remove <path>`: after the PR merges.
- `touch ~/.claude/hooks/.disabled`: kill switch for every hook.
