//! A second external consumer, deliberately a different shape from `minimal-app`.
//!
//! This is the consumability test: everything above is fizzy's own build graph exercising
//! itself, which proves nothing about whether an outside package can use it. Here fizzy is an
//! ordinary dependency, the app sets its own identity, and the resulting executable is the
//! app's — not fizzy's.
const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const fizzy = b.dependency("fizzy", .{
        .target = target,
        .optimize = optimize,
        // Identity (Phase 3): this app is not fizzy.
        .@"app-name" = @as([]const u8, "studioapp"),
        .@"app-display-name" = @as([]const u8, "Studio App"),
        .@"app-bundle-id" = @as([]const u8, "dev.fizzy.studioapp"),
        // Layout (Phase 5): one of fizzy's shipped shapes, used as-is.
        .@"new-shell" = true,
        .shell = @as([]const u8, "studio"),
    });

    b.installArtifact(fizzy.artifact("studioapp"));
}
