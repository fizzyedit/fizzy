#!/bin/sh
# The hidden input's tests (web/tests/text-input.test.js) against the web.js the web build
# writes: `zig build web` first. Node also runs the wheel, pointer-input and two-copy embed checks.
# CI builds the web assets and runs both suites. Use --embed-only for the build-independent
# Node check; hidden-input tests also support jsc.
set -eu
cd "$(dirname "$0")/.."
if [ "${1:-}" = --embed-only ]; then
    node web/tests/field-hints.test.mjs
    node web/tests/keyboard-inset.test.mjs
    exec node web/tests/embed.test.mjs
fi
js=zig-out/web/web.js
[ -f "$js" ] || { echo "test-web-text-input: no $js; run zig build web" >&2; exit 1; }
if command -v node >/dev/null; then
    node web/tests/wheel-input.test.mjs
    node web/tests/pointer-input.test.mjs
    node web/tests/field-hints.test.mjs
    node web/tests/keyboard-inset.test.mjs
    node web/tests/text-input.test.js "$PWD/$js"
    exec node web/tests/embed.test.mjs
fi
jsc=/System/Library/Frameworks/JavaScriptCore.framework/Versions/Current/Helpers/jsc
[ -x "$jsc" ] || { echo "test-web-text-input: needs node (or macOS's jsc)" >&2; exit 1; }
exec "$jsc" -m web/tests/text-input.test.js -- "$PWD/$js"
