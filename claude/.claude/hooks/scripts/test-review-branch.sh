#!/usr/bin/env bash
# Runs review-branch.sh end to end in a throwaway repo under a fake HOME, with
# fake claude and codex CLIs on PATH that script each review's output and
# timing, so two reviews of one worktree can be made to overlap on purpose.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
RB="$HERE/review-branch.sh"
T=$(mktemp -d)
export HOME="$T/home"; mkdir -p "$HOME"
export TMPDIR="$T/tmp"; mkdir -p "$TMPDIR"
unset CLAUDE_CODE_SESSION_ID CLAUDE_REVIEW_ACCEPT CLAUDE_REVIEW_ENGINE

R="$T/repo"
git init -q -b main "$R"
gc() { git -C "$R" -c user.email=t@t -c user.name=t "$@"; }
gc commit -q --allow-empty -m init
gc switch -q -c feat/x
echo x > "$R/x.txt"; gc add x.txt; gc commit -q -m "add x"

repokey=$(printf '%s' "$(git -C "$R" rev-parse --show-toplevel)" | shasum -a 256 | awk '{print $1}')
trap 'rm -rf "$T" "/tmp/claude-review-branch-$repokey.log"' EXIT
state="$HOME/.claude/hooks/state"

# FAKE_VERDICT is the review's last line. FAKE_STARTED is touched once the
# review is partway out; FAKE_HOLD holds the rest back until that file exists.
# FAKE_PAD sizes the first assistant line, so a review that overlaps another
# can be made longer than it: equal lengths would overwrite byte for byte and
# hide a shared file.
mkdir -p "$T/bin"
cat > "$T/bin/claude" <<'EOF'
#!/usr/bin/env bash
echo '{"type":"system","subtype":"init","model":"fake"}'
jq -nc --arg t "$(head -c "${FAKE_PAD:-10}" /dev/zero | tr '\0' a)" '{type:"assistant",message:{content:[{type:"text",text:$t}]}}'
[[ -n "${FAKE_STARTED:-}" ]] && touch "$FAKE_STARTED"
[[ -n "${FAKE_HOLD:-}" ]] && until [[ -e "$FAKE_HOLD" ]]; do sleep 0.05; done
jq -nc --arg r "$(printf '## Findings\nnone\n\nVERDICT: %s' "$FAKE_VERDICT")" '{type:"result",result:$r}'
EOF
cat > "$T/bin/codex" <<'EOF'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do [[ "$1" == -o ]] && { out="$2"; shift; }; shift; done
echo '{"type":"thread.started","thread_id":"fake"}'
printf '## Findings\nnone\n\nVERDICT: %s\n' "$FAKE_VERDICT" > "$out"
[[ -n "${FAKE_STARTED:-}" ]] && touch "$FAKE_STARTED"
[[ -n "${FAKE_HOLD:-}" ]] && until [[ -e "$FAKE_HOLD" ]]; do sleep 0.05; done
echo '{"type":"turn.completed","usage":{}}'
EOF
chmod +x "$T/bin/claude" "$T/bin/codex"
export PATH="$T/bin:$PATH"

pass=0; fail=0
check() { # $1=desc $2=got $3=want
  if [[ "$2" == "$3" ]]; then pass=$((pass+1)); echo "PASS: $1"
  else fail=$((fail+1)); echo "FAIL: $1 — expected $3, got $2"; fi
}
await() { local i; for ((i=0;i<400;i++)); do [[ -e "$1" ]] && return 0; sleep 0.05; done; return 1; }
review() { # $1=engine $2=log name; FAKE_* from the caller's environment
  "$RB" "$R" --base main --engine "$1" --effort high >"$T/$2.log" 2>&1
}
sentinel_present() { ls "$state"/review-ok-branch-* >/dev/null 2>&1 && echo yes || echo no; }
reset() { rm -rf "$state" "$T"/started "$T"/released; }

reset
FAKE_VERDICT=PASS review claude lone; check "a lone PASS review exits 0" $? 0
check "a lone PASS review writes the sentinel" "$(sentinel_present)" yes

# The second review starts while the first is still streaming and finishes
# before it; the first must still read its own stream and its own verdict.
for engine in claude codex; do
  reset
  FAKE_VERDICT=PASS FAKE_PAD=20000 FAKE_STARTED="$T/started" FAKE_HOLD="$T/released" review "$engine" first & first=$!
  await "$T/started" || { echo "FAIL: $engine first review never started"; exit 1; }
  FAKE_VERDICT=FAIL review "$engine" second; second=$?
  touch "$T/released"; wait "$first"; first=$?
  check "$engine: a review overlapping another on one worktree keeps its own PASS" "$first" 0
  check "$engine: the overlapping review keeps its own FAIL" "$second" 2
  check "$engine: the PASS of the overlapped review writes the sentinel" "$(sentinel_present)" yes
done

check "finished reviews leave no per-run scratch behind" "$(find "$TMPDIR" -mindepth 1 | wc -l | tr -d ' ')" 0

echo "---"; echo "$pass passed, $fail failed"; exit $((fail > 0))
