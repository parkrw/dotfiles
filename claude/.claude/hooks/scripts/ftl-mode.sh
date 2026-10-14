#!/usr/bin/env bash
# ftl-mode.sh — UserPromptExpansion and PreToolUse(Skill). Records which /ftl
# mode the session is in, for ftl-stop-gate.sh. Two events because each sees
# one way in only: a typed /ftl expands without a Skill tool call, and a Skill
# call by Claude never expands a prompt.
# Kill switch: ~/.claude/hooks/.no-ftl-mode
source "$HOME/.claude/hooks/scripts/common.sh"

check_disabled
require_jq
read_input

case "$(jq -r '.hook_event_name // ""' <<<"$INPUT")" in
  UserPromptExpansion)
    name=$(jq -r '.command_name // ""' <<<"$INPUT")
    args=$(jq -r '.command_args // ""' <<<"$INPUT") ;;
  PreToolUse)
    name=$(jq -r '.tool_input.skill // ""' <<<"$INPUT")
    args=$(jq -r '.tool_input.args // ""' <<<"$INPUT") ;;
  *) exit 0 ;;
esac
# A directory-scoped variant is named <dir>:ftl.
[[ "$name" == ftl || "$name" == *:ftl ]] || exit 0

# session_id becomes a filename component — strip anything path-capable
session=$(jq -r '.session_id // ""' <<<"$INPUT")
session=${session//[^a-zA-Z0-9_-]/}
[[ -n "$session" ]] || exit 0

args="${args#"${args%%[![:space:]]*}"}"
args="${args%"${args##*[![:space:]]}"}"
# The dispatch in skills/ftl/SKILL.md. Help leaves the mode alone: it runs
# nothing, so the session is still doing whatever it was.
case "$args" in
  --help|help|-h)   exit 0 ;;
  "")               mode=check ;;
  ship)             mode=ship ;;
  "ship --integrate") mode=integrate ;;
  *" --ship")       mode=task-ship ;;
  *)                mode=orient ;;
esac

STATE_DIR="$HOOKS_DIR/state"
mkdir -p "$STATE_DIR"
find "$STATE_DIR" -name 'ftl-mode-*' -type f -mtime +7 -delete 2>/dev/null || true
printf '%s\n' "$mode" > "$STATE_DIR/ftl-mode-$session"
