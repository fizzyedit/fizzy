//! Standalone build for the example plugin — the canonical third-party shape, and the simplest
//! possible one: declare `fizzy`, call `fizzy.plugin.create` (defaults its root to `root.zig`),
//! then `fizzy.plugin.install`. `cd src/plugins/example && zig build` produces
//! `example.<dylib|dll|so>`. Copy this for a new pure-Zig plugin. See docs/PLUGINS.md.
const std = @import("std");
const fizzy = @import("fizzy");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = fizzy.plugin.create(b, .{
        .name = "example",
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("root.zig"),
    });
    fizzy.plugin.install(b, lib, .{});
}
