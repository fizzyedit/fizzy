//! Host-injected plugin runtime: the allocator and `*Host` the shell pushes into a plugin
//! dylib at load (`fizzy_plugin_set_globals`). Plugin code reads them through
//! `sdk.allocator()` and `sdk.host()` — there is no per-plugin file to store them.
//!
//! Each loaded dylib compiles its own `sdk` and `core`, so these statics are private to one
//! plugin image; the host injects them before `register` (and re-injects if they change).
//! `installRuntime` also wires the matching `core.gpa` so allocating `core` helpers work
//! without each plugin remembering to sync it.
const std = @import("std");
const core = @import("core");
const Host = @import("Host.zig");

var gpa: std.mem.Allocator = undefined;
var host_ptr: *Host = undefined;
/// Shell-owned plugin state injected before `register` (built-in static/dylib path).
var injected_state: ?*anyopaque = null;

/// The persistent host allocator. Use for anything that outlives a frame; you own every
/// allocation and must free it. Frame-scoped scratch is `host().arena()`.
pub fn allocator() std.mem.Allocator {
    return gpa;
}

/// The shell `*Host` — registries, services, and the `EditorAPI` read surface.
pub fn host() *Host {
    return host_ptr;
}

/// Called by `dylib.exportEntry`'s `fizzy_plugin_set_globals` export. Third-party plugins
/// own their state in `register`; built-ins may inject a shell-owned pointer here.
pub fn installRuntime(
    gpa_in: ?*const std.mem.Allocator,
    host_in: ?*Host,
    state_ptr: ?*anyopaque,
) void {
    if (gpa_in) |a| {
        gpa = a.*;
        core.gpa = a.*;
    }
    if (host_in) |h| host_ptr = h;
    if (state_ptr) |s| injected_state = s;
}

pub fn injectedState(comptime T: type) ?*T {
    const s = injected_state orelse return null;
    return @ptrCast(@alignCast(s));
}
