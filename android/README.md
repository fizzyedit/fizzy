# Android hello

An SDL3 window with dvui drawing, packaged as an APK: the first step of fizzyedit/plans#60. A tap
on the button changes what is drawn. Plugins are compiled in (there are no plugin libraries on
mobile); this hello draws no plugin yet, and it is dvui's own SDL3 backend, not fizzy's.

## How it is built

Two halves, as in dvui's `examples/android-example` (kept for now, as the plan recommends):

- **`zig build lib`** (this directory) cross-compiles `src/main.zig`, dvui and SDL3 to two static
  archives, `libfizzy_hello.a` and `libSDL3.a`, and installs SDL's Java sources beside them. dvui is
  the repo's one pin, reached through `../sdk` (`build.zig`).
- **`project/`** is a Gradle project that compiles SDL's Java side, links both archives into
  `libfizzy_hello.so` with the NDK's CMake (`app/src/main/c`), and packages the APK. Its
  `zigBuild_<abi>` tasks run `zig build lib` before every build, once per ABI.

`arm64-v8a` is the phone; `x86_64` is the emulator on an x86_64 host (an arm64 image does not run
on one). `-PabiFilters=arm64-v8a` builds the phone's alone.

## Build

You need a JDK 17 or newer, the Android SDK (platform 35, build-tools 35, NDK 27.2.12479018,
CMake) and `zig` on `PATH`. Gradle installs missing SDK parts itself once `sdk.dir` is set.

```sh
cd android/project
echo "sdk.dir=$HOME/Android/Sdk" > local.properties        # untracked
export JAVA_HOME=... ANDROID_HOME=$HOME/Android/Sdk
./gradlew assembleDebug                                    # app/build/outputs/apk/debug/app-debug.apk
```

Or the Zig half alone, for one ABI:

```sh
cd android
zig build lib -Dtarget=x86_64-linux-android.24 -Doptimize=ReleaseSafe \
    -Dandroid_include_path=$ANDROID_HOME/ndk/27.2.12479018/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include
```

dvui's `sdl3` dependency is lazy: the first `zig build lib` configures, fetches it and configures
again. `build.zig` skips installing SDL3 on the first pass (dvui's `artifact("SDL3")` would panic).

## Run

```sh
avdmanager create avd -n fizzy -k "system-images;android-35;google_apis;x86_64" -d pixel_6
emulator -avd fizzy -no-snapshot            # needs /dev/kvm; add -no-window -gpu swiftshader_indirect headless
adb install -r project/app/build/outputs/apk/debug/app-debug.apk
adb shell am start -n dev.fizzyedit.hello/.FizzyActivity
adb exec-out screencap -p > hello.png
adb shell input tap 540 1200                # the tap button
```

## Pitfalls

- **Use a Zig global cache of its own** (`ZIG_GLOBAL_CACHE_DIR`) if the shared one holds dvui's
  other lazy dependencies. Zig unpacks every lazy dependency that sits in the global cache into
  `zig-pkg`, and a dependency of another backend (cairo, expat) then fails to compile under this
  Zig.
- **minSdk is 24:** Zig's `std.Io` calls `preadv64`/`pwritev64`, which bionic has from API 24.
- **The Java side and the native side come from one SDL source**, so they cannot drift.

## What is not here yet

Fizzy's own backend (`backend/`: its GPU renderer, glass, OS windows) and the editor are not built
for Android; this hello is dvui on dvui's SDL3 backend. Moving to fizzy's backend is the next step,
and `app/store/registry/compat.zig`'s `hostKey()` must map Android to `android-aarch64` before any
Android build downloads a plugin.
