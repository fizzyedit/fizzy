//! What an application's plugin list must say. std-only, so the rules are tested in
//! `zig build test` (`fizzy-plugin-list-tests`) although the build is their only user.

const std = @import("std");
const BundledPlugin = @import("sdk.zig").BundledPlugin;

/// Whether `plugins` links fizzy's own `name`, rather than leaving it out or bringing a module of
/// its own under that id.
pub fn linksFizzys(plugins: []const BundledPlugin, name: []const u8) bool {
    for (plugins) |p| if (p.module == null and std.mem.eql(u8, p.name, name)) return true;
    return false;
}

/// The list links exactly what it names: an empty one links nothing. workbench is the one fizzy
/// must be named, because the editor still holds its state (fizzyedit/plans#13). `buildApp`
/// still adds all of fizzy's to a list of an app's own plugins alone, until example-app names
/// them, so this sees the list after that.
pub fn check(plugins: []const BundledPlugin) error{WorkbenchNotLinked}!void {
    if (!linksFizzys(plugins, "workbench")) return error.WorkbenchNotLinked;
}

/// A module that is only ever compared to null.
fn appModule() *std.Build.Module {
    return @ptrFromInt(@alignOf(std.Build.Module));
}

test check {
    const workbench: BundledPlugin = .{ .name = "workbench" };
    const text: BundledPlugin = .{ .name = "text" };
    const hello: BundledPlugin = .{ .name = "hello", .module = appModule() };
    const own_workbench: BundledPlugin = .{ .name = "workbench", .module = appModule() };

    try check(&.{ workbench, text, hello });
    try check(&.{workbench});
    try std.testing.expectError(error.WorkbenchNotLinked, check(&.{}));
    try std.testing.expectError(error.WorkbenchNotLinked, check(&.{hello}));
    try std.testing.expectError(error.WorkbenchNotLinked, check(&.{ hello, text }));
    // An app's module under fizzy's id is not fizzy's workbench.
    try std.testing.expectError(error.WorkbenchNotLinked, check(&.{own_workbench}));
}
