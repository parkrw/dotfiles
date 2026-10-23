#!/usr/bin/env bash
# Pipe-test suite for tasklog and its cklog/vanlog names.
# Builds throwaway repos whose origins are fake CloudKey, vanillin and
# personal URLs; nothing is fetched. TASKLOG_DIR keeps the DBs in a temp dir.
set -u
BIN="${BIN:-$(cd "$(dirname "$0")" && pwd)}"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export TASKLOG_DIR="$T/db"
unset CLAUDE_CODE_SESSION_ID

mkrepo() { # $1=dir $2=origin url
  git init -q -b main "$1"
  git -C "$1" remote add origin "$2"
}
mkrepo "$T/core" https://github.com/CloudKey-io/core.git
mkrepo "$T/core-ssh" git@github.com:cloudkey-io/core
mkrepo "$T/van" https://github.com/parkrw/vanillin.git
mkrepo "$T/other" https://github.com/parkrw/gorag.git
git init -q -b main "$T/noorigin"

pass=0; fail=0
ok() { pass=$((pass+1)); echo "PASS: $1"; }
ko() { fail=$((fail+1)); echo "FAIL: $1 — $2"; }
# $1=desc $2=cwd $3=expected exit, then the command; stdout lands in $out
run() {
  local desc=$1 cwd=$2 want=$3; shift 3
  out=$(cd "$cwd" && "$@" 2>"$T/err"); local got=$?
  if [[ $got == "$want" ]]; then ok "$desc"; else ko "$desc" "exit $got, want $want: $(cat "$T/err")"; fi
}
sql() { # $1=db file $2=query — prints the first column of the first row
  node -e 'const { DatabaseSync } = require("node:sqlite");
    const row = new DatabaseSync(process.argv[1]).prepare(process.argv[2]).get();
    process.stdout.write(String(row && Object.values(row)[0]))' "$1" "$2"
}
has() { # $1=desc $2=needle — in the last run's stdout
  if [[ "$out" == *"$2"* ]]; then ok "$1"; else ko "$1" "missing [$2] in: $out"; fi
}

# The name guard, both ways
run "vanlog refuses in core"                 "$T/core"     2 "$BIN/vanlog" plan list
run "cklog refuses in vanillin"              "$T/van"      2 "$BIN/cklog" plan list
run "cklog refuses in a personal repo"       "$T/other"    2 "$BIN/cklog" plan list
run "tasklog refuses a repo no name owns"    "$T/other"    2 "$BIN/tasklog" plan list
run "tasklog refuses a repo with no origin"  "$T/noorigin" 2 "$BIN/tasklog" plan list
run "cklog runs in core"                     "$T/core"     0 "$BIN/cklog" plan list
run "vanlog runs in vanillin"                "$T/van"      0 "$BIN/vanlog" plan list
[[ -f "$TASKLOG_DIR/ck.db" && -f "$TASKLOG_DIR/van.db" ]] && ok "the names keep separate DBs" || ko "the names keep separate DBs" "$(ls "$TASKLOG_DIR")"

# Migration from an empty DB
got=$(sql "$TASKLOG_DIR/ck.db" "SELECT (SELECT user_version FROM pragma_user_version) || ' ' || (SELECT journal_mode FROM pragma_journal_mode) || ' ' || (SELECT group_concat(name) FROM (SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name))")
[[ $got == "1 wal decisions,events,flakes,plans,prs,suite_runs" ]] && ok "migrates a fresh DB to the current version" || ko "migrates a fresh DB to the current version" "$got"

# State round trip
run "plan add"                                "$T/core" 0 "$BIN/cklog" plan add platform-overview --path PLAN.md --title "Platform overview"
run "a second plan with the same slug fails"  "$T/core" 1 "$BIN/cklog" plan add platform-overview
run "state on an unknown plan fails"          "$T/core" 1 "$BIN/cklog" state nope P1 building
run "state rejects an unknown state"          "$T/core" 1 "$BIN/cklog" state platform-overview P1 done
run "state sets a row"                        "$T/core" 0 "$BIN/cklog" state platform-overview P5 building --branch overview-p5 --head abc123def456789 --subject "web: glance row"
run "state changes only what it names"        "$T/core" 0 "$BIN/cklog" state platform-overview P5 ready --pr 412
run "show reads the row back"                 "$T/core" 0 "$BIN/cklog" show --json platform-overview
row=$(jq -c '.[0] | [.code, .state, .pr, .branch, .head, .subject]' <<<"$out")
[[ $row == '["P5","ready",412,"overview-p5","abc123def456789","web: glance row"]' ]] && ok "the row keeps earlier fields" || ko "the row keeps earlier fields" "$row"
run "a worktree of core sees the same plan"   "$T/core-ssh" 0 "$BIN/cklog" show platform-overview
has "a worktree of core sees the same plan (row)" "overview-p5"
run "state writes state events"               "$T/core" 0 "$BIN/cklog" log platform-overview P5
has "the first state event names its fields"  "state  building branch=overview-p5 head=abc123def456789 subject=web: glance row"
has "the second state event names the PR"     "state  ready pr=412"
run "state merged"                            "$T/core" 0 "$BIN/cklog" state platform-overview P4 merged
run "show hides merged rows"                  "$T/core" 0 "$BIN/cklog" show
[[ "$out" != *P4* && "$out" == *P5* ]] && ok "show hides merged rows (rows)" || ko "show hides merged rows (rows)" "$out"
run "show --all lists merged rows"            "$T/core" 0 "$BIN/cklog" show --all
has "show --all lists merged rows (row)"      "P4"
run "plan list counts open rows"              "$T/core" 0 "$BIN/cklog" plan list
has "plan list counts open rows (count)"      "platform-overview  1"
run "log --since rejects a non-date"          "$T/core" 1 "$BIN/cklog" log platform-overview --since soon
run "log --since a future date is empty"      "$T/core" 0 "$BIN/cklog" log platform-overview --since 2999-01-01
[[ -z "$out" ]] && ok "log --since filters" || ko "log --since filters" "$out"

