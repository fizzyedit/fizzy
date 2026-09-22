//! An application built on fizzy as a *library*, in a separate package.
//!
//! This app owns `src/layout.zig` — canvas, right-hand stack, short strip. Fizzy is an
//! ordinary dependency; the layout is not a shipped preset.
const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const fizzy = b.dependency("fizzy", .{
        .target = target,
        .optimize = optimize,
        .@"app-name" = @as([]const u8, "studioapp"),
        .@"app-display-name" = @as([]const u8, "Studio App"),
        .@"app-bundle-id" = @as([]const u8, "dev.fizzy.studioapp"),
        // `src/layout.zon` is the same arrangement as data — swap the line below for it to see
        // the two side by side. A shape that needs a condition has to be the `.zig` one.
        .@"app-layout" = b.path(if (b.option(bool, "zon-layout", "Use the data (.zon) shape instead of the function") orelse false)
            "src/layout.zon"
        else
            "src/layout.zig"),
    });

    const exe = fizzy.artifact("studioapp");
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run the studio app").dependOn(&run_cmd.step);
}
