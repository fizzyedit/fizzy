#!/usr/bin/env bash
# Exercise worker mechanics with fake tools; no network, builds or repository writes.
set -euo pipefail
cd "$(dirname "$0")/.."
source_root=$PWD
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
mkdir -p "$tmp/repo/scripts" "$tmp/repo/docs" "$tmp/repo/.jj" "$tmp/repo/.git" "$tmp/bin"
cp scripts/agent-{prepare,finish} scripts/check-pr-body "$tmp/repo/scripts/"
cp docs/VISION.md "$tmp/repo/docs/"
# A summary in the shape of docs/AGENT_WORK.md "The PR page", where jj and git each keep it.
fence='```'
plain=$'## In plain words\n\nA tap opens the keyboard.\n\n'
plain+=$'## What changes\n\n- A tap no longer closes the keyboard.\n\n'"${fence}zig"$'\nevent.preventDefault();\n'"$fence"$'\n\n'
plain+=$'## What you will notice\n\nTyping works.\n\n'
plain+=$'## How we know it works\n\nA test that fails without it.\n\n'
plain+=$'## How this serves fizzy\n\n[Phones and tablets](https://github.com/fizzyedit/fizzy/blob/main/docs/VISION.md#mobile).\n\n'
technical=$'## Goal\n\ng\n\n## What changed and why\n\nw\n\n## How it was verified\n\nv\n\n## Not done / follow-ups\n\nn'
summary() { printf '%s\n' "$plain$technical" | tee "$tmp/repo/.jj/PR_SUMMARY.md" >"$tmp/repo/.git/PR_SUMMARY.md"; }
no_summary() { rm -f "$tmp/repo/.jj/PR_SUMMARY.md" "$tmp/repo/.git/PR_SUMMARY.md"; }
titled() { printf '# ci: a tap opens the keyboard\n%s\n' "$plain$technical" | tee "$tmp/repo/.jj/PR_SUMMARY.md" >"$tmp/repo/.git/PR_SUMMARY.md"; }
summary
export AGENT_TEST_DIR=$tmp
export AGENT_PREPARE_ALLOW_TMP=1  # the test checkout may itself sit under /tmp
export PATH="$tmp/bin:$PATH"
cat >"$tmp/bin/jj" <<'FAKE'
#!/usr/bin/env bash
set -e
printf '%s\n' "$*" >>"$AGENT_TEST_DIR/calls"
if [[ ${AGENT_TEST_GIT:-} == 1 && $1 == root ]]; then exit 1; fi
if [[ $1 == root ]]; then echo "$AGENT_TEST_DIR/repo"; exit 0; fi
case "$1 $2" in
    'workspace add')
        destination=${*: -1}
        mkdir -p "$destination/docs" "$destination/scripts"
        if [[ -e $AGENT_TEST_DIR/cloud-setup.sh ]]; then
            cp "$AGENT_TEST_DIR/cloud-setup.sh" "$destination/scripts/"
        fi
        ;;
    'log -r')
        if [[ $* == *description* ]]; then
            [[ -e $AGENT_TEST_DIR/no-desc ]] || echo 'ci: worker title'
        else echo ci/example; fi ;;
    'diff --from') echo ' scripts/example | 1 +' ;;
