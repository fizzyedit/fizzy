//! A text document's state as bytes, for a demo's snapshot (`sdk.Plugin.captureDocumentState`).
//!
//! Held in memory for one session of one build and never written anywhere, so the layout is
//! this file's alone: a version byte, the flags (dirty, focused), the selection as anchor and
//! head (the caret's end, so a selection made backwards comes back backwards), the scroll and the
//! preview's split, then the text. std-only, so it tests as pure logic (`Document.captureState` and `restoreState`
//! are the halves that touch the editor).
const std = @import("std");

pub const State = struct {
    text: []const u8,
    anchor: usize,
    head: usize,
    dirty: bool,
    /// The editor had keyboard focus. A snapshot's own record of focus is a widget id, and the
    /// editor's id changes when its document is closed and opened again: put back with the
    /// document, focus follows it to whichever editor shows it now.
    focused: bool = false,
    /// `Document.PreviewMode`, as its integer.
    preview_mode: u8,
    scroll_y: f32,
    split: f32,
};

const version: u8 = 2;
const header = 3 + 8 + 8 + 4 + 4 + 8;

pub fn encode(allocator: std.mem.Allocator, s: State) ![]u8 {
    const out = try allocator.alloc(u8, header + s.text.len);
    out[0] = version;
    out[1] = @as(u8, @intFromBool(s.dirty)) | @as(u8, @intFromBool(s.focused)) << 1;
    out[2] = s.preview_mode;
    std.mem.writeInt(u64, out[3..11], s.anchor, .little);
    std.mem.writeInt(u64, out[11..19], s.head, .little);
    std.mem.writeInt(u32, out[19..23], @bitCast(s.scroll_y), .little);
    std.mem.writeInt(u32, out[23..27], @bitCast(s.split), .little);
    std.mem.writeInt(u64, out[27..35], s.text.len, .little);
    @memcpy(out[header..], s.text);
    return out;
}

/// The state in `bytes`; its text borrows from them. The selection is clamped to the text.
pub fn decode(bytes: []const u8) error{BadState}!State {
    if (bytes.len < header or bytes[0] != version) return error.BadState;
    const len = std.mem.readInt(u64, bytes[27..35], .little);
    if (bytes.len - header != len) return error.BadState;
    const text = bytes[header..];
    return .{
        .text = text,
        .anchor = @min(std.mem.readInt(u64, bytes[3..11], .little), text.len),
        .head = @min(std.mem.readInt(u64, bytes[11..19], .little), text.len),
        .dirty = bytes[1] & 1 != 0,
        .focused = bytes[1] & 2 != 0,
        .preview_mode = bytes[2],
        .scroll_y = @bitCast(std.mem.readInt(u32, bytes[19..23], .little)),
        .split = @bitCast(std.mem.readInt(u32, bytes[23..27], .little)),
    };
}

test "a document's state round-trips, a backwards selection with it" {
    const gpa = std.testing.allocator;
    const s: State = .{ .text = "const x = 1;\n", .anchor = 9, .head = 6, .dirty = true, .focused = true, .preview_mode = 2, .scroll_y = 120.5, .split = 0.4 };
    const bytes = try encode(gpa, s);
    defer gpa.free(bytes);
    try std.testing.expectEqualDeep(s, try decode(bytes));
}

test "what is not a whole state is refused, and a selection past the text is clamped" {
    const gpa = std.testing.allocator;
    const bytes = try encode(gpa, .{ .text = "abc", .anchor = 99, .head = 1, .dirty = false, .preview_mode = 0, .scroll_y = 0, .split = 0.5 });
    defer gpa.free(bytes);
    for (0..bytes.len) |n| try std.testing.expectError(error.BadState, decode(bytes[0..n]));
    var wrong = try gpa.dupe(u8, bytes);
    defer gpa.free(wrong);
    wrong[0] = 9;
    try std.testing.expectError(error.BadState, decode(wrong));
    try std.testing.expectEqual(@as(usize, 3), (try decode(bytes)).anchor);
}
