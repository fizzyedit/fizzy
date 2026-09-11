//! Wasm-target stubs for `singleton.zig`. The browser has one tab = one fizzy;
//! cross-tab single-instance / argv forwarding has no analogue, so every entry
//! point here is either a no-op or returns an empty argv slice. Mirrors the
//! native API exactly so `App.zig` can call into it without arch gating.

const std = @import("std");
const dvui = @import("dvui");

/// Unused here (one tab is one instance), but declared so this file mirrors the native API.
/// See the native implementation: the app sets this. Unused on the web, where one tab is one
/// application and there is nothing to lock against.
pub var app_id: [:0]const u8 = "app.unnamed";
pub var app_name: []const u8 = "app";

pub fn earlyStartup(_: std.mem.Allocator, _: std.process.Init) !void {}

pub fn consumeStartupArgv() []const []const u8 {
    return &.{};
}

pub fn acquireLock(_: std.mem.Allocator, _: []const []const u8) !void {}

pub fn registerWindow(_: *dvui.Window, _: []const []const u8) void {}

pub fn deinit() void {}

pub fn drainPending() void {}

pub fn queuePath(_: []const u8) void {}

/// On native this iterates the OS argv and resolves file args to absolute paths.
/// On web there's no argv (the page URL could theoretically carry one in
/// `?file=…` later, but that's a future concern); return a minimal `argv[0]`
/// only so `freeResolvedArgv` has something to free.
pub fn collectAndResolveArgv(
    gpa: std.mem.Allocator,
    _: ?std.process.Init,
) ![]const []const u8 {
    const out = try gpa.alloc([]const u8, 1);
    errdefer gpa.free(out);
    out[0] = try gpa.dupe(u8, app_name);
    return out;
}

pub fn freeResolvedArgv(gpa: std.mem.Allocator, argv: []const []const u8) void {
    for (argv) |s| gpa.free(s);
    gpa.free(argv);
}
