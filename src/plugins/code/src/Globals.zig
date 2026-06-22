//! Runtime injection points for the code plugin.
//!
//! The shell sets these once during `App` startup so plugin code can reach the
//! app allocator, the Host (EditorAPI surface), and the plugin's own state without
//! importing `fizzy.zig`. Mirrors the pixel-art plugin's `Globals.zig` injection pattern.
const std = @import("std");
const code = @import("../code.zig");
const sdk = code.sdk;
const core = code.core;
const State = @import("State.zig");

pub var gpa: std.mem.Allocator = undefined;
pub var host: *sdk.Host = undefined;
pub var state: *State = undefined;

pub fn allocator() std.mem.Allocator {
    return gpa;
}

/// For a loaded dylib build, the host calls `fizzy_plugin_set_globals` on the image before `register`.
pub fn installRuntime(
    gpa_ptr: ?*const std.mem.Allocator,
    host_ptr: ?*sdk.Host,
    state_ptr: ?*State,
) void {
    if (gpa_ptr) |a| {
        gpa = a.*;
        core.gpa = a.*;
    }
    if (host_ptr) |h| host = h;
    if (state_ptr) |s| state = s;
}