esac
FAKE
cat >"$tmp/bin/gh" <<'FAKE'
#!/usr/bin/env bash
set -e
printf '%s\n' "$*" >>"$AGENT_TEST_DIR/calls"
if [[ $1 == issue && $2 == view ]]; then echo 'Typing works on a phone'; fi
if [[ $1 == pr && $2 == list && ${AGENT_TEST_EXISTING:-} == 1 ]]; then echo 12; fi
if [[ $1 == pr && $2 == view && -n ${AGENT_TEST_BODY:-} ]]; then printf '%s\n' "$AGENT_TEST_BODY"; fi
if [[ $1 == pr && ( $2 == create || $2 == edit ) ]]; then
    while [[ $# -gt 0 ]]; do
        if [[ $1 == --body-file ]]; then cp "$2" "$AGENT_TEST_DIR/body"; break; fi
        shift
    done
fi
FAKE
cat >"$tmp/repo/scripts/check-fmt.sh" <<'FAKE'
#!/usr/bin/env bash
if [[ -e $AGENT_TEST_DIR/fail ]]; then exit 1; fi
echo formatted
FAKE
cat >"$tmp/repo/scripts/zb" <<'FAKE'
#!/usr/bin/env bash
if [[ -e $AGENT_TEST_DIR/no-summary ]]; then exit 0; fi
echo "Build Summary: 1/1 steps succeeded$(cat "$AGENT_TEST_DIR/suffix" 2>/dev/null)"
if [[ -e $AGENT_TEST_DIR/long ]]; then seq 1 200; echo 'Build Summary: 1/1 steps succeeded'; fi
FAKE
chmod +x "$tmp/bin/"* "$tmp/repo/scripts/"*
prepare=$tmp/repo/scripts/agent-prepare
finish=$tmp/repo/scripts/agent-finish
"$prepare" ci/example >"$tmp/output"
grep -qx "$tmp/repo-ci-example/docs/AGENT_WORK.md" "$tmp/output" || fail 'rules path'
if "$prepare" ci/example >"$tmp/output" 2>&1; then fail 'existing workspace accepted'; fi
if "$prepare" ../bad >"$tmp/output" 2>&1; then fail 'unsafe branch accepted'; fi
if "$finish" bad >"$tmp/output" 2>&1; then fail 'invalid issue accepted'; fi
"$finish" fizzyedit/work#42 >"$tmp/output"
grep -q 'Part of fizzyedit/work#42' "$tmp/body" || fail 'issue reference'
grep -q 'scripts/example' "$tmp/body" || fail 'diff evidence'
grep -q '1/1 steps succeeded' "$tmp/body" || fail 'gate evidence'
grep -q 'pr create --draft' "$tmp/calls" || fail 'draft PR'
grep -q -- '--title ci: worker title' "$tmp/calls" || fail 'PR title from description'
! grep -q 'describe -r' "$tmp/calls" || fail 'worker description overwritten on first finish'
printf ' (3/3 tests passed)' >"$tmp/suffix"
"$finish" 42 >"$tmp/output"
grep -q 'tests passed' "$tmp/body" || fail 'tests suffix gate'
rm "$tmp/suffix"
touch "$tmp/long"
"$finish" 42 >"$tmp/output"
! grep -qx 100 "$tmp/body" || fail 'gate output not tailed'
grep -qx 200 "$tmp/body" || fail 'gate output tail missing'
! grep -qx 150 "$tmp/body" || fail 'gate output tail longer than 50 lines'
grep -q 'earlier output omitted' "$tmp/body" || fail 'tail marker'
rm "$tmp/long"
: >"$tmp/calls"
touch "$tmp/no-desc"
# The branch's slug is no title: a summary that names none is refused.
if "$finish" 42 >"$tmp/output" 2>&1; then fail 'slug title accepted'; fi
grep -q 'is a slug' "$tmp/output" || fail 'slug title not named'
titled
"$finish" 42 >"$tmp/output"
grep -q 'describe -r @ -m ci: example' "$tmp/calls" || fail 'empty description filled'
rm "$tmp/no-desc"
summary
: >"$tmp/calls"
"$finish" 42 >"$tmp/output"
! grep -q 'describe' "$tmp/calls" || fail 'worker description overwritten'
touch "$tmp/fail"
: >"$tmp/calls"
"$finish" --claim 42 >"$tmp/output"
grep -q 'pr create --draft' "$tmp/calls" || fail 'claim draft PR'
grep -q 'Gates not run yet' "$tmp/body" || fail 'claim body'
rm "$tmp/fail"
rm "$tmp/body"
touch "$tmp/fail"
if "$finish" 42 >"$tmp/output" 2>&1; then fail 'failed gate accepted'; fi
[[ ! -e $tmp/body ]] || fail 'published after failed gate'
grep -q '^agent-finish: gate failed:' "$tmp/output" || fail 'failure reason'
! grep -q 'scripts/zb zig build' "$source_root/docs/AGENT_WORK.md" || fail 'invalid zb invocation'
rm "$tmp/fail"
touch "$tmp/no-summary"
if "$finish" 42 >"$tmp/output" 2>&1; then fail 'missing summary accepted'; fi
[[ ! -e $tmp/body ]] || fail 'published without Build Summary'
rm "$tmp/no-summary"
"$finish" 42 >"$tmp/output"
grep -qxF '<details><summary>For agents: technical summary</summary>' "$tmp/body" || fail 'technical summary not collapsed'
[[ $(grep -c '^## In plain words$' "$tmp/body") == 1 ]] || fail 'plain words section'
[[ $(grep -n '^## How we know it works$' "$tmp/body" | cut -d: -f1) -lt $(grep -n '^## Goal$' "$tmp/body" | cut -d: -f1) ]] ||
    fail 'plain sections not above the technical ones'
no_summary
rm "$tmp/body"
if "$finish" 42 >"$tmp/output" 2>&1; then fail 'missing PR page accepted'; fi
[[ ! -e $tmp/body ]] || fail 'published without the plain sections'
grep -q 'How this serves fizzy' "$tmp/output" || fail 'missing section not named'
printf '# ci: a tap opens the keyboard\n%s\n' "${plain/VISION.md#mobile/VISION.md#nowhere}$technical" >"$tmp/repo/.jj/PR_SUMMARY.md"
if "$finish" 42 >"$tmp/output" 2>&1; then fail 'unknown vision anchor accepted'; fi
grep -q 'no anchor "nowhere"' "$tmp/output" || fail 'unknown anchor not named'
printf '# ci: a tap opens the keyboard\n%s\n' "$plain$technical" >"$tmp/repo/.jj/PR_SUMMARY.md"
: >"$tmp/calls"
"$finish" 42 >"$tmp/output"
grep -q -- '--title ci: a tap opens the keyboard' "$tmp/calls" || fail 'PR title from the summary'
! grep -q '^# ci:' "$tmp/body" || fail 'title line left in the body'
summary
bad=$(mktemp -d /tmp/agent-test.XXXXXX)
mkdir "$bad/scripts"
cp "$tmp/repo/scripts/agent-prepare" "$bad/scripts/"
if AGENT_PREPARE_ALLOW_TMP= "$bad/scripts/agent-prepare" ci/example >"$tmp/output" 2>&1; then rm -rf "$bad"; fail 'tmp workspace accepted'; fi
rm -rf "$bad"
cat >"$tmp/bin/git" <<'FAKE'
#!/usr/bin/env bash
set -e
printf 'git %s\n' "$*" >>"$AGENT_TEST_DIR/calls"
case "$1 $2" in
    'worktree add') mkdir -p "${*: -2:1}" ;;
    'symbolic-ref --quiet') echo ci/git ;;
    'rev-list --count') echo "${AGENT_TEST_AHEAD:-1}" ;;
    'diff origin/main') echo ' scripts/git-example | 1 +' ;;
    'rev-parse --git-dir') echo "$AGENT_TEST_DIR/repo/.git" ;;
