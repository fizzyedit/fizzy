#!/usr/bin/env bash
# Superfan dedupe: the fingerprints already filed in the findings repo.
#
#   scripts/fan-dedupe.sh [fan]          list "<fingerprint> <number> <verdict>", one per issue
#   scripts/fan-dedupe.sh --check <fp>   exit 0 new (file it), 10 duplicate (skip), 11 regression
#
# A fingerprint is a `fingerprint: ...` line of an issue body (.claude/skills/fan-common); a body may
# carry several (the low-severity batch has one per low), and every one is indexed.
# Verdict: open; dismissed (closed wontfix/invalid/not planned/duplicate); fixed (closed, completed).
# --check: an open or dismissed match is a duplicate; only fixed matches mean the finding is back,
# so file it as a regression and name the old number (printed on stdout).
#
# FAN_REPO (default fizzyedit/work) is where the issues are. FAN_ISSUES_JSON names a file of
# `gh issue list --json number,state,stateReason,labels,body` output to use instead of calling gh
# (the dry run and the tests use it).
set -euo pipefail

repo="${FAN_REPO:-fizzyedit/work}"
fan=""
check=""
while [ $# -gt 0 ]; do
  case "$1" in
    --check) check="${2:?--check needs a fingerprint}"; shift 2 ;;
    -h | --help) sed -n '2,13p' "$0"; exit 0 ;;
    -*) echo "fan-dedupe: unknown option $1" >&2; exit 2 ;;
    *) fan="$1"; shift ;;
  esac
done
if [ -z "$fan" ] && [ -n "$check" ]; then
  fan="${check#fan:}"
  fan="fan:${fan%%/*}"
fi
fan="${fan#fan:}"

if [ -n "${FAN_ISSUES_JSON:-}" ]; then
  json=$(cat "$FAN_ISSUES_JSON")
else
  args=(-R "$repo" -l superfan --state all --limit 1000 --json number,state,stateReason,labels,body)
  [ -n "$fan" ] && args+=(-l "fan:$fan")
  json=$(gh issue list "${args[@]}")
fi

rows=$(printf '%s' "$json" | jq -r '
  .[] | (.labels | map(.name)) as $l
  | ((.body // "") | gsub("\r"; "") | split("\n") | map(select(startswith("fingerprint: ")))[]
     | sub("^fingerprint: "; "") | sub("[ \t]+$"; "")) as $fp
  | select($fp != "")
  | [$fp, (.number | tostring),
     (if .state == "OPEN" then "open"
      elif ($l | index("wontfix") or index("invalid")) or .stateReason == "NOT_PLANNED" or .stateReason == "DUPLICATE" then "dismissed"
      else "fixed" end)]
  | @tsv')

if [ -z "$check" ]; then
  [ -n "$rows" ] && printf '%s\n' "$rows" | tr '\t' ' '
  exit 0
fi

fixed=""
while IFS=$'\t' read -r fp num verdict; do
  [ "$fp" = "$check" ] || continue
  case "$verdict" in
    open | dismissed) echo "duplicate of #$num ($verdict)"; exit 10 ;;
    fixed) fixed="$num" ;;
  esac
done <<< "$rows"
if [ -n "$fixed" ]; then
  echo "regression of #$fixed"
  exit 11
fi
echo "new"
