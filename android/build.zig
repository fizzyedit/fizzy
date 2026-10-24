//! The Android hello: an SDL3 window with dvui drawing, as two static archives that the Gradle
//! project in `project/` links into its JNI library. See README.md.
const std = @import("std");
const dvui_build = @import("fizzy_sdk").dvui;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = .{
        .cpu_arch = .aarch64,
        .os_tag = .linux,
        .abi = .android,
        .android_api_level = 24,
    } });
    const optimize = b.standardOptimizeOption(.{});

    const ndk_include = b.option(
        std.Build.LazyPath,
        "android_include_path",
        "The NDK's sysroot usr/include (<ndk>/toolchains/llvm/prebuilt/<host>/sysroot/usr/include)",
    );

    const dvui_dep = b.dependency("fizzy_sdk", .{}).builder.dependency("dvui", .{
        .target = target,
        .optimize = optimize,
        .backend = .sdl3,
        .accesskit = .off,
        .android_include_path = ndk_include,
    });

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true, // linked into the app's JNI .so
    });
    mod.addImport("dvui", dvui_dep.module("dvui_sdl3"));

    const hello = b.addLibrary(.{ .name = "fizzy_hello", .root_module = mod });
    // Debug C code (SDL, stb) calls __ubsan_handle_*, which the NDK linker has no runtime for.
    hello.bundle_ubsan_rt = true;
    hello.bundle_compiler_rt = true; // ubsan_rt needs __extendxftf2, which the NDK lacks

    const lib_step = b.step("lib", "Install libfizzy_hello.a, libSDL3.a and SDL's Java sources for project/");
    lib_step.dependOn(&b.addInstallArtifact(hello, .{}).step);
    // dvui installs its SDL3 only once its lazy `sdl3` dependency is fetched, which is after the
    // first configure pass; `dvui_dep.artifact("SDL3")` panics on that pass instead of waiting.
    const sdl3_fetched = for (dvui_dep.builder.install_tls.step.dependencies.items) |dep| {
        const install = dep.cast(std.Build.Step.InstallArtifact) orelse continue;
        if (std.mem.eql(u8, install.artifact.name, "SDL3")) break true;
    } else false;
    if (sdl3_fetched) dvui_build.installAndroidSdl3(b, dvui_dep, lib_step);
}
