# AGENTS.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Personal macOS dotfiles. There is no build and no application code — these are configuration files deployed into `$HOME` via GNU Stow. The scripts and hooks that have tests keep them beside themselves, each run directly: older bash ones as `test-*.sh` pipe tests (`bash <file>`), Python ones as `test_*.py` unittest files (`python3 <file>`); there is no CI.

New scripts are Python 3, standard library only, written to run on 3.9 (macOS's `/usr/bin/python3`). Ubuntu server and minimal images ship `python3` with `sqlite3` and macOS has it once the Command Line Tools are in, so they run with nothing to install.

## Git

- Push feature branches and open PRs with `gh pr create` without asking.
- Never push to `main`, never merge, never tag. PRs are opened, never merged.

## Architecture: Stow package layout

Each top-level directory (`nvim/`, `tmux/`, `zsh/`, `scripts/`, `markdownlint/`, `claude/`, `codex/`, `karabiner/`) is a **GNU Stow package** whose internal path mirrors where it lands under `$HOME`. For example `nvim/.config/nvim/init.lua` is deployed to `~/.config/nvim/init.lua`.

Deploy by symlinking a package into `$HOME` from the repo root:

```bash
stow nvim         # symlinks nvim/.config/nvim       -> ~/.config/nvim
stow tmux         # symlinks tmux/.config/tmux       -> ~/.config/tmux
stow zsh          # symlinks zsh/.zshrc, .p10k.zsh, .zprofile -> ~/
stow scripts      # symlinks scripts/.local/bin/*    -> ~/.local/bin/
stow markdownlint # symlinks markdownlint/.markdownlint.json -> ~/.markdownlint.json
stow claude       # symlinks claude/.claude/*        -> ~/.claude/
stow codex        # symlinks codex/.codex/*         -> ~/.codex/
stow karabiner    # symlinks karabiner/.config/karabiner -> ~/.config/karabiner
stow -D nvim      # un-deploy (remove symlinks)
```

The deployed files in `$HOME` are symlinks back into this repo, so editing a file here edits the live config. (The README's `git clone … ~/.config/` instruction is outdated — Stow is the actual mechanism.)

## Neovim (`nvim/.config/nvim/`)

Built on **LazyVim**; `lua/config/lazy.lua` is the entry point. Config in `lua/config/` layers on top of LazyVim defaults rather than replacing them; specs in `lua/plugins/*.lua` are **merged** with LazyVim's. To extend a list option (e.g. `ensure_installed`), use the `opts = function(_, opts)` form and `vim.list_extend`; see `lsp.lua` and `proto.lua` for the pattern.

Notable: custom keymaps use `s`-prefixed window commands and `t`-prefixed Telescope pickers (`editor.lua`, `keymaps.lua`); `pwilliams/discipline.lua` rate-limits repeated `hjkl`. Prettier only runs in repos that have their own Prettier config (`vim.g.lazyvim_prettier_needs_config = true` in `options.lua`).

`lazy-lock.json` is gitignored — the plugin lockfile is intentionally not tracked.

`selene` and `luacheck` are available for linting Lua, but only inside Neovim — they're installed via Mason, not on PATH.

## Scripts (`scripts/.local/bin/`)

Custom shell tools deployed to `~/.local/bin`:

- `reqd` — **moved to its own repo** at `~/Developments/work/ck/programmin/reqd`; what's here is an untracked, gitignored symlink keeping it on PATH.
- `cht.sh` — **vendored third-party** cheat.sh shell client (has its own `update`/`version` self-management). Don't hand-edit; treat as upstream.
- `pr-wait` — polls a PR until its checks settle and GitHub's merge state says it can squash-merge; the exit code names the verdict (ready, failed, behind/conflict, blocked, closed, timeout). `/ftl ship --integrate` waits on it after opening the PR.
- `claude-review-stats` — zero-dependency Node. Reports on `~/.claude/review-ledger/`, where `review-branch.sh` records every review: verdicts, cost, what became of each finding in the branch's next review, and the finding categories (area and cause) assigned by `--categorize` with haiku. Each run also imports the reviewer's own headless transcripts from `~/.claude/projects` before Claude Code's `cleanupPeriodDays` deletes them. `--json` carries the area/cause taxonomy with the runs and findings; the `review-insights` skill renders it as a page.
- `tasklog` — Python stdlib on `sqlite3`: a plan, PR-state, event, decision and flake log per work context, so concurrent sessions append rows instead of rewriting a PLAN.md. `cklog` (CloudKey, `ck.db`) and `vanlog` (vanillin, `van.db`) are tracked symlinks to it; each exits 2 in a repo whose origin it does not own. DBs live in `${TASKLOG_DIR:-~/.local/state/claude/tasks}`. Text passed as `-` is read from stdin. As core's `apps/api/src/db.js`: write commands open a writer that sets WAL and migrates, read commands a read-only reader. Tests: `python3 scripts/.local/bin/test_tasklog.py`.

The `claude` file (untracked) is **not** part of these dotfiles. It's a symlink the Claude Code installer wrote to `~/.local/bin/claude` (pointing at `~/.local/share/claude/versions/<ver>`); because `~/.local/bin` is a folded Stow symlink to this directory, that write landed inside the repo. It's machine- and version-specific — don't commit it (gitignore it, or unfold the dir so `~/.local/bin` holds per-file symlinks).

## Claude Code (`claude/.claude/`)

Global Claude Code config. `~/.claude/` is a real directory full of machine state, so Stow **folds**: only the items below become symlinks; everything else there (`projects/`, `sessions/`, `history.jsonl`, caches, `plugins/`, `settings.local.json`, `review-ledger/`, and `hooks/logs/` + `hooks/.rename-plans-since`) stays real and untracked.

Stowed:

- `AGENTS.md` — global cross-project instructions; `settings.json` — permissions, hooks wiring, status line, plugins; `keybindings.json`; `statusline-command.sh`; `extra-system-prompt.txt`.
- `commands/` — custom slash commands. `skills/` — one dir per skill, each holding a `SKILL.md`: planning (`cycle`, `cycle-issues`, `delib`), execution (`slice`, `implementer`), session plumbing (`handoff`, `spawn`), `pm`, and `review-insights` (the review ledger as an artifact, with recommendations; `render.mjs` and `page.html` live beside its `SKILL.md`). `skills/shared/` is **not** a skill — it holds cross-skill reference docs (`next-command.md`, the next-command routing table) that skills read by path; without a `SKILL.md` the loader ignores it.
- `hooks/scripts/` — `bash-write-gate.sh` (PreToolUse(Bash) gate), `rename-plans.sh` (Stop hook), and their `common.sh` lib. **Vendored** from the now-archived `review-hooks` repo and wired via the `hooks` block in `settings.json`; edit here = live. The dormant scripts and `patterns/` from that repo were intentionally left behind.

`settings.local.json` is machine-local and deliberately **not** stowed.

## Codex (`codex/.codex/`)

Global Codex CLI config. `~/.codex/` is a real directory full of machine state, so Stow **folds**: only the items below become symlinks; everything else there (`auth.json`, `installation_id`, sqlite DBs, logs, `sessions/`, `history.jsonl`, caches, plugin caches, memories, worktrees, shell snapshots, temporary files, and automation reports) stays real and untracked.

Stowed:

- `config.toml` — model, TUI, trusted projects, marketplace, plugin, and feature settings.
- `AGENTS.md` — global Codex instructions.
- `rules/default.rules` — approved command prefix rules.

## Karabiner-Elements (`karabiner/.config/karabiner/`)

The **only** package Stow deploys as a whole-directory symlink rather than folding. Karabiner saves `karabiner.json` by writing a temp file and renaming it over the target, which replaces a file-level symlink with a regular file and silently un-stows it; linking the directory keeps that rename inside the repo. Consequence: everything Karabiner writes lands here, so `automatic_backups/` is gitignored via `karabiner/.config/karabiner/.gitignore`.

`karabiner.json` is **machine-written** — the app rewrites the whole file (sorted keys, 4-space indent) on any UI change, and `profiles[].devices` holds per-machine vendor/product IDs. Edit rules by patching the JSON with a script or through the UI, never by hand-formatting; expect churn in unrelated keys.

Rules are duplicated by design: the durable source is `assets/complex_modifications/vim-nav-layers.json` (what the UI's "Add rule" browser reads), and the active copy lives in `profiles[0].complex_modifications.rules`. Change both, or the next reinstall silently drops the mapping. Order matters — Karabiner takes the **first** matching manipulator.

Colemak is a macOS input source, not keyboard firmware, so Karabiner sees **physical** QWERTY key codes: write `h`/`j`/`k`/`l` to mean the keys that type Colemak `h`/`n`/`e`/`i`. This cuts both ways — `to` events are re-encoded by the layout too, so `to.key_code: "f"` types `t` under Colemak. **Never emit letter key codes**; use arrows, `home`/`end`, and other layout-independent codes so the mappings survive an input-source switch.

`to` events are also re-interpreted by macOS's own key handling, which is a separate trap from the layout one. A bare `f1` dims the display rather than sending F1, because the F-keys-as-media-keys behaviour applies to Karabiner's virtual keyboard too; emit `f1` with `modifiers: ["fn"]` to reach an app bound to F1. Likewise a `caps_lock` press shorter than roughly 100 ms is dropped, so emitting it needs `hold_down_milliseconds`.

`optional: ["caps_lock"]` is **not** decoration on these rules — it is why they keep working while caps lock is on. An active caps lock is an extra modifier on the `from` event, and an unlisted extra modifier fails the match. A manipulator that lacks it dies the moment caps lock engages, which reads as "the caps-lock toggle turns it on but nothing turns it off". Put it on every layer manipulator.

Selection variants come from `from.modifiers.optional: ["shift", "caps_lock"]` — Karabiner forwards optional modifiers to the `to` event, so one manipulator yields both the move and the `shift` select. Don't add mirrored `shift` manipulators, *except* where the selecting key must emit something different from the moving key (the iTerm2 word/line keys below); those need a `mandatory: ["shift"]` manipulator ordered **before** its unshifted twin.

**Editing `karabiner.json` does not apply it.** The app keeps the config in memory and does not reliably pick up external writes, so a hand-edit must be followed by `launchctl kickstart -k gui/$(id -u)/org.pqrs.service.agent.karabiner_console_user_server`. Two traps if you skip it: you will be testing the previously loaded rules, and the app's next own write can clobber your edit from stale memory. The `console_user_server.log` records only connection chatter — never config loads — so it cannot confirm a reload either way; verify by pressing keys.

Per-device `simple_modifications` are applied **before** `complex_modifications`, which is what makes the corner keys work: `caps_lock` --> `left_control` is why the `Layer 1` rules can match `mandatory: ["control"]`, and physical `left_control` --> `left_option` is why the physical ctrl key gets every Layer 2 mapping (and every left-option Raycast hotkey) for free, with no rule duplicated onto a second `from` key. Add a Layer 2 binding once, in the rules, and both trigger keys pick it up. The corollary is that a complex rule can no longer see a physical `left_control` at all — the disabled `Vim 1/11`..`11/11` layer toggles on tapping `left_control` and would not fire if re-enabled.

Layer 2 uses `left_option` as a plain mandatory modifier. A held non-modifier key as the layer trigger (variable set on `to`, cleared by `to_after_key_up`, `to_if_alone` for the tap) was tried with `Tab` and rejected: the manipulator did not engage and the held key just auto-repeated.

Terminal keys have several encodings and oh-my-zsh binds only some of them: `khome`/`kend` cover the application-cursor forms (`^[OH`/`^[OF`) but leave `^[[H`/`^[[F` and the `^[[1~`/`^[[4~` family on `undefined-key`, which reads as "home/end silently does nothing" whenever the terminal is not in application mode. `shift-select.zsh` binds all of them; bind every form rather than assuming a mode.

iTerm2 gets its own manipulators (ordered first, `frontmost_application_if`) because a terminal has no selection to forward: word/line moves become `ctrl`+arrow and `home`/`end`, and the shifted variants emit sequences that the zsh widgets in `omz/.oh-my-zsh/custom/shift-select.zsh` turn into a `REGION_ACTIVE` selection. Two encoding constraints pin those choices: iTerm2's left option is set to `Esc+` (so left-option combos arrive ESC-prefixed, not as an xterm modifier), and `tmux.conf` binds `C-S-Left`/`C-S-Right` to `swap-window`, so `ctrl`+`shift`+arrow never reaches the shell. Word-select therefore emits **right** option + shift + arrow (`^[[1;4D`/`^[[1;4C`). Changing either setting means re-checking these.

The `Vim 1/11`..`11/11` rules are a third-party `vim_mode` layer gated on the `vim_mode` variable (toggled by tapping `left_control`). All twelve are `"enabled": false`. They precede the `Layer 1`/`Layer 2` rules and would capture bare `h j k l` if switched on.
