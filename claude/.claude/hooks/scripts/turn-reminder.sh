#!/usr/bin/env bash
# turn-reminder.sh — UserPromptSubmit. Injects the per-turn discipline reminder
# (conciseness + CLAUDE.md compliance + priority order) as additionalContext.
# Per-script kill switch: touch ~/.claude/hooks/.no-turn-reminder
source "$HOME/.claude/hooks/scripts/common.sh"

check_disabled
require_jq

REMINDER='REMINDER: Be concise. Shortest response that fully answers. No preamble, no recap, no restated question. This covers ALL written output, not just chat: documentation, git commit messages, and PR descriptions are concise too. Plans terse (bullets/steps). Tool preambles: one short line or nothing. Follow every CLAUDE.md rule — no AI attribution — no skipping. Local git writes need no approval: run them and let the hooks allow, ask or deny. Priorities: security, data integrity, reliability first; then readability; then performance.'

jq -n --arg ctx "$REMINDER" \
  '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:$ctx}}'
