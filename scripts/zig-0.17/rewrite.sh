#!/usr/bin/env bash
# The mechanical half of the Zig 0.17 switch (plans/ZIG_0_17_PLAN.md, "Where the work lives").
# Lives only on the `zig/0.17` branch: re-run after every merge from `main`, so code main adds is
# rewritten too, and delete it in the PR that merges the branch. Idempotent.
#
# Hand migrations are not here. What is here either `zig fmt` does, or is a rename with one
# right answer.
set -euo pipefail
cd "$(jj root 2>/dev/null || git rev-parse --show-toplevel)"
here=scripts/zig-0.17
zig=(${ZIG:-zig})  # e.g. ZIG="zig 0.17.0"

files=$(jj file list | grep -E '\.zig$' | grep -v -E '^(spikes|scripts/zig-0\.17)/')
[ -n "$files" ] || { echo "no .zig files found" >&2; exit 1; }

# Deprecated in 0.17, removed in 0.18 (lands on main as step 0; a no-op once it has).
perl -pi -e 's/(?<![\w.])builtin\.(os|cpu|abi|object_format)\b/builtin.target.$1/g;
             s/\@import\("builtin"\)\.(os|cpu|abi|object_format)\b/\@import("builtin").target.$1/g' $files

# std renames with one right answer.
perl -pi -e 'next if m{^\s*//};
  s/(?<![\w])\.Debug\b(?!\.)/.debug/g; s/(?<![\w])\.ReleaseFast\b/.fast/g;
  s/(?<![\w])\.ReleaseSafe\b/.safe/g;  s/(?<![\w])\.ReleaseSmall\b/.small/g;
  s/\.initEmpty\(\)/.empty/g;
  s/std\.meta\.Int\(/\@Int(/g;
  s/std\.ascii\.indexOfIgnoreCase\(/std.ascii.findIgnoreCase(/g;
  s/std\.builtin\.Type\.StructField\.Attributes/std.lang.Type.Struct.FieldAttributes/g;
  s/std\.builtin\.Type\.UnionField\.Attributes/std.lang.Type.Union.FieldAttributes/g' $files
# allocator.dupeZ(T, x) -> dupeSentinel(T, x, 0); std.fmt.bufPrintZ(...) -> bufPrintSentinel(..., 0).
# Method calls only: a local helper that happens to be named dupeZ is left alone.
perl -0pi -e 's/\.dupeZ(\((?:[^()]++|(?1))*\))/my $a=$1; $a =~ s{\)\z}{, 0)}; ".dupeSentinel$a"/ge;
              s/\.bufPrintZ(\((?:[^()]++|(?1))*\))/my $a=$1; $a =~ s{\)\z}{, 0)}; ".bufPrintSentinel$a"/ge' $files

# @typeInfo's struct-of-arrays shape, for field loops that read only names, types and defaults.
python3 $here/fields.py $files >/dev/null
python3 $here/unused.py $here $files >/dev/null

# Not std.zon.parse: each call is ported by hand to its owner's arena. A 0.16 call that a merge
# from main brings fails to compile, which is the reminder.

# Last: zig fmt's own upgrades (@intFromEnum -> @backingInt, ...).
jj file list | grep -E "\.(zig|zon)$" | xargs "${zig[@]}" fmt >/dev/null  # everything, spikes too
