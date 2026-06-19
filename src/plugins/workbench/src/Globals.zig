//! Runtime injection points for the workbench plugin (Stage W).
//!
//! The shell sets these once during `App` startup so workbench code can reach the
//! app allocator and the Host (EditorAPI surface) without importing `fizzy.zig`.
//! Mirrors `plugins/pixelart/src/Globals.zig`.
const std = @import("std");
const workbench = @import("../workbench.zig");
const sdk = workbench.sdk;

pub var gpa: std.mem.Allocator = undefined;
pub var host: *sdk.Host = undefined;

pub fn allocator() std.mem.Allocator {
    return gpa;
}
