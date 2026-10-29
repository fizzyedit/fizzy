//! An application over fizzy's build API, for `scripts/check-examples.sh`: two plugin packages
//! built with `fizzy.framework` (one for both kinds of executable, one native-only), the web and
//! package steps, and the failures the API promises.
//!
//! `-Dfixture-fail=<case>` builds a list the API refuses: `twice` lists a plugin twice,
//! `web-taken` has a `web` step already.
const std = @import("std");
const fizzy = @import("fizzy");
const both = @import("fixture_both");
const native = @import("fixture_native");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const fail = b.option([]const u8, "fixture-fail", "A case the API must refuse") orelse "";

    // Files that go beside the executable in the pack input, and an argument for `vpk pack`.
    const helpers = b.addWriteFiles();
    _ = helpers.add("fixture-helper.txt", "beside the executable\n");

    const fizzy_dep = b.dependency("fizzy", .{
        .target = target,
        .optimize = optimize,
        .@"defer-app" = true,
        .@"app-name" = @as([]const u8, "fixtureapp"),
        .@"package-dirs" = &[_]std.Build.LazyPath{helpers.getDirectory()},
        .@"vpk-args" = &[_][]const u8{ "--fixture-vpk-arg", "1" },
    });
    const both_dep = b.dependency("fixture_both", .{});
    const native_dep = b.dependency("fixture_native", .{});

    const list = [_]fizzy.BundledPlugin{
        fizzy.plugins.workbench,
        fizzy.plugins.text,
        .{ .name = "fixture_both", .targets = &.{
            .{ .target = .native, .module = both.staticModule(both_dep.builder, fizzy.framework(fizzy_dep, .native)) },
            .{ .target = .web, .module = both.staticModule(both_dep.builder, fizzy.framework(fizzy_dep, .web)) },
        } },
        .{ .name = "fixture_native", .targets = &.{
            .{ .target = .native, .module = native.staticModule(native_dep.builder, fizzy.framework(fizzy_dep, .native)) },
        } },
    };
    const twice = list ++ [_]fizzy.BundledPlugin{list[2]};
    const app = try fizzy.addApp(fizzy_dep, if (std.mem.eql(u8, fail, "twice")) &twice else &list);
    b.installArtifact(app.exe);

    if (std.mem.eql(u8, fail, "web-taken")) _ = b.step("web", "taken before the API's");
    try fizzy.addWebSteps(b, fizzy_dep);
    try fizzy.addPackageSteps(b, fizzy_dep);
}
