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

if [[ -f "$OFF_REPOS" ]]; then
  cwd=$(jq -r '.cwd // ""' <<<"$INPUT"); [[ -z "$cwd" ]] && cwd=$PWD
  # Keyed on the main checkout so linked worktrees share the opt-out.
  if common=$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
    grep -Fxq "$(cd "$(dirname "$common")" && pwd -P)" "$OFF_REPOS" && exit 0
  fi
fi

# Edit's new_string repeats its old_string anchor lines and Write resends the
# whole file, so subtract what is already there: legacy lines must not block.
added=$(jq -r '(.tool_input.edits // [.tool_input | select(.new_string)])[] | ((.new_string | split("\n")) - ((.old_string // "") | split("\n")))[]' <<<"$INPUT")
content=$(jq -r '.tool_input.content // ""' <<<"$INPUT")
if [[ -n "$content" ]]; then
  [[ -f "$path" ]] && content=$(grep -vxFf "$path" <<<"$content" || true)
  added+=$'\n'"$content"
fi

pat='toHaveBeenCalled|toBeCalled|calledWith|calledOnce|callCount|call_count|assert_called|assert_has_calls|assert_not_called|AssertCalled|AssertNumberOfCalls|AssertExpectations|\.EXPECT\(\)|\.Times\(|to receive\(|have_received|(jest|vi)\.(fn|mock|spyOn)|sinon\.|MagicMock|mock\.patch|@patch|(^|[^[:alnum:]_])(it|test|describe)\.skip|(^|[^[:alnum:]_])x(it|describe|test)\(|pytest\.mark\.skip|unittest\.skip|t\.Skip\('
hits=$(grep -E "$pat" <<<"$added" || true)
[[ -z "$hits" ]] && exit 0

{
  echo "Test standard: assert observable outcomes (results, return codes, emitted output, side effects), not call shape. No mock that neuters the path under test; inject a seam and assert the result. No skip: fix or delete."
  echo "$hits"
} >&2
exit 2
