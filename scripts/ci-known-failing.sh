#!/usr/bin/env bash
# Run `zig build test --summary all` (or a wrapper of it), and let it fail only for a test that is
# not on a list of known failures.
#
#   ci-known-failing.sh <list> <command...>
#
# The list holds one known failure per line, `<test binary>: <test name> | work#N`, the issue
# that owns its fix; `#` starts a comment. CI uses it for Windows' merge-group run, where one
# intermittent crash that also fails on main ejected PRs from the queue (fizzyedit/work#549).
#
# Fail-closed: the command's own status stands unless every failure in its output is attributed,
# by exact binary and exact test name, to a listed line. That needs all of:
#   - a `Build Summary:` line (a fetch failure, a kill or a dead build runner has none);
#   - its `(K failed)` equal to the number of `run test <bin>` steps in the summary tree that
#     report a failing test, so a compile error or any other failed step fails the run;
#   - every `error: '<name>' ...` line in such a step's failure block listed for that binary,
#     at least one per failing test, and no other `error:` line in the block;
#   - the summary's failed, crashed and timed-out test totals equal to those steps' sum.
# The runner's generic `error:` and `failed command:` lines elsewhere (Windows prints a
# pkg-config one on every run, green or not) are neither matched nor needed.
#
# A listed test whose binary ran clean is reported as passing (a notice and a line in
# $GITHUB_STEP_SUMMARY), so the list shrinks; a tolerated failure is a warning naming its owner.
set -uo pipefail

if [ "$#" -lt 2 ]; then
  echo "usage: $0 <list> <command...>" >&2
  exit 2
fi
list=$1
shift
if [ ! -r "$list" ]; then
  echo "::error::known-failing list $list is missing"
  exit 2
fi

log="$(mktemp)"
trap 'rm -f "$log"' EXIT

"$@" 2>&1 | tee "$log"
status="${PIPESTATUS[0]}"

summary="${GITHUB_STEP_SUMMARY:-/dev/null}"

# Prints `::notice::`/`::warning::`/`::error::` lines and the step summary's Markdown (prefixed
# `md:`); exits 0 when the run may pass, 1 when the command's status must stand.
verdict=$(LC_ALL=C awk -v status="$status" '
  function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
  function count(s, word,   m) {
    if (match(s, "[0-9]+ " word)) { m = substr(s, RSTART, RLENGTH); sub(/ .*/, "", m); return m + 0 }
    return 0
  }
  # The test name of a test runner error line, or "" when the line names no test.
  function test_name(line,   kws, n, i, at, best) {
    if (substr(line, 1, 8) != "error: '\''") return ""
    n = split("failed|errored|exited with|terminated with|timed out|leaked|logged", kws, "|")
    best = 0
    for (i = 1; i <= n; i++) {
      at = index(line, "'\'' " kws[i])
      if (at > 9 && (best == 0 || at < best)) best = at
    }
    return best ? substr(line, 9, best - 9) : ""
  }

  # The list.
  FILENAME == ARGV[1] {
    line = $0; sub(/\r$/, "", line)
    if (line ~ /^[ \t]*(#|$)/) next
    bar = 0
    for (i = length(line); i > 0; i--) if (substr(line, i, 3) == " | ") { bar = i; break }
    owner = bar ? trim(substr(line, bar + 3)) : ""
    entry = bar ? trim(substr(line, 1, bar - 1)) : trim(line)
    colon = index(entry, ": ")
    if (owner !~ /^work#[0-9]+$/ || colon < 2) {
      print "::error::" ARGV[1] ": \"" line "\" is not `<test binary>: <test name> | work#N`"
      bad_list = 1
      next
    }
    listed[entry] = owner
    listed_bin[entry] = substr(entry, 1, colon - 1)
    next
  }

  # The command output.
  {
    line = $0
    sub(/\r$/, "", line)
    gsub(/\033\[[0-9;]*m/, "", line)
  }
  line ~ /^Build Summary: / {
    have_summary = 1; in_tree = 1
    steps = line; sub(/;.*/, "", steps)
    tests = line; sub(/^[^;]*;?/, "", tests)
    summary_failed_steps = count(steps, "failed")
    summary_failed_tests = count(tests, "failed") + count(tests, "crashed") + count(tests, "timed out")
    next
  }
  !in_tree {
    if (line ~ /^[ |]*\+- /) {
      leaf = line; sub(/^[ |]*\+- /, "", leaf)
      leaf_bin = ""
      if (leaf ~ /^run test [^ ]+/) { split(leaf, f, " "); leaf_bin = f[3] }
      next
    }
    if (leaf_bin != "" && substr(line, 1, 7) == "error: ") {
      name = test_name(line)
      if (name == "") { stray[leaf_bin] = stray[leaf_bin] " " line; next }
      key = leaf_bin ": " name
      if (!(key in named)) { named[key] = 1; named_count[leaf_bin]++ }
    }
    next
  }
  line ~ /^[ |]*\+- run test [^ ]+/ && line !~ /\(reused\)/ {
    step = line; sub(/^[ |]*\+- /, "", step)
    split(step, f, " "); bin = f[3]
    ran[bin] = 1
    bad = count(step, "fail") + count(step, "crash") + count(step, "timeout")
    flagged = count(step, "leaks") + count(step, "error logs")
    if (bad + flagged > 0) {
      failing_steps++
      failing[bin] = 1
      want[bin] += bad > 0 ? bad : 1
      tree_failed_tests += bad
    }
  }

  END {
    for (key in listed) {
      if (!(listed_bin[key] in ran)) continue
      if (listed_bin[key] in failing && key in named) continue
      print "::notice::known failure passed: " key " (" listed[key] "); remove it from " ARGV[1]
      passed_md = passed_md "md:- `" key "` (" listed[key] ")\n"
    }
    if (passed_md != "") printf "md:### Listed as failing on this OS, passed this run\n%s", passed_md

    if (bad_list) exit 1
    if (status == 0) exit 0
    if (!have_summary) { print "::notice::no Build Summary: the failure is not a test"; exit 1 }
    if (failing_steps == 0 || summary_failed_steps != failing_steps) {
      print "::notice::" summary_failed_steps " failed steps, " failing_steps + 0 " of them failing tests: not only known failures"
      exit 1
    }
    if (summary_failed_tests != tree_failed_tests) {
      print "::notice::the summary counts " summary_failed_tests " failed tests, the steps " tree_failed_tests + 0
      exit 1
    }
    ok = 1
    for (bin in failing) {
      if (bin in stray) { print "::notice::" bin " failed outside a named test:" stray[bin]; ok = 0 }
      if (named_count[bin] < want[bin]) {
        print "::notice::" bin ": " want[bin] " failing tests, " named_count[bin] + 0 " named"
        ok = 0
      }
    }
    for (key in named) {
      if (key in listed) continue
      print "::notice::not a known failure: " key
      ok = 0
    }
    if (!ok) exit 1
    for (key in named) {
      print "::warning::known failure, not failing the job: " key " (" listed[key] ")"
      failed_md = failed_md "md:- `" key "` (" listed[key] ")\n"
    }
    printf "md:### Known failures tolerated this run\n%s", failed_md
    exit 0
  }
' "$list" "$log")
allowed=$?

printf '%s\n' "$verdict" | grep -v '^md:'
printf '%s\n' "$verdict" | sed -n 's/^md://p' >>"$summary"

if [ "$allowed" -ne 0 ]; then
  if [ "$status" -eq 0 ]; then exit 1; fi
  exit "$status"
fi
exit 0
