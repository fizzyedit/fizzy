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
    const app_id = "dev.fizzy.hello";

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
    const hello = b.addLibrary(.{ .name = "main", .root_module = mod });
    // Debug C code (SDL, stb) calls __ubsan_handle_*, which the NDK linker has no runtime for.
    hello.bundle_ubsan_rt = true;
    hello.bundle_compiler_rt = true; // ubsan_rt needs __extendxftf2, which the NDK lacks

    const linked = linkLibrary(b, paths, target.result.cpu.arch, hello);
    android_step.dependOn(&b.addInstallFile(linked.so, b.fmt("android/{s}/libmain.so", .{linked.abi})).step);
    const apk = addApk(b, paths, target.result.cpu.arch, hello, .{
        .id = app_id,
        .label = "Fizzy",
        .icon = null,
        .apk_name = "fizzy-hello.apk",
    });
    apk_step.dependOn(&b.addInstallFile(apk, "fizzy-hello.apk").step);
}

/// Links and packages an Android static app library. The library's target sets minSdk.
pub fn addApk(b: *std.Build, sdk: AndroidSdk, arch: std.Target.Cpu.Arch, lib: *std.Build.Step.Compile, app: struct {
    id: []const u8,
    label: []const u8,
    icon: ?std.Build.LazyPath,
    apk_name: []const u8,
}) std.Build.LazyPath {
    const linked = linkLibrary(b, sdk, arch, lib);
    const package = b.addSystemCommand(&.{"sh"});
    package.addFileArg(b.path("android/package.sh"));
    package.addFileArg(linked.so);
    package.addFileArg(b.path("android/AndroidManifest.xml"));
    package.addFileArg(b.path("android/src/FizzyActivity.java"));
    package.addDirectoryArg(linked.java);
    package.addArg(b.pathJoin(&.{ sdk.dir, "platforms", sdk.platform, "android.jar" }));
    const apk = package.addOutputFileArg(app.apk_name);
    package.addArgs(&.{ b.pathJoin(&.{ sdk.dir, "build-tools", sdk.build_tools }), linked.abi, sdk.keystore, app.id, app.label, b.fmt("{d}", .{lib.root_module.resolved_target.?.result.os.version_range.linux.android}) });
    if (app.icon) |icon| package.addFileArg(icon);
    return apk;
}

fn linkLibrary(b: *std.Build, paths: AndroidSdk, arch: std.Target.Cpu.Arch, lib: *std.Build.Step.Compile) struct { so: std.Build.LazyPath, java: std.Build.LazyPath, abi: []const u8 } {
    const target = lib.root_module.resolved_target.?;
    const optimize = lib.root_module.optimize.?;
    const abi = switch (arch) {
        .aarch64 => "arm64-v8a",
        .x86_64 => "x86_64",
        else => @panic("Android APK supports aarch64 and x86_64"),
    };
    const sysroot = paths.sysroot(b, b.graph.host.result.os.tag);
    const sdl_paths = @import("common.zig").sdlSystemPaths(b, target, null, paths) catch @panic("Android SDK paths unavailable");
    const native = exe.nativeDvui(b, .fizzy, target, optimize, .off, sdl_paths);
    // Zig retries configuration after fetching these lazy dependencies.
    const sdl = backend.androidSdl(exe.backendDependency(b), exe.backendOptions(target, optimize, sdl_paths)) orelse
        return .{ .so = b.path("android/AndroidManifest.xml"), .java = b.path("android/src"), .abi = abi };
    const link = b.addSystemCommand(&.{ b.pathJoin(&.{ sysroot, "../bin/clang" }), b.fmt("--target={s}-linux-android{d}", .{ @tagName(arch), target.result.os.version_range.linux.android }), "-shared" });
    const so = link.addPrefixedOutputFileArg("-o", "libmain.so");
    // SDL resolves JNI entry points and SDL_main by name at runtime.
    link.addArgs(&.{ "-s", "-Wl,--gc-sections", "-Wl,-z,max-page-size=16384", "-Wl,--whole-archive" });
    link.addArtifactArg(lib);
    link.addArtifactArg(sdl.lib);
    link.addArg("-Wl,--no-whole-archive");
    // Zig static archives do not contain dvui's linked C libraries.
    if (native.dep.builder.lazyDependency("freetype", .{ .target = target, .optimize = optimize })) |ft|
        link.addArtifactArg(ft.artifact("freetype"));
    if (native.dep.builder.lazyDependency("tree_sitter", .{ .target = target, .optimize = optimize })) |ts|
        link.addArtifactArg(ts.artifact("tree-sitter"));
    link.addArgs(&.{ "-landroid", "-llog", "-lEGL", "-lGLESv1_CM", "-lGLESv2", "-lOpenSLES", "-ldl", "-lm" });
    return .{ .so = so, .java = sdl.java, .abi = abi };
}

pub fn sdlMainModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.OptimizeMode) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("android/sdl_main.zig"),
        .target = target,
        .optimize = optimize,
    });
}
