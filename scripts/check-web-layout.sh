#!/usr/bin/env bash
# Compile the web (wasm) build with an app-owned layout, once as data (`.zon`) and once as code.
#
# `zig build check-web` alone never sets `-Dapp-layout`, so `build/web.zig`'s `wireAppLayout`
# call is a no-op there. With the option set and that call removed, the wasm root fails with
# "no module named 'app_layout' available within module".
set -euo pipefail
cd "$(dirname "$0")/.."
for layout in tests/shapes/minimal.zon tests/shapes/endless.zig; do
    echo "check-web-layout: -Dapp-layout=$layout"
    scripts/zb build check-web "-Dapp-layout=$layout"
done
