//! Document staging helpers for plugin authors.
//!
//! Use these from `loadDocument` / `loadDocumentFromBytes` vtable hooks when your document
//! type is constructed from a path or bytes into a shell-owned staging buffer.
const std = @import("std");

const Plugin = @import("Plugin.zig");

/// Shell-allocated staging memory for one document load/create.
pub const StagingBuffer = struct {
    backing: []u8,
    buf: []u8,

    pub fn deinit(self: StagingBuffer, allocator: std.mem.Allocator) void {
        allocator.free(self.backing);
    }
};

pub fn allocStaging(plugin: *Plugin, allocator: std.mem.Allocator) !StagingBuffer {
    const staging = try plugin.allocDocumentBuffer(allocator);
    return .{ .backing = staging.backing, .buf = staging.buf };
}

pub fn loadPathInto(comptime Doc: type, path: []const u8, out: *Doc) !void {
    out.* = try Doc.fromPath(path);
}

pub fn loadBytesInto(comptime Doc: type, path: []const u8, bytes: []const u8, out: *Doc) !void {
    out.* = try Doc.fromBytes(path, bytes);
}

/// Load `path` into the plugin staging buffer at `staging.buf.ptr`.
pub fn loadIntoStaging(plugin: *Plugin, path: []const u8, staging: StagingBuffer) !void {
    const handled = try plugin.loadDocument(path, staging.buf.ptr);
    if (!handled) return error.Unsupported;
}

/// Load in-memory bytes into the plugin staging buffer at `staging.buf.ptr`.
pub fn loadBytesIntoStaging(
    plugin: *Plugin,
    path: []const u8,
    bytes: []const u8,
    staging: StagingBuffer,
) !void {
    const handled = try plugin.loadDocumentFromBytes(path, bytes, staging.buf.ptr);
    if (!handled) return error.Unsupported;
}
