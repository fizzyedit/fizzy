#!/usr/bin/env bash
# Checks scripts/perf-compile's store: the store directory and its option precedence, the
# monthly file name, that stdout and the stored lines are the same, that a second run appends,
# and that --no-store writes nothing. A fake zig stands in so the run takes no build time.
cd "$(dirname "$0")" || exit 1
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
printf '#!/bin/sh\nexit 0\n' >"$T/zig"
chmod +x "$T/zig"
export PATH=$T:$PATH FIZZY_PERF_MAX_LOAD=100000 FIZZY_PERF_TMP=$T/tmp XDG_DATA_HOME=$T/xdg
unset FIZZY_PERF_STORE
fail() { echo "FAIL: $1"; exit 1; }
run() { ./perf-compile --runs 1 --only noop "$@" 2>/dev/null; }

# The default store is $XDG_DATA_HOME/fizzy/perf, and the file is named for the line's month.
run >"$T/out1" || fail "run failed"
[ -s "$T/out1" ] || fail "no lines on stdout"
month=$(sed -n 's/.*"date":"\([0-9]\{4\}-[0-9]\{2\}\)-.*/\1/p' "$T/out1" | head -1)
file=$T/xdg/fizzy/perf/$month.jsonl
[ -f "$file" ] || fail "no $file: $(find "$T/xdg" -type f)"
cmp -s "$T/out1" "$file" || fail "stored lines differ from stdout"

# A second run appends and keeps the first run's lines.
run >"$T/out2" || fail "second run failed"
cat "$T/out1" "$T/out2" | cmp -s - "$file" || fail "second run did not append after the first"

# $FIZZY_PERF_STORE beats the default, and --store beats both.
FIZZY_PERF_STORE=$T/env run >"$T/out3" || fail "env run failed"
cmp -s "$T/out3" "$T/env/$month.jsonl" || fail "FIZZY_PERF_STORE not used"
FIZZY_PERF_STORE=$T/env run --store "$T/flag" >"$T/out4" || fail "flag run failed"
cmp -s "$T/out4" "$T/flag/$month.jsonl" || fail "--store not used"
[ "$(wc -l <"$T/env/$month.jsonl")" = 1 ] || fail "--store also wrote to FIZZY_PERF_STORE"

# --no-store prints and writes nothing, even with a store named.
rm -rf "$T/none"
FIZZY_PERF_STORE=$T/none run --no-store >"$T/out5" || fail "--no-store run failed"
[ -s "$T/out5" ] || fail "--no-store printed nothing"
[ ! -e "$T/none" ] || fail "--no-store made a store"
echo "test-perf-compile: ok"
