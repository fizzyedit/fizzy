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

    const lib = fizzy.plugin.create(b, .{
        .name = "text",
        .version = @import("build.zig.zon").version,
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("root.zig"),
    });
    fizzy.plugin.install(b, lib, .{});
}
