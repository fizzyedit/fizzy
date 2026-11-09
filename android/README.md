# Android hello

An SDL3 window with dvui drawing, packaged as an APK: the first step of fizzyedit/plans#60. A tap
on the button changes what is drawn. Plugins are compiled in (there are no plugin libraries on
mobile); this hello draws no plugin yet. The hello runs on fizzy's backend with SDL's Java
from `backend/`'s pinned SDL.

## Build

`zig build apk` (`build/android.zig`, in the root build graph) cross-compiles `android/src/main.zig`, dvui and SDL3, links them with the NDK's clang into
`libmain.so`, and packages `zig-out/fizzy-hello.apk` with the Android SDK's tools (`javac`,
`d8`, `aapt2`, `zipalign`, `apksigner`). There is no Gradle project: SDL's Java side is compiled
from the same SDL source the native side is built from, with the 9-line `src/FizzyActivity.java`.

You need a JDK 17 or newer on `PATH` and the Android SDK (platform 35, build-tools 35.0.0, NDK
27.2.12479018). The build selects the NDK toolchain directory for the host OS. Packaging
requires a POSIX shell; only Linux packaging has been exercised. A debug keystore is made once with
`keytool -genkey -v -keystore ~/.android/debug.keystore -alias androiddebugkey -storepass android
-keypass android -keyalg RSA -validity 10000 -dname CN=debug`.

```sh
export ANDROID_HOME=$HOME/android/sdk
scripts/zb build apk -Dandroid-sdk=$ANDROID_HOME -Dandroid-arch=x86_64   # the emulator on an x86_64 host
scripts/zb build apk -Dandroid-sdk=$ANDROID_HOME                         # a phone (aarch64, the default)
```

`scripts/zb build android -Dandroid-sdk=$ANDROID_HOME -Dandroid-arch=x86_64` builds only the
native library, installed at `zig-out/android/x86_64/libmain.so` (or `android/arm64-v8a/`
for aarch64). It does not require Java, APK signing, or an emulator. Neither Android step is
part of a default desktop build.

The backend's SDL dependency is lazy: the first `scripts/zb build apk` configures, fetches it and configures
again. Other options: `-Dandroid-ndk`, `-Dandroid-build-tools`, `-Dandroid-platform`, `-Dandroid-keystore`. The app id is `dev.fizzy.hello` (`build/bundle_id.zig`).

## An app as an APK

An app built on fizzy adds the APK step after `buildApp` in its `build.zig`:

```zig
try fizzy.buildApp(fizzy_dep, &.{ fizzy.plugins.workbench, fizzy.plugins.text });
try fizzy.addApkSteps(b, fizzy_dep);
```

Pass `.@"defer-app" = true`, the Android target, and `android-sdk` to the fizzy dependency,
just as for the other build options. Then run:

```sh
export PATH=/opt/android-jdk/bin:$PATH
export ANDROID_HOME=/opt/android-sdk
zig build apk -Dtarget=aarch64-linux-android -Dandroid-sdk=$ANDROID_HOME
```

The result is `zig-out/<app-name>.apk`. Its package id comes from `app-bundle-id`, its
launcher label from `app-package-title` (or `app-name`), and its PNG launcher icon from
`app-icon` (fizzy's icon by default). The shared library is always `libmain.so`; the activity's
Java package stays `dev.fizzyedit.hello` independently of the app id. APKs request INTERNET
permission and resize the window for the software keyboard.

App APKs require API 26 or newer because the crash reporter uses `pthread_getname_np`;
the hello keeps API 24. The default Android target API is also supported. Packaging uses the
debug keystore selected by `android-keystore`. Updates need the same package id and the
same keystore: keep that key to install an update over an existing installation. This step
does not create a release key. A non-Android `apk` step explains which target to pass.

## Run in the emulator (pop-os)

The x86_64 emulator needs hardware acceleration, so `/dev/kvm` must be writable by you:
`sudo usermod -aG kvm $USER`, then log in again. First run
`$ANDROID_HOME/emulator/emulator -accel-check`: if `/dev/kvm` is absent, the host needs KVM
exposed before group permissions can help. A display is optional with `-no-window`.

```sh
SDK=$ANDROID_HOME
$SDK/cmdline-tools/latest/bin/sdkmanager "system-images;android-35;google_apis;x86_64" "emulator"
$SDK/cmdline-tools/latest/bin/avdmanager create avd -n fizzy -k "system-images;android-35;google_apis;x86_64" -d pixel_6
$SDK/emulator/emulator -avd fizzy -no-snapshot &         # add -no-window -gpu swiftshader_indirect headless
$SDK/platform-tools/adb install -r zig-out/fizzy-hello.apk
$SDK/platform-tools/adb shell am start -n dev.fizzy.hello/dev.fizzyedit.hello.FizzyActivity
$SDK/platform-tools/adb exec-out screencap -p > hello-before.png
# Read the button position from hello-before.png; coordinates vary with the AVD.
$SDK/platform-tools/adb shell input tap <button-x> <button-y>
$SDK/platform-tools/adb exec-out screencap -p > hello-after.png
```

Confirm that the displayed tap count increases by one in the second screenshot; a different
image alone does not prove that touch input reached the button.

## Lifecycle check

Leaving and coming back, ten times over, then Back. With the app running:

```sh
ADB=$ANDROID_HOME/platform-tools/adb
for i in $(seq 10); do
  $ADB shell input keyevent KEYCODE_HOME
  $ADB shell monkey -p dev.fizzy.hello 1
done
```

Each time the app comes back it draws at once. Then open a menu and press Back:
`$ADB shell input keyevent KEYCODE_BACK` closes the menu (Back reaches the app as Escape). Press it
once more: with nothing left to close the app goes to the background without finishing, and
`$ADB shell dumpsys activity activities | grep -i fizzy` still lists it. Last,
`$ADB logcat -d | grep -E " F DEBUG|SDL_GPU"` prints nothing: no crash, no GPU error.

## Pitfalls

See `AGENTS.md`: the Zig cache, minSdk 24, linking with the NDK's clang, and why Java stays
(SDL3 runs only under its `SDLActivity`; a NativeActivity would be a second platform layer).

Nothing in CI builds this yet. The proposed **Android (library)** job builds the native library
on Ubuntu with the Android SDK and NDK 27.x; the maintainer adds this job separately.
Device verification follows a green PR.
