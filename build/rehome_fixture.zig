//! A plugin graph for proving `plugins.rehome`, and the checks on what it returns. Native-only
//! source: the web build re-homes it to wasm32 and compiles that, never linking it into the app.
//!
//! `-Drehome-fixture-fault=<kind>` breaks it on purpose; each kind must fail the build, which is
//! how the checks are shown to be live (`libc`, `cycle`, `plain`).
const std = @import("std");
const sdk = @import("sdk.zig");

const Fault = enum { none, libc, cycle, plain };

/// A build script runs once, and `std.Build` declares each option once.
var chosen: ?Fault = null;

fn fault(b: *std.Build) Fault {
    if (chosen) |f| return f;
    chosen = b.option(
        Fault,
        "rehome-fixture-fault",
        "Break the rehome fixture on purpose (libc, cycle, plain); the build must fail",
    ) orelse .none;
    return chosen.?;
}

/// root -> child (dvui, C sources, framework-free "plain" module, and a way back to root) and root
/// -> same_child.
pub fn graph(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.OptimizeMode) *std.Build.Module {
    const old_dvui = sdk.dvuiDependency(b, .{
        .target = target,
        .optimize = optimize,
        .backend = .testing,
    }).module("dvui_testing");
    const child = b.createModule(.{
        .root_source_file = b.path("tests/fixtures/rehome/child.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = if (fault(b) == .libc) true else null,
    });
    child.addImport("dvui", old_dvui);
    child.addImport("plain", b.createModule(.{
        .root_source_file = b.path("tests/fixtures/rehome/plain.zig"),
        .target = target,
        .optimize = optimize,
    }));
    child.addIncludePath(b.path("tests/fixtures/rehome"));
    child.addCMacro("REHOME_VALUE", "42");
    child.addCSourceFile(.{ .file = b.path("tests/fixtures/rehome/value.c"), .flags = &.{} });
    const root = b.createModule(.{
        .root_source_file = b.path("tests/fixtures/rehome/plugin.zig"),
        .target = target,
        .optimize = optimize,
    });
    root.addImport("dvui", old_dvui);
    root.addImport("fizzy_sdk", old_dvui);
    root.addImport("child", child);
    root.addImport("same_child", child);
    child.addImport("back", root);
    return root;
}

fn expect(ok: bool, what: []const u8) void {
    if (!ok) std.debug.panic("fizzy: rehome fixture check failed: {s}", .{what});
}

/// `source` is what `create` made, `copy` what `rehome` made of it. `same_target` is whether the
/// copy was made for the target the source is pinned to, so its framework-free module may be
/// shared.
pub fn check(b: *std.Build, source: *std.Build.Module, copy: *std.Build.Module, same_target: bool) void {
    const f = fault(b);
    const source_child = source.import_table.get("child").?;
    const copied_child = copy.import_table.get("child").?;
    expect(copied_child != source_child, "a module reaching the framework is copied");
    expect(copied_child == copy.import_table.get("same_child").?, "a diamond import is copied once");
    const back = copied_child.import_table.get("back").?;
    expect(if (f == .cycle) back == source else back == copy, "a cycle maps to the copy of its root");
    const shared = copied_child.import_table.get("plain") == source_child.import_table.get("plain");
    expect(
        if (f == .plain) shared != same_target else shared == same_target,
        "a framework-free module is shared only where the target is the same",
    );
}
