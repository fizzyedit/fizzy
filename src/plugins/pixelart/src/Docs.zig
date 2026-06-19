//! Open-document registry for the pixel-art plugin.
//!
//! The shell stores opaque `DocHandle`s in `Editor.open_files`; this map owns the
//! concrete `Internal.File` values their `ptr` fields point at.
const std = @import("std");
const pixelart = @import("../pixelart.zig");
const Globals = pixelart.Globals;
const sdk = pixelart.sdk;
const Internal = pixelart.internal;

const Docs = @This();

files: std.AutoArrayHashMapUnmanaged(u64, Internal.File) = .{},

pub fn fileFrom(self: *Docs, doc: sdk.DocHandle) *Internal.File {
    return self.files.getPtr(doc.id).?;
}

pub fn activeFile(self: *Docs, host: *sdk.Host) ?*Internal.File {
    const doc = host.activeDoc() orelse return null;
    return self.fileFrom(doc);
}

pub fn fileById(self: *Docs, id: u64) ?*Internal.File {
    return self.files.getPtr(id);
}

pub fn fileFromPath(self: *Docs, path: []const u8) ?*Internal.File {
    for (self.files.values()) |*file| {
        if (std.mem.eql(u8, file.path, path)) return file;
    }
    return null;
}

pub fn deinit(self: *Docs, allocator: std.mem.Allocator) void {
    self.files.deinit(allocator);
}
