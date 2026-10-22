#!/usr/bin/env bash
# Superfan lint: a fan that is told to post and told not to post posts nothing (the smoke run's
# bug). Fails on contradictory "do not post" language in any fan skill, and in any routine prompt
# given as a file argument or on stdin.
#
#   scripts/fan-lint.sh                  every .claude/skills/fan-*/SKILL.md
#   scripts/fan-lint.sh prompt.txt ...   those files too (a routine's prompt, saved)
#   echo "$prompt" | scripts/fan-lint.sh -   a prompt on stdin
#
# Also checks each fan skill has frontmatter `name` and `needs:`, and that a routine prompt is the
# one line `Run /fan-<name>`.
set -euo pipefail
# Argument files are relative to where the caller stands, so resolve them before the cd to the root.
args=()
for a in "$@"; do
  if [ "$a" = - ] || [[ "$a" = /* ]]; then args+=("$a"); else args+=("$PWD/$a"); fi
done
cd "$(dirname "$0")/.."

bad='do not (post|file|report|create|open|change anything)|don.t (post|file|report)|never (post|file|report) (a |any |the )?(summary|issue|finding)|post nothing|nothing is posted|read-only run'
status=0

lint_text() { # name, file
  if grep -n -i -E "$bad" "$2" | sed "s|^|$1: contradictory language: |" | grep .; then status=1; fi
}

shopt -s nullglob
for f in .claude/skills/fan-*/SKILL.md; do
  lint_text "$f" "$f"
  if [ "$f" != .claude/skills/fan-common/SKILL.md ]; then
    head -n 12 "$f" | grep -q '^needs:' || { echo "$f: frontmatter has no needs:"; status=1; }
  fi
  head -n 12 "$f" | grep -q '^name: fan-' || { echo "$f: frontmatter name is not fan-*"; status=1; }
done

for p in ${args[@]+"${args[@]}"}; do
  if [ "$p" = - ]; then tmp=$(mktemp); cat > "$tmp"; src=stdin; else tmp="$p"; src="$p"; fi
  lint_text "$src" "$tmp"
  lines=$(grep -c . "$tmp" || true)
  if [ "$lines" -ne 1 ] || ! grep -q -E '^Run /fan-[a-z]+[[:space:]]*$' "$tmp"; then
    echo "$src: a routine prompt is the one line 'Run /fan-<name>'"; status=1
  fi
  [ "$p" = - ] && rm -f "$tmp"
done
exit "$status"
