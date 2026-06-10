const std = @import("std");
const builtin = @import("builtin");
const known_folders = @import("known-folders");

pub fn configRoot(
    io: std.Io,
    arena: std.mem.Allocator,
    environ: std.process.Environ,
    fallback: []const u8,
) ![]const u8 {
    if (comptime builtin.target.cpu.arch == .wasm32) return fallback;
    var environ_map = try environ.createMap(arena);
    defer environ_map.deinit();
    return known_folders.getPath(io, arena, environ_map, .local_configuration) catch fallback orelse fallback;
}

pub fn configFolder(
    allocator: std.mem.Allocator,
    io: std.Io,
    arena: std.mem.Allocator,
    environ: std.process.Environ,
    fallback: []const u8,
) ![]const u8 {
    const config_root = try configRoot(io, arena, environ, fallback);
    return std.fs.path.join(allocator, &.{ config_root, "fizzy" }) catch fallback;
}

pub fn configFolderZ(
    buf: []u8,
    io: std.Io,
    environ: std.process.Environ,
    fallback: []const u8,
) ?[:0]const u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const folder = configFolder(arena.allocator(), io, arena.allocator(), environ, fallback) catch return null;
    if (folder.len + 1 > buf.len) return null;
    @memcpy(buf[0..folder.len], folder);
    buf[folder.len] = 0;
    return buf[0..folder.len :0];
}
