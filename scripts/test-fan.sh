#!/usr/bin/env bash
# Dry run of the superfan scripts on seeded input. CI runs this; no network, no gh.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

cat > "$tmp/issues.json" <<'JSON'
[
 {"number":11,"state":"OPEN","stateReason":null,"labels":[{"name":"superfan"},{"name":"fan:boundary"}],
  "body":"sev med\n\nWhy.\n\nfingerprint: fan:boundary/relative-sdk-import/src/editor/Foo.zig"},
 {"number":12,"state":"CLOSED","stateReason":"NOT_PLANNED","labels":[{"name":"wontfix"}],
  "body":"x\r\nfingerprint: fan:boundary/plugin-cross-import/plugins/text:use\r\n"},
 {"number":13,"state":"CLOSED","stateReason":"COMPLETED","labels":[],
  "body":"x\nfingerprint: fan:boundary/dvui-second-pin/build.zig.zon"},
 {"number":14,"state":"OPEN","stateReason":null,"labels":[],"body":"no fingerprint here"},
 {"number":15,"state":"OPEN","stateReason":null,"labels":[],"body":"batch\nfingerprint: fan:boundary/a/one\nfingerprint: fan:boundary/a/two"}
]
JSON
export FAN_ISSUES_JSON="$tmp/issues.json"

out=$(scripts/fan-dedupe.sh boundary)
[ "$(printf '%s\n' "$out" | wc -l)" -eq 5 ] || fail "list should show 5 fingerprints: $out"
printf '%s\n' "$out" | grep -q 'plugin-cross-import/plugins/text:use 12 dismissed' || fail "dismissed: $out"
printf '%s\n' "$out" | grep -q 'dvui-second-pin/build.zig.zon 13 fixed' || fail "fixed: $out"

code() { set +e; "$@" >"$tmp/out" 2>&1; echo $?; set -e; }
[ "$(code scripts/fan-dedupe.sh --check fan:boundary/relative-sdk-import/src/editor/Foo.zig)" = 10 ] || fail "open dup"
[ "$(code scripts/fan-dedupe.sh --check fan:boundary/plugin-cross-import/plugins/text:use)" = 10 ] || fail "dismissed dup"
[ "$(code scripts/fan-dedupe.sh --check fan:boundary/dvui-second-pin/build.zig.zon)" = 11 ] || fail "regression"
grep -q '#13' "$tmp/out" || fail "regression names old number"
[ "$(code scripts/fan-dedupe.sh --check fan:boundary/fingerprint-drift/sdk/src/version.zig)" = 0 ] || fail "new"

[ "$(code scripts/fan-dedupe.sh --check fan:boundary/a/one)" = 10 ] || fail "batch first fingerprint"

# Known and accepted, read from the fan's skill; a fixed batch is not a regression.
mkdir -p "$tmp/ka/fan-boundary"
printf '## 4. Known and accepted\n\n- `fan:boundary/x/accepted.zig`\nfan:boundary/<id>/<path>\n\n## 5. Sev\nfan:boundary/y/not-accepted\n' > "$tmp/ka/fan-boundary/SKILL.md"
[ "$(FIZZY_FAN_SKILLS="$tmp/ka" code scripts/fan-dedupe.sh --check fan:boundary/x/accepted.zig)" = 10 ] || fail "known and accepted"
[ "$(FIZZY_FAN_SKILLS="$tmp/ka" code scripts/fan-dedupe.sh --check fan:boundary/y/not-accepted)" = 0 ] || fail "other section not accepted"
cat > "$tmp/batch.json" <<'JSON'
[{"number":31,"state":"CLOSED","stateReason":"COMPLETED","labels":[],"body":"fingerprint: fan:boundary/l/a\nfingerprint: fan:boundary/l/b"}]
JSON
[ "$(FAN_ISSUES_JSON="$tmp/batch.json" code scripts/fan-dedupe.sh --check fan:boundary/l/a)" = 10 ] || fail "closed batch is not a regression"
# A relative prompt file resolves against the caller's directory.
echo 'Run /fan-boundary' > "$tmp/p.txt"
(cd "$tmp" && "$OLDPWD/scripts/fan-lint.sh" p.txt) || fail "relative prompt file"

# Router.
[ "$(scripts/fan-route.sh boundary)" = "boundary cloud-linux cloud" ] || fail "route boundary"
mkdir -p "$tmp/skills/fan-look"
printf -- '---\nname: fan-look\nneeds: [windows, macos]\n---\n' > "$tmp/skills/fan-look/SKILL.md"
export FIZZY_FAN_SKILLS="$tmp/skills"
[ "$(code scripts/fan-route.sh look)" = 3 ] || fail "no runner exits 3"
[ "$(grep -c no-runner "$tmp/out")" = 2 ] || fail "two no-runner lines"
printf 'win | windows, app-window | yes | 1 | 01-06 | yes\nmac | macos | yes | 0 | any | yes\n' > "$tmp/cap.txt"
FIZZY_FAN_CAPACITY="$tmp/cap.txt" scripts/fan-route.sh look >"$tmp/out" || true
grep -q 'look windows win' "$tmp/out" || fail "windows routed"
grep -q 'look macos no-runner' "$tmp/out" || fail "macos has no free slot"
unset FIZZY_FAN_SKILLS

# fan:zig-std: routes to cloud, and its dedupe is per fan.
[ "$(scripts/fan-route.sh zig-std)" = "zig-std cloud-linux cloud" ] || fail "route zig-std"
cat > "$tmp/zs.json" <<'JSON'
[{"number":21,"state":"OPEN","stateReason":null,"labels":[{"name":"superfan"},{"name":"fan:zig-std"}],
  "body":"Hand-rolled startsWith; std.mem.startsWith at lib/std/mem.zig:2410\n\nfingerprint: fan:zig-std/hand-rolled-std/core/paths.zig:startsWith"}]
JSON
FAN_ISSUES_JSON="$tmp/zs.json" scripts/fan-dedupe.sh zig-std | grep -q 'hand-rolled-std/core/paths.zig:startsWith 21 open' || fail "zig-std list"
[ "$(FAN_ISSUES_JSON="$tmp/zs.json" code scripts/fan-dedupe.sh --check fan:zig-std/hand-rolled-std/core/paths.zig:startsWith)" = 10 ] || fail "zig-std dup"
[ "$(FAN_ISSUES_JSON="$tmp/zs.json" code scripts/fan-dedupe.sh --check fan:zig-std/io-writer/app/Log.zig:print)" = 0 ] || fail "zig-std new"

# Lint.
scripts/fan-lint.sh || fail "repo skills lint clean"
echo 'Run /fan-boundary' | scripts/fan-lint.sh - || fail "good prompt"
[ "$(echo 'Run /fan-boundary. Do not post anything.' | scripts/fan-lint.sh - >/dev/null; echo $?)" = 1 ] || fail "contradiction caught"
printf 'Do the run, file the summary.\nThen do not post or change anything.\n' | scripts/fan-lint.sh - >"$tmp/out" && fail "old smoke prompt passes"
grep -q contradictory "$tmp/out" || fail "old smoke prompt named"
echo "test-fan: ok"
