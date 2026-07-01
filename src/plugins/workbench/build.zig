//! Standalone build for the workbench plugin — the canonical third-party shape.
//! `cd src/plugins/workbench && zig build` produces `workbench.<dylib|dll|so>`. The
//! `-Dworkbench-file-tree` option feeds a `workbench_opts` module the plugin imports;
//! attaching a build-options module to a `fizzy.plugin.create` lib is exactly how any
//! third-party plugin would expose compile-time flags. See docs/PLUGINS.md.
const std = @import("std");
const fizzy = @import("fizzy");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const file_tree = b.option(
        bool,
        "workbench-file-tree",
        "Register the Files sidebar view at compile time",
    ) orelse true;
    const workbench_opts = b.addOptions();
    workbench_opts.addOption(bool, "file_tree", file_tree);

    const lib = fizzy.plugin.create(b, .{
        .name = "workbench",
        .version = @import("build.zig.zon").version,
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("root.zig"),
    });
    lib.root_module.addOptions("workbench_opts", workbench_opts);

    if (b.lazyDependency("icons", .{ .target = target, .optimize = optimize })) |dep| {
        lib.root_module.addImport("icons", dep.module("icons"));
    }

    fizzy.plugin.install(b, lib, .{});
}
