//! Range edits through a focused field on dvui's testing window.
const std = @import("std");
const dvui = @import("dvui");
const TextEntry = @import("TextEntry.zig");
const field_edit = @import("glass").field_edit;

// The test frame writes these on the test runner thread.
var buffers: [2][10001]u8 = undefined;
// The test frame records widget identities on the test runner thread.
var ids: [2]dvui.Id = undefined;
// The test frame records selection on the test runner thread.
var selections: [2]dvui.TextLayoutWidget.Selection = undefined;
// Tests choose the field count on the test runner thread.
var two = false;

fn frame() !dvui.App.Result {
    for (0..if (two) @as(usize, 2) else 1) |i| {
        var field = TextEntry.init(@src(), .{ .text = .{ .buffer = &buffers[i] } }, .{ .id_extra = i, .expand = .horizontal });
        ids[i] = field.entry.data().id;
        selections[i] = field.entry.textLayout.selection.*;
        field.deinit();
    }
    return .ok;
}

fn after() !void {
    const win = dvui.currentWindow();
    _ = try frame();
    _ = try win.end(.{});
    try win.begin(win.frame_time_ns + 16 * std.time.ns_per_ms);
}

fn setup(text: []const u8) !void {
    _ = field_edit.take();
    two = false;
    for (&buffers) |*buf| {
        @memset(buf, 0);
        @memcpy(buf[0..text.len], text);
    }
    try dvui.testing.settle(frame);
    dvui.focusWidget(ids[0], null, null);
}

fn replace(start: usize, end: usize, text: []const u8) !void {
    try std.testing.expect(field_edit.push(.{ .replace = .{ .range = .{ .start = start, .end = end }, .text = text } }));
    try after();
}

fn select(start: usize, end: usize) !void {
    try std.testing.expect(field_edit.push(.{ .select = .{ .start = start, .end = end } }));
    try after();
}

test "a replace fixes a word where it sits" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 100 } });
    defer t.deinit();
    try setup("teh cat");
    try replace(0, 3, "the");
    try std.testing.expectEqualStrings("the cat", std.mem.sliceTo(&buffers[0], 0));
    try std.testing.expectEqual(@as(usize, 3), selections[0].cursor);
}

test "a range inside a code point widens to it" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 100 } });
    defer t.deinit();
    try setup("h\xc3\xa9llo");
    try replace(2, 2, "e");
    try std.testing.expectEqualStrings("hello", std.mem.sliceTo(&buffers[0], 0));
}

test "select moves the caret and the selection" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 100 } });
    defer t.deinit();
    try setup("hello world");
    try select(6, 11);
    try std.testing.expectEqual(@as(usize, 6), selections[0].start);
    try std.testing.expectEqual(@as(usize, 11), selections[0].end);
    try select(3, 3);
    try std.testing.expectEqual(@as(usize, 3), selections[0].cursor);
    try std.testing.expect(selections[0].empty());
    try select(std.math.maxInt(usize), std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 11), selections[0].cursor);
    try std.testing.expect(selections[0].empty());
    try select(11, 6);
    try std.testing.expectEqual(@as(usize, 6), selections[0].start);
    try std.testing.expectEqual(@as(usize, 11), selections[0].end);
    try std.testing.expectEqual(@as(usize, 6), selections[0].cursor);
    _ = try frame();
    try std.testing.expectEqual(field_edit.Range{ .start = 11, .end = 6 }, field_edit.current().?.sel);
}

test "an unfocused field leaves edits queued" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 100 } });
    defer t.deinit();
    try setup("teh cat");
    two = true;
    try after();
    dvui.focusWidget(ids[1], null, null);
    try replace(0, 3, "the");
    try std.testing.expectEqualStrings("teh cat", std.mem.sliceTo(&buffers[0], 0));
    try std.testing.expectEqualStrings("the cat", std.mem.sliceTo(&buffers[1], 0));
    dvui.focusWidget(null, null, null);
    try std.testing.expect(field_edit.push(.{ .select = .{ .start = 0, .end = 0 } }));
    try after();
    try std.testing.expectEqual(@as(usize, 1), field_edit.take().len);
}

test "a long field publishes a window round the caret" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 100 } });
    defer t.deinit();
    try setup(&(@as([10000]u8, @splat('x'))));
    try select(8000, 8000);
    _ = try frame();
    const state = field_edit.current().?;
    try std.testing.expectEqual(@as(usize, 4096), state.text.len);
    try std.testing.expect(state.offset <= 8000 and 8000 < state.offset + state.text.len);
    try std.testing.expectEqual(field_edit.Range{ .start = 8000, .end = 8000 }, state.sel);
    const win = dvui.currentWindow();
    const next = dvui.frameTimeNS() + std.time.ns_per_ms;
    _ = try win.end(.{});
    try win.begin(next);
    try std.testing.expect(field_edit.current() == null);
}
