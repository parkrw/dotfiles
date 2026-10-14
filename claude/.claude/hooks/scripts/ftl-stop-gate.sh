#!/usr/bin/env bash
# ftl-stop-gate.sh — Stop. A turn of /ftl ship, ship --integrate or
# <task> --ship may end only where the skill lets it: handed off, stopped on
# one question, stopped with open findings listed, or waiting on its review.
# Any other stop means a step was skipped.
#
# Logs every judged stop to $HOOKS_DIR/logs/ftl-stop-gate.jsonl and tells the
# user what it would block. It blocks only once
# ~/.claude/hooks/.ftl-stop-gate-enforce exists, and then once per stop: a
# check Claude cannot satisfy (a review it was refused) must not hold the
# turn open for the harness's eight continuations.
#
# The mode comes from ftl-mode.sh. A hand-off that passes clears it, so the
# session's later turns are not judged as ship turns.
# Kill switch: ~/.claude/hooks/.no-ftl-stop-gate
source "$HOME/.claude/hooks/scripts/common.sh"

check_disabled
require_jq
read_input

# session_id becomes a filename component — strip anything path-capable
session=$(jq -r '.session_id // ""' <<<"$INPUT")
session=${session//[^a-zA-Z0-9_-]/}
[[ -n "$session" ]] || exit 0
mode_file="$HOOKS_DIR/state/ftl-mode-$session"
[[ -f "$mode_file" ]] || exit 0
mode=$(head -1 "$mode_file")
case "$mode" in ship|integrate|task-ship) ;; *) exit 0 ;; esac

msg=$(jq -r '.last_assistant_message // ""' <<<"$INPUT")
cwd=$(jq -r '.cwd // ""' <<<"$INPUT")
continued=$(jq -r '.stop_hook_active // false' <<<"$INPUT")
scratch=$(jq -r '.scratchpad_dir // ""' <<<"$INPUT")
[[ -n "$scratch" ]] || scratch="${TMPDIR:-/tmp}"

wt=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true)
branch=$([[ -n "$wt" ]] && git -C "$wt" branch --show-current 2>/dev/null || true)

verdict="" escape="" failed=()
last_line=$(printf '%s\n' "$msg" | awk 'NF { l = $0 } END { print l }')

# Captured before grepping: under pipefail, grep -q exiting early SIGPIPEs the
# writer and the pipeline reads as no match.
reviews=$(pgrep -lf 'review-branch\.sh' 2>/dev/null || true)
question_re='\?[[:space:]*`]*$'
if [[ "$last_line" =~ $question_re ]]; then
  escape="question"
elif grep -qE '^[-*[:space:]]*`?[^[:space:]`]+:([0-9]+|\?)`? - ' <<<"$msg"; then
  escape="open findings"
elif [[ -n "$wt" ]] && grep -qF -- "review-branch.sh $wt" <<<"$reviews"; then
  escape="review running"
fi

if [[ -n "$escape" ]]; then
  verdict=escape
elif [[ -z "$wt" ]]; then
  verdict=fail
  failed+=("session cwd $cwd is not a git worktree; Ship works in its worktree")
else
  default=$(git -C "$wt" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || true)
  default=${default#origin/}
  if [[ -z "$default" ]]; then
    failed+=("origin/HEAD is unset; Ship step 2 prints git remote set-head origin -a")
  elif [[ -z "$branch" || "$branch" == "$default" ]]; then
    failed+=("on ${branch:-a detached HEAD}; Ship step 1 creates a worktree first")
  else
    [[ -z "$(git -C "$wt" status --porcelain 2>/dev/null)" ]] ||
      failed+=("uncommitted changes in $wt; every round commits before it reviews")
    bodies=$(git -C "$wt" log --format=%b "origin/$default..HEAD" 2>/dev/null || true)
    [[ -z "${bodies//[[:space:]]/}" ]] ||
      failed+=("a commit on $branch has a body or trailer; Check step 6 allows a subject only")
    sentinel=$("$HOOKS_DIR/scripts/review-branch.sh" "$wt" --dry-run 2>/dev/null | sed -n 's/^sentinel=//p' || true)
    [[ -n "$sentinel" && -f "$sentinel" ]] ||
      failed+=("no passing claude-review for this diff; Ship step 4 loops until Findings is none")
    compgen -G "$scratch/ftl-pr-body-*-${branch//\//-}.md" >/dev/null ||
      failed+=("no PR body at $scratch/ftl-pr-body-<repo>-${branch//\//-}.md; Ship step 5 writes it first")
  fi
  if ! grep -qE 'https://github\.com/[^[:space:]]+/pull/[0-9]+' <<<"$msg" &&
     ! { grep -qE '^cd /' <<<"$msg" && grep -qF 'git push -u origin' <<<"$msg"; }; then
    failed+=("the last message is neither a PR URL nor the cd/push hand-off block of Ship step 5")
  fi
  if (( ${#failed[@]} )); then verdict=fail; else verdict=pass; fi
fi

enforce=false
[[ -f "$HOOKS_DIR/.ftl-stop-gate-enforce" ]] && enforce=true

mkdir -p "$HOOKS_DIR/logs"
jq -nc --arg session "$session" --arg mode "$mode" --arg cwd "$cwd" --arg branch "$branch" \
  --arg verdict "$verdict" --arg escape "$escape" --argjson enforce "$enforce" \
  --argjson continued "$continued" \
  --args '{ts: (now | todate), session: $session, mode: $mode, cwd: $cwd, branch: $branch,
           verdict: $verdict, escape: $escape, failed: $ARGS.positional,
           enforce: $enforce, continued: $continued}' ${failed[@]+"${failed[@]}"} \
  >> "$HOOKS_DIR/logs/ftl-stop-gate.jsonl"

[[ "$verdict" == pass ]] && rm -f "$mode_file"
[[ "$verdict" == fail ]] || exit 0

reasons=$(printf -- '- %s\n' "${failed[@]}")
if [[ "$enforce" == true && "$continued" != true ]]; then
  jq -n --arg r "/ftl $mode is not done:
$reasons
Finish the step each line names, or end on one question or the open findings." \
    '{decision: "block", reason: $r}'
else
  how="log only"; [[ "$enforce" == true ]] && how="blocked once already"
  jq -n --arg m "ftl-stop-gate ($how): /ftl $mode is not done —
$reasons" '{systemMessage: $m}'
fi
