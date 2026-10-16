#!/usr/bin/env bash
# ftl-every-prompt.sh — UserPromptSubmit. In a repo whose main checkout carries
# .claude-ftl (claude-gate ftl on), tells Claude to run the prompt through /ftl.
# A hook cannot invoke a skill, only ask for it, so this is an instruction, not
# a guarantee. Slash commands pass untouched: /ftl itself, and any other skill
# the human chose for the turn.
# Kill switch: ~/.claude/hooks/.no-ftl-every-prompt
source "$HOME/.claude/hooks/scripts/common.sh"

check_disabled
require_jq
read_input

[[ "$(jq -r '.prompt // ""' <<<"$INPUT")" != /* ]] || exit 0

cwd=$(jq -r '.cwd // ""' <<<"$INPUT")
[[ -n "$cwd" ]] || exit 0
# The main checkout, so a linked worktree shares its parent's setting.
common=$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || exit 0
[[ -f "$(dirname "$common")/.claude-ftl" ]] || exit 0

CTX='This repo runs every task through /ftl (claude-gate ftl on). Before acting on this prompt, invoke the Skill tool with skill "ftl" and args set to the prompt as its task, then work by that method. Exception: when the prompt answers your question or continues the task already under way, keep following the ftl method already loaded instead of orienting again.'

jq -n --arg ctx "$CTX" \
  '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:$ctx}}'
