#!/usr/bin/env bash
# review-branch.sh <checkout-path> — adversarial fresh-context review of a
# branch's PR diff (<base>...HEAD) via a headless agent CLI: `claude -p` by
# default, `codex exec` with --engine codex. The sole writer of a review
# approval, consumed by pre-push's review_gate().
#
# Why the branch diff and not the staged diff: a squash-merged PR lands as one
# commit, so the branch diff IS the artifact that ships. Reviewing per commit
# charges N reviews for a change that merges as one, and never sees the final
# shape — a bug introduced in an early commit and fixed in a later one still
# fails a per-commit review, and a bug that only emerges from two commits
# together passes every one of them.
#
# The sentinel is named for the sha256 of the diff itself, with no repo or
# worktree path in the key. Three consequences, all deliberate:
#   - Two worktrees of one repo hold independent approvals, so concurrent
#     `/cycle --spawn` workers each carry their own review, and an approval
#     earned in a linked worktree is found from anywhere.
#   - A new commit, a rebase, or an amend changes the diff and therefore the
#     hash, so the approval expires on its own with nothing to invalidate.
#   - Re-reviewing an unchanged branch is free: the sentinel is already there.
#
# On VERDICT: PASS it writes the sentinel pre-push checks, so the authoring
# session never writes its own approval. Fail-closed: a missing or garbled
# verdict counts as FAIL.
#
# Reviewer model, claude engine: opus by default. The alias tracks the newest
# Opus, so a sonnet, opus-4.6, or opus-4.8 author all draw the same top-tier
# reviewer instead of one weaker than themselves. --model <name> or
# CLAUDE_REVIEW_MODEL overrides.
# Reviewer model, codex engine: gpt-5.5, pinned for the same reason as opus —
# a review must not weaken because a config was retuned for other work. Not
# gpt-5.5-codex: a ChatGPT-account login is refused that model outright.
# --model <name> or CODEX_REVIEW_MODEL overrides.
# Reviewer effort: one level above the author's (low→medium→high→xhigh),
# capped at xhigh — never max. --bump doubles the step (+2 instead of +1). Both
# CLIs take the same ladder, so the level crosses engines unchanged.
#
# A second engine is worth the branching because the two fail differently: a
# reviewer sharing the author's model and training shares its blind spots, and
# the whole point of this gate is a reader that is not the author.
set -euo pipefail

# ---- pure helpers (unit-tested via REVIEW_BRANCH_LIB_ONLY) ----
auto_effort() {  # author effort -> one level above, capped at xhigh ("" if unknown)
  case "$1" in
    low)    echo medium ;;
    medium) echo high ;;
    high)   echo xhigh ;;
    xhigh)  echo xhigh ;;
    max)    echo xhigh ;;
    *)      echo "" ;;
  esac
}
# branch_diff <worktree> <base> <tip> — the exact diff pre-push hashes. Both
# sides MUST build the string byte-for-byte identically or no sentinel is ever
# found and every push blocks, so this is the single definition and the hook
# mirrors it flag-for-flag.
#
# Every rendering knob is pinned because the hash is over rendered diff text,
# not over tree content. Unpinned, a user's own git config decides the bytes:
# core.abbrev alone rewrites the `index abc..def` line, so a review run under
# one config and a push under another disagree and the approval evaporates
# with nothing on screen to explain it.
branch_diff() {
  git -C "$1" \
    -c core.abbrev=40 \
    -c diff.algorithm=myers \
    -c diff.renames=true \
    -c diff.noprefix=false \
    -c diff.mnemonicPrefix=false \
    diff --no-color --no-ext-diff --no-textconv --unified=3 "$2...$3"
}
[[ -n "${REVIEW_BRANCH_LIB_ONLY:-}" ]] && return 0

repo=""
cli_model=""   # --model <m>: explicit reviewer model (highest precedence)
cli_base=""    # --base <ref>: override the resolved default branch
bump=""        # --bump: double the effort step (+2 instead of +1)
dry_run=""     # --dry-run: print base/tip/hash/sentinel and stop
engine="${CLAUDE_REVIEW_ENGINE:-claude}"  # --engine: which CLI reviews
while [[ $# -gt 0 ]]; do
  case "$1" in
    --engine)  engine="${2:?--engine needs a value}"; shift 2 ;;
    --engine=*) engine="${1#--engine=}"; shift ;;
    --model)   cli_model="${2:?--model needs a value}"; shift 2 ;;
    --model=*) cli_model="${1#--model=}"; shift ;;
    --base)    cli_base="${2:?--base needs a value}"; shift 2 ;;
    --base=*)  cli_base="${1#--base=}"; shift ;;
    --bump)    bump=1; shift ;;
    --dry-run) dry_run=1; shift ;;
    --)        shift; break ;;
    -*)        echo "review-branch: unknown flag $1" >&2; exit 1 ;;
    *)         [[ -z "$repo" ]] || { echo "review-branch: unexpected arg $1" >&2; exit 1; }
               repo="$1"; shift ;;
  esac
