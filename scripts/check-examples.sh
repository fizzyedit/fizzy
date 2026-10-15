#!/usr/bin/env bash
# Build fizzyedit/example-app and fizzyedit/example-plugin against this tree.
#
# Both repos depend on fizzy by URL. Each is built here against a tarball of this tree instead,
# as it is on disk (uncommitted changes too): `zig fetch --save` swaps the pin for it, and a
# fetched package holds only what its `build.zig.zon` lists in `.paths`, exactly as a URL
# dependency does. A path dependency (or `zig build --fork`) would see the whole checkout and
# miss a file left out of `.paths`.
#
# example-app gets the whole repo (its shapes, and its dvui app on either backend), and for its
# replay app the plugin SDK; example-plugin gets the plugin SDK. The SDK is packed as a release
# would be (`scripts/pack-sdk.sh`).
#
# Usage:
#   scripts/check-examples.sh            # clones both repos' main
#   EXAMPLES_DIR=../fizzyedit scripts/check-examples.sh
#                                        # uses checkouts of your own (example-app/ and
#                                        # example-plugin/ in that directory), as they are on
#                                        # disk, copied so they are left untouched
#
# CI: the examples job of .github/workflows/ci.yml.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# A directory's files as they are on disk, without build output or version control.
# macOS's bsdtar would add an AppleDouble `._name` entry beside every file carrying xattrs (every
# checkout has com.apple.provenance); unpacked, `backend/patches/sdl/._0001-….patch` fails the
# SDL patch step with NoSections. GNU tar, which CI uses, writes none (see scripts/pack-sdk.sh).
tar_flags=()
if tar --version 2>/dev/null | grep -q bsdtar; then
  export COPYFILE_DISABLE=1
  tar_flags=(--no-xattrs --no-mac-metadata)
fi
pack() {
  tar "${tar_flags[@]}" -C "$1" -cf - --exclude=./.zig-cache --exclude=./zig-out \
    --exclude=./zig-pkg --exclude=./.git --exclude=./.jj --exclude=./.profile .
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

(cd "$work/example-plugin" && zig fetch --save=fizzy "$sdk_tarball" >/dev/null)
(
  cd "$work/example-app"
  zig fetch --save=fizzy "$work/fizzy.tar.gz" >/dev/null
  # Its replay app depends on the plugin SDK alone: this tree's, packed as a release would be.
  zig fetch --save=fizzy_sdk "$sdk_tarball" >/dev/null
)

# The plugin build installs the plugin: into a profile of its own, not this machine's fizzy.
export FIZZY_PROFILE="$work/profile"
export work

# What each build is: its repo, then its arguments.
build_args() {
  case $1 in
    plugin) echo example-plugin ;;
    minimal | studio | endless) echo "example-app -Dshape=$1" ;;
    # The studio shape as data.
    studio-zon) echo example-app -Dshape=studio -Dzon-layout=true ;;
    replay) echo example-app replay ;;
    # A plain dvui app on fizzy's backend, its floating windows OS windows (`fizzy.addDvui`,
    # `viewports`); and the same code on dvui's own SDL3 backend, through `viewports_none`.
    dvui) echo example-app dvui ;;
    dvui-sdl3) echo example-app dvui -Ddvui-backend=sdl3 ;;
  esac
}
# One build, into a prefix of its own (the shapes all install `fizzy`), its output kept and shown
# only if it fails.
build_one() {
  local args start
  read -r -a args <<< "$(build_args "$1")"
  start=$SECONDS
  if (cd "$work/${args[0]}" && zig build --prefix "$work/out/$1" "${args[@]:1}" --summary all) \
    > "$work/log-$1.txt" 2>&1; then
    echo "ok    $1 ($((SECONDS - start)) s)"
  else
    echo "FAIL  $1 ($((SECONDS - start)) s)"
    sed 's/^/      /' "$work/log-$1.txt"
    return 1
  fi
}
export -f build_args build_one

builds="plugin minimal studio endless studio-zon replay dvui dvui-sdl3"

# Each build is one compile of an app that mostly keeps one core busy, so they run side by side,
# EXAMPLES_JOBS at once (3: CI's runner has 4 cores and 16 GB). First each configuration is
# configured alone (`-l` lists its steps), which fetches the lazy dependencies it asks for, so
# the builds never unpack into one `zig-pkg/` at once.
for b in $builds; do
  read -r -a args <<< "$(build_args "$b")"
  opts=()
  for a in "${args[@]:1}"; do [[ $a == -* ]] && opts+=("$a"); done
  (cd "$work/${args[0]}" && zig build -l ${opts[@]+"${opts[@]}"} > /dev/null)
done
echo "== example-plugin and example-app, against this tree"
printf '%s\n' $builds | xargs -P "${EXAMPLES_JOBS:-3}" -n 1 bash -c 'build_one "$1"' _
