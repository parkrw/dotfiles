#!/usr/bin/env bash
# Pipe-test suite for ~/.claude/hooks/scripts/ctx-handoff-nudge.sh
# State files hold context USED %; nudge fires at used >= threshold (default 25).
# Uses a temp CTX_STATE_DIR so the real state dir is untouched.
set -u
HOOK="$HOME/.claude/hooks/scripts/ctx-handoff-nudge.sh"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export CTX_STATE_DIR="$T"

pass=0; fail=0
check() { # $1=desc $2=session_id $3=expected (nudge|silent)
  out=$(jq -n --arg s "$2" '{session_id:$s,hook_event_name:"Stop"}' | "$HOOK")
  got="silent"
  [[ -n "$out" ]] && [[ "$(echo "$out" | jq -r '.systemMessage // empty' 2>/dev/null)" == *handoff* ]] && got="nudge"
  if [[ "$got" == "$3" ]]; then pass=$((pass+1)); echo "PASS: $1"
  else fail=$((fail+1)); echo "FAIL: $1 — expected $3, got $got (out: $out)"; fi
}

check "no state file -> silent"            "s-none"  silent

echo 5 > "$T/ctx-s-low"
check "used 5 -> silent"                   "s-low"   silent

echo 25 > "$T/ctx-s-edge"
check "used 25 (boundary) -> nudge"        "s-edge"  nudge
check "same session again -> debounced"    "s-edge"  silent

echo 88 > "$T/ctx-s-high"
check "used 88, new session -> nudge"      "s-high"  nudge

echo garbage > "$T/ctx-s-bad"
check "garbage state -> silent, no crash"  "s-bad"   silent

echo 25.4 > "$T/ctx-s-frac"
check "fractional used 25.4 -> nudge"      "s-frac"  nudge

echo 24.9 > "$T/ctx-s-under"
check "used 24.9 -> silent"                "s-under" silent

echo "---"
echo "$pass passed, $fail failed"
exit $((fail > 0))
