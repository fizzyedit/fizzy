//! Runtime injection points for the workbench plugin.
//!
//! The shell sets these once during `App` startup so workbench code can reach the
//! app allocator and the Host (EditorAPI surface) without importing `fizzy.zig`.
//! Mirrors the pixel-art plugin's `Globals.zig` injection pattern.
const std = @import("std");
const wb_mod = @import("../workbench.zig");
const sdk = wb_mod.sdk;
const Workbench = @import("Workbench.zig");
const core = @import("core");

pub var gpa: std.mem.Allocator = undefined;
pub var host: *sdk.Host = undefined;
pub var workbench: *Workbench = undefined;

pub fn allocator() std.mem.Allocator {
    return gpa;
}

/// For a loaded dylib build, the host calls `fizzy_plugin_set_globals` on the image before `register`.
pub fn installRuntime(
    gpa_ptr: ?*const std.mem.Allocator,
    host_ptr: ?*sdk.Host,
    workbench_ptr: ?*Workbench,
) void {
    if (gpa_ptr) |a| {
        gpa = a.*;
        core.gpa = a.*;
    }
    if (host_ptr) |h| host = h;
    if (workbench_ptr) |w| workbench = w;
}
