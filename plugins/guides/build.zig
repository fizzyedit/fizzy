//! Standalone build for the guides plugin — the canonical third-party shape.
//! `cd plugins/guides && zig build` produces `guides.<dylib|dll|so>`. The fizzy-internal
//! static-embed build lives separately in `static/` and is driven by the root build.
const std = @import("std");
const fizzy = @import("fizzy");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const plugin = fizzy.plugin.create(b, .{ .target = target, .optimize = optimize });
    fizzy.plugin.install(b, plugin.lib, .{});
}
