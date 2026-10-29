#!/bin/sh
# Package the Android hello with the SDK tools; arguments come from build/android.zig.
set -eu

so=$1 manifest=$2 activity=$3 sdl_java=$4 jar=$5 out=$6 bt=$7 abi=$8 keystore=$9 app_id=${10}
bt=$(cd "$bt" && pwd) # absolute: aapt runs from the staging directory
stage=$(mktemp -d); trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/classes" "$stage/lib/$abi"
javac --release 17 -cp "$jar" -d "$stage/classes" "$sdl_java"/org/libsdl/app/*.java "$activity"
"$bt/d8" --lib "$jar" --min-api 24 --output "$stage" $(find "$stage/classes" -name '*.class')
"$bt/aapt2" link -o "$stage/base.apk" --manifest "$manifest" -I "$jar" --min-sdk-version 24 --target-sdk-version 35 --rename-manifest-package "$app_id"
cp "$so" "$stage/lib/$abi/libfizzy_hello.so"
(cd "$stage" && "$bt/aapt" add base.apk classes.dex "lib/$abi/libfizzy_hello.so" >/dev/null)
"$bt/zipalign" -f -P 16 4 "$stage/base.apk" "$out"
"$bt/apksigner" sign --ks "$keystore" --ks-pass pass:android "$out"
