#!/usr/bin/env bash
# Claude Code status line
# Shows: git-branch  model  context-bar

input=$(cat)

# --- data from JSON (single jq call for efficiency and null-safety) ---
# Unit-separator delimited: unlike tab (whitespace IFS), \x1f preserves
# empty fields, so a missing project_dir or percentage can't shift fields.
IFS=$'\x1f' read -r cwd project_dir model used session_id <<< "$(
  echo "$input" | jq -r '[
    (.workspace.current_dir // .cwd // ""),
    (.workspace.project_dir // ""),
    (.model.display_name // ""),
    (if .context_window.used_percentage == null then "" else (.context_window.used_percentage | tostring) end),
    (.session_id // "")
  ] | join("\u001f")'
)"

# --- persist used % for the ctx-handoff-nudge Stop hook ---
# (Stop-hook input carries no context data; this file bridges the gap.)
if [ -n "$session_id" ] && [ -n "$used" ]; then
  printf '%s\n' "$used" > "$HOME/.claude/hooks/state/ctx-$session_id" 2>/dev/null || true
fi

# --- ANSI colours (dimmed-friendly 256-colour palette) ---
YELLOW="\033[38;5;179m"
CYAN="\033[38;5;73m"
ORANGE="\033[38;5;173m"
RED="\033[38;5;167m"
RESET="\033[0m"

CTX_BASE="\033[38;5;74m"

# --- git branch ---
# Try each candidate directory in preference order; use HEAD file as
# fallback to avoid lock contention entirely.
git_part=""
for try_dir in "$cwd" "$project_dir"; do
  [ -z "$try_dir" ] && continue
  # Primary: ask git (no locks)
  if git_out=$(GIT_OPTIONAL_LOCKS=0 git -C "$try_dir" symbolic-ref --short HEAD 2>/dev/null); then
    git_part="${YELLOW} ${git_out}${RESET}"
    break
  fi
  # Secondary: read HEAD file directly (handles detached HEAD too)
  head_file="$try_dir/.git/HEAD"
  if [ -f "$head_file" ]; then
    head_content=$(cat "$head_file" 2>/dev/null)
    if [[ "$head_content" == ref:* ]]; then
      branch="${head_content#ref: refs/heads/}"
      git_part="${YELLOW} ${branch}${RESET}"
    else
      # detached HEAD - show short SHA
      git_part="${YELLOW} ${head_content:0:7}${RESET}"
    fi
    break
  fi
done

# --- shorten model name: strip "Claude " prefix to save space ---
short_model="${model#Claude }"
model_part="${CYAN}${short_model}${RESET}"

# --- context bar: 10-block visual bar + numeric % (sky blue -> orange -> red) ---
ctx_part=""
if [ -n "$used" ]; then
  used_int=${used%.*}
  if   [ "$used_int" -ge 85 ]; then bar_color="$RED"
  elif [ "$used_int" -ge 60 ]; then bar_color="$ORANGE"
  else                               bar_color="$CTX_BASE"
  fi
  filled=$(( used_int / 10 ))
  empty=$(( 10 - filled ))
  bar=""
  for (( i=0; i<filled; i++ )); do bar="${bar}█"; done
  for (( i=0; i<empty;  i++ )); do bar="${bar}░"; done
  ctx_part="${bar_color}${bar} ${used_int}%${RESET}"
fi

# --- assemble: git  model  ctx ---
parts=()
[ -n "$git_part"     ] && parts+=("$git_part")
[ -n "$model_part"   ] && parts+=("$model_part")
[ -n "$ctx_part"     ] && parts+=("$ctx_part")

line=""
for part in "${parts[@]}"; do
  if [ -z "$line" ]; then
    line="$part"
  else
    line="${line}  ${part}"
  fi
done

printf "%b\n" "$line"
