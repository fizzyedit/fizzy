//! Standalone build for the text plugin — the canonical third-party shape.
//! `cd src/plugins/text && zig build` produces `text.<dylib|dll|so>`. Identical in form to
//! any external plugin: declare `fizzy`, call `fizzy.plugin.create` + `.install`. The
//! fizzy-internal static-embed build lives separately in `static/` and is driven by the
//! root build. See docs/PLUGINS.md.
const std = @import("std");
const fizzy = @import("fizzy");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const plugin = fizzy.plugin.create(b, .{ .target = target, .optimize = optimize });
    fizzy.plugin.install(b, plugin.lib, .{});
}
