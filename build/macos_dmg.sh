#!/bin/sh
# A drag-to-Applications disk image from the .app vpk packed: the bundle beside a link to
# /Applications. Run by `zig build package` for a macOS target (build/package.zig).
#
#   macos_dmg.sh <vpk-output-dir> <volume-name> <sign-identity> <notary-profile> <out.dmg>
#
# The .app comes out of vpk's `*-Portable.zip`, already signed (and notarized and stapled when
# vpk was given a notary profile), so the image holds the very bundle the .pkg installs. An
# empty <sign-identity> leaves the image unsigned; an empty <notary-profile> leaves it
# unnotarized. Velopack updates an app run from wherever it was dragged to, since its locator
# goes by the executable's path.
set -eu

if [ "$#" -ne 5 ]; then
    echo "usage: $0 <vpk-output-dir> <volume-name> <sign-identity> <notary-profile> <out.dmg>" >&2
    exit 2
fi
vpk_dir="$1"
volume="$2"
identity="$3"
notary_profile="$4"
out="$5"

if ! command -v hdiutil >/dev/null 2>&1; then
    echo "error: a macOS .dmg needs hdiutil, so it is built on a macOS host only" >&2
    exit 1
fi

zip=""
for f in "$vpk_dir"/*-Portable.zip; do
    [ -f "$f" ] && zip="$f" && break
done
if [ -z "$zip" ]; then
    echo "error: no *-Portable.zip in $vpk_dir to take the .app from" >&2
    ls -la "$vpk_dir" >&2
    exit 1
fi

stage="$(mktemp -d "${TMPDIR:-/tmp}/fizzy-dmg.XXXXXX")"
trap 'rm -rf "$stage"' EXIT

# ditto, not unzip: it keeps the bundle's symlinks, extended attributes and signature intact.
ditto -x -k "$zip" "$stage"
apps=$(find "$stage" -maxdepth 1 -name '*.app' -type d | wc -l | tr -d ' ')
if [ "$apps" != "1" ]; then
    echo "error: expected one .app in $zip, found $apps" >&2
    exit 1
fi
ln -s /Applications "$stage/Applications"

rm -f "$out"
# hdiutil create fails now and then with "Resource busy" on CI runners; a retry clears it.
n=0
until hdiutil create -volname "$volume" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$out"; do
    n=$((n + 1))
    if [ "$n" -ge 3 ]; then
        echo "error: hdiutil create failed $n times" >&2
        exit 1
    fi
    sleep $((n * 5))
done

if [ -n "$identity" ]; then
    codesign --force --sign "$identity" --timestamp "$out"
    codesign --verify --verbose=2 "$out"
fi
if [ -n "$notary_profile" ]; then
    # Notarizing an unsigned image is refused, so a profile without an identity is a mistake.
    if [ -z "$identity" ]; then
        echo "error: notarizing the .dmg needs -Dmacos-sign-app as well" >&2
        exit 1
    fi
    xcrun notarytool submit "$out" --keychain-profile "$notary_profile" --wait
    xcrun stapler staple "$out"
    xcrun stapler validate "$out"
fi
