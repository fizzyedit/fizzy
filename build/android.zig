//! `zig build apk -Dandroid-sdk=<dir>`: the Android hello (`android/`), an SDL3 window with dvui
//! drawing, packaged as an APK with the Android SDK's own tools. See `android/README.md`.
const std = @import("std");
const exe = @import("exe.zig");
const backend = @import("fizzy_backend");

pub const AndroidSdk = struct {
    dir: []const u8,
    ndk: []const u8,
    build_tools: []const u8,
    platform: []const u8,
    keystore: []const u8,

    pub fn sysroot(self: AndroidSdk, b: *std.Build, host: std.Target.Os.Tag) []const u8 {
        // The NDK ships x86_64 host tools; Darwin's tools also run on Apple Silicon.
        const host_tag = switch (host) {
            .linux => "linux-x86_64",
            .macos => "darwin-x86_64",
            .windows => "windows-x86_64",
            else => @panic("Android NDK tools are unavailable for this host OS"),
        };
        return b.pathJoin(&.{ self.dir, "ndk", self.ndk, "toolchains/llvm/prebuilt", host_tag, "sysroot" });
    }
};

pub fn add(b: *std.Build, android: ?AndroidSdk) void {
    const android_step = b.step("android", "Build the Android hello native library (needs -Dandroid-sdk)");
    const apk_step = b.step("apk", "Build zig-out/fizzy-hello.apk (needs -Dandroid-sdk)");
    const paths = android orelse {
        const missing_sdk = b.addFail("Android build: pass -Dandroid-sdk=<Android SDK directory>");
        android_step.dependOn(&missing_sdk.step);
        apk_step.dependOn(&missing_sdk.step);
        return;
    };
    const arch = b.option(enum { aarch64, x86_64 }, "android-arch", "aarch64 (phones, the default) or x86_64 (the emulator on an x86_64 host)") orelse .aarch64;
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
    const sysroot = paths.sysroot(b, b.graph.host.result.os.tag);
    const sdl_paths = @import("common.zig").sdlSystemPaths(b, target, null, paths) catch @panic("Android SDK paths unavailable");
    const native = exe.nativeDvui(b, .fizzy, target, optimize, .off, sdl_paths);

    const mod = b.createModule(.{
        .root_source_file = b.path("android/src/main.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true, // linked into the app's JNI .so
    });
    mod.addImport("android_sdl_main", sdlMainModule(b, target, optimize));
    mod.addImport("dvui", native.dvui);
    mod.addImport("backend", native.backend);
    mod.addImport("platform", exe.platformModule(b, native, target, optimize, sdl_paths));
    const hello = b.addLibrary(.{ .name = "fizzy_hello", .root_module = mod });
    // Debug C code (SDL, stb) calls __ubsan_handle_*, which the NDK linker has no runtime for.
    hello.bundle_ubsan_rt = true;
    hello.bundle_compiler_rt = true; // ubsan_rt needs __extendxftf2, which the NDK lacks

    // Artifact publication waits for lazy dependencies; Zig retries configuration after fetching.
    const sdl = backend.androidSdl(exe.backendDependency(b), exe.backendOptions(target, optimize, sdl_paths)) orelse return;

    // Zig ships no Android libc, so the NDK's clang links. SDL finds its JNI entry points and
    // `SDL_main` by name at runtime, so both archives link whole.
    const link = b.addSystemCommand(&.{ b.pathJoin(&.{ sysroot, "../bin/clang" }), b.fmt("--target={s}24", .{triple}), "-shared" });
    const so = link.addPrefixedOutputFileArg("-o", "libfizzy_hello.so");
    link.addArgs(&.{ "-s", "-Wl,--gc-sections", "-Wl,-z,max-page-size=16384", "-Wl,--whole-archive" });
    link.addArtifactArg(hello);
    link.addArtifactArg(sdl.lib);
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
    package.addDirectoryArg(sdl.java);
    package.addArg(b.pathJoin(&.{ paths.dir, "platforms", paths.platform, "android.jar" }));
    const apk = package.addOutputFileArg("fizzy-hello.apk");
    package.addArgs(&.{ b.pathJoin(&.{ paths.dir, "build-tools", paths.build_tools }), abi, paths.keystore, app_id });

    apk_step.dependOn(&b.addInstallFile(apk, "fizzy-hello.apk").step);
}

pub fn sdlMainModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.OptimizeMode) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("android/sdl_main.zig"),
        .target = target,
        .optimize = optimize,
    });
}
