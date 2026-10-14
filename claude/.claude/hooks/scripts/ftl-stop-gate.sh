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
# A run is the prompt that started it (ftl-mode.sh records its prompt_id),
# plus the next prompt after each wait the skill resumes from: a question,
# variants, an unblock command, a running review (whose completion arrives as
# a new prompt). The hand-off and the waits that end the run — a rebase or
# merge sequence for the human, open findings — clear the mode, and any other
# later prompt does too, so the session's later turns are not judged as ship
# turns. A prompt that changes the subject right after a resumable wait is
# judged once: the hook cannot tell it from an answer.
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
{ IFS= read -r mode; IFS= read -r owner; IFS= read -r resume; } < "$mode_file" || true
case "$mode" in ship|integrate|task-ship) ;; *) exit 0 ;; esac

prompt=$(jq -r '.prompt_id // ""' <<<"$INPUT")
if [[ -n "$prompt" && -n "$owner" && "$prompt" != "$owner" ]]; then
  [[ "$resume" == resume ]] || { rm -f "$mode_file"; exit 0; }
  owner=$prompt
fi

msg=$(jq -r '.last_assistant_message // ""' <<<"$INPUT")
cwd=$(jq -r '.cwd // ""' <<<"$INPUT")
continued=$(jq -r '.stop_hook_active // false' <<<"$INPUT")
transcript=$(jq -r '.transcript_path // ""' <<<"$INPUT")
background=$(jq -c '.background_tasks // []' <<<"$INPUT")

wt=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true)
branch=$([[ -n "$wt" ]] && git -C "$wt" branch --show-current 2>/dev/null || true)

# The body of the message's closing fenced block, if it ends on one.
closing_block=$(awk '
  /^[[:space:]]*```/ { if (inside) { inside = 0; last = buf; closed = NR } else { inside = 1; buf = "" } next }
  inside { buf = buf $0 "\n" }
  NF { tail = NR }
  END { if (closed && closed >= tail) printf "%s", last }' <<<"$msg")
last_line=$(awk 'NF { l = $0 } END { print l }' <<<"$msg")

# Ship step 5's two forms, and only those: a PR URL alone on its line, or a
# closing block that cds and pushes the branch. A URL cited mid-sentence or a
# force-with-lease for the human is not a hand-off.
handed_off=false
if grep -qE '^[[:space:]*_<`]*https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/pull/[0-9]+[>`*_]*[[:space:]]*$' <<<"$msg" ||
   { grep -qE '^[[:space:]]*cd /' <<<"$closing_block" && grep -qF 'git push -u origin' <<<"$closing_block"; }; then
  handed_off=true
fi

# Captured before grepping: under pipefail, grep -q exiting early SIGPIPEs the
# writer and the pipeline reads as no match.
# Each line gets a trailing space so a worktree path matches only as a whole
# argument: ../repo is a prefix of every sibling worktree ../repo-<name>.
reviews=$(pgrep -lf 'review-branch\.sh' 2>/dev/null | sed 's/$/ /' || true)
question_re='\?[[:space:]*`]*$'
escape="" resumes=false
if [[ "$last_line" =~ $question_re ]]; then
  escape="question" resumes=true
elif [[ -n "$closing_block" && "$handed_off" == false ]]; then
  escape="commands for the human"
  # Orient step 4's sequences (Ship step 2, an aborted conflict) end the run:
  # the human rebases or merges, then reruns /ftl ship. Step 3a's unblock
  # command resumes it.
  grep -qE '\bgit\b.*\b(rebase|merge)\b' <<<"$closing_block" || resumes=true
elif grep -qE 'https://claude\.ai/(code/)?artifact/' <<<"$msg"; then
  escape="variants" resumes=true
elif grep -qE '^[-*[:space:]]*`?[^[:space:]`]+:([0-9]+|\?)`? - ' <<<"$msg"; then
  escape="open findings"
elif { [[ -n "$wt" ]] && grep -qF -- "review-branch.sh $wt " <<<"$reviews"; } ||
     grep -qE 'claude-review|review-branch' <<<"$background"; then
  escape="review running" resumes=true
fi

# The PR body's directory is the session scratchpad, which Stop input does not
# name, so the body is found where Ship step 5 wrote it: a Write in the transcript.
# Matched by whole file name: by suffix, branch x would find feat-x's body.
# <repo> is the main checkout's name (Ship step 1's ../<repo>-<name>), or the
# worktree's own, should Claude read it that way.
body_written() {
  local slug="${branch//\//-}" common names=() name path
  common=$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
  [[ -n "$common" ]] && names+=("ftl-pr-body-$(basename "${common%/.git}")-$slug.md")
  names+=("ftl-pr-body-$(basename "$wt")-$slug.md")
  for name in "${names[@]}"; do
    [[ -f "${TMPDIR:-/tmp}/$name" ]] && return 0
  done
  [[ -f "$transcript" ]] || return 1
  while IFS= read -r path; do
    for name in "${names[@]}"; do
      [[ "${path##*/}" == "$name" && -f "$path" ]] && return 0
    done
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
    failed+=("the last message is neither the PR URL on its own line nor the cd/push hand-off block of Ship step 5")
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

if [[ "$handed_off" == true || "$verdict" == pass ]] || [[ "$verdict" == escape && "$resumes" == false ]]; then
  rm -f "$mode_file"
else
  # A fail keeps the run to this prompt, so an enforced block's continuation
  # is still judged; a resumable wait lets the next prompt continue it.
  printf '%s\n%s\n%s\n' "$mode" "$owner" "$([[ "$resumes" == true ]] && echo resume)" > "$mode_file"
fi
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
