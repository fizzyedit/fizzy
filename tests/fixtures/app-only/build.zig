//! An app that lists only a plugin of its own. `buildApp` links exactly the list it is given, and
//! until fizzyedit/plans#16 makes workbench optional the build must fail naming
//! `fizzy.plugins.workbench`; `scripts/check-examples.sh` expects that. When plans#16 lands this
//! flips to expecting success, which is where "names none of fizzy's links none" becomes true.
const std = @import("std");
const fizzy = @import("fizzy");

pub fn build(b: *std.Build) !void {
    const fizzy_dep = b.dependency("fizzy", .{
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
        .@"defer-app" = true,
    });
    try fizzy.buildApp(fizzy_dep, &.{.{
        .name = "solo",
        .module = b.createModule(.{ .root_source_file = b.path("plugin.zig") }),
    }});
}
