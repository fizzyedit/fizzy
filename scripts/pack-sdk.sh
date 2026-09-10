#!/usr/bin/env bash
# Pack the plugin-facing SDK into a self-contained tarball for URL pins.
#
# Zig has no "depend on a subdirectory of this archive" — plugins must fetch a
# package whose root build.zig.zon has no Velopack. This script stages `sdk/` as
# the package root and vendors `core/` + `src/sdk` beside it so
# `plugin_sdk.repoPath` resolves via in-package `src/` (see that function).
#
# Usage:
#   ./scripts/pack-sdk.sh                 # writes zig-out/sdk/fizzy-sdk-vX.Y.Z.tar.gz
#   ./scripts/pack-sdk.sh /tmp/out        # alternate output directory
#
# CI: .github/workflows/sdk-tag.yml runs this and uploads the archive as a
# GitHub release asset on the matching sdk-v* tag.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

block=$(awk '/pub const sdk_version = std\.SemanticVersion\{/,/\};/' sdk/sdk_version.zig)
major=$(grep -oE '\.major = [0-9]+' <<<"$block" | grep -oE '[0-9]+')
minor=$(grep -oE '\.minor = [0-9]+' <<<"$block" | grep -oE '[0-9]+')
patch=$(grep -oE '\.patch = [0-9]+' <<<"$block" | grep -oE '[0-9]+')
if [[ -z "$major" || -z "$minor" || -z "$patch" ]]; then
  echo "pack-sdk: failed to parse sdk_version from sdk/sdk_version.zig" >&2
  exit 1
fi

version="${major}.${minor}.${patch}"
tag="sdk-v${version}"
pkg_name="fizzy-sdk-v${version}"
out_dir="${1:-"$root/zig-out/sdk"}"
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT

pkg="$staging/$pkg_name"
mkdir -p "$pkg/src"

# Package root = today's sdk/ build surface (no app-only deps).
cp -R sdk/. "$pkg/"
# Runtime / module sources that exportModules points at.
cp -R core "$pkg/core"
cp -R src/sdk "$pkg/src/sdk"

# Drop build/editor-only noise if any leaked into the copy (none expected).
rm -rf "$pkg/core/.zig-cache" "$pkg/src/sdk/.zig-cache" 2>/dev/null || true
rm -rf "$pkg/.zig-cache" "$pkg/zig-pkg" "$pkg/zig-out" 2>/dev/null || true

# Tarball package must hash the vendored trees (`core/` and `src/sdk/`); the in-repo
# sdk/build.zig.zon does not list them, because there they live beside the package
# rather than inside it.
python3 - <<'PY' "$pkg/build.zig.zon" "$version"
import sys, re
path, version = sys.argv[1], sys.argv[2]
text = open(path).read()
if '"src"' not in text.split(".paths")[1].split("}")[0]:
    text = text.replace(
        '        "paths.zig",\n    },',
        '        "paths.zig",\n        "core",\n        "src",\n    },',
        1,
    )
text = re.sub(r'\.version = "[^"]*"', f'.version = "{version}"', text, count=1)
open(path, "w").write(text)
PY

mkdir -p "$out_dir"
archive="$out_dir/${pkg_name}.tar.gz"
tar -czf "$archive" -C "$staging" "$pkg_name"

echo "Packed $tag -> $archive"
url="https://github.com/fizzyedit/fizzy/releases/download/${tag}/${pkg_name}.tar.gz"
echo "Pin example:"
echo "  .fizzy = .{"
echo "      .url = \"${url}\","
echo "      .hash = \"…\","
echo "  },"
echo
echo "  zig fetch --save=fizzy ${url}"