# Text from stdin passes through untouched
text=$'it\'s "done" — ran `git push origin main` && $(rm -rf /)\nsecond line'
out=$(cd "$T/core" && printf '%s' "$text" | "$BIN/cklog" event platform-overview P5 note - 2>&1) && ok "event reads stdin" || ko "event reads stdin" "$out"
got=$(sql "$TASKLOG_DIR/ck.db" "SELECT text FROM events WHERE kind = 'note'")
[[ "$got" == "$text" ]] && ok "stdin text lands byte for byte" || ko "stdin text lands byte for byte" "$got"
out=$(cd "$T/core" && printf 'keep "hide" off\n' | "$BIN/cklog" decide platform-overview - --by human --quote "don't hide it" 2>&1) && ok "decide reads stdin" || ko "decide reads stdin" "$out"
CLAUDE_CODE_SESSION_ID=sess-1 run "event records the session" "$T/core" 0 "$BIN/cklog" event platform-overview P5 review "round 1: 2 findings"
got=$(sql "$TASKLOG_DIR/ck.db" "SELECT session FROM events WHERE kind = 'review'")
[[ "$got" == sess-1 ]] && ok "the session id is stored" || ko "the session id is stored" "$got"

# 20 concurrent writers all land, against a DB none of them has opened yet
export TASKLOG_DIR="$T/db-race"
pids=()
for i in $(seq 1 20); do
  (cd "$T/core" && "$BIN/cklog" plan add "race-$i" >/dev/null 2>>"$T/race.err") & pids+=($!)
done
for p in "${pids[@]}"; do wait "$p"; done
pids=()
for i in $(seq 1 20); do
  (cd "$T/core" && "$BIN/cklog" event race-1 R1 tick "writer $i" 2>>"$T/race.err") & pids+=($!)
done
for p in "${pids[@]}"; do wait "$p"; done
run "concurrent writers" "$T/core" 0 "$BIN/cklog" plan list
n=$(grep -c '^race-' <<<"$out")
[[ $n == 20 ]] && ok "20 concurrent first runs all add their plan" || ko "20 concurrent first runs all add their plan" "$n plans; $(cat "$T/race.err")"
run "concurrent events" "$T/core" 0 "$BIN/cklog" log race-1
n=$(grep -c 'tick  writer' <<<"$out")
[[ $n == 20 ]] && ok "20 concurrent events all land" || ko "20 concurrent events all land" "$n events; $(cat "$T/race.err")"
export TASKLOG_DIR="$T/db"

# Flakes
run "flake add"                               "$T/core" 0 "$BIN/cklog" flake add "chart-math > pointGrid" "load-sensitive"
run "flake add a second"                      "$T/core" 0 "$BIN/cklog" flake add "panel-table padding"
run "flake match" "$T/core" 0 sh -c "printf '%s\n' 'packages/ui/test/chart-math.test.js > chart-math > pointGrid spreads points' 'apps/web/test/glance-row.test.jsx > renders' '' | '$BIN/cklog' flake match"
[[ "$out" == $'KNOWN packages/ui/test/chart-math.test.js > chart-math > pointGrid spreads points\nNEW apps/web/test/glance-row.test.jsx > renders' ]] && ok "flake match sorts KNOWN and NEW" || ko "flake match sorts KNOWN and NEW" "$out"
run "flake list"                              "$T/core" 0 "$BIN/cklog" flake list
has "a matched flake counts its sighting"     "chart-math > pointGrid  1"
has "an unmatched flake stays unseen"         "panel-table padding     0"
run "flakes belong to their repo"             "$T/van"  0 "$BIN/vanlog" flake list
[[ -z "$out" ]] && ok "flakes belong to their repo (empty)" || ko "flakes belong to their repo (empty)" "$out"
run "flake rm"                                "$T/core" 0 "$BIN/cklog" flake rm "panel-table padding"
run "flake rm of an unknown id fails"         "$T/core" 1 "$BIN/cklog" flake rm "panel-table padding"

# Brief
run "brief renders" "$T/core" 0 "$BIN/cklog" brief platform-overview P5
has "brief names the plan file"               "Plan: $(cd "$T/core" && pwd -P)/PLAN.md"
has "brief carries the PR row"                "- pr: 412"
has "brief carries the decision and quote"    $'keep "hide" off (human)\n  > don\'t hide it'
has "brief carries recent events"             "review: round 1: 2 findings"
has "brief carries the flakes"                '- `chart-math > pointGrid` — load-sensitive'
run "brief of a code with no row"             "$T/core" 0 "$BIN/cklog" brief platform-overview P9
has "brief says the row is missing"           "No row yet."

run "an unknown command fails"                "$T/core" 1 "$BIN/cklog" frob
run "an unknown option fails"                 "$T/core" 1 "$BIN/cklog" show --frob

echo "---"
echo "$pass passed, $fail failed"
exit $((fail > 0))
