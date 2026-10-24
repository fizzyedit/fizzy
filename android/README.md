# Android hello

An SDL3 window with dvui drawing, packaged as an APK: the first step of fizzyedit/plans#60. A tap
on the button changes what is drawn. Plugins are compiled in (there are no plugin libraries on
mobile); this hello draws no plugin yet, and it is dvui's own SDL3 backend, not fizzy's.

## Build

`zig build apk` cross-compiles `src/main.zig`, dvui and SDL3, links them with the NDK's clang into
`libfizzy_hello.so`, and packages `zig-out/fizzy-hello.apk` with the Android SDK's tools (`javac`,
`d8`, `aapt2`, `zipalign`, `apksigner`). There is no Gradle project: SDL's Java side is compiled
from the same SDL source the native side is built from, with the 9-line `src/FizzyActivity.java`.

You need a JDK 17 or newer on `PATH` and the Android SDK (platform 35, build-tools 35.0.0, NDK
27.2.12479018) on a Linux x86_64 host. A debug keystore is made once with
`keytool -genkey -v -keystore ~/.android/debug.keystore -alias androiddebugkey -storepass android
-keypass android -keyalg RSA -validity 10000 -dname CN=debug`.

```sh
export ANDROID_HOME=$HOME/android/sdk                    # or -Dandroid_sdk=...
cd android
zig build apk -Dtarget=x86_64-linux-android.24           # the emulator on an x86_64 host
zig build apk -Dtarget=aarch64-linux-android.24          # a phone (the default target)
```

dvui's `sdl3` dependency is lazy: the first `zig build apk` configures, fetches it and configures
again. Other options: `-Dndk_version`, `-Dbuild_tools`, `-Dplatform`, `-Dkeystore`.

## Run in the emulator (pop-os)

The x86_64 emulator needs hardware acceleration, so `/dev/kvm` must be writable by you:
`sudo usermod -aG kvm $USER`, then log in again.

```sh
SDK=$ANDROID_HOME
$SDK/cmdline-tools/latest/bin/sdkmanager "system-images;android-35;google_apis;x86_64" "emulator"
$SDK/cmdline-tools/latest/bin/avdmanager create avd -n fizzy -k "system-images;android-35;google_apis;x86_64" -d pixel_6
$SDK/emulator/emulator -avd fizzy -no-snapshot &         # add -no-window -gpu swiftshader_indirect headless
$SDK/platform-tools/adb install -r zig-out/fizzy-hello.apk
$SDK/platform-tools/adb shell am start -n dev.fizzyedit.hello/.FizzyActivity
$SDK/platform-tools/adb shell input tap 540 1200         # the tap button
$SDK/platform-tools/adb exec-out screencap -p > hello.png
```

## Pitfalls

- **Use a Zig global cache of its own** (`ZIG_GLOBAL_CACHE_DIR`) if the shared one holds dvui's
  other lazy dependencies. Zig unpacks every lazy dependency that sits in the global cache into
  `zig-pkg`, and a dependency of another backend (cairo, expat) then fails to compile under this
  Zig.
- **minSdk is 24:** Zig's `std.Io` calls `preadv64`/`pwritev64`, which bionic has from API 24.
- **Zig cannot link the library:** it ships no Android libc, so the NDK's clang does, with both
  archives whole (SDL finds its JNI entry points and `SDL_main` by name at runtime).

## What is not here yet

Fizzy's own backend (`backend/`: its GPU renderer, glass, OS windows) and the editor are not built
for Android; this hello is dvui on dvui's SDL3 backend. Moving to fizzy's backend is the next step,
and `app/store/registry/compat.zig`'s `hostKey()` must map Android to `android-aarch64` before any
Android build downloads a plugin.