done
[[ -n "$repo" ]] || { echo "usage: review-branch.sh <checkout-path> [--engine claude|codex] [--base <ref>] [--model <model>] [--bump] [--dry-run]" >&2; exit 1; }

case "$engine" in
  claude|codex) ;;
  *) echo "review-branch: unknown engine '$engine' — claude or codex" >&2; exit 1 ;;
esac
command -v "$engine" >/dev/null 2>&1 ||
  { echo "review-branch: '$engine' is not installed or not on PATH" >&2; exit 1; }

worktree=$(git -C "$repo" rev-parse --show-toplevel)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/pr-size-lib.sh"

base=$(resolve_base "$worktree" "$cli_base")
[[ -n "$base" ]] || { echo "review-branch: cannot resolve a default branch in $worktree — pass --base <ref>" >&2; exit 1; }
git -C "$worktree" rev-parse --verify --quiet "$base" >/dev/null 2>&1 ||
  { echo "review-branch: base '$base' does not exist in $worktree" >&2; exit 1; }

tip=$(git -C "$worktree" rev-parse HEAD)
hash=$(branch_diff "$worktree" "$base" "$tip" | shasum -a 256 | awk '{print $1}')
empty=$(printf '' | shasum -a 256 | awk '{print $1}')
[[ "$hash" == "$empty" ]] && { echo "review-branch: $base...HEAD is empty in $worktree — nothing to review" >&2; exit 1; }

