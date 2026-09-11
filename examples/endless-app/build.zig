//! An application built on fizzy as a *library*, in a separate package.
//!
//! Unlike `minimal-app` / `studio-app`, this one brings its own layout (`src/layout.zig`)
//! rather than picking a shipped `-Dlayout=` preset. That is the consumability test for a
//! real app: fizzy compiles the file in through `-Dapp-layout=` and calls `layout`.
const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const fizzy = b.dependency("fizzy", .{
        .target = target,
        .optimize = optimize,
        .@"app-name" = @as([]const u8, "endlessapp"),
        .@"app-display-name" = @as([]const u8, "Endless App"),
        .@"app-bundle-id" = @as([]const u8, "dev.fizzy.endlessapp"),
        .@"app-layout" = b.path("src/layout.zig"),
    });

    const exe = fizzy.artifact("endlessapp");
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the endless app");
    run_step.dependOn(&run_cmd.step);
}
