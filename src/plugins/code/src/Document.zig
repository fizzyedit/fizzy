//! A single open text document: its path, contents, and grouping. The contents are kept
//! in an `ArrayList(u8)` so the editing widget can grow/shrink it in place; the shell stores
//! only an opaque `DocHandle` whose `id` maps back to the registered `Document`.
const std = @import("std");
const builtin = @import("builtin");
const code = @import("../code.zig");
const dvui = code.dvui;
const Globals = code.Globals;

const is_wasm = builtin.target.cpu.arch == .wasm32;

const Document = @This();

/// Shell document id (monotonic, allocated from the host).
id: u64,
/// Absolute path on disk, heap-owned.
path: []u8,
/// Tab grouping (which split/tab group this document lives in).
grouping: u64 = 0,
/// File contents. The text-editing widget reads from and writes back to `items`.
text: std.ArrayList(u8) = .empty,
/// Cached `\n` count + 1; refreshed on load and when the editor reports edits.
line_count: usize = 1,
/// Unsaved-edits flag, set when the editing widget reports a change.
dirty: bool = false,

/// 64 MiB — generous for source files; guards against opening something huge by mistake.
const max_file_bytes: usize = 64 * 1024 * 1024;

/// Build a document from in-memory bytes (browser file picker, or after reading from disk).
pub fn fromBytes(path: []const u8, bytes: []const u8) !Document {
    const gpa = Globals.allocator();
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(gpa);
    try text.appendSlice(gpa, bytes);
    const path_copy = try gpa.dupe(u8, path);
    errdefer gpa.free(path_copy);
    var doc = Document{
        .id = Globals.host.allocDocId(),
        .path = path_copy,
        .text = text,
    };
    doc.refreshLineCount();
    return doc;
}

pub fn refreshLineCount(self: *Document) void {
    self.line_count = if (self.text.items.len == 0) 1 else std.mem.count(u8, self.text.items, "\n") + 1;
}

/// Build a document by reading `path` from disk. Runs on the shell's load worker thread.
/// Web has no filesystem; documents there are opened from bytes (`fromBytes`) instead.
pub fn fromPath(path: []const u8) !Document {
    if (comptime is_wasm) return error.Unsupported;
    const gpa = Globals.allocator();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(dvui.io, path, gpa, .limited(max_file_bytes));
    defer gpa.free(bytes);
    return fromBytes(path, bytes);
}

pub fn deinit(self: *Document) void {
    const gpa = Globals.allocator();
    gpa.free(self.path);
    self.text.deinit(gpa);
}

/// Write the current contents back to `path`.
pub fn save(self: *Document) !void {
    if (comptime is_wasm) return error.Unsupported;
    try std.Io.Dir.cwd().writeFile(dvui.io, .{ .sub_path = self.path, .data = self.text.items });
    self.dirty = false;
}
