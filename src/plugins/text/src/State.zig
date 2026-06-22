//! Code plugin runtime state: open text document registry.
const std = @import("std");
const sdk = @import("sdk");
const Document = @import("Document.zig");

const State = @This();

/// Heap-allocated per document (not stored by value) so the pointer handed out as
/// `DocHandle.ptr` stays stable for the document's whole lifetime — a value stored
/// directly in this map would relocate on hashmap growth or an unrelated `swapRemove`.
docs: std.AutoArrayHashMapUnmanaged(u64, *Document) = .empty,

/// Persisted via `Host.loadPluginSettings`/`storePluginSettings` — see `Settings.zig`.
insert_spaces_on_tab: bool = true,
tab_size: u8 = 4,
/// When true, `saveDocument` reformats the document (via the active `LanguageSupport.format`
/// provider for its extension, if any) immediately before writing it to disk.
format_on_save: bool = false,

pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
    for (self.docs.values()) |doc| {
        doc.deinit();
        allocator.destroy(doc);
    }
    self.docs.deinit(allocator);
}

pub fn docById(self: *State, id: u64) ?*Document {
    return self.docs.get(id);
}

pub fn docFrom(self: *State, doc: sdk.DocHandle) ?*Document {
    return self.docs.get(doc.id);
}

pub fn docByPath(self: *State, path: []const u8) ?*Document {
    for (self.docs.values()) |doc| {
        if (std.mem.eql(u8, doc.path, path)) return doc;
    }
    return null;
}
