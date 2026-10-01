//! A third-party-shaped plugin that draws with its own GPU program (`core.programs`). Built like
//! any plugin: `zig build` here for the desktop dylib, `-Dtarget=wasm32-freestanding` for the web.
const std = @import("std");
const fizzy = @import("fizzy");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const plugin = fizzy.plugin.create(b, .{ .target = target, .optimize = optimize });
    fizzy.plugin.install(b, plugin.lib, .{});
}
