//! Document staging helpers for plugin authors.
//!
//! Use these from `loadDocument` / `loadDocumentFromBytes` vtable hooks when your document
//! type is constructed from a path or bytes into a fizzy-owned staging buffer.
const std = @import("std");

const Plugin = @import("Plugin.zig");

/// Fizzy-allocated staging memory for one document load/create.
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

/// The surface id of an open document: `<owner plugin id>.doc:<path>`. A document is a surface
/// for exactly as long as it is open — the app registers it when the load lands and takes it
/// back on close — and this is the one place its id is spelled, because two sides need it: the
/// app that registers it, and the workbench that assigns it to a pane. Stable across sessions
/// by construction, which is what makes an assignment to it a way to restore one.
pub fn surfaceId(allocator: std.mem.Allocator, owner_id: []const u8, path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}.doc:{s}", .{ owner_id, path });
}

/// The keyword every document surface carries. A shape places documents by accepting this,
/// qualified by wherever it puts them (`main.document`).
pub const keyword = "document";
pub const keywords: []const []const u8 = &.{keyword};

/// Whether a surface id names a document, and the path if so. This is how a surface is mapped
/// back to its document (`host.docFromPath`) — by convention of the id, so `Surface` itself
/// carries nothing document-shaped.
pub fn pathOfSurfaceId(id: []const u8) ?[]const u8 {
    const marker = ".doc:";
    const at = std.mem.indexOf(u8, id, marker) orelse return null;
    return id[at + marker.len ..];
}
