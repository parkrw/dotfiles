#!/usr/bin/env bash
# outcome-assert-gate.sh — PreToolUse(Edit|Write|MultiEdit). Denies call-shape
# assertions, mock frameworks, and skipped tests in text being added to a test
# file. Syntactic only: hand-rolled fakes and Bash-written files pass through
# to the review gate (review-branch.sh), which judges meaning.
#
# Fails OPEN: a lint, not a permission gate.
# Kill switch: touch ~/.claude/hooks/.no-outcome-assert-gate
source "$HOME/.claude/hooks/scripts/common.sh"

check_disabled
require_jq
read_input

path=$(jq -r '.tool_input.file_path // ""' <<<"$INPUT")
case "$path" in
  *_test.go|*.test.[jt]s|*.test.[jt]sx|*.spec.[jt]s|*.spec.[jt]sx|*/test_*.py|*_test.py|*_spec.rb) ;;
  *) exit 0 ;;
esac

# Only added text, so legacy tests don't block unrelated edits.
added=$(jq -r '[.tool_input.content, .tool_input.new_string, (.tool_input.edits[]?.new_string)] | map(select(.)) | join("\n")' <<<"$INPUT")

pat='toHaveBeenCalled|toBeCalled|calledWith|calledOnce|callCount|call_count|assert_called|assert_has_calls|assert_not_called|AssertCalled|AssertNumberOfCalls|AssertExpectations|\.EXPECT\(\)|\.Times\(|to receive\(|have_received|(jest|vi)\.(fn|mock|spyOn)|sinon\.|MagicMock|mock\.patch|@patch|(it|test|describe)\.skip|(^|[^[:alnum:]_])x(it|describe|test)\(|pytest\.mark\.skip|unittest\.skip|t\.Skip\('
hits=$(grep -nE "$pat" <<<"$added" || true)
[[ -z "$hits" ]] && exit 0

{
  echo "Test standard: assert observable outcomes (results, return codes, emitted output, side effects), not call shape. No mock that neuters the path under test; inject a seam and assert the result. No skip: fix or delete."
  echo "$hits"
} >&2
exit 2
