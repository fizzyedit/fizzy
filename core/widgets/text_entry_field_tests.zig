//! Range edits use the focused field's own dvui editing path.
const std = @import("std");
const dvui = @import("dvui");
const field_edit = @import("glass").field_edit;
const TextEntry = @import("TextEntry.zig");

// The frame helper and tests write these on the test runner thread.
var buffers: [2][10001]u8 = undefined;
var ids: [2]dvui.Id = undefined;
var selections: [2]dvui.TextLayoutWidget.Selection = undefined;
var two_fields = false;

fn frame() !dvui.App.Result {
    for (0..@as(usize, if (two_fields) 2 else 1)) |i| {
        var field = TextEntry.init(@src(), .{ .text = .{ .buffer = &buffers[i] } }, .{ .id_extra = i, .expand = .horizontal });
        ids[i] = field.entry.data().id;
        selections[i] = field.entry.textLayout.selection.*;
        field.deinit();
    }
    return .ok;
}

fn after() !void {
    _ = try frame();
    const win = dvui.currentWindow();
    _ = try win.end(.{});
    try win.begin(win.frame_time_ns + std.time.ns_per_ms);
}

fn setup(text: []const u8, two: bool) !void {
    _ = field_edit.take();
    two_fields = two;
    for (&buffers) |*buffer| {
        @memset(buffer, 0);
        @memcpy(buffer[0..text.len], text);
    }
    try dvui.testing.settle(frame);
    dvui.focusWidget(ids[if (two) 1 else 0], null, null);
}

fn expectText(index: usize, text: []const u8) !void {
    try std.testing.expectEqualStrings(text, std.mem.sliceTo(&buffers[index], 0));
}

test "a replace fixes a word where it sits" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 100 } });
    defer t.deinit();
    try setup("teh cat", false);
    try std.testing.expect(field_edit.push(.{ .replace = .{ .range = .{ .start = 0, .end = 3 }, .text = "the" } }));
    _ = try frame();
    const state = field_edit.current().?;
    try std.testing.expectEqualStrings("the cat", state.text);
    try std.testing.expectEqual(@as(usize, 0), state.offset);
    try std.testing.expectEqual(@as(?bool, null), state.hints.autocorrect);
    try expectText(0, "the cat");
    try std.testing.expectEqual(@as(usize, 3), selections[0].cursor);
}

test "a range inside a code point widens to it" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 100 } });
    defer t.deinit();
    try setup("h\xc3\xa9llo", false);
    try std.testing.expect(field_edit.push(.{ .replace = .{ .range = .{ .start = 2, .end = 2 }, .text = "e" } }));
    try after();
    try expectText(0, "hello");
}

test "select moves the caret and the selection" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 100 } });
    defer t.deinit();
    try setup("hello world", false);
    try std.testing.expect(field_edit.push(.{ .select = .{ .start = 6, .end = 11 } }));
    try after();
    try std.testing.expectEqual(@as(usize, 6), selections[0].start);
    try std.testing.expectEqual(@as(usize, 11), selections[0].end);
    try std.testing.expectEqual(@as(usize, 11), selections[0].cursor);
    try std.testing.expect(field_edit.push(.{ .select = .{ .start = 3, .end = 3 } }));
    try after();
    try std.testing.expectEqual(@as(usize, 3), selections[0].cursor);
    try std.testing.expect(selections[0].empty());
    try std.testing.expect(field_edit.push(.{ .select = .{ .start = 99, .end = 6 } }));
    try after();
    try std.testing.expectEqual(@as(usize, 6), selections[0].start);
    try std.testing.expectEqual(@as(usize, 11), selections[0].end);
}

test "an unfocused field leaves edits queued" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 100 } });
    defer t.deinit();
    try setup("teh cat", true);
    try std.testing.expect(field_edit.push(.{ .replace = .{ .range = .{ .start = 0, .end = 3 }, .text = "the" } }));
    try after();
    try expectText(0, "teh cat");
    try expectText(1, "the cat");
    dvui.focusWidget(null, null, null);
    try std.testing.expect(field_edit.push(.{ .select = .{ .start = 1, .end = 2 } }));
    try after();
    try std.testing.expectEqual(@as(usize, 1), field_edit.take().len);
    try std.testing.expectEqual(@as(?field_edit.State, null), field_edit.current());
}

test "a long field publishes a window round the caret" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 100 } });
    defer t.deinit();
    const text = @as([10000]u8, @splat('a'));
    try setup(&text, false);
    try std.testing.expect(field_edit.push(.{ .select = .{ .start = 8000, .end = 8000 } }));
    _ = try frame();
    const state = field_edit.current().?;
    try std.testing.expectEqual(@as(usize, 4096), state.text.len);
    try std.testing.expect(state.offset <= 8000 and 8000 < state.offset + state.text.len);
    try std.testing.expectEqual(field_edit.Range{ .start = 8000, .end = 8000 }, state.sel);
}
