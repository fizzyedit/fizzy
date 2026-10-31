#!/usr/bin/env bash
# Make a Claude Code cloud session (Linux) able to build fizzy.
#
# A cloud environment's GitHub proxy lets only fizzyedit/fizzy's own URLs through, so `zig build`
# cannot fetch the other repos fizzy depends on (fizzyedit/dvui, zf, assetpack, ...). The `deps-cache`
# workflow (.github/workflows/deps-cache.yml) puts the Zig package cache those builds need, and
# this script, on a rolling release of this repo. The script installs Zig and unpacks that cache,
# after which `zig build` finds every dependency already fetched.
#
# The environment's setup script is this one line:
#   curl -fsSL https://github.com/fizzyedit/fizzy/releases/download/deps-cache/cloud-setup.sh | bash
#
# A session sourced from a plugin repo (fizzyedit/chat, ...) runs the same line. The cache holds the
# fizzy-sdk package those plugins pin, which the proxy resets if a build fetches it by URL, and
# the dependencies of each store plugin. Set PLUGIN_REPO to that repo's checkout (or `1` for the
# current directory, which under curl|bash may not be the checkout; so pass the path), on the bash
# side of the pipe (`curl ... | PLUGIN_REPO=/path/to/repo bash`). The script ends by running
# `zig build --fetch` there, so a package the cache lacks shows up at setup time rather than as a
# build failure; it never fails the setup.
#
# jj is not needed here: the script never calls it, so a machine without it is fine.
#
# Re-running is safe: it overwrites the cache's packages with the published ones.
set -euo pipefail

zig_version="${ZIG_VERSION:-0.17.0}"
asset_url="${DEPS_CACHE_URL:-https://github.com/fizzyedit/fizzy/releases/download/deps-cache/zig-deps-linux.tar.zst}"
cache="${ZIG_GLOBAL_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/zig}"

as_root() { if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi; }
# Root, or a sudo that needs no password. Codex cloud has neither, so the zig link goes in a user
# bin directory there (as it does wherever /usr/local/bin is not writable and sudo cannot help).
can_root() { [ "$(id -u)" -eq 0 ] || { command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; }; }

# --- Zig -------------------------------------------------------------------------------------
if command -v zig >/dev/null 2>&1 && [ "$(zig version)" = "$zig_version" ]; then
    echo "zig $zig_version already installed"
else
    python3 -m pip install --quiet --break-system-packages "ziglang==$zig_version" 2>/dev/null ||
        python3 -m pip install --quiet "ziglang==$zig_version"
    # Isolated mode first, as it always was; pip's user site-packages is outside it, so fall back
    # to plain mode (from /, keeping the current directory off the import path) only if that fails.
    find_zig='import os, ziglang; print(os.path.dirname(ziglang.__file__))'
    zig_dir="$(python3 -I -c "$find_zig" 2>/dev/null || { cd / && python3 -c "$find_zig"; })"
    if [ -w /usr/local/bin ]; then
        ln -sf "$zig_dir/zig" /usr/local/bin/zig
    elif [ "$(id -u)" -ne 0 ] && can_root; then
        sudo ln -sf "$zig_dir/zig" /usr/local/bin/zig
    else
        mkdir -p "$HOME/.local/bin"
        ln -sf "$zig_dir/zig" "$HOME/.local/bin/zig"
        export PATH="$HOME/.local/bin:$PATH"
        echo "/usr/local/bin is not writable and there is no sudo: linked zig into $HOME/.local/bin; add it to PATH in later shells"
    fi
    echo "installed zig $(zig version)"
fi

# --- zstd (to unpack the cache) ----------------------------------------------------------------
if ! command -v zstd >/dev/null 2>&1; then
    can_root || { echo "zstd is missing and there is no root or sudo to install it" >&2; exit 1; }
    as_root apt-get update -qq >/dev/null
    as_root apt-get install -y --no-install-recommends zstd >/dev/null
fi

# --- the dependency cache ------------------------------------------------------------------------
mkdir -p "$cache"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
echo "downloading $asset_url"
curl -fsSL --retry 4 --retry-delay 2 --retry-all-errors -o "$tmp/deps.tar.zst" "$asset_url"
zstd -d -q "$tmp/deps.tar.zst" -o "$tmp/deps.tar"
tar -xf "$tmp/deps.tar" -C "$cache"

count="$(find "$cache/p" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"
size="$(du -sh "$cache/p" | cut -f1)"
echo "restored $count packages ($size) into $cache/p"
ls "$cache/p" | sed 's/^/  /'

# --- a plugin repo's own dependencies (PLUGIN_REPO) ---------------------------------------------
if [ -n "${PLUGIN_REPO:-}" ]; then
    repo_dir="$PLUGIN_REPO"
    [ "$repo_dir" = 1 ] && repo_dir="$PWD"
    if [ -f "$repo_dir/build.zig.zon" ]; then
        if (cd "$repo_dir" && ZIG_GLOBAL_CACHE_DIR="$cache" zig build --fetch); then
            echo "every dependency of $repo_dir is in the cache"
        else
            echo "warning: zig build --fetch failed in $repo_dir: a dependency is not in the cache" >&2
        fi
    else
        echo "warning: PLUGIN_REPO=$PLUGIN_REPO has no build.zig.zon" >&2
    fi
fi
