#!/usr/bin/env bash
# PostToolUse hook for Edit/Write: run `zig fmt` on the .zig or .zon file just written, so an
# agent's edits arrive formatted and CI's format check (scripts/check-fmt.sh) has nothing to say.
#
# Never blocks: a file mid-edit that doesn't parse yet is left as it is, and without jq or zig
# nothing happens.
set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0
command -v zig >/dev/null 2>&1 || exit 0
file=$(jq -r '.tool_input.file_path // .tool_response.filePath // empty')
case "$file" in
*/zig-pkg/* | */.zig-cache/* | */zig-out/*) exit 0 ;;
*.zig | *.zon) ;;
*) exit 0 ;;
esac
[ -f "$file" ] || exit 0

# From the file's own directory, so a zig version manager finds the nearest build.zig.zon.
cd "$(dirname "$file")" && zig fmt "$file" >/dev/null 2>&1
exit 0
