//! Code plugin runtime state: open text document registry.
const std = @import("std");
const sdk = @import("fizzy_sdk");
const Document = @import("Document.zig");
const Settings = @import("Settings.zig");

const State = @This();

const Schema = sdk.settings.Schema(Settings);

/// Heap-allocated per document (not stored by value) so the pointer handed out as
/// `DocHandle.ptr` stays stable for the document's whole lifetime — a value stored
/// directly in this map would relocate on hashmap growth or an unrelated `swapRemove`.
docs: std.AutoArrayHashMapUnmanaged(u64, *Document) = .empty,

/// Persisted via `Host.loadPluginSettings`/`storePluginSettings` — see `Settings.zig`.
settings: Settings = .{},

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

pub fn loadSettings(self: *State, host: *sdk.Host) void {
    Schema.load(host, "text", &self.settings);
}

/// Register schema with the Host — shell draws shared controls from `Schema.settings`.
pub fn registerSettings(self: *State, host: *sdk.Host, plugin: *sdk.Plugin) !void {
    try Schema.register(host, plugin, .{
        .title = "Text Editor",
        .value = &self.settings,
    });
}
