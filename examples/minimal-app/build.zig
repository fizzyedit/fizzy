//! An application built on fizzy as a *library*, in a separate package.
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
        .@"app-name" = @as([]const u8, "minimalapp"),
        .@"app-display-name" = @as([]const u8, "Minimal App"),
        .@"app-bundle-id" = @as([]const u8, "dev.fizzy.minimalapp"),
        // Layout: one of fizzy's shipped shapes, used as-is.
        .@"region-layout" = true,
        .layout = @as([]const u8, "minimal"),
    });

    b.installArtifact(fizzy.artifact("minimalapp"));
}
