#!/usr/bin/env bash
# outcome-assert-gate.sh — PreToolUse(Edit|Write|MultiEdit). Denies call-shape
# assertions, mock frameworks, and skipped tests in lines being added to a test
# file. Syntactic only: hand-rolled fakes and Bash-written files pass through
# to the review gate (review-branch.sh), which judges meaning.
#
# Fails OPEN: a lint, not a permission gate.
# Kill switch: touch ~/.claude/hooks/.no-outcome-assert-gate
# Per repo, where the repo's own test conventions win: list its main checkout
# in ~/.claude/hooks/outcome-assert-off-repos, one absolute path per line;
# symlinked paths resolve.
source "$HOME/.claude/hooks/scripts/common.sh"

OFF_REPOS="$HOOKS_DIR/outcome-assert-off-repos"

check_disabled
require_jq
read_input

path=$(jq -r '.tool_input.file_path // ""' <<<"$INPUT")
# Basename, because a case glob's * also matches /: test_harness/app/retry.py
# would otherwise match test_*.py.
case "$(basename "$path")" in
  *_test.go) lang=go ;;
  *.test.[jt]s|*.test.[jt]sx|*.spec.[jt]s|*.spec.[jt]sx) lang=js ;;
  test_*.py|*_test.py) lang=py ;;
  *_spec.rb) lang=rb ;;
  *) exit 0 ;;
esac

dir=$(dirname "$path")
while [[ ! -d "$dir" ]]; do dir=$(dirname "$dir"); done

# Keyed on the main checkout of the file's repo, so linked worktrees share the
# opt-out and the session's cwd does not decide it. Both sides are resolved
# physically: on macOS /var and /tmp are symlinks into /private.
if [[ -f "$OFF_REPOS" ]] && common=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
  root=$(cd "$(dirname "$common")" && pwd -P)
  while IFS= read -r listed || [[ -n "$listed" ]]; do
    [[ -d "$listed" && "$(cd "$listed" && pwd -P)" == "$root" ]] && exit 0
  done < "$OFF_REPOS"
fi

# Edit's new_string repeats its old_string anchor and Write resends the whole
# file. A line already in the file or in HEAD is legacy, so re-anchoring or
# moving it across edits must not block; only lines new to both are judged.
# Compared with whitespace normalized, so re-indenting a legacy line into a new
# block, or gofmt realigning it, does not make it new.
normalize() { sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/[[:space:]]+/ /g'; }
proposed=$(jq -r '.tool_input.content // empty, ((.tool_input.edits // [.tool_input | select(.new_string)])[] | .new_string)' <<<"$INPUT" | normalize)
# old_string is not a source: a later MultiEdit anchor can be a line an earlier
# edit in the same call added.
legacy() {
  [[ -f "$path" ]] && cat "$path"
  git -C "$(dirname "$path")" show "HEAD:./$(basename "$path")" 2>/dev/null || true
}
# A hash set, not grep -f: grep's cost is proposed x legacy lines, which runs
# past the hook timeout on a Write of a few-thousand-line file. FILENAME, not
# NR==FNR, because an empty legacy stream would make every line look seen.
added=$(awk 'FILENAME == ARGV[1] { seen[$0]; next } !($0 in seen)' <(legacy | normalize) - <<<"$proposed")

# Call-shape and mock names are distinctive in any language. Skip forms are
# not (a Go `pending []string` field, a JS `{ pending: true }` state), so each
# is matched only in the language where it skips. ^ works: lines are trimmed.
pats=(
  'toHaveBeenCalled|toBeCalled|calledWith|calledOnce|callCount|call_count'
  'assert_called|assert_has_calls|assert_not_called'
  'AssertCalled|AssertNumberOfCalls|AssertExpectations|\.EXPECT\(\)|\.Times\('
  'to receive\(|have_received'
  '(jest|vi)\.(fn|mock|spyOn)|sinon\.|MagicMock|mock\.patch|@patch'
)
# A skip: option counts only with true or a string reason; skip: (page - 1) is
# pagination. Go's bare Skip( is a common method name (readers, scanners), so it
# counts only on a testing receiver; Skipf and SkipNow are testing's alone.
quote=$'[\'"`]'
case "$lang" in
  go) pats+=('\.Skip(f|Now)\(|((^|[^[:alnum:]_])(t|b|f|tb)|\.T\(\))\.Skip\(') ;;
  js) pats+=(
        '(^|[^[:alnum:]_])(it|test|describe)\.skip(\(|\.each)|(^|[^[:alnum:]_])x(it|describe|test)\('
        ',[[:space:]]*\{[[:space:]]*skip:[[:space:]]*(true|'"$quote"')'
      ) ;;
  py) pats+=('pytest\.(mark\.)?skip|unittest\.skip|skipTest\(') ;;
  rb) pats+=(
        '(^|[^[:alnum:]_])x(it|describe|context|specify)([[:space:]]|\()'
        '^(skip|pending)([[:space:]]+[^=[:space:]]|\(|$)'
        ',[[:space:]]*(skip|pending):[[:space:]]*(true|'"$quote"')'
      ) ;;
esac
pat=$(IFS='|'; echo "${pats[*]}")
hits=$(grep -E "$pat" <<<"$added" || true)
[[ -z "$hits" ]] && exit 0

{
  echo "Test standard: assert observable outcomes (results, return codes, emitted output, side effects), not call shape. No mock that neuters the path under test; inject a seam and assert the result. No skip: fix or delete."
  echo "$hits"
} >&2
exit 2
