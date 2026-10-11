#!/usr/bin/env bash
# ctx-handoff-nudge.sh — Stop hook. When context USED reaches
# CTX_NUDGE_USED% (default 25), hand the work to a fresh session, once per
# session (marker file).
#
# Inside tmux the hook blocks the stop, which makes Claude continue with the
# reason as its instruction: run /newchat --spawn --replace, which opens the
# successor in a new tmux window and then closes this session's pane. Outside
# tmux there is no window to open, so it only tells the user.
#
# Stop is a turn boundary, but a turn can still end mid-rebase or mid-merge
# (a conflict waiting on the user). Handing off there strands the operation,
# so the hook stays quiet without marking and checks again at the next stop.
#
# Stop-hook input has no context data, so statusline-command.sh writes the
# used % to $CTX_STATE_DIR/ctx-<session_id> on every render; this reads it.
# Kill switch: ~/.claude/hooks/.no-ctx-handoff-nudge
source "$HOME/.claude/hooks/scripts/common.sh"

check_disabled
require_jq
read_input

THRESHOLD="${CTX_NUDGE_USED:-25}"
STATE_DIR="${CTX_STATE_DIR:-$HOOKS_DIR/state}"

session_id=$(echo "$INPUT" | jq -r '.session_id // empty')
[[ -n "$session_id" ]] || exit 0
# A stop already continued by a Stop hook: blocking again would loop.
[[ "$(echo "$INPUT" | jq -r '.stop_hook_active // false')" == true ]] && exit 0

state_file="$STATE_DIR/ctx-$session_id"
marker="$STATE_DIR/ctx-nudged-$session_id"
[[ -f "$state_file" ]] || exit 0
[[ -f "$marker" ]] && exit 0

used=$(head -1 "$state_file" 2>/dev/null | tr -d '[:space:]')
used=${used%.*}                          # 25.4 -> 25
[[ "$used" =~ ^[0-9]+$ ]] || exit 0      # garbage -> silent
(( used >= THRESHOLD )) || exit 0

cwd=$(echo "$INPUT" | jq -r '.cwd // empty')
if [[ -n "$cwd" ]] && git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1; then
  for p in rebase-merge rebase-apply MERGE_HEAD; do
    [[ -e "$(git -C "$cwd" rev-parse --git-path "$p" 2>/dev/null)" ]] && exit 0
  done
fi

touch "$marker"
# Opportunistic cleanup of stale session state (>7 days)
find "$STATE_DIR" -name 'ctx-*' -mtime +7 -delete 2>/dev/null || true

if [[ -n "${TMUX:-}" ]]; then
  jq -n --arg used "$used" --arg t "$THRESHOLD" '{
    decision: "block",
    reason: ("Context " + $used + "% used (handoff at " + $t + "%). Hand this work to a fresh session now: finish or checkpoint the current sub-task, then run /newchat --spawn --replace \"continue: <the current task>\". If a background task (a review, a build, a test run) is still running, wait for it to finish first."),
    systemMessage: ("Context " + $used + "% used — handoff to a new session via /newchat --spawn --replace.")
  }'
else
  jq -n --arg m "⚠ Context ${used}% used (handoff at ${THRESHOLD}%) — run /newchat --spawn before restarting." \
    '{systemMessage: $m}'
fi
