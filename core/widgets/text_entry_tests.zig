const std = @import("std");
const dvui = @import("dvui");
const TextEntry = @import("TextEntry.zig");
const ScrollArea = @import("ScrollArea.zig");

const text = "alpha beta gamma";
var buffer: [64]u8 = undefined;
var focused = false;
var selection: dvui.TextLayoutWidget.Selection = .{};
var touch_editing = false;
var menu = false;
// The test frame records these on the test runner thread.
var draggables = false;
// The test frame records the physical caret centre on the test runner thread.
var caret: dvui.Point.Physical = .{};
var field_bottom: f32 = 0;
var focus_field = false;
var scroll_info: dvui.ScrollInfo = .{};

fn frame() !dvui.App.Result {
    var field = TextEntry.init(@src(), .{ .text = .{ .buffer = &buffer } }, .{ .expand = .horizontal });
    defer field.deinit();
    focused = field.entry.data().id == dvui.focusedWidgetId();
    selection = field.entry.textLayout.selection.*;
    touch_editing = field.entry.textLayout.state.touch_editing;
    menu = field.entry.textLayout.state.te_show_context_menu;
    draggables = field.entry.textLayout.state.te_show_draggables;
    caret = field.entry.textLayout.screenRectScale(field.entry.textLayout.state.sel_end_r).r.center();
    return .ok;
}

fn scrollFrame() !dvui.App.Result {
    var root = dvui.box(@src(), .{}, .{ .expand = .both });
    defer root.deinit();
    var scroll = ScrollArea.init(@src(), .{ .scroll_info = &scroll_info, .horizontal = .none, .vertical_bar = .hide }, .{ .expand = .both });
    defer scroll.deinit();
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .h = 500 } });
    var field = TextEntry.init(@src(), .{}, .{ .min_size_content = .{ .w = 100, .h = 30 } });
    defer field.deinit();
    if (focus_field) dvui.focusWidget(field.entry.data().id, null, null);
    const rs = field.entry.data().borderRectScale();
    field_bottom = (rs.r.y + rs.r.h) / rs.s;
    return .ok;
}

fn after(ms: u64) !void {
    const cw = dvui.currentWindow();
    _ = try frame();
    _ = try cw.end(.{});
    try cw.begin(cw.frame_time_ns + @as(i128, ms) * std.time.ns_per_ms);
}

fn touch(action: dvui.Event.Mouse.Action) !void {
    _ = try dvui.currentWindow().addEventPointer(.{ .button = .touch0, .action = action, .xynorm = .{ .x = 0.1, .y = 0.05 } });
}

fn reset() void {
    @memset(&buffer, 0);
    @memcpy(buffer[0..text.len], text);
}

test "a touch press does not focus the field; the release of a tap does" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 200 } });
    defer t.deinit();
    reset();
    try dvui.testing.settle(frame);
    try touch(.press);
    try after(50);
    try std.testing.expect(!focused);
    try touch(.release);
    try after(16);
    try std.testing.expect(focused);
    try std.testing.expectEqual(selection.start, selection.end);
    try std.testing.expect(!touch_editing);
}

test "a press and release in one frame focus the field" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 200 } });
    defer t.deinit();
    reset();
    try dvui.testing.settle(frame);
    try touch(.press);
    try touch(.release);
    try after(16);
    try std.testing.expect(focused);
    try std.testing.expectEqual(selection.start, selection.end);
    try std.testing.expect(!touch_editing);
}

test "a drag past the slop that starts on the field leaves it unfocused" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 200 } });
    defer t.deinit();
    reset();
    try dvui.testing.settle(frame);
    try touch(.press);
    try after(50);
    _ = try dvui.currentWindow().addEventTouchMotion(.touch0, 0.1, 0.2, 0, 0.15);
    try after(600);
    try touch(.release);
    try after(16);
    try std.testing.expect(!focused);
    try std.testing.expectEqual(selection.start, selection.end);
    try std.testing.expect(!touch_editing);
}

