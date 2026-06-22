//! Browser download helpers for the wasm build (no shell `fizzy` dependency).
const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const pixi_mod = @import("../pixi.zig");
const runtime = @import("runtime.zig");

fn downloadNameWithExtension(allocator: std.mem.Allocator, filename: []const u8, ext: []const u8) ![]const u8 {
    if (std.ascii.eqlIgnoreCase(std.fs.path.extension(filename), ext)) {
        return try allocator.dupe(u8, filename);
    }
    const base = std.fs.path.basename(filename);
    const stem: []const u8 = if (std.mem.lastIndexOf(u8, base, ".")) |i| base[0..i] else base;
    if (stem.len == 0) {
        return try std.fmt.allocPrint(allocator, "download{s}", .{ext});
    }
    return try std.fmt.allocPrint(allocator, "{s}{s}", .{ stem, ext });
}

pub fn downloadBytes(filename: []const u8, data: []const u8) !void {
    if (comptime builtin.target.cpu.arch != .wasm32) return;
    try dvui.backend.downloadData(filename, data);
}

pub fn downloadBytesWithExtension(filename: []const u8, ext: []const u8, data: []const u8) !void {
    if (comptime builtin.target.cpu.arch != .wasm32) return;
    const name = try downloadNameWithExtension(runtime.allocator(), filename, ext);
    defer runtime.allocator().free(name);
    try downloadBytes(name, data);
}