esac
FAKE
chmod +x "$tmp/bin/git"
AGENT_TEST_GIT=1 "$prepare" ci/git >"$tmp/output"
grep -q 'git worktree add -b ci/git' "$tmp/calls" || fail 'git worktree fallback'
titled
AGENT_TEST_GIT=1 "$finish" 42 >"$tmp/output"
summary
grep -q 'git push --set-upstream origin ci/git' "$tmp/calls" || fail 'git push fallback'
: >"$tmp/calls"
AGENT_TEST_GIT=1 AGENT_TEST_AHEAD=0 "$finish" --claim 42 >"$tmp/output"
grep -q 'git commit --allow-empty -m Typing works on a phone: claim' "$tmp/calls" || fail 'git claim empty commit'
: >"$tmp/calls"
AGENT_TEST_GIT=1 "$finish" --claim 42 >"$tmp/output"
! grep -q 'allow-empty' "$tmp/calls" || fail 'empty commit despite commits ahead'
AGENT_TEST_EXISTING=1 "$finish" 42 >"$tmp/output"
grep -q 'pr edit 12 --body-file' "$tmp/calls" || fail 'existing PR refresh'
# A rework run keeps the PR's own work issue; a fresh PR takes the issue being worked.
AGENT_TEST_EXISTING=1 AGENT_TEST_BODY=$'Part of fizzyedit/work#7\n\n## Goal\n\nold' "$finish" 99 >"$tmp/output"
[[ $(head -n 1 "$tmp/body") == 'Part of fizzyedit/work#7' ]] || fail 'rework replaced Part of line'
grep -qx 'Rework: work#99' "$tmp/body" || fail 'rework line missing'
! grep -q 'Part of fizzyedit/work#99' "$tmp/body" || fail 'rework issue became Part of'
# Without PR_SUMMARY.md the body above the marker is read back, its collapsed block kept once.
no_summary
summary_body=$(printf '%s\n' "$plain<details><summary>For agents: technical summary</summary>"$'\n\n'"$technical"$'\n\n</details>')
AGENT_TEST_EXISTING=1 AGENT_TEST_BODY=$'Part of fizzyedit/work#7\nRework: work#5\n\n'"$summary_body"$'\n\n<!-- agent-finish: generated below -->' "$finish" 99 >"$tmp/output"
[[ $(grep -c '^Rework:' "$tmp/body") == 1 ]] || fail 'old rework line carried into summary'
[[ $(grep -c 'For agents: technical summary' "$tmp/body") == 1 ]] || fail 'technical summary wrapped twice'
summary
AGENT_TEST_EXISTING=1 AGENT_TEST_BODY=$'Part of fizzyedit/work#42\n\nx' "$finish" 42 >"$tmp/output"
! grep -q '^Rework:' "$tmp/body" || fail 'rework line on a same-issue run'
AGENT_TEST_EXISTING=1 "$finish" 42 >"$tmp/output"
grep -q '^Part of fizzyedit/work#42$' "$tmp/body" || fail 'fresh PR issue line'
# The PR page checks: title, layout with a code snippet, and the agent-notes block.
check=$tmp/repo/scripts/check-pr-body
notes='<!-- agent-notes {"issue":978,"worker":"claude","slot":"windows","status":"ready","area":"web","open_questions":[],"next":"review"} -->'
details=$'<details><summary>For agents: technical summary</summary>\n\n'"$technical"$'\n\n</details>'
page() { printf '%s\n%s\n\n%s\n\n%s\n' "$1" "$plain$details" "${2-}" "${3-}"; }
page '# web: a tap on a phone keeps the keyboard open' '' "$notes" >"$tmp/good.md"
"$check" "$tmp/good.md" >"$tmp/output" 2>&1 || fail "good page refused: $(cat "$tmp/output")"
bad() { # <file> <expected message>
    if "$check" "$1" >"$tmp/output" 2>&1; then fail "accepted: $2"; fi
    grep -q -- "$2" "$tmp/output" || fail "not named: $2 ($(cat "$tmp/output"))"
}
page '# windows: work-723' '' "$notes" >"$tmp/bad.md"; bad "$tmp/bad.md" 'is a slug'
page '# linux: touch-slop' '' "$notes" >"$tmp/bad.md"; bad "$tmp/bad.md" 'is a slug'
page '# web: a tap on a phone keeps the keyboard open and the page scrolls to the field at once' '' "$notes" >"$tmp/bad.md"
bad "$tmp/bad.md" 'over 72 characters'
page 'Part of #1' '' "$notes" >"$tmp/bad.md"
"$check" --title 'work-723' "$tmp/bad.md" >"$tmp/output" 2>&1 && fail 'title without an area accepted'
grep -q 'not "area: what changes"' "$tmp/output" || fail 'title shape not named'
good=$(<"$tmp/good.md")
printf '%s\n' "${good/${fence}zig/${fence}}" | sed '/^event.preventDefault/d;/^```$/d' >"$tmp/bad.md"
bad "$tmp/bad.md" 'no fenced code snippet'
long=$(seq 1 16 | sed 's/^/line /')
printf '%s\n' "${good/event.preventDefault();/$long}" >"$tmp/bad.md"; bad "$tmp/bad.md" 'over 15 lines'
swapped=${good/$'## What you will notice\n\nTyping works.\n\n'/}
printf '%s\n' "${swapped/$'## In plain words'/$'## What you will notice\n\nTyping works.\n\n## In plain words'}" >"$tmp/bad.md"
bad "$tmp/bad.md" 'not all there in order'
page '# web: a tap on a phone keeps the keyboard open' '' '<!-- agent-notes {"issue":978, -->' >"$tmp/bad.md"
bad "$tmp/bad.md" 'agent-notes'
page '# web: a tap on a phone keeps the keyboard open' '' "${notes/\"slot\":\"windows\",/}" >"$tmp/bad.md"
bad "$tmp/bad.md" 'lacks "slot"'
page '# web: a tap on a phone keeps the keyboard open' '' "${notes/\"next\":\"review\"/\"next\":\"later\"}" >"$tmp/bad.md"
bad "$tmp/bad.md" '"next" is not'
page '# web: a tap on a phone keeps the keyboard open' "$notes" 'trailing text' >"$tmp/bad.md"
bad "$tmp/bad.md" 'not the last thing'
# A claim draft may be empty; a ready page may not.
draft=${notes/ready/draft}
empty_plain=${plain//A tap opens the keyboard./Draft: work in progress}
printf '%s\n%s\n' "$empty_plain$details" "$draft" >"$tmp/draft.md"
"$check" "$tmp/draft.md" >"$tmp/output" 2>&1 || fail "empty draft refused: $(cat "$tmp/output")"
printf '%s\n%s\n' "$empty_plain$details" "$notes" >"$tmp/bad.md"; bad "$tmp/bad.md" 'missing or empty'
# The worked example in docs/AGENT_WORK.md (PR #978 rewritten) passes the check.
awk '/^````markdown/ { on = 1; next } /^````$/ { on = 0 } on' "$source_root/docs/AGENT_WORK.md" >"$tmp/example.md"
"$check" --title 'web: a tap on a phone keeps the keyboard open' "$tmp/example.md" >"$tmp/output" 2>&1 ||
    fail "the documented example fails: $(cat "$tmp/output")"
# agent-finish: the claim draft takes the work issue's title; every page ends with its notes.
: >"$tmp/calls"
"$finish" --claim 42 >"$tmp/output"
grep -q -- '--title Typing works on a phone' "$tmp/calls" || fail 'claim title from the work issue'
tail -n 1 "$tmp/body" | grep -q '"issue":42.*"status":"draft"' || fail 'claim agent-notes'
"$finish" 42 >"$tmp/output"
tail -n 1 "$tmp/body" | grep -q '"status":"ready"' || fail 'finish agent-notes'
"$check" "$tmp/body" >"$tmp/output" 2>&1 || fail "published page refused: $(cat "$tmp/output")"
AGENT_TEST_EXISTING=1 AGENT_TEST_BODY=$'Part of fizzyedit/work#42\n\n'"${notes/\"open_questions\":[]/\"open_questions\":[\"which phone?\"]}" "$finish" 42 >"$tmp/output"
tail -n 1 "$tmp/body" | grep -q 'which phone?' || fail 'agent-notes questions lost on a rerun'
cat >"$tmp/bin/uname" <<'FAKE'
#!/usr/bin/env bash
echo Linux
FAKE
cat >"$tmp/cloud-setup.sh" <<'FAKE'
#!/usr/bin/env bash
touch "$AGENT_TEST_DIR/setup-ran"
FAKE
chmod +x "$tmp/bin/uname" "$tmp/cloud-setup.sh"
# System bins provide the shell and basic tools, without the developer's Zig launcher.
PATH="$tmp/bin:/usr/bin:/bin" "$prepare" ci/cloud >"$tmp/output"
[[ -e $tmp/setup-ran ]] || fail 'Linux without Zig did not run cloud setup'
echo ok
