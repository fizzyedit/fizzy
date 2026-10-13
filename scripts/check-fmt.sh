#!/usr/bin/env bash
# Check that every tracked .zig and .zon file is as `zig fmt` writes it. CI runs this; run it
# before you push, or fix the files it names with `scripts/check-fmt.sh --fix`.
#
# Only tracked files: each plugin carries its own zig-pkg/ and .zig-cache/, full of other
# people's code that is not ours to reformat. The list comes from jj where there is one: in a
# colocated checkout git's index trails jj's working copy, and a jj workspace has none of its own.
set -euo pipefail
cd "$(dirname "$0")/.."

if command -v jj >/dev/null 2>&1 && jj root >/dev/null 2>&1; then
  files=$(jj file list 'glob:**/*.zig' 'glob:**/*.zon')
else
  files=$(git ls-files '*.zig' '*.zon')
fi
if [ -z "$files" ]; then
  echo "check-fmt: no tracked .zig or .zon files found" >&2
  exit 1
fi

if [ "${1:-}" = --fix ]; then
  printf '%s\n' "$files" | tr '\n' '\0' | xargs -0 zig fmt
  exit 0
fi

# `zig fmt --check` names each file it would change and exits non-zero.
if ! unformatted=$(printf '%s\n' "$files" | tr '\n' '\0' | xargs -0 zig fmt --check); then
  echo "Not formatted (fix with scripts/check-fmt.sh --fix):"
  echo "$unformatted"
  exit 1
fi