test "a small drag and release in one frame leave the field unfocused" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 200 } });
    defer t.deinit();
    reset();
    try dvui.testing.settle(frame);
    try touch(.press);
    _ = try dvui.currentWindow().addEventTouchMotion(.touch0, 0.1, 0.08, 0, 0.03);
    _ = try dvui.currentWindow().addEventPointer(.{ .button = .touch0, .action = .release, .xynorm = .{ .x = 0.1, .y = 0.08 } });
    try after(16);
    try std.testing.expect(!focused);
    try std.testing.expectEqual(selection.start, selection.end);
    try std.testing.expect(!touch_editing);
}

test "a hold selects the word under the finger, focuses and shows the menu" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 200 } });
    defer t.deinit();
    reset();
    try dvui.testing.settle(frame);
    try touch(.press);
    try after(400);
    try after(100);
    try std.testing.expect(!focused);
    try std.testing.expectEqual(selection.start, selection.end);
    try std.testing.expect(!touch_editing);
    try after(16);
    try after(16);
    try after(16);
    try std.testing.expect(focused);
    try std.testing.expectEqualStrings("alpha", text[selection.start..selection.end]);
    try std.testing.expect(touch_editing);
    try std.testing.expect(menu);
    try touch(.release);
    try after(16);
    try after(16);
    try std.testing.expect(focused);
    try std.testing.expectEqualStrings("alpha", text[selection.start..selection.end]);
    try std.testing.expect(touch_editing);
    try std.testing.expect(menu);
}

test "the wrapper scrolls its enclosing area to a newly focused field" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 200 } });
    defer t.deinit();
    scroll_info = .{};
    focus_field = false;
    try dvui.testing.settle(scrollFrame);
    try std.testing.expect(field_bottom > 200);
    try std.testing.expectEqual(@as(f32, 0), scroll_info.viewport.y);
    focus_field = true;
    try dvui.testing.settle(scrollFrame);
    try std.testing.expect(scroll_info.viewport.y > 0);
    try std.testing.expect(field_bottom <= 200.5);
    try std.testing.expect(field_bottom > 140);
}

test "a double tap selects the word" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 200 } });
    defer t.deinit();
    reset();
    try dvui.testing.settle(frame);
    try touch(.press);
    try after(30);
    try touch(.release);
    try after(100);
    try touch(.press);
    try after(30);
    try touch(.release);
    try after(16);
    try after(16);
    try std.testing.expectEqualStrings("alpha", text[selection.start..selection.end]);
    try std.testing.expect(focused);
    try std.testing.expect(touch_editing);
}

test "two taps more than 300 ms apart do not select" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 200 } });
    defer t.deinit();
    reset();
    try dvui.testing.settle(frame);
    try touch(.press);
    try after(30);
    try touch(.release);
    // Beyond TouchHold's double-tap interval.
    try after(400);
    try touch(.press);
    try after(30);
    try touch(.release);
    try after(16);
    try after(16);
    try std.testing.expect(focused);
    try std.testing.expectEqual(selection.start, selection.end);
}

test "a tap on the focused caret opens the menu and another closes it" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 200 } });
    defer t.deinit();
    reset();
    try dvui.testing.settle(frame);
    try touch(.press);
    try after(30);
    try touch(.release);
    // Each tap is beyond TouchHold's double-tap interval.
    try after(400);
    try after(16);
    for ([_]bool{ true, false }) |show| {
        const wr = dvui.windowRectPixels();
        const point = caret;
        _ = try dvui.currentWindow().addEventPointer(.{ .button = .touch0, .action = .press, .xynorm = .{ .x = point.x / wr.w, .y = point.y / wr.h } });
        try after(30);
        _ = try dvui.currentWindow().addEventPointer(.{ .button = .touch0, .action = .release, .xynorm = .{ .x = point.x / wr.w, .y = point.y / wr.h } });
        try after(400);
        try after(16);
        try std.testing.expect(focused);
        try std.testing.expectEqual(selection.start, selection.end);
        try std.testing.expectEqual(show, touch_editing);
        try std.testing.expectEqual(show, draggables);
        try std.testing.expectEqual(show, menu);
    }
}
