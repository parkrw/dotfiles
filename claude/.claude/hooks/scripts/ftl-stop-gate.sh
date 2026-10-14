#!/usr/bin/env bash
# ftl-stop-gate.sh — Stop. A turn of /ftl ship, ship --integrate or
# <task> --ship may end only where the skill lets it: handed off, or at one of
# its stop-and-wait points — one question, commands printed for the human,
# variants to pick from, open findings listed, or a review still running.
# Any other stop means a step was skipped.
#
# Logs every judged stop to $HOOKS_DIR/logs/ftl-stop-gate.jsonl and tells the
# user what it would block. It blocks only once
# ~/.claude/hooks/.ftl-stop-gate-enforce exists, and then once per stop: a
# check Claude cannot satisfy (a review it was refused, or a failure stop such
# as SKILL.md's apply or pwd check, which reads like a skipped step) costs one
# continuation, not the harness's eight.
#
# The mode comes from ftl-mode.sh. A message that carries the hand-off clears
# it, whatever the verdict, so the session's later turns are not judged as
# ship turns.
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
transcript=$(jq -r '.transcript_path // ""' <<<"$INPUT")
background=$(jq -c '.background_tasks // []' <<<"$INPUT")

wt=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true)
branch=$([[ -n "$wt" ]] && git -C "$wt" branch --show-current 2>/dev/null || true)

handed_off=false
if grep -qE 'https://github\.com/[^[:space:]]+/pull/[0-9]+' <<<"$msg" ||
   { grep -qE '^cd /' <<<"$msg" && grep -qF 'git push -u origin' <<<"$msg"; }; then
  handed_off=true
fi

# The body of the message's closing fenced block, if it ends on one.
closing_block=$(awk '
  /^[[:space:]]*```/ { if (inside) { inside = 0; last = buf; closed = NR } else { inside = 1; buf = "" } next }
  inside { buf = buf $0 "\n" }
  NF { tail = NR }
  END { if (closed && closed >= tail) printf "%s", last }' <<<"$msg")
last_line=$(awk 'NF { l = $0 } END { print l }' <<<"$msg")

# Captured before grepping: under pipefail, grep -q exiting early SIGPIPEs the
# writer and the pipeline reads as no match.
reviews=$(pgrep -lf 'review-branch\.sh' 2>/dev/null || true)
question_re='\?[[:space:]*`]*$'
escape=""
if [[ "$last_line" =~ $question_re ]]; then
  escape="question"
elif [[ -n "$closing_block" ]] && ! grep -qF 'git push' <<<"$closing_block"; then
  escape="commands for the human"
elif grep -qE 'https://claude\.ai/(code/)?artifact/' <<<"$msg"; then
  escape="variants"
elif grep -qE '^[-*[:space:]]*`?[^[:space:]`]+:([0-9]+|\?)`? - ' <<<"$msg"; then
  escape="open findings"
elif { [[ -n "$wt" ]] && grep -qF -- "review-branch.sh $wt" <<<"$reviews"; } ||
     grep -qE 'claude-review|review-branch' <<<"$background"; then
  escape="review running"
fi

# The PR body's directory is the session scratchpad, which Stop input does not
# name, so the body is found where Ship step 5 wrote it: a Write in the transcript.
body_written() {
  local slug="${branch//\//-}" path
  compgen -G "${TMPDIR:-/tmp}/ftl-pr-body-*-$slug.md" >/dev/null && return 0
  [[ -f "$transcript" ]] || return 1
  while IFS= read -r path; do
    [[ "$path" == *"-$slug.md" && -f "$path" ]] && return 0
  done < <(grep -oE '"file_path":"[^"]*/ftl-pr-body-[^"]*\.md"' "$transcript" | sed 's/^"file_path":"//; s/"$//' | sort -u)
  return 1
}

failed=()
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
    body_written ||
      failed+=("no ftl-pr-body-<repo>-${branch//\//-}.md written; Ship step 5 writes the PR body first")
  fi
  [[ "$handed_off" == true ]] ||
    failed+=("the last message is neither a PR URL nor the cd/push hand-off block of Ship step 5")
  if (( ${#failed[@]} )); then verdict=fail; else verdict=pass; fi
fi

enforce=false
[[ -f "$HOOKS_DIR/.ftl-stop-gate-enforce" ]] && enforce=true

mkdir -p "$HOOKS_DIR/logs"
jq -nc --arg session "$session" --arg mode "$mode" --arg cwd "$cwd" --arg branch "$branch" \
  --arg verdict "$verdict" --arg escape "$escape" --argjson enforce "$enforce" \
  --argjson continued "$continued" --argjson handed_off "$handed_off" \
  --args '{ts: (now | todate), session: $session, mode: $mode, cwd: $cwd, branch: $branch,
           verdict: $verdict, escape: $escape, handed_off: $handed_off, failed: $ARGS.positional,
           enforce: $enforce, continued: $continued}' ${failed[@]+"${failed[@]}"} \
  >> "$HOOKS_DIR/logs/ftl-stop-gate.jsonl"

[[ "$handed_off" == true ]] && rm -f "$mode_file"
[[ "$verdict" == fail ]] || exit 0

reasons=$(printf -- '- %s\n' "${failed[@]}")
if [[ "$enforce" == true && "$continued" != true ]]; then
  jq -n --arg r "/ftl $mode is not done:
$reasons
Finish the step each line names, or stop where the skill says to wait: one question, the commands for the human, or the open findings." \
    '{decision: "block", reason: $r}'
else
  how="log only"; [[ "$enforce" == true ]] && how="blocked once already"
  jq -n --arg m "ftl-stop-gate ($how): /ftl $mode is not done —
$reasons" '{systemMessage: $m}'
fi
