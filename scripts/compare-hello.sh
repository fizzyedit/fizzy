#!/usr/bin/env bash
# Measure a stock Electron/Tauri hello app; opt-in, never called by CI.
# See docs/HELLO_NUMBERS.md for the first-frame marker and fresh-profile contract.
set -euo pipefail
exec python3 "$(dirname "$0")/hello-numbers.py" "$@"
