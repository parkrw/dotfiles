#!/usr/bin/env bash
# outcome-assert-gate.sh — PreToolUse(Edit|Write|MultiEdit). Denies call-shape
# assertions, mock frameworks, and skipped tests in lines being added to a test
# file. Syntactic only: hand-rolled fakes and Bash-written files pass through
# to the review gate (review-branch.sh), which judges meaning.
#
# Fails OPEN: a lint, not a permission gate.
# Kill switch: touch ~/.claude/hooks/.no-outcome-assert-gate
# Per repo, where the repo's own test conventions win: list its main checkout
# in ~/.claude/hooks/outcome-assert-off-repos, one absolute path per line.
source "$HOME/.claude/hooks/scripts/common.sh"

OFF_REPOS="$HOOKS_DIR/outcome-assert-off-repos"

check_disabled
require_jq
read_input

path=$(jq -r '.tool_input.file_path // ""' <<<"$INPUT")
case "$path" in
  *_test.go|*.test.[jt]s|*.test.[jt]sx|*.spec.[jt]s|*.spec.[jt]sx|*/test_*.py|*_test.py|*_spec.rb) ;;
  *) exit 0 ;;
esac

dir=$(dirname "$path")
while [[ ! -d "$dir" ]]; do dir=$(dirname "$dir"); done

# Keyed on the main checkout of the file's repo, so linked worktrees share the
# opt-out and the session's cwd does not decide it.
if [[ -f "$OFF_REPOS" ]] && common=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
  grep -Fxq "$(cd "$(dirname "$common")" && pwd -P)" "$OFF_REPOS" && exit 0
fi

# Edit's new_string repeats its old_string anchor and Write resends the whole
# file. A line already in the file or in HEAD is legacy, so re-anchoring or
# moving it across edits must not block; only lines new to both are judged.
# Compared trimmed, so wrapping a legacy line in a new block re-indents it
# without making it new.
trim() { sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'; }
proposed=$(jq -r '.tool_input.content // empty, ((.tool_input.edits // [.tool_input | select(.new_string)])[] | .new_string)' <<<"$INPUT" | trim)
legacy() {
  jq -r '(.tool_input.edits // [.tool_input])[] | .old_string // empty' <<<"$INPUT"
  [[ -f "$path" ]] && cat "$path"
  git -C "$(dirname "$path")" show "HEAD:./$(basename "$path")" 2>/dev/null || true
}
added=$(grep -vxFf <(legacy | trim) <<<"$proposed" || true)

pat='toHaveBeenCalled|toBeCalled|calledWith|calledOnce|callCount|call_count|assert_called|assert_has_calls|assert_not_called|AssertCalled|AssertNumberOfCalls|AssertExpectations|\.EXPECT\(\)|\.Times\(|to receive\(|have_received|(jest|vi)\.(fn|mock|spyOn)|sinon\.|MagicMock|mock\.patch|@patch|(^|[^[:alnum:]_])(it|test|describe)\.skip|(^|[^[:alnum:]_])x(it|describe|test)\(|pytest\.mark\.skip|unittest\.skip|(^|[^[:alnum:]_])[tb]\.Skip(f|Now)?\('
hits=$(grep -E "$pat" <<<"$added" || true)
[[ -z "$hits" ]] && exit 0

{
  echo "Test standard: assert observable outcomes (results, return codes, emitted output, side effects), not call shape. No mock that neuters the path under test; inject a seam and assert the result. No skip: fix or delete."
  echo "$hits"
} >&2
exit 2
