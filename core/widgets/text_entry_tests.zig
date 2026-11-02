//! Touch focus and selection through the wrapped entry in a real dvui test window.
const std = @import("std");
const dvui = @import("dvui");
const TextEntry = @import("../widgets.zig").TextEntry;
const text = "alpha beta gamma";

// Written by the frame and its driver on the test UI thread.
var buffer: [64]u8 = @splat(0);
// Written by testFrame on the test UI thread.
var focused = false;
// Written by testFrame on the test UI thread.
var selection: dvui.TextLayoutWidget.Selection = .{};
// Written by testFrame on the test UI thread.
var touch_editing = false;
// Written by testFrame on the test UI thread.
var show_menu = false;

fn testFrame() !dvui.App.Result {
    var field = TextEntry.init(@src(), .{ .text = .{ .buffer = &buffer } }, .{ .expand = .horizontal });
    defer field.deinit();
    focused = dvui.focusedWidgetId() == field.entry.data().id;
    selection = field.entry.textLayout.selection.*;
    touch_editing = field.entry.textLayout.state.touch_editing;
    show_menu = field.entry.textLayout.state.te_show_context_menu;
    return .ok;
}

fn settle() !void {
    buffer = @splat(0);
    @memcpy(buffer[0..text.len], text);
    try dvui.testing.settle(testFrame);
}

// Render at the current time, then begin the next frame `ms` later.
fn frameAfter(ms: u64) !void {
    const win = dvui.currentWindow();
    _ = try testFrame();
    _ = try win.end(.{});
    try win.begin(win.frame_time_ns + @as(i128, ms) * std.time.ns_per_ms);
}

const x = 0.1;
const y = 0.05;

fn touch(action: dvui.Event.Mouse.Action) !void {
    _ = try dvui.currentWindow().addEventPointer(.{ .button = .touch0, .action = action, .xynorm = .{ .x = x, .y = y } });
}

fn expectNoSelection() !void {
    try std.testing.expectEqual(selection.start, selection.end);
    try std.testing.expect(!touch_editing);
}

test "a touch press does not focus the field; the release of a tap does" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 200 } });
    defer t.deinit();
    try settle();
    try touch(.press);
    try frameAfter(50);
    try std.testing.expect(!focused);
    try expectNoSelection();
    try touch(.release);
    try frameAfter(16);
    try frameAfter(16);
    try std.testing.expect(focused);
    try expectNoSelection();
}

test "a press and release in one frame focus the field" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 200 } });
    defer t.deinit();
    try settle();
    try touch(.press);
    try touch(.release);
    try frameAfter(16);
    try frameAfter(16);
    try std.testing.expect(focused);
    try expectNoSelection();
}

test "a drag past the slop that starts on the field leaves it unfocused" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 200 } });
    defer t.deinit();
    try settle();
    try touch(.press);
    try frameAfter(50);
    // 30 points of motion on a 200-point window exceeds the hold slop.
    _ = try dvui.currentWindow().addEventTouchMotion(.touch0, x, y + 30.0 / 200.0, 0, 30.0 / 200.0);
    try frameAfter(600);
    _ = try dvui.currentWindow().addEventPointer(.{ .button = .touch0, .action = .release, .xynorm = .{ .x = x, .y = y + 30.0 / 200.0 } });
    try frameAfter(16);
    try frameAfter(16);
    try std.testing.expect(!focused);
    try expectNoSelection();
}

test "a small drag and release in one frame leave the field unfocused" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 200 } });
    defer t.deinit();
    try settle();
    try touch(.press);
    // Six points exceeds dvui's drag threshold but stays inside the hold slop.
    _ = try dvui.currentWindow().addEventTouchMotion(.touch0, x, y + 6.0 / 200.0, 0, 6.0 / 200.0);
    _ = try dvui.currentWindow().addEventPointer(.{ .button = .touch0, .action = .release, .xynorm = .{ .x = x, .y = y + 6.0 / 200.0 } });
    try frameAfter(16);
    try frameAfter(16);
    try std.testing.expect(!focused);
    try expectNoSelection();
}

test "a hold selects the word under the finger, focuses and shows the menu" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 200 } });
    defer t.deinit();
    try settle();
    try touch(.press);
    try frameAfter(300);
    try frameAfter(100);
    try frameAfter(100);
    try std.testing.expect(!focused);
    try expectNoSelection();
    try frameAfter(16);
    try frameAfter(16);
    try frameAfter(16);
    try std.testing.expect(focused);
    try std.testing.expectEqualStrings("alpha", buffer[selection.start..selection.end]);
    try std.testing.expect(touch_editing);
    try std.testing.expect(show_menu);
    try touch(.release);
    try frameAfter(16);
    try frameAfter(16);
    try std.testing.expect(focused);
    try std.testing.expectEqualStrings("alpha", buffer[selection.start..selection.end]);
    try std.testing.expect(touch_editing);
    try std.testing.expect(show_menu);
}
