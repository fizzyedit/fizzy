//! Code plugin runtime state: the registry of open text documents.
//!
//! The shell stores opaque `DocHandle`s in `Editor.open_files`; this map owns the
//! concrete `Document` values their `id`s map back to.
const std = @import("std");
const code = @import("../code.zig");
const sdk = code.sdk;
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

pub fn docFrom(self: *State, doc: sdk.DocHandle) ?*Document {
    return self.docs.getPtr(doc.id);
}

pub fn docByPath(self: *State, path: []const u8) ?*Document {
    for (self.docs.values()) |*doc| {
        if (std.mem.eql(u8, doc.path, path)) return doc;
    }
    return null;
}
