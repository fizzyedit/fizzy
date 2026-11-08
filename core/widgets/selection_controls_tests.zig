const std = @import("std");
const dvui = @import("dvui");
const SelectableText = @import("SelectableText.zig");
const SelectionControls = @import("SelectionControls.zig");

const text = "alpha beta gamma delta";
const LayoutState = std.meta.Child(@FieldType(dvui.TextLayoutWidget, "state"));

// Written by `frame` and read by the test that drives it, on the one test thread.
var layout_id: ?dvui.Id = null;
var selection: dvui.TextLayoutWidget.Selection = .{};
// Whether dvui's menu flag was set as a frame started, before `dvui.textLayout` reads it, in any
// frame since `start`.
var dvui_flag_at_start = false;
// Whether a frame since `start` drew a floating window that is neither the menu nor one of the
// two 36-point handles.
var other_windows = false;
// The selection's last line, in natural pixels.
var selection_end: dvui.Rect = .{};
var copies: usize = 0;
var actions: usize = 0;

fn onAction(action: SelectionControls.Action) void {
    actions += 1;
    if (action == .copy) copies += 1;
}

fn frame() !dvui.App.Result {
    if (layout_id) |id| {
        if (dvui.dataGetPtr(null, id, "__state", LayoutState)) |state| {
            if (state.te_show_context_menu) dvui_flag_at_start = true;
        }
    }
    var box = dvui.box(@src(), .{}, .{ .expand = .both });
    defer box.deinit();
    var st = SelectableText.initStyled(@src(), .{}, .{ .expand = .horizontal }, .{ .on_action = onAction });
    st.tl.addText(text, .{});
    layout_id = st.tl.data().id;
    selection = st.tl.selection.*;
    selection_end = dvui.windowRectScale().rectFromPhysical(st.tl.screenRectScale(st.tl.state.sel_end_r).r);
    st.deinit();

    const cw = dvui.currentWindow();
    for (cw.subwindows.stack.items) |sw| {
        if (!sw.used or sw.id == cw.data().id) continue;
        if (SelectionControls.test_last_menu) |m| if (sw.rect.equals(m.rect)) continue;
        if (sw.rect.w == 36 and sw.rect.h == 36) continue;
        other_windows = true;
    }
    return .ok;
}

fn frameAfter(ms: u64) !void {
    const cw = dvui.currentWindow();
    _ = try frame();
    _ = try cw.end(.{});
    try cw.begin(cw.frame_time_ns + @as(i128, ms) * std.time.ns_per_ms);
}

fn touch(action: dvui.Event.Mouse.Action, x: f32, y: f32) !void {
    const cw = dvui.currentWindow();
    _ = try cw.addEventPointer(.{ .button = .touch0, .action = action, .xynorm = .{ .x = x, .y = y } });
}

fn selected() []const u8 {
    return text[@min(selection.start, text.len)..@min(selection.end, text.len)];
}

/// A 300x200 window with the text at its top and "alpha" held past the hold, the finger still down.
fn hold() !dvui.testing {
    const t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 200 } });
    layout_id = null;
    copies = 0;
    actions = 0;
    SelectionControls.test_last_menu = null;
    try dvui.testing.settle(frame);
    dvui_flag_at_start = false;
    other_windows = false;
    try touch(.press, 0.1, 0.05);
    try frameAfter(500);
    try frameAfter(16);
    try frameAfter(16);
    return t;
}

/// `hold`, then the finger lifted.
fn start() !dvui.testing {
    const t = try hold();
    try touch(.release, 0.1, 0.05);
    try frameAfter(16);
    try frameAfter(16);
    try frameAfter(16);
    try std.testing.expectEqualStrings("alpha", selected());
    return t;
}

test "the menu waits for the finger that selects to lift" {
    var t = try hold();
    defer t.deinit();
    try std.testing.expectEqualStrings("alpha", selected());
    try frameAfter(16);
    try std.testing.expect(SelectionControls.test_last_menu == null);
    try touch(.release, 0.1, 0.05);
    try frameAfter(16);
    try frameAfter(16);
    try std.testing.expect(SelectionControls.test_last_menu != null);
}

test "dvui's menu never shows on plain text" {
    var t = try start();
    defer t.deinit();
    // A tap on Select all, the last button, keeps touch editing on: the frame after its release
    // is where dvui would draw its own.
    const r = SelectionControls.test_last_menu.?.rect;
    const x = (r.x + r.w - 20) / 300.0;
    const y = (r.y + r.h / 2) / 200.0;
    try touch(.press, x, y);
    try frameAfter(16);
    try touch(.release, x, y);
    try frameAfter(16);
    try frameAfter(16);
    try std.testing.expect(!dvui_flag_at_start);
    try std.testing.expect(!other_windows);
}

test "plain text gets Copy and Select all, at least 44 points tall" {
    var t = try start();
    defer t.deinit();
    const m = SelectionControls.test_last_menu.?;
    try std.testing.expectEqual(2, m.labels);
    try std.testing.expect(m.rect.h >= 44);
}

test "Copy reports the action and puts the text on the clipboard" {
    var t = try start();
    defer t.deinit();
    // Copy is the first button.
    const r = SelectionControls.test_last_menu.?.rect;
    const x = (r.x + 20) / 300.0;
    const y = (r.y + r.h / 2) / 200.0;
    try touch(.press, x, y);
    try frameAfter(16);
    try touch(.release, x, y);
    try frameAfter(16);
    try std.testing.expectEqual(1, copies);
    try std.testing.expectEqual(1, actions);
    try std.testing.expectEqualStrings("alpha", dvui.clipboardText());

    SelectionControls.test_last_menu = null;
    try frameAfter(16);
    try std.testing.expect(SelectionControls.test_last_menu == null);
    try std.testing.expectEqualStrings("alpha", selected());
}

test "a menu that would leave the top goes below the selection" {
    var t = try start();
    defer t.deinit();
    const r = SelectionControls.test_last_menu.?.rect;
    try std.testing.expect(r.y > selection_end.y + selection_end.h);
    try std.testing.expect(r.x >= 0 and r.y >= 0 and r.x + r.w <= 300 and r.y + r.h <= 200);
}
