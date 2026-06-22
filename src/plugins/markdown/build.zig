const std = @import("std");
const fizzy = @import("fizzy");
const integration = @import("static/integration.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = fizzy.plugin.create(b, .{
        .name = "markdown",
        .version = @import("build.zig.zon").version,
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("root.zig"),
    });

    integration.linkCmark(b, target, optimize, lib.root_module);

    fizzy.plugin.install(b, lib, .{});
}
