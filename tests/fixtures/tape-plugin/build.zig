const std = @import("std");
const fizzy = @import("fizzy");

/// The plugin as an application links it (`build/app.zig` builds it this way and plays its tests).
// anytype: the app's framework struct, whose type `fizzy.plugin.staticModule` owns.
pub fn staticModule(b: *std.Build, framework: anytype) *std.Build.Module {
    return fizzy.plugin.staticModule(b, framework, .{});
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const plugin = fizzy.plugin.create(b, .{ .target = target, .optimize = optimize });

    // The plugin's module as the dylib sees it, tested: `tape` and `replay` resolve in a store
    // plugin as they do in a bundled one (`build/app.zig` tests `play.zig` the other way).
    const tests = b.addTest(.{ .name = "tape-fixture-tests", .root_module = plugin.module });
    const test_step = b.step("test", "Run the fixture's tests as a dylib plugin sees its imports");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    test_step.dependOn(&plugin.lib.step);
}
