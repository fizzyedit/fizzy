# Android hello

An SDL3 window with dvui drawing, packaged as an APK: the first step of fizzyedit/plans#60. A tap
on the button changes what is drawn. Plugins are compiled in (there are no plugin libraries on
mobile); this hello draws no plugin yet, and it is dvui's own SDL3 backend, not fizzy's.

## Build

`zig build apk` (`build/android.zig`, in the root build graph) cross-compiles `android/src/main.zig`, dvui and SDL3, links them with the NDK's clang into
`libfizzy_hello.so`, and packages `zig-out/fizzy-hello.apk` with the Android SDK's tools (`javac`,
`d8`, `aapt2`, `zipalign`, `apksigner`). There is no Gradle project: SDL's Java side is compiled
from the same SDL source the native side is built from, with the 9-line `src/FizzyActivity.java`.

You need a JDK 17 or newer on `PATH` and the Android SDK (platform 35, build-tools 35.0.0, NDK
27.2.12479018) on a Linux x86_64 host. A debug keystore is made once with
`keytool -genkey -v -keystore ~/.android/debug.keystore -alias androiddebugkey -storepass android
-keypass android -keyalg RSA -validity 10000 -dname CN=debug`.

```sh
export ANDROID_HOME=$HOME/android/sdk
zig build apk -Dandroid-sdk=$ANDROID_HOME -Dandroid-arch=x86_64   # the emulator on an x86_64 host
zig build apk -Dandroid-sdk=$ANDROID_HOME                         # a phone (aarch64, the default)
```

dvui's `sdl3` dependency is lazy: the first `zig build apk` configures, fetches it and configures
again. Other options: `-Dandroid-ndk`, `-Dandroid-build-tools`, `-Dandroid-platform`, `-Dandroid-keystore`. The app id is `dev.fizzy.hello` (`build/bundle_id.zig`).

## Run in the emulator (pop-os)

The x86_64 emulator needs hardware acceleration, so `/dev/kvm` must be writable by you:
`sudo usermod -aG kvm $USER`, then log in again.

```sh
SDK=$ANDROID_HOME
$SDK/cmdline-tools/latest/bin/sdkmanager "system-images;android-35;google_apis;x86_64" "emulator"
$SDK/cmdline-tools/latest/bin/avdmanager create avd -n fizzy -k "system-images;android-35;google_apis;x86_64" -d pixel_6
$SDK/emulator/emulator -avd fizzy -no-snapshot &         # add -no-window -gpu swiftshader_indirect headless
$SDK/platform-tools/adb install -r zig-out/fizzy-hello.apk
$SDK/platform-tools/adb shell am start -n dev.fizzy.hello/dev.fizzyedit.hello.FizzyActivity
$SDK/platform-tools/adb shell input tap 540 1200         # the tap button
$SDK/platform-tools/adb exec-out screencap -p > hello.png
```

## Pitfalls

See `AGENTS.md`: the Zig cache, minSdk 24, linking with the NDK's clang, and why Java stays
(SDL3 runs only under its `SDLActivity`; a NativeActivity would be a second platform layer).

## What is not here yet

This hello is dvui on dvui's own SDL3 backend and its lazy `sdl3` package: a second SDL pin beside
`backend/build.zig.zon`'s, kept as a stated, temporary exception. Fizzy's backend (`backend/`: its
GPU renderer, glass, OS windows) has no Android target in its build yet, and linking the hello
against it, with SDL's Java sources from the same pinned `sdl_source`, was not attempted here. The
editor is not built for Android either, and `app/store/registry/compat.zig`'s `hostKey()` must map
Android to `android-aarch64` before any Android build downloads a plugin.
