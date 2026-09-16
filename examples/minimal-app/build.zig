//! An application built on fizzy as a *library*, in a separate package.
//!
//! This app owns `src/layout.zig` — one main region, no rail or panel. Fizzy is an ordinary
//! dependency; the layout is not a shipped preset.
const std = @import("std");
const fizzy = @import("fizzy");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // `defer-app`: fizzy does not build the application from inside `b.dependency` — this
    // build.zig calls `buildApp` with the plugins it bundles, which `b.dependency` options
    // cannot carry (a plugin is a module from another package).
    const fizzy_dep = b.dependency("fizzy", .{
        .target = target,
        .optimize = optimize,
        .@"defer-app" = true,
        .@"app-name" = @as([]const u8, "minimalapp"),
        .@"app-display-name" = @as([]const u8, "Minimal App"),
        .@"app-bundle-id" = @as([]const u8, "dev.fizzy.minimalapp"),
        .@"app-layout" = b.path("src/layout.zig"),
    });
    const hello = b.dependency("hello", .{ .target = target, .optimize = optimize });
    try fizzy.buildApp(fizzy_dep, &.{
        .{ .name = "hello", .module = hello.module("plugin") },
    });

    const exe = fizzy_dep.artifact("minimalapp");
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run the minimal app").dependOn(&run_cmd.step);
}
