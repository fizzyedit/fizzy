# android/: the Android hello

The host shell of an APK (`AndroidManifest.xml`, `src/FizzyActivity.java`) and a hello
(`src/main.zig`: dvui on SDL3, a tap changes what is drawn). The build is `build/android.zig`
(`scripts/zb build apk -Dandroid-sdk=<dir>`); `README.md` has the steps and the emulator run. The hello
is not an app entry: fizzy on Android is `build/exe.zig` with an Android target.

- **SDL needs its Java `SDLActivity`.** SDL3 has no NativeActivity mode, so "no Java at all" would
  mean a second platform layer beside SDL (input, surface, IME over JNI). Java stays until the
  Zig windowing library (plans#51) grows an Android backend.
- **Zig cannot link the library:** it ships no Android libc, so the NDK's clang does, with the
  hello and SDL archives whole (SDL finds its JNI entry points and `SDL_main` by name).
- **minSdk is 24:** `std.Io` calls `preadv64`/`pwritev64`, which bionic has from API 24.
- **Use a Zig global cache of its own** (`ZIG_GLOBAL_CACHE_DIR`) when the shared one holds dvui's
  other lazy dependencies: Zig unpacks them into `zig-pkg`, and cairo/expat then fail to compile.
- **Nothing in CI builds this yet.** `scripts/zb build apk` needs the NDK and SDK.
  `scripts/zb build android -Dandroid-sdk=<dir>` builds only the native library into
  `zig-out/android/<abi>/libfizzy_hello.so`, without Java or signing. Both steps accept
  `-Dandroid-arch=x86_64` (emulator) or `aarch64` (phone, the default).
