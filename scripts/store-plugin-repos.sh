#!/usr/bin/env bash
# Print the GitHub repos (owner/repo, one per line) of the plugins in the store registry,
# fizzy's own monorepo left out. `.github/workflows/deps-cache.yml` uses it to cache what those
# plugins build from. A registry entry names its repo in `homepage`, else in `manifest_url`.
#
# Needs `gh` (authenticated, GH_TOKEN) and `jq`.
set -euo pipefail

registry="${STORE_REGISTRY:-fizzyedit/plugins}"

gh api "repos/$registry/contents/registry" --jq '.[] | select(.name | endswith(".json")) | .download_url' |
    while read -r url; do
        curl -fsSL --retry 4 --retry-delay 2 --retry-all-errors "$url" |
            jq -r '[.homepage, .manifest_url][] | select(. != null) | capture("^https://github.com/(?<repo>[^/]+/[^/]+)") | .repo' |
            sed -n 1p
    done | { grep -v -x -i "fizzyedit/fizzy" || true; } | sort -u
