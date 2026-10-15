#!/usr/bin/env bash
# tool-cadence-reminder.sh — PostToolUse (all tools). Every Nth tool call in a
# session, re-inject a one-line discipline reminder so long tool-use runs don't
# drift from CLAUDE.md; silent on all other calls.
# Parallel tool calls can race the counter — worst case a reminder fires one
# call early/late, which is harmless, so no locking.
# Per-script kill switch: touch ~/.claude/hooks/.no-tool-cadence-reminder
source "$HOME/.claude/hooks/scripts/common.sh"

check_disabled
require_jq
read_input

EVERY=10
STATE_DIR="$HOME/.claude/hooks/state"
mkdir -p "$STATE_DIR"

# prune counters from long-dead sessions
find "$STATE_DIR" -name 'cadence-*' -type f -mtime +7 -delete 2>/dev/null || true

# session_id becomes a filename component — strip anything path-capable
session=$(echo "$INPUT" | jq -r '.session_id // "unknown"')
session=${session//[^a-zA-Z0-9_-]/}
[[ -z "$session" ]] && session="unknown"

counter_file="$STATE_DIR/cadence-$session"
count=0
[[ -f "$counter_file" ]] && count=$(<"$counter_file")
[[ "$count" =~ ^[0-9]+$ ]] || count=0
count=$((count + 1))
printf '%s' "$count" > "$counter_file"

(( count % EVERY == 0 )) || exit 0

jq -n '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:"Reminder: stay concise; follow CLAUDE.md exactly (no AI attribution; local git writes need no approval — the hooks decide); priorities: security, data integrity, reliability first, then readability, then performance."}}'
