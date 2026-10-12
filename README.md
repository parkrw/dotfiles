# Parker's Dotfiles

Personal macOS config, deployed with [GNU Stow](https://www.gnu.org/software/stow/).
Each top-level dir (`nvim/`, `tmux/`, `scripts/`, `markdownlint/`, `claude/`, `codex/`, `karabiner/`, `zsh/`, `omz/`) is a Stow package; `stow <pkg>` symlinks it into `$HOME`. The deployed files are symlinks back into the repo, so editing here edits the live config. `docs/` is documentation, not a package.

Self-improving review (ship, review, measure, adjust): [docs/self-improve-review.md](docs/self-improve-review.md).

## Table of Contents

- [New machine setup](#new-machine-setup)
- [Terminal](#terminal)
  - [IDE](#ide)
  - [Shell](#shell)
- [zsh / oh-my-zsh](#zsh--oh-my-zsh)
- [Karabiner-Elements](#karabiner-elements)
- [Raycast](#raycast)

## New machine setup

```bash
# 1. Prerequisites (jq is required by the claude hooks + statusline)
brew install stow jq

# 2. Clone (examples assume ~/dotfiles; Stow makes symlinks relative to wherever you clone)
git clone https://github.com/pwilliams-ck/dotfiles ~/dotfiles
cd ~/dotfiles

# 3. Deploy packages
stow nvim tmux scripts markdownlint codex karabiner zsh
```

`stow -D <pkg>` un-deploys (removes the symlinks).

### zsh / oh-my-zsh

`zsh/` carries `.zshrc`, `.zprofile`, and `.p10k.zsh`. `omz/` carries only the
hand-written files under `$ZSH_CUSTOM` (`~/.oh-my-zsh/custom/`) — oh-my-zsh
itself, its bundled examples, and third-party plugins are upstream checkouts and
are **not** in this repo. `~/.oh-my-zsh` must exist as a real directory before
stowing `omz`, otherwise Stow symlinks the whole thing into the repo.

```bash
brew install powerlevel10k zsh-syntax-highlighting eza bat fd ripgrep fzf dust lazygit
sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
git clone https://github.com/zsh-users/zsh-autosuggestions \
  ~/.oh-my-zsh/custom/plugins/zsh-autosuggestions
cd ~/dotfiles && stow zsh omz
```

Stowed under `omz/`:

- `custom/aliases.zsh` — eza/git/go/npm/docker/fzf aliases.
- `custom/env.zsh` — `EDITOR`, `MANPAGER`, `FZF_*` defaults.
- `custom/shift-select.zsh` — shift+motion selects text on the command line, driven by the [Karabiner](#karabiner-elements) `Tab` nav layer.

oh-my-zsh gitignores `custom/`, so these symlinks won't dirty the omz checkout.

### Claude Code

The CLI is **not** in this repo — install it separately. And unlike nvim/tmux,
Claude Code keeps its runtime state (`projects/`, `sessions/`, `history.jsonl`,
caches) **inside** `~/.claude`, so it must already exist as a real directory
before stowing — otherwise Stow symlinks the whole `~/.claude` into the repo and
Claude writes session state into git.

```bash
curl -fsSL https://claude.ai/install.sh | bash   # or: brew install --cask claude-code
claude                                            # log in; creates ~/.claude as a real dir
# quit Claude, then:
cd ~/dotfiles && stow claude
```

Not carried by the repo — set up separately on each machine:

- **Plugins** flagged in `settings.json` (`feature-dev`, `gopls-lsp`) — install via the plugin marketplace.
- **MCP servers** (e.g. clickup) and their auth — machine-local (`~/.claude.json`); reconfigure.
- `~/.claude/settings.local.json` and `hooks/logs/` — machine-local, intentionally untracked.
- The hook scripts were vendored from the archived `review-hooks` repo; edit them under `claude/.claude/hooks/scripts/`.
- **Global git hooks** need `git config --global core.hooksPath ~/.config/git/hooks` once per machine, after `stow git`. Without it the pre-push guard never runs.
- `~/.config/git/ignore` is machine-local and untracked; it needs a `.claude-remote-ok` line so opt-in markers stay out of tracked trees.

#### Letting Claude push

Claude's remote writes are denied by default in every repo. To opt one in, drop an empty `.claude-remote-ok` in its root — per repo, and per worktree. That downgrades push/pull/`gh` to a confirmation prompt.

Pushes to `main`/`master`, tags, branch deletions, and force pushes stay denied no matter what, enforced in `git/.config/git/hooks/pre-push` from the ref list git hands the hook on stdin.

### Codex

The Codex CLI is **not** in this repo — install it separately. Codex keeps runtime state (`sessions/`, `history.jsonl`, sqlite DBs, caches, memories, plugin caches, auth, and temporary files) inside `~/.codex`, so it must already exist as a real directory before stowing — otherwise Stow symlinks the whole `~/.codex` into the repo and Codex writes state into git.

```bash
codex                       # log in; creates ~/.codex as a real dir
# quit Codex, then:
cd ~/dotfiles && stow codex
```

Stowed:

- `config.toml` — model, TUI, trusted projects, marketplace, plugin, and feature settings.
- `AGENTS.md` — global Codex instructions.
- `rules/default.rules` — approved command prefix rules.

Not carried by the repo — keep machine-local:

- `auth.json`, `installation_id`, sqlite DBs, logs, sessions, history, caches, plugin caches, memories, worktrees, shell snapshots, temporary files, and automation reports.

## Terminal

- [iTerm2](https://iterm2.com/documentation.html) - MacOS Terminal Emulator
- [tmux](https://github.com/tmux/tmux/wiki) - Terminal multiplexer

### IDE

- [LazyVim](https://lazyvim.org) - Custom LazyVim config

### Shell

- [zsh](https://www.zsh.org/) - Shell
- [oh-my-zsh](https://ohmyz.sh/) - `zsh` management, themes, plugins, etc.

## Karabiner-Elements

[Karabiner-Elements](https://karabiner-elements.pqrs.org/) - MacOS keymapping. Stowed as the `karabiner/` package; install the app separately, then `stow karabiner`.

Unlike `claude/` and `codex/`, this package deploys `~/.config/karabiner` as a **whole-directory** symlink. Karabiner rewrites `karabiner.json` by writing a temp file and renaming it over the original, which would replace a file-level symlink with a regular file and silently un-stow it. Linking the directory instead keeps that rename inside the repo. `automatic_backups/` is gitignored.

Key maps live in `assets/complex_modifications/vim-nav-layers.json`, mirrored into the active profile in `karabiner.json`. Karabiner-Elements holds the config in memory and does **not** reliably notice hand-edits to `karabiner.json`, so after editing it outside the app, force a re-read:

```bash
launchctl kickstart -k gui/$(id -u)/org.pqrs.service.agent.karabiner_console_user_server
```

Skipping that leaves the app running the old rules — and its next write can overwrite the file from stale memory. Colemak comes from the macOS input source, so Karabiner matches **physical** (QWERTY-position) keys — physical `h j k l` are Colemak `h n e i`.

Layer 1 — hold `left ctrl`:

- `h n e i` (physical `hjkl`) --> `left`, `down`, `up`, `right`
- `[` --> `esc`

Layer 2 — hold `left option`:

| Hold `left option` + | Physical key | Everywhere | iTerm2 |
| --- | --- | --- | --- |
| `h n e i` | `h j k l` | arrows | arrows |
| `l u` | `u i` | word left / right (`opt`+arrow) | `ctrl`+arrow (zsh `backward-word`/`forward-word`) |
| `j y` | `y o` | line start / end (`cmd`+arrow) | `home` / `end` |
| `o` | `;` | `fn`+`f1` (temp desktop view) | same |
| `'` | `'` | `caps lock` | same |

Only **left** option is captured, so `right option` still types accented characters. Raycast hotkeys have to avoid left-option + these eight letters.

Add `shift` to any layer-1 or layer-2 key to select instead of move. Outside iTerm2 this needs no extra rules: `shift` is matched as an *optional* modifier and passes through to the emitted arrow (`shift`+`opt`+`left` selects a word, `shift`+`cmd`+`right` selects to end of line).

Selecting on the **command line** is different — a terminal has no cursor-selection concept to forward to, so the shifted keys are separate manipulators that emit sequences zsh widgets act on (`omz/.oh-my-zsh/custom/shift-select.zsh`). Word-select sends **right**-option+shift+arrow: iTerm2's left option is set to `Esc+`, and `ctrl`+`shift`+arrow is already taken by `swap-window` in `tmux.conf`.

Also configured, per device: `caps lock` --> `left ctrl`, and the physical `left ctrl` --> `left option`, making an oversized layer-2 key out of the bottom-left corner. That includes the Raycast and emoji hotkeys bound to left-option combos, since they see an ordinary `left option`. `caps lock` itself therefore has no key of its own and lives on layer 2 (`left option`+`'`) instead.

Two emission quirks are baked into those two bindings. A bare `f1` in a `to` event still goes through the macOS media-key layer and dims the screen, so the temp-desktop key emits `fn`+`f1` — the same event the physical `fn`+`F1` produces. And macOS ignores a `caps lock` press that is too brief, so that binding carries `hold_down_milliseconds: 100`.

The `vim_mode` layer (rules `Vim 1/11`..`11/11`, toggled by tapping `left ctrl`) is present but **disabled**; while on it captures bare `h j k l` and shadows layer 2.

## Raycast

[Raycast](https://raycast.com) - Improved Spotlight search & much more.
