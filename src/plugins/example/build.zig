//! Standalone build for the example plugin — the canonical third-party shape, and the simplest
//! possible one: declare `fizzy`, call `fizzy.plugin.create` (defaults its root to `root.zig`),
//! then `fizzy.plugin.install`. Copy this for a new pure-Zig plugin. `zig build install` builds it
//! and installs it into this OS's fizzy plugins dir (the editor loads it on next launch), and also
//! leaves `zig-out/example.<ext>` for packaging. See docs/PLUGINS.md.
const std = @import("std");
const fizzy = @import("fizzy");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = fizzy.plugin.create(b, .{
        .name = "example",
        // Single source of truth for the release version: `manifest.version` reads this back
        // through the injected `fizzy_plugin_options` module.
        .version = @import("build.zig.zon").version,
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("root.zig"),
    });
    fizzy.plugin.install(b, lib, .{});
}
