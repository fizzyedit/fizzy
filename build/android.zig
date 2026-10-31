//! `zig build apk -Dandroid-sdk=<dir>`: the Android hello (`android/`), an SDL3 window with dvui
//! drawing, packaged as an APK with the Android SDK's own tools. See `android/README.md`.
const std = @import("std");
const builtin = @import("builtin");
const sdk = @import("sdk.zig");

pub fn add(b: *std.Build) void {
    const android_step = b.step("android", "Build the Android hello native library (needs -Dandroid-sdk)");
    const apk_step = b.step("apk", "Build zig-out/fizzy-hello.apk (needs -Dandroid-sdk)");
    // Options only, never the environment: see `build.zig`. Without the SDK the step says so, and
    // dvui's Android dependencies are never configured for a desktop build.
    const sdk_dir = b.option([]const u8, "android-sdk", "The Android SDK directory (platform 35, build-tools 35.0.0, NDK 27.2.12479018)") orelse {
        const missing_sdk = b.addFail("Android build: pass -Dandroid-sdk=<Android SDK directory>");
        android_step.dependOn(&missing_sdk.step);
        apk_step.dependOn(&missing_sdk.step);
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
    // The NDK ships x86_64 host tools; Darwin's tools also run on Apple Silicon.
    const host_tag = switch (builtin.os.tag) {
        .linux => "linux-x86_64",
        .macos => "darwin-x86_64",
        .windows => "windows-x86_64",
        else => {
            apk_step.dependOn(&b.addFail("Android NDK tools are unavailable for this host OS").step);
            return;
        },
    };
    const sysroot = b.pathJoin(&.{ sdk_dir, "ndk", ndk_version, "toolchains/llvm/prebuilt", host_tag, "sysroot" });

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

    // Artifact publication waits for lazy dependencies; Zig retries configuration after fetching.
    if (b.graph.needed_lazy_dependencies.count() != 0) return;
    const sdl3 = dvui_dep.artifact("SDL3");

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

    android_step.dependOn(&b.addInstallFile(so, b.fmt("android/{s}/libfizzy_hello.so", .{abi})).step);

    // SDL's Java side (the same source the native side is built from), dexed with FizzyActivity,
    // beside the manifest and the library.
    const package = b.addSystemCommand(&.{"sh"});
    package.addFileArg(b.path("android/package.sh"));
    package.addFileArg(so);
    package.addFileArg(b.path("android/AndroidManifest.xml"));
    package.addFileArg(b.path("android/src/FizzyActivity.java"));
    package.addDirectoryArg(dvui_dep.namedLazyPath("sdl3_android_java"));
    package.addArg(b.pathJoin(&.{ sdk_dir, "platforms", platform, "android.jar" }));
    const apk = package.addOutputFileArg("fizzy-hello.apk");
    package.addArgs(&.{ b.pathJoin(&.{ sdk_dir, "build-tools", build_tools }), abi, keystore, app_id });

    apk_step.dependOn(&b.addInstallFile(apk, "fizzy-hello.apk").step);
}
