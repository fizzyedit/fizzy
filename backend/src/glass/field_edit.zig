//! Focused field state out, byte-range edits in, on the UI thread.
//! Each replacement is one dvui edit.
const std = @import("std");
const dvui = @import("dvui");
const field_hints = @import("field_hints.zig");

pub const Range = struct { start: usize, end: usize };
pub const State = struct {
    /// Borrowed for this frame: at most 4 KB around the caret, starting at absolute byte `offset`.
    text: []const u8,
    offset: usize,
    /// Absolute byte offsets: start is the anchor, end is the caret.
    sel: Range,
    hints: field_hints.Hints,
};
pub const Edit = union(enum) {
    replace: struct { range: Range, text: []const u8 },
    select: Range,
};
const Published = struct { state: State, frame: i128 };

pub fn publish(state: State) void {
    const win = dvui.currentWindow();
    dvui.dataSet(win, win.data().id, "_field_edit", Published{ .state = state, .frame = dvui.frameTimeNS() });
}

/// This frame's borrowed state, or null when nobody published.
pub fn current() ?State {
    const win = dvui.currentWindow();
    const p = dvui.dataGet(null, win.data().id, "_field_edit", Published) orelse return null;
    return if (p.frame == dvui.frameTimeNS()) p.state else null;
}

// push/take write this storage on the UI thread; only initialized slots are read.
var queue: [16]Edit = undefined;
// push/take write the queue count on the UI thread.
var count: usize = 0;
// push writes copied text on the UI thread; only initialized bytes are read.
var bytes: [4096]u8 = undefined;
// push/take write the byte count on the UI thread.
var used: usize = 0;

/// Copies replacement text. Full storage drops only the incoming edit.
pub fn push(edit: Edit) bool {
    if (count == queue.len) return false;
    var owned = edit;
    if (edit == .replace) {
        const text = edit.replace.text;
        if (text.len > bytes.len - used) return false;
        @memcpy(bytes[used..][0..text.len], text);
        owned.replace.text = bytes[used..][0..text.len];
        used += text.len;
    }
    queue[count] = owned;
    count += 1;
    return true;
}

/// Empties the queue; returned edits and texts remain valid until the next push.
pub fn take() []const Edit {
    const result = queue[0..count];
    count = 0;
    used = 0;
    return result;
}

test "edits come back in order and the queue empties" {
    _ = take();
    var source = "the".*;
    try std.testing.expect(push(.{ .replace = .{ .range = .{ .start = 0, .end = 3 }, .text = &source } }));
    @memset(&source, 'x');
    try std.testing.expect(push(.{ .select = .{ .start = 1, .end = 2 } }));
    const edits = take();
    try std.testing.expectEqual(@as(usize, 2), edits.len);
    try std.testing.expectEqualStrings("the", edits[0].replace.text);
    try std.testing.expectEqual(@as(usize, 1), edits[1].select.start);
    try std.testing.expectEqual(@as(usize, 0), take().len);
}

test "a full queue drops the new edit, never an old one" {
    _ = take();
    for (0..16) |i| try std.testing.expect(push(.{ .select = .{ .start = i, .end = i } }));
    try std.testing.expect(!push(.{ .select = .{ .start = 99, .end = 99 } }));
    const edits = take();
    try std.testing.expectEqual(@as(usize, 16), edits.len);
    for (edits, 0..) |edit, i| try std.testing.expectEqual(i, edit.select.start);
    try std.testing.expect(!push(.{ .replace = .{ .range = .{ .start = 0, .end = 0 }, .text = &(@as([5120]u8, @splat('x'))) } }));
    try std.testing.expectEqual(@as(usize, 0), take().len);
}
