# Custom aliases
#
# System
# Edit the repo copies, not the deployed symlinks — single quotes so $EDITOR
# resolves at call time.
alias zshconfig='$EDITOR ~/dotfiles/zsh/.zshrc'
alias zshaliases='$EDITOR ~/dotfiles/omz/.oh-my-zsh/custom/aliases.zsh'
alias zshenv='$EDITOR ~/dotfiles/omz/.oh-my-zsh/custom/env.zsh'
alias ohmyzsh='$EDITOR ~/.oh-my-zsh'

# eza — shared flags, expanded into the aliases below at definition time.
# Add --hyperlink for clickable filenames (needs tmux >= 3.4 + a supporting terminal).
_eza=(--colour=always --colour-scale=all --colour-scale-mode=gradient
      --icons=always --classify=always --group-directories-first --git)
# keep this line here.
alias l="eza -l $_eza"
alias ll="eza -la $_eza"
alias lls="eza -la $_eza --sort=modified --time=modified --time-style=relative"
alias llz="eza -la $_eza --sort=size --total-size"   # real dir sizes; slow on huge trees
alias lt="eza -T --level=2 $_eza --git-ignore"       # tree, skips gitignored
alias lg="eza -la $_eza --git-repos"                 # git status + nested repo state
alias f="fzf"
alias h="history"
alias hf="history 1 | fzf --tac"
alias hf1="history -t '%F' 1 | awk -v c=\$(date -v-1m +%F) '\$2 >= c' | fzf --tac"
alias hf3="history -t '%F' 1 | awk -v c=\$(date -v-3m +%F) '\$2 >= c' | fzf --tac"
alias hf6="history -t '%F' 1 | awk -v c=\$(date -v-6m +%F) '\$2 >= c' | fzf --tac"
alias hfy="history -t '%F' 1 | awk -v c=\$(date -v-1y +%F) '\$2 >= c' | fzf --tac"
alias c="clear"


# Code
alias ta="tmux a"
alias vim="nvim"
alias v="nvim"
alias cl="claude"
alias clog="cl --model=claude-opus-4-6\[1m\]" # OG claude opus 4.6 1M context
alias clog8="cl --model=claude-opus-4-8\[1m\]"
alias clsog="cl --model=claude-sonnet\[4-6\]" # OG claude sonnet 4.6 1M context
alias cx="codex"
alias py="python3"

# Files / search
alias cat="bat --paging=never"   # `command cat` for raw output in scripts
alias rgi="rg -i"
alias rgf="rg --files | fzf --preview 'bat --color=always {}'"
alias ff="fd --type f"
alias dud="dust -d1"             # what's eating this dir

# Git — human-only operations; see hbops CLAUDE.md
# omz git plugin already gives gst/gd/gco/gcm/glol/grbi/gwip…
alias ghi="githelp" # zsh git plugin commands
alias lgit="lazygit"
alias prs="gh pr list --author @me"
alias prv="gh pr view --web"
alias ci="gh run list --limit 5"
alias prc="gh pr create"
alias il="gh issue list"
alias iv="gh issue view"
alias ic="gh issue create"

# Go — omz golang plugin already gives gob/got/gof/gov…
alias gt="go test ./..."
alias gtr="go test -v -race -cover ./..."
alias gtf="go test -v -run"      # gtf TestFoo ./oplog/
alias gmt="go mod tidy"

# Docker / k8s — omz kubectl plugin already gives k/kgp/kgs…
alias dps="docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'"
alias dlog="docker logs -f --tail=100"
alias kctx="kubectl config get-contexts"

# JS / React — npm-first, low-dep. `n` stays the node version manager; `nl` is /usr/bin/nl.
# omz npm plugin adds completions + its own npm* aliases.
alias ni="npm install"
alias nid="npm install -D"
alias nci="npm ci"                     # lockfile-exact install
alias nun="npm uninstall"
alias nr="npm run"                     # nr dev / nr build (tab-completes script names)
alias nd="npm run dev"
alias nb="npm run build"
alias nt="npm test"
alias nlint="npm run lint"
alias nout="npm outdated"
alias nwhy="npm explain"               # nwhy <pkg> — why is this in the tree
alias ndry="npm install --dry-run"     # see the blast radius before adding a dep
alias ndeps="npm ls --all --parseable | wc -l"   # transitive dep count
alias nx="npx"
alias nxn="npx --no-install"           # local bins only, never silently fetch
alias tc="npx --no-install tsc --noEmit"
alias tcw="npx --no-install tsc --noEmit --watch"
alias serve="python3 -m http.server 8000"   # static preview, zero deps
# open a component fast: fuzzy over jsx/tsx/js/css with preview
alias vf='nvim "$(fd -t f -e jsx -e tsx -e js -e ts -e css | fzf --preview "bat --color=always {}")"'

# Misc
alias envrc='$EDITOR .envrc && direnv allow'
alias jqp="jq -C . | bat -l json"
alias path='echo $PATH | tr ":" "\n"'
alias reload="exec zsh"

