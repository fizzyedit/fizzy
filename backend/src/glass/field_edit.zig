//! Focused field state out, UTF-8 byte-range edits in, on the UI thread.
//! Each replacement is one dvui edit through the field's own editing path.
const std = @import("std");
const dvui = @import("dvui");
const field_hints = @import("field_hints.zig");

pub const Range = struct { start: usize, end: usize };
pub const State = struct {
    /// Borrowed for this frame: at most a 4 KB window around the caret.
    text: []const u8,
    /// Byte offset of this window in the whole field.
    offset: usize,
    /// Absolute byte positions: start is the anchor, end is the caret.
    sel: Range,
    hints: field_hints.Hints,
};
pub const Edit = union(enum) {
    replace: struct { range: Range, text: []const u8 },
    select: Range,
};
const Published = struct { state: State, frame: i128 };

// push/take write these on the UI thread; only initialized queue/buffer prefixes are read.
var queue: [16]Edit = undefined;
var bytes: [4096]u8 = undefined;
var count: usize = 0;
var used: usize = 0;

/// Publish borrowed state for this frame only; the last publisher wins.
pub fn publish(state: State) void {
    const win = dvui.currentWindow();
    dvui.dataSet(win, win.data().id, "_field_edit", Published{ .state = state, .frame = dvui.frameTimeNS() });
}

/// Return null when no field published in this frame.
pub fn current() ?State {
    const win = dvui.currentWindow();
    const p = dvui.dataGet(null, win.data().id, "_field_edit", Published) orelse return null;
    return if (p.frame == dvui.frameTimeNS()) p.state else null;
}

/// Copy an edit and its text; capacity exhaustion drops only the incoming edit.
pub fn push(edit: Edit) bool {
    if (count == queue.len) return false;
    var copy = edit;
    if (edit == .replace) {
        const text = edit.replace.text;
        if (text.len > bytes.len - used) return false;
        @memcpy(bytes[used..][0..text.len], text);
        copy.replace.text = bytes[used..][0..text.len];
        used += text.len;
    }
    queue[count] = copy;
    count += 1;
    return true;
}

/// Drain in order. The slice and its texts remain valid until the next push.
/// Fields wait for focus before draining so an unfocused field cannot consume another field's edits.
pub fn take() []const Edit {
    const result = queue[0..count];
    count = 0;
    used = 0;
    return result;
}

test "edits come back in order and the queue empties" {
    _ = take();
    var text = [_]u8{ 'h', 'i' };
    try std.testing.expect(push(.{ .replace = .{ .range = .{ .start = 1, .end = 2 }, .text = &text } }));
    text[0] = 'x';
    try std.testing.expect(push(.{ .select = .{ .start = 3, .end = 4 } }));
    const edits = take();
    try std.testing.expectEqual(@as(usize, 2), edits.len);
    try std.testing.expectEqualStrings("hi", edits[0].replace.text);
    try std.testing.expectEqual(@as(usize, 1), edits[0].replace.range.start);
    try std.testing.expectEqual(@as(usize, 3), edits[1].select.start);
    try std.testing.expectEqual(@as(usize, 0), take().len);
    try std.testing.expectEqualStrings("hi", edits[0].replace.text);
}

test "a full queue drops the new edit, never an old one" {
    _ = take();
    const large = @as([5 * 1024]u8, @splat('x'));
    try std.testing.expect(!push(.{ .replace = .{ .range = .{ .start = 0, .end = 0 }, .text = &large } }));
    for (0..16) |i| try std.testing.expect(push(.{ .select = .{ .start = i, .end = i } }));
    try std.testing.expect(!push(.{ .select = .{ .start = 99, .end = 99 } }));
    const edits = take();
    try std.testing.expectEqual(@as(usize, 16), edits.len);
    for (edits, 0..) |edit, i| try std.testing.expectEqual(i, edit.select.start);
    const full = @as([4096]u8, @splat('a'));
    try std.testing.expect(push(.{ .replace = .{ .range = .{ .start = 0, .end = 0 }, .text = &full } }));
    try std.testing.expect(!push(.{ .replace = .{ .range = .{ .start = 0, .end = 0 }, .text = "b" } }));
    try std.testing.expectEqualStrings(&full, take()[0].replace.text);
}
