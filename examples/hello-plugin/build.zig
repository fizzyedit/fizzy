//! A third-party-shaped plugin, as small as one gets. `zig build` here produces the dylib the
//! store would ship; `fizzy.plugin.create` also exports the same source as the `"plugin"`
//! module, which is what an application bundles with `fizzy.buildApp` (see
//! `examples/minimal-app/build.zig`).
const std = @import("std");
const fizzy = @import("fizzy");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const plugin = fizzy.plugin.create(b, .{ .target = target, .optimize = optimize });
    fizzy.plugin.install(b, plugin.lib, .{});
}
