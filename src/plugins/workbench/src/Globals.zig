//! Runtime injection points for the workbench plugin (Stage W).
//!
//! The shell sets these once during `App` startup so workbench code can reach the
//! app allocator and the Host (EditorAPI surface) without importing `fizzy.zig`.
//! Mirrors the pixel-art plugin's `Globals.zig` injection pattern.
const std = @import("std");
const wb_mod = @import("../workbench.zig");
const sdk = wb_mod.sdk;
const Workbench = @import("Workbench.zig");

pub var gpa: std.mem.Allocator = undefined;
pub var host: *sdk.Host = undefined;
pub var workbench: *Workbench = undefined;

pub fn allocator() std.mem.Allocator {
    return gpa;
}
