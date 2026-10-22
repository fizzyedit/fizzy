#!/usr/bin/env bash
# Build and measure example-app minimal. See docs/HELLO_NUMBERS.md for the protocol.
set -euo pipefail
exec python3 "$(dirname "$0")/hello-numbers.py" "$@"