# Reported in the status line and --dry-run so the size of what is being
# reviewed is visible. Neither value routes the model: the reviewer is opus for
# every diff, because a small diff is not a shallow one.
branch_lines=$(net_changed_lines "$worktree" "$base")
docs_only=1
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  case "$f" in
    *.md|*.txt|*.rst|*.adoc|docs/*|README*|CHANGELOG*|LICENSE*|CONTRIBUTING*) ;;
    *) docs_only=0; break ;;
  esac
done < <(git -C "$worktree" diff --name-only "$base...$tip")

state="$HOME/.claude/hooks/state"; mkdir -p "$state"
# Content-keyed: the approval belongs to the diff, not to a checkout path.
sentinel="$state/review-ok-branch-$hash"
# Report, live log, and per-engine scratch stay path-keyed so a repo has one
# readable latest report.
repokey=$(printf '%s' "$worktree" | shasum -a 256 | awk '{print $1}')
report="$state/review-branch-$repokey.md"
live="/tmp/claude-review-branch-$repokey.log"
stream="$state/review-branch-$repokey.stream.jsonl"
codex_last="$state/review-branch-$repokey.last"

if [[ -n "$dry_run" ]]; then
  printf 'worktree=%s\nbase=%s\ntip=%s\ndiff=%s\nsentinel=%s\nlines=%s\ndocs_only=%s\nengine=%s\n' \
    "$worktree" "$base" "$tip" "$hash" "$sentinel" "$branch_lines" "$docs_only" "$engine"
  exit 0
fi

: > "$live"
echo "review-branch: live log: $live" >&2

prompt='You are a senior reviewer. Review the branch diff that a pull request
would show: `git diff '"$base"'...HEAD`. Work through this scope in order — a
reviewer who just "reviews the code" returns style notes and misses the
contract breaks.

- Correctness. Every finding carries a concrete failure: the input or state
  that produces a wrong result, a crash, or a hang. No scenario, no finding.
- Security, data integrity, reliability. Injection; secrets or tokens in the
  diff; widened permissions; a bypassed gate (--no-verify, a repo-local
  core.hooksPath, a hand-written marker). Lost or double-applied writes, and
  partial failure that leaves inconsistent state. Races, unbounded retries,
  missing timeouts.
- Repo rules. Read this repo'\''s CLAUDE.md/AGENTS.md and the docs whose trigger
  matches the diff, then judge the diff against those — not against generic
  best practice.
- Patterns and style. Match the surrounding code and each file'\''s own
  prevailing convention: naming, error handling, comment policy, prose wrap.
- Tests. Changed behaviour with no test is a finding. Judge by READING the test
  files. A stub that neuters the path under test is a finding too, because it
  turns a green suite into no coverage.
- CI. READ the workflows, Makefile, or hook config and judge whether the diff
  clears each job. NEVER run CI, a test suite, a linter, or a formatter — you
  read, the author runs. Say so plainly when the repo has no CI.
- Docs. A limit, flag, or behaviour stated in two places where only one moved
  is a finding.

Budget: at most 25 tool calls. At 20, stop and report. Over-budget is worse
than incomplete.

ACCEPTED_RISKS_PLACEHOLDER

Output exactly this shape:
## Findings
path:line — blocker|major|minor — defect (most severe first; "none" if none)
  Evidence: quoted text or command output
  Effect: the concrete failure
## Unverified
(plain statements, or "none")
VERDICT: PASS
(or VERDICT: FAIL — the verdict is the last line, nothing after it)'

# Accepted risks: the author can list known design decisions that the reviewer
# should note in Unverified but not count toward FAIL.
accept_file="${CLAUDE_REVIEW_ACCEPT:-}"
accept_section=""
if [[ -f "$accept_file" ]]; then
  accept_section="Accepted risks (the author has acknowledged these — note them in Unverified,
do NOT count them toward the verdict):
$(cat "$accept_file")"
  echo "review-branch: loaded accepted risks from $accept_file" >&2
fi
prompt="${prompt/ACCEPTED_RISKS_PLACEHOLDER/$accept_section}"

# Detect the author's model and effort from the session transcript (best-effort).
caller_model=""
caller_effort=""
if [[ -n "${CLAUDE_CODE_SESSION_ID:-}" ]] && command -v jq >/dev/null 2>&1; then
  # || true: under pipefail a missing projects dir makes find exit 1, which
  # set -e turns into a silent death with no verdict and no report. Author
  # detection is best-effort — not finding a transcript must not end the review.
  tp=$(find "$HOME/.claude/projects" -name "${CLAUDE_CODE_SESSION_ID}.jsonl" 2>/dev/null | head -1 || true)
  if [[ -n "$tp" ]]; then
    caller_model=$(jq -r 'select(.type=="assistant") | .message.model // empty' "$tp" 2>/dev/null | tail -1)
    caller_effort=$(jq -r 'select(.type=="system" and .subtype=="init") | .cliEffort // .effort // empty' "$tp" 2>/dev/null | tail -1)
  fi
fi

# Precedence, claude: --model > CLAUDE_REVIEW_MODEL > opus (default).
# Precedence, codex:  --model > CODEX_REVIEW_MODEL > gpt-5.5 (default).
# The two engines do not share a model namespace, so each carries its own env
# override; CLAUDE_REVIEW_MODEL=opus would be meaningless to codex.
if [[ -n "$cli_model" ]]; then
  review_model="$cli_model"
elif [[ "$engine" == codex ]]; then
  review_model="${CODEX_REVIEW_MODEL:-gpt-5.5}"
elif [[ -n "${CLAUDE_REVIEW_MODEL:-}" ]]; then
  review_model="$CLAUDE_REVIEW_MODEL"
else
  review_model=opus
fi

base_effort="${caller_effort:-medium}"
if [[ -n "$bump" ]]; then
  review_effort=$(auto_effort "$(auto_effort "$base_effort")")
else
  review_effort=$(auto_effort "$base_effort")
fi

echo "review-branch: author='${caller_model:-?}' effort='${caller_effort:-? (defaulting to medium)}' engine='$engine' reviewer='${review_model:-<codex config default>}' review_effort='$review_effort' base=$base ${branch_lines}L docs_only=$docs_only" >&2

# fable falls back to opus when unavailable rather than erroring out (which
# under set -e would kill the review and block the push).
review_fallback=""
[[ "$review_model" == "fable" ]] && review_fallback="opus"

# </dev/null on both: the prompt is passed as an arg, so neither CLI needs
# stdin. Left open (as under Claude's Bash tool, where fd0 is a non-EOF pipe)
# the child blocks on a stdin read forever — codex even announces "Reading
# additional input from stdin..." and then hangs with no further output.
run_review_claude() {
  cd "$worktree" && claude -p "$prompt" \
    ${review_model:+--model "$review_model"} \
    ${review_effort:+--effort "$review_effort"} \
    ${review_fallback:+--fallback-model "$review_fallback"} \
    "$@" \
    --allowedTools "Read" "Grep" "Glob" "Bash(git diff:*)" "Bash(git log:*)" "Bash(git show:*)" "Bash(git status:*)" \
    </dev/null
}

# -s read-only is the analogue of the claude side's tool allowlist, and the two
# are strict in opposite directions: codex may run any command, but the OS
# sandbox denies every write, so the reviewer cannot edit the tree it judges.
# -o is codex's documented final-message file. The JSONL stream carries the
# same text, but only -o is a contract, so the verdict is read from there.
run_review_codex() {
  : > "$codex_last"
  codex exec "$prompt" \
    -C "$worktree" \
    -s read-only \
    ${review_model:+-m "$review_model"} \
    ${review_effort:+-c model_reasoning_effort="$review_effort"} \
    -o "$codex_last" \
    "$@" \
    </dev/null
}

# The streaming output is the SAME generation as the default — rendering each
# event as a terse step line costs no extra tokens, it just unbuffers what the
# CLIs otherwise withhold until the end. No jq -> blocking capture, no live
# steps. An empty or garbled capture needs no special case: it carries no
# VERDICT line, and the verdict check below fails closed on that.
if command -v jq >/dev/null 2>&1; then
  set +e
  if [[ "$engine" == codex ]]; then
    run_review_codex --json \
      | tee "$stream" \
      | jq -rj --unbuffered '
          if .type=="thread.started" then "▶ reviewing branch (codex)\n"
          elif .type=="item.started" and .item.type=="command_execution" then
            "  → \(.item.command | gsub("\\s+";" ") | .[0:100])\n"
          elif .type=="item.completed" and .item.type=="agent_message" then
            "  ✎ \(.item.text | gsub("\\s+";" ") | .[0:100])\n"
          elif .type=="turn.completed" then "◀ review complete\n"
          else empty end' \
      | tee -a "$live" >&2
    cstat=${PIPESTATUS[0]}
  else
    run_review_claude --output-format stream-json --verbose \
      | tee "$stream" \
      | jq -rj --unbuffered '
          if .type=="system" and .subtype=="init" then
            "▶ reviewing branch (model=\(.model // "?"))\n"
          elif .type=="assistant" then
            (.message.content[]? |
              if .type=="tool_use" then
                "  → \(.name) \(.input.file_path // .input.pattern // .input.command // .input.path // "")\n"
              elif .type=="text" and ((.text|length)>0) then
                "  ✎ \(.text | gsub("\\s+";" ") | .[0:100])\n"
              else empty end)
          elif .type=="result" then "◀ review complete\n"
          else empty end' \
      | tee -a "$live" >&2
    cstat=${PIPESTATUS[0]}
  fi
  set -e
  [[ $cstat -eq 0 ]] || { echo "review-branch: $engine exited $cstat" >&2; exit "$cstat"; }
  if [[ "$engine" == codex ]]; then
    out=$(cat "$codex_last")
  else
    out=$(jq -r 'select(.type=="result") | .result // empty' "$stream")
  fi
elif [[ "$engine" == codex ]]; then
  run_review_codex >&2
  out=$(cat "$codex_last")
else
  out=$(run_review_claude)
fi

{ echo "# Branch review — $worktree"
  echo "- reviewed: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "- engine: $engine${review_model:+ ($review_model)}"
  echo "- base: $base"
  echo "- tip: $tip"
  echo "- diff sha256: $hash"
  [[ -n "$accept_section" ]] && printf '\n## Accepted risks (loaded from %s)\n%s\n' "$accept_file" "$accept_section"
  echo
  echo "$out"
} > "$report"

echo "$out"
echo
verdict=$(echo "$out" | grep -E '^VERDICT: (PASS|FAIL)[[:space:]]*$' | tail -1 || true)
failcount="$state/review-branch-fails-$repokey"
if [[ "$verdict" == "VERDICT: PASS" ]]; then
  printf '%s\n' "$hash" > "$sentinel"
  rm -f "$failcount"
  echo "review-branch: PASS — sentinel written; report: $report"
else
  cur_fails=0
  if [[ -f "$failcount" ]]; then
    saved_hash=$(sed -n '1p' "$failcount" 2>/dev/null)
    saved_count=$(sed -n '2p' "$failcount" 2>/dev/null)
    [[ "$saved_hash" == "$hash" ]] && cur_fails="${saved_count:-0}"
  fi
  printf '%s\n%s\n' "$hash" "$(( cur_fails + 1 ))" > "$failcount"
  echo "review-branch: FAIL ($(( cur_fails + 1 )) consecutive on this diff) — fix findings, commit, rerun. report: $report"
  exit 2
fi
