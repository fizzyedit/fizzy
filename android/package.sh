#!/bin/sh
# Package an Android app with the SDK tools; arguments come from build/android.zig.
set -eu

so=$1 manifest=$2 activity=$3 edit=$4 sdl_java=$5 jar=$6 out=$7 bt=$8 abi=$9 keystore=${10} app_id=${11} label=${12} min_sdk=${13} icon=${14:-}
bt=$(cd "$bt" && pwd) # absolute: aapt runs from the staging directory
stage=$(mktemp -d); trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/classes" "$stage/lib/$abi"
javac --release 17 -cp "$jar" -d "$stage/classes" "$sdl_java"/org/libsdl/app/*.java "$edit" "$activity"
"$bt/d8" --lib "$jar" --min-api "$min_sdk" --output "$stage" $(find "$stage/classes" -name '*.class')
# Escape both XML attribute syntax and sed's replacement syntax.
escaped_label=$(printf '%s' "$label" | sed 's/\&/\&amp;/g; s/"/\&quot;/g; s/</\&lt;/g; s/>/\&gt;/g' | sed 's/[\\\&|]/\\\&/g')
icon_attr=
set --
if [ -n "$icon" ]; then
    mkdir -p "$stage/res/mipmap-xxxhdpi"
    cp "$icon" "$stage/res/mipmap-xxxhdpi/ic_launcher.png"
    "$bt/aapt2" compile --dir "$stage/res" -o "$stage/resources.zip"
    icon_attr='android:icon="@mipmap/ic_launcher"'
    set -- "$stage/resources.zip"
fi
sed -e "s|APP_LABEL|$escaped_label|" -e "s|APP_ICON|$icon_attr|" -e "s|minSdkVersion=\"26\"|minSdkVersion=\"$min_sdk\"|" "$manifest" > "$stage/AndroidManifest.xml"
"$bt/aapt2" link -o "$stage/base.apk" --manifest "$stage/AndroidManifest.xml" -I "$jar" --min-sdk-version "$min_sdk" --target-sdk-version 35 --rename-manifest-package "$app_id" "$@"
cp "$so" "$stage/lib/$abi/libmain.so"
(cd "$stage" && "$bt/aapt" add base.apk classes.dex "lib/$abi/libmain.so" >/dev/null)
"$bt/zipalign" -f -P 16 4 "$stage/base.apk" "$out"
"$bt/apksigner" sign --ks "$keystore" --ks-pass pass:android "$out"
