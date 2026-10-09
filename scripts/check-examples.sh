#!/usr/bin/env bash
# Build fizzyedit/example-app and fizzyedit/example-plugin against this tree.
#
# Both repos depend on fizzy by URL. Each is built here against a tarball of this tree instead,
# as it is on disk (uncommitted changes too): `zig fetch --save` swaps the pin for it, and a
# fetched package holds only what its `build.zig.zon` lists in `.paths`, exactly as a URL
# dependency does. A path dependency (or `zig build --fork`) would see the whole checkout and
# miss a file left out of `.paths`.
#
# example-app gets the whole repo, and for its replay app the plugin SDK; example-plugin gets the
# plugin SDK. The SDK is packed as a release would be (`scripts/pack-sdk.sh`).
#
# Usage:
#   scripts/check-examples.sh            # clones both repos' main
#   EXAMPLES_DIR=../fizzyedit scripts/check-examples.sh
#                                        # uses checkouts of your own (example-app/ and
#                                        # example-plugin/ in that directory), as they are on
#                                        # disk, copied so they are left untouched
#
# CI: the Linux job of .github/workflows/ci.yml.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# A directory's files as they are on disk, without build output or version control.
pack() {
  tar -C "$1" -cf - --exclude=./.zig-cache --exclude=./zig-out --exclude=./zig-pkg \
    --exclude=./.git --exclude=./.jj --exclude=./.profile .
}

pack "$root" | gzip > "$work/fizzy.tar.gz"
bash scripts/pack-sdk.sh "$work/sdk" >/dev/null
sdk_tarball="$(ls "$work"/sdk/fizzy-sdk-v*.tar.gz)"

for repo in example-app example-plugin; do
  if [[ -n "${EXAMPLES_DIR:-}" ]]; then
    mkdir -p "$work/$repo"
    pack "$EXAMPLES_DIR/$repo" | tar -x -C "$work/$repo"
  else
    git clone --quiet --depth 1 "https://github.com/fizzyedit/$repo" "$work/$repo"
  fi
done

echo "== example-plugin, against this tree's SDK"
(
  cd "$work/example-plugin"
  zig fetch --save=fizzy "$sdk_tarball" >/dev/null
  # Its build installs the plugin: into a profile of its own, not this machine's fizzy.
  FIZZY_PROFILE="$work/profile" zig build --summary all
)

echo "== example-app, against this tree"
(
  cd "$work/example-app"
  zig fetch --save=fizzy "$work/fizzy.tar.gz" >/dev/null
  # Its replay app depends on the plugin SDK alone: this tree's, packed as a release would be.
  zig fetch --save=fizzy_sdk "$sdk_tarball" >/dev/null
  for shape in minimal studio endless; do
    echo "-- $shape"
    zig build -Dshape="$shape" --summary all
  done
  echo "-- studio, as data"
  zig build -Dshape=studio -Dzon-layout=true --summary all
  echo "-- the replay app"
  zig build replay --summary all
)
