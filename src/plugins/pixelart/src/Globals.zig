//! Runtime injection points for the pixel-art plugin (Phase 4 Stage D).
//!
//! The shell sets these once during `App` startup so plugin code can reach the
//! app allocator and singletons without importing `fizzy.zig`.
const std = @import("std");
const State = @import("State.zig");
const Packer = @import("Packer.zig");

pub var gpa: std.mem.Allocator = undefined;
pub var state: *State = undefined;
pub var packer: *Packer = undefined;

pub fn allocator() std.mem.Allocator {
    return gpa;
}
