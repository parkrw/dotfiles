#!/usr/bin/env bash
# agent-ask-gate.sh — PreToolUse(Agent) gate. Subagent spawns must never fire
# without explicit per-call approval. A hook decision overrides settings
# allow-lists, so this survives an accidental "Agent" re-added to
# settings.local.json by a "don't ask again" click — it prompts for every
# spawn but the /ftl ship --integrate pre-review, and never hard-blocks.
# Per-script kill switch: touch ~/.claude/hooks/.no-agent-ask-gate
source "$HOME/.claude/hooks/scripts/common.sh"

check_disabled
require_jq
read_input

# Matcher already scopes this to Agent, but re-check defensively so a broadened
# matcher can never make this ask on unrelated tools.
tool=$(echo "$INPUT" | jq -r '.tool_name // ""')
[[ "$tool" == "Agent" ]] || exit 0

# The one exception: /ftl ship --integrate runs unattended, and its Sonnet
# pre-review (skills/ftl/SKILL.md, Ship step 4) would stall it on a prompt.
# ftl-mode.sh records the mode; the spawn must match the skill's exact shape.
session=$(jq -r '.session_id // ""' <<<"$INPUT")
session=${session//[^a-zA-Z0-9_-]/}
mode=""
[[ -n "$session" && -f "$HOOKS_DIR/state/ftl-mode-$session" ]] \
  && IFS= read -r mode < "$HOOKS_DIR/state/ftl-mode-$session" || true
if [[ "$mode" == integrate || "$mode" == task-ship ]] && jq -e '.tool_input
     | .description == "ftl pre-review" and .model == "sonnet"
       and ((.subagent_type // "general-purpose") == "general-purpose")' <<<"$INPUT" >/dev/null; then
  jq -n '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"allow",permissionDecisionReason:"ftl ship --integrate pre-review."}}'
  exit 0
fi

jq -n '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:"Subagent spawns require explicit per-call approval — never auto-allowed."}}'
