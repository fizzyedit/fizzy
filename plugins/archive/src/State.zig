//! Archive plugin runtime state: the open archives, each a mount.
const std = @import("std");
const sdk = @import("fizzy_sdk");
const Document = @import("Document.zig");

const State = @This();

docs: std.AutoArrayHashMapUnmanaged(u64, Document) = .empty,

pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
    for (self.docs.values()) |*doc| doc.deinit();
    self.docs.deinit(allocator);
}

pub fn docById(self: *State, id: u64) ?*Document {
    return self.docs.getPtr(id);
}

pub fn docByPath(self: *State, path: []const u8) ?*Document {
    for (self.docs.values()) |*doc| {
        if (std.mem.eql(u8, doc.path, path)) return doc;
    }
    return null;
}
