#!/usr/bin/env bash
# Checks scripts/ci-known-failing.sh on the real Windows output of run 40559487600 (a listed crash
# in fizzy-control-server-tests) and variants of it: only a failure that is listed, by binary and
# test name, may pass; everything else keeps the command's status.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
T=$(mktemp -d)
trap 'rm -f -r "$T"' EXIT

crash=fixtures/ci-known-failing/windows-crash.txt
listed='fizzy-control-server-tests: Server.test.an upgraded connection carries bytes both ways until the app closes it'
printf '# known failures\n\n%s | work#549\n' "$listed" >"$T/list"

failures=0
# expect <name> <want status> <log> <exit status> [list]: run the wrapper on a command that prints
# the log and exits with the status.
expect() {
  local name=$1 want=$2 log=$3 code=$4 list=${5:-$T/list} got
  : >"$T/summary"
  GITHUB_STEP_SUMMARY=$T/summary bash ci-known-failing.sh "$list" sh -c 'cat "$1"; exit "$2"' sh "$log" "$code" >"$T/out" 2>&1
  got=$?
  if [ "$got" -ne "$want" ]; then
    echo "FAIL: $name: exit $got, want $want"
    grep '^::' "$T/out"
    failures=$((failures + 1))
  else
    echo "ok: $name"
  fi
}
# variant <file> <sed script>: the crash log, edited.
variant() { sed "$2" "$crash" >"$T/$1"; }

expect "the listed crash passes" 0 "$crash" 1
grep -q "^::warning::known failure, not failing the job: $listed (work#549)" "$T/out" ||
  { echo "FAIL: no warning naming the tolerated failure"; failures=$((failures + 1)); }
grep -q "Known failures tolerated" "$T/summary" ||
  { echo "FAIL: the step summary lacks the tolerated failure"; failures=$((failures + 1)); }

variant other-name.log "s/an upgraded connection carries bytes/a different test/"
expect "an unlisted test in the same binary fails" 1 "$T/other-name.log" 1

variant other-bin.log "s/fizzy-control-server-tests/fizzy-control-json-tests/g"
expect "the listed name in another binary fails" 1 "$T/other-bin.log" 1

# A second test of the same binary fails beside the listed one.
variant second.log "/^error: 'Server.test.an upgraded/i\\
error: 'Server.test.another one' failed:
s/18 pass, 1 crash (19 total)/17 pass, 1 fail, 1 crash (19 total)/
s/(18 skipped, 1 crashed)/(18 skipped, 1 failed, 1 crashed)/"
expect "a second failure beside the listed one fails" 1 "$T/second.log" 1

# The same counts with only the listed test named: a failure the parser cannot name.
variant unnamed.log "s/18 pass, 1 crash (19 total)/17 pass, 1 fail, 1 crash (19 total)/
s/(18 skipped, 1 crashed)/(18 skipped, 1 failed, 1 crashed)/"
expect "a failing test with no name fails" 1 "$T/unnamed.log" 1

variant runner.log "/^failed command: .*control-server-tests/i\\
error: the test runner failed to respond for 60 seconds"
expect "a runner error in the listed binary's block fails" 1 "$T/runner.log" 1

variant compile.log "s/(1 failed)/(2 failed)/
s/^+- run test fizzy-lint-tests .*/+- run test fizzy-lint-tests 3 errors/"
expect "a compile error beside the listed crash fails" 1 "$T/compile.log" 1

variant leak.log "s/(19 total)\$/(19 total); 1 leaks/
/^failed command: .*control-server-tests/i\\
error: 'Server.test.leaky' leaked 1 allocations:"
expect "a leak in an unlisted test fails" 1 "$T/leak.log" 1

grep -v '^Build Summary' "$crash" >"$T/no-summary.log"
expect "no Build Summary fails" 1 "$T/no-summary.log" 1

expect "the command's own status stands" 3 "$T/other-name.log" 3

printf '%s\n' "$listed" >"$T/ownerless"
expect "a list line with no owner fails" 1 "$crash" 1 "$T/ownerless"
expect "a list line with no owner fails a green run too" 1 "$T/no-summary.log" 0 "$T/ownerless"

variant green.log "/^test\$/,/^\$/d
s/^Build Summary: .*/Build Summary: 185\/185 steps succeeded; 873\/891 tests passed (18 skipped)/
s/18 pass, 1 crash (19 total)/19 pass (19 total) 1s MaxRSS:5M/"
expect "a green run passes" 0 "$T/green.log" 0
grep -q "^::notice::known failure passed: $listed (work#549)" "$T/out" ||
  { echo "FAIL: a listed test that passed is not reported"; failures=$((failures + 1)); }
grep -q "passed this run" "$T/summary" ||
  { echo "FAIL: the step summary lacks the passing listed test"; failures=$((failures + 1)); }

if [ "$failures" -ne 0 ]; then
  echo "$failures failed"
  exit 1
fi
echo "all passed"
