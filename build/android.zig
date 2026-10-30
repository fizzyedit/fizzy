//! `zig build apk -Dandroid-sdk=<dir>`: the Android hello (`android/`), an SDL3 window with dvui
//! drawing, packaged as an APK with the Android SDK's own tools. See `android/README.md`.
const std = @import("std");
const sdk = @import("sdk.zig");

pub fn add(b: *std.Build) void {
    const apk_step = b.step("apk", "Build zig-out/fizzy-hello.apk (needs -Dandroid-sdk)");
    // Options only, never the environment: see `build.zig`. Without the SDK the step says so, and
    // dvui's Android dependencies are never configured for a desktop build.
    const sdk_dir = b.option([]const u8, "android-sdk", "The Android SDK directory (platform 35, build-tools 35.0.0, NDK 27.2.12479018)") orelse {
        apk_step.dependOn(&b.addFail("zig build apk: pass -Dandroid-sdk=<Android SDK directory>").step);
        return;
    };
    const arch = b.option(enum { aarch64, x86_64 }, "android-arch", "aarch64 (phones, the default) or x86_64 (the emulator on an x86_64 host)") orelse .aarch64;
    const ndk_version = b.option([]const u8, "android-ndk", "NDK under <sdk>/ndk") orelse "27.2.12479018";
    const build_tools = b.option([]const u8, "android-build-tools", "Build-tools under <sdk>/build-tools") orelse "35.0.0";
    const platform = b.option([]const u8, "android-platform", "Platform under <sdk>/platforms") orelse "android-35";
    const keystore = b.option([]const u8, "android-keystore", "Debug keystore (alias androiddebugkey, password android)") orelse
        b.pathJoin(&.{ b.graph.environ_map.get("HOME") orelse ".", ".android/debug.keystore" });
    // The activity's Java package stays `dev.fizzyedit.hello` (its source); this is the app's id.
    const app_id = b.fmt("dev.fizzy.{s}", .{@import("bundle_id.zig").component(b.allocator, "hello")});

    const target = b.resolveTargetQuery(.{
        .cpu_arch = switch (arch) {
            .aarch64 => .aarch64,
            .x86_64 => .x86_64,
        },
        .os_tag = .linux,
        .abi = .android,
        .android_api_level = 24, // Zig's std.Io calls preadv64/pwritev64, which bionic has from API 24
    });
    const optimize: std.lang.OptimizeMode = .ReleaseSafe;
    const abi = switch (arch) {
        .aarch64 => "arm64-v8a",
        .x86_64 => "x86_64",
    };
    const triple = b.fmt("{s}-linux-android", .{@tagName(arch)});
    const sysroot = b.pathJoin(&.{ sdk_dir, "ndk", ndk_version, "toolchains/llvm/prebuilt/linux-x86_64/sysroot" });

    const dvui_dep = sdk.dvuiDependency(b, .{
        .target = target,
        .optimize = optimize,
        .backend = .sdl3,
        .accesskit = .off,
        .android_include_path = std.Build.LazyPath{ .cwd_relative = b.pathJoin(&.{ sysroot, "usr/include" }) },
    });

    const mod = b.createModule(.{
        .root_source_file = b.path("android/src/main.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true, // linked into the app's JNI .so
    });
    mod.addImport("dvui", dvui_dep.module("dvui_sdl3"));
    const hello = b.addLibrary(.{ .name = "fizzy_hello", .root_module = mod });
    // Debug C code (SDL, stb) calls __ubsan_handle_*, which the NDK linker has no runtime for.
    hello.bundle_ubsan_rt = true;
    hello.bundle_compiler_rt = true; // ubsan_rt needs __extendxftf2, which the NDK lacks

    // dvui builds its SDL3 only once its lazy `sdl3` dependency is fetched, which is after the first
    // configure pass; `dvui_dep.artifact("SDL3")` panics on that pass instead of waiting.
    const sdl3 = for (dvui_dep.builder.install_tls.step.dependencies.items) |dep| {
        const install = dep.cast(std.Build.Step.InstallArtifact) orelse continue;
        if (std.mem.eql(u8, install.artifact.name, "SDL3")) break install.artifact;
    } else return;

    // Zig ships no Android libc, so the NDK's clang links. SDL finds its JNI entry points and
    // `SDL_main` by name at runtime, so both archives link whole.
    const link = b.addSystemCommand(&.{ b.pathJoin(&.{ sysroot, "../bin/clang" }), b.fmt("--target={s}24", .{triple}), "-shared" });
    const so = link.addPrefixedOutputFileArg("-o", "libfizzy_hello.so");
    link.addArgs(&.{ "-s", "-Wl,--gc-sections", "-Wl,-z,max-page-size=16384", "-Wl,--whole-archive" });
    link.addArtifactArg(hello);
    link.addArtifactArg(sdl3);
    link.addArgs(&.{
        "-Wl,--no-whole-archive",
        "-landroid",
        "-llog",
        "-lEGL",
        "-lGLESv1_CM",
        "-lGLESv2",
        "-lOpenSLES",
        "-ldl",
        "-lm",
    });

    // SDL's Java side (the same source the native side is built from), dexed with FizzyActivity,
    // beside the manifest and the library.
    const package = b.addSystemCommand(&.{
        "sh",      "-ec",
        \\so=$1 manifest=$2 activity=$3 sdl_java=$4 jar=$5 out=$6 bt=$7 abi=$8 keystore=$9 app_id=${10}
        \\bt=$(cd "$bt" && pwd) # absolute: aapt runs from the staging directory
        \\stage=$(mktemp -d); trap 'rm -rf "$stage"' EXIT
        \\mkdir -p "$stage/classes" "$stage/lib/$abi"
        \\javac --release 17 -cp "$jar" -d "$stage/classes" "$sdl_java"/org/libsdl/app/*.java "$activity"
        \\"$bt/d8" --lib "$jar" --min-api 24 --output "$stage" $(find "$stage/classes" -name '*.class')
        \\"$bt/aapt2" link -o "$stage/base.apk" --manifest "$manifest" -I "$jar" --min-sdk-version 24 --target-sdk-version 35 --rename-manifest-package "$app_id"
        \\cp "$so" "$stage/lib/$abi/libfizzy_hello.so"
        \\(cd "$stage" && "$bt/aapt" add base.apk classes.dex "lib/$abi/libfizzy_hello.so" >/dev/null)
        \\"$bt/zipalign" -f -P 16 4 "$stage/base.apk" "$out"
        \\"$bt/apksigner" sign --ks "$keystore" --ks-pass pass:android "$out"
        ,
        "package",
    });
    package.addFileArg(so);
    package.addFileArg(b.path("android/AndroidManifest.xml"));
    package.addFileArg(b.path("android/src/FizzyActivity.java"));
    package.addDirectoryArg(dvui_dep.namedLazyPath("sdl3_android_java"));
    package.addArg(b.pathJoin(&.{ sdk_dir, "platforms", platform, "android.jar" }));
    const apk = package.addOutputFileArg("fizzy-hello.apk");
    package.addArgs(&.{ b.pathJoin(&.{ sdk_dir, "build-tools", build_tools }), abi, keystore, app_id });

    apk_step.dependOn(&b.addInstallFile(apk, "fizzy-hello.apk").step);
}
