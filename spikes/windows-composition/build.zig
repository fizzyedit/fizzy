//! The composition spike: Windows only. `zig build -Dtarget=x86_64-windows-gnu` (or
//! aarch64-windows-gnu) puts `windows-composition-spike.exe` in `zig-out/bin`. See README.md.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = .{ .os_tag = .windows, .abi = .gnu } });
    const optimize = b.standardOptimizeOption(.{});

    const sdl = b.dependency("sdl", .{ .target = target, .optimize = optimize });
    const sdl_c = b.addTranslateC(.{
        .root_source_file = b.path("src/sdl3-c.h"),
        .target = target,
        .optimize = optimize,
    });
    sdl_c.addIncludePath(sdl.artifact("SDL3").getEmittedIncludeTree());

    const exe = b.addExecutable(.{
        .name = "windows-composition-spike",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "sdl3-c", .module = sdl_c.createModule() },
                .{ .name = "win32", .module = b.dependency("zigwin32", .{}).module("win32") },
            },
        }),
    });
    exe.root_module.linkLibrary(sdl.artifact("SDL3"));
    for ([_][]const u8{ "d3d11", "dxgi", "d2d1", "dwmapi", "user32", "ole32" }) |lib| exe.root_module.linkSystemLibrary(lib, .{});
    b.installArtifact(exe);
}
