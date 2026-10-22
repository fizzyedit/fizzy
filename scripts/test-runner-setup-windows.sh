#!/bin/sh
# Runs scripts/test-runner-setup.ps1 (the runner-setup.ps1 dry run) under pwsh; skips cleanly
# where pwsh is not installed.
cd "$(dirname "$0")" || exit 1
if ! command -v pwsh >/dev/null 2>&1; then
    echo 'skip: pwsh not installed'
    exit 0
fi
exec pwsh -NoProfile -ExecutionPolicy Bypass -File ./test-runner-setup.ps1
