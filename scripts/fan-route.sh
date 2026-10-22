#!/usr/bin/env bash
# Superfan router: which runner a fan runs on.
#
#   scripts/fan-route.sh <fan>      one line per need: "<fan> <need> <runner>"
#
# A fan's SKILL.md frontmatter declares `needs:` (one need, or `[a, b]` = once on each). For each
# need this picks the first online runner in the capacity file that offers it and has a slot. A
# need no runner offers prints "<fan> <need> no-runner" and the script exits 3: the fan writes a
# "no runner" record instead of filing an error issue. Cloud is only one row of the table.
#
# FIZZY_FAN_CAPACITY overrides the capacity file (default scripts/fan-capacity.txt);
# FIZZY_FAN_SKILLS overrides the skills directory (default .claude/skills).
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
fan="${1:?usage: fan-route.sh <fan>}"
fan="${fan#fan:}"
fan="${fan#fan-}"
capacity="${FIZZY_FAN_CAPACITY:-$here/scripts/fan-capacity.txt}"
skill="${FIZZY_FAN_SKILLS:-$here/.claude/skills}/fan-$fan/SKILL.md"

[ -f "$skill" ] || { echo "fan-route: no skill $skill" >&2; exit 2; }
[ -f "$capacity" ] || { echo "fan-route: no capacity file $capacity" >&2; exit 2; }

# The frontmatter is the block between the first two `---` lines.
line=$(awk '/^---[ \t]*$/ { n++; next } n == 1 && /^needs:/ { print; exit } n >= 2 { exit }' "$skill")
[ -n "$line" ] || { echo "fan-route: $skill has no needs: in its frontmatter" >&2; exit 2; }
needs=$(printf '%s' "${line#needs:}" | tr -d '[]' | tr ',' ' ')

status=0
for need in $needs; do
  runner=$(awk -F'|' -v need="$need" '
    /^[ \t]*#/ || NF < 6 { next }
    { for (i = 1; i <= 6; i++) gsub(/^[ \t]+|[ \t]+$/, "", $i) }
    $6 == "yes" && $4 + 0 > 0 {
      n = split($2, offered, ",")
      for (i = 1; i <= n; i++) { gsub(/[ \t]/, "", offered[i]); if (offered[i] == need) { print $1; exit } }
    }' "$capacity")
  if [ -n "$runner" ]; then
    echo "$fan $need $runner"
  else
    echo "$fan $need no-runner"
    status=3
  fi
done
exit "$status"
