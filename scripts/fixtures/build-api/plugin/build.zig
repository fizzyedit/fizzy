//! A plugin package the way `fizzy.plugin.staticModule` documents it: the module is built against
//! the framework the application's executables link, with a dependency of its own added.
const std = @import("std");
const fizzy = @import("fizzy");

// anytype: the Framework of fizzy's build, a build-time duck type (pinned SDKs have their own type)
pub fn staticModule(b: *std.Build, framework: anytype) *std.Build.Module {
    const m = fizzy.plugin.staticModule(b, framework, .{});
    const lib = b.createModule(.{
        .root_source_file = b.path("lib.zig"),
        .target = framework.target,
        .optimize = framework.optimize,
    });
    lib.addCSourceFile(.{ .file = b.path("lib.c") });
    m.addImport("fixture_lib", lib);
    return m;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const plugin = fizzy.plugin.create(b, .{ .target = target, .optimize = optimize });
    fizzy.plugin.install(b, plugin.lib, .{});
}
