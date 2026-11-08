const std = @import("std");
const dvui = @import("dvui");
const SelectableText = @import("SelectableText.zig");
const SelectionControls = @import("SelectionControls.zig");
const TextEntry = @import("TextEntry.zig");

const text = "alpha beta gamma delta";
const field_text = "alpha beta";
const LayoutState = std.meta.Child(@FieldType(dvui.TextLayoutWidget, "state"));

/// What `frame` draws: plain text, or a field.
const Subject = enum { text, field };

// Written by `frame` and read by the test that drives it, on the one test thread.
var subject: Subject = .text;
var layout_id: ?dvui.Id = null;
var field_id: ?dvui.Id = null;
var selection: dvui.TextLayoutWidget.Selection = .{};
// The field's text as its last frame ended.
var field_buf: [64]u8 = undefined;
var field_len: usize = 0;
// The caret's rect, in natural pixels.
var caret: dvui.Rect = .{};
var cuts: usize = 0;
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
    if (action == .cut) cuts += 1;
}

fn fieldText() []const u8 {
    return field_buf[0..field_len];
}

fn frame() !dvui.App.Result {
    if (layout_id) |id| {
        if (dvui.dataGetPtr(null, id, "__state", LayoutState)) |state| {
            if (state.te_show_context_menu) dvui_flag_at_start = true;
        }
    }
    var box = dvui.box(@src(), .{}, .{ .expand = .both });
    defer box.deinit();
    switch (subject) {
        .text => {
            var st = SelectableText.initStyled(@src(), .{}, .{ .expand = .horizontal }, .{ .on_action = onAction });
            st.tl.addText(text, .{});
            layout_id = st.tl.data().id;
            selection = st.tl.selection.*;
            selection_end = dvui.windowRectScale().rectFromPhysical(st.tl.screenRectScale(st.tl.state.sel_end_r).r);
            st.deinit();
        },
        .field => {
            var te = TextEntry.initStyled(@src(), .{ .text_initial = field_text }, .{ .expand = .horizontal }, .{ .on_action = onAction });
            const tl = &te.entry.textLayout;
            layout_id = tl.data().id;
            field_id = te.entry.data().id;
            selection = tl.selection.*;
            caret = dvui.windowRectScale().rectFromPhysical(tl.screenRectScale(tl.state.sel_end_r).r);
            selection_end = caret;
            const now = te.entry.getText();
            field_len = @min(now.len, field_buf.len);
            @memcpy(field_buf[0..field_len], now[0..field_len]);
            te.deinit();
        },
    }

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
    const of = switch (subject) {
        .text => text,
        .field => fieldText(),
    };
    return of[@min(selection.start, of.len)..@min(selection.end, of.len)];
}

/// Where "alpha" is in `on`, as fractions of the window.
fn alpha(on: Subject) dvui.Point {
    return switch (on) {
        .text => .{ .x = 0.1, .y = 0.05 },
        // Inside the field's margin, border and padding.
        .field => .{ .x = 0.1, .y = 0.1 },
    };
}

/// A 300x200 window with `on` drawn at its top, settled.
fn open(on: Subject) !dvui.testing {
    const t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 200 } });
    subject = on;
    layout_id = null;
    field_id = null;
    copies = 0;
    cuts = 0;
    actions = 0;
    SelectionControls.test_last_menu = null;
    try dvui.testing.settle(frame);
    dvui_flag_at_start = false;
    other_windows = false;
    return t;
}

/// `on` with "alpha" held past the hold, the finger still down.
fn hold(on: Subject) !dvui.testing {
    const t = try open(on);
    const p = alpha(on);
    try touch(.press, p.x, p.y);
    try frameAfter(500);
    try frameAfter(16);
    try frameAfter(16);
    return t;
}

/// `hold`, then the finger lifted.
fn start(on: Subject) !dvui.testing {
    const t = try hold(on);
    const p = alpha(on);
    try touch(.release, p.x, p.y);
    try frameAfter(16);
    try frameAfter(16);
    try frameAfter(16);
    try std.testing.expectEqualStrings("alpha", selected());
    return t;
}

/// A tap of the menu's first button, or its last, with the frame after its release. Buttons
/// differ in width, so this aims 20 points in from the row's ends.
fn tapButton(first: bool) !void {
    const r = SelectionControls.test_last_menu.?.rect;
    const x = (if (first) r.x + 20 else r.x + r.w - 20) / 300.0;
    const y = (r.y + r.h / 2) / 200.0;
    try touch(.press, x, y);
    try frameAfter(16);
    try touch(.release, x, y);
    try frameAfter(16);
}

test "the menu waits for the finger that selects to lift" {
    var t = try hold(.text);
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
    var t = try start(.text);
    defer t.deinit();
    // A tap on Select all, the last button, keeps touch editing on: the frame after its release
    // is where dvui would draw its own.
    try tapButton(false);
    try frameAfter(16);
    try std.testing.expect(!dvui_flag_at_start);
    try std.testing.expect(!other_windows);
}

test "plain text gets Copy and Select all, at least 44 points tall" {
    var t = try start(.text);
    defer t.deinit();
    const m = SelectionControls.test_last_menu.?;
    try std.testing.expectEqual(2, m.labels);
    try std.testing.expect(m.rect.h >= 44);
}

test "Copy reports the action and puts the text on the clipboard" {
    var t = try start(.text);
    defer t.deinit();
    // Copy is the first button.
    try tapButton(true);
    try std.testing.expectEqual(1, copies);
    try std.testing.expectEqual(1, actions);
    try std.testing.expectEqualStrings("alpha", dvui.clipboardText());

    SelectionControls.test_last_menu = null;
    try frameAfter(16);
    try std.testing.expect(SelectionControls.test_last_menu == null);
    try std.testing.expectEqualStrings("alpha", selected());
}

test "a menu that would leave the top goes below the selection" {
    var t = try start(.text);
    defer t.deinit();
    const r = SelectionControls.test_last_menu.?.rect;
    try std.testing.expect(r.y > selection_end.y + selection_end.h);
    try std.testing.expect(r.x >= 0 and r.y >= 0 and r.x + r.w <= 300 and r.y + r.h <= 200);
}

test "dvui's menu never shows in a field" {
    var t = try start(.field);
    defer t.deinit();
    try std.testing.expect(SelectionControls.test_last_menu != null);
    // A tap on Select all, the last button, keeps touch editing on: the frame after its release
    // is where dvui would draw its own.
    try tapButton(false);
    try frameAfter(16);
    try std.testing.expect(!dvui_flag_at_start);
    try std.testing.expect(!other_windows);
}

test "the field's menu has four labelled buttons at least 44 points tall" {
    var t = try start(.field);
    defer t.deinit();
    const m = SelectionControls.test_last_menu.?;
    try std.testing.expectEqual(4, m.labels);
    try std.testing.expect(m.rect.h >= 44);
}

test "Cut reports the action, empties the selection's text and keeps the field focused" {
    var t = try start(.field);
    defer t.deinit();
    // Cut is the first button.
    try tapButton(true);
    try std.testing.expectEqual(1, cuts);
    try std.testing.expectEqual(1, actions);
    try std.testing.expectEqualStrings(" beta", fieldText());
    try std.testing.expectEqualStrings("alpha", dvui.clipboardText());
    try std.testing.expectEqual(field_id, dvui.focusedWidgetId());

    SelectionControls.test_last_menu = null;
    try frameAfter(16);
    try std.testing.expect(SelectionControls.test_last_menu == null);
}

test "a tap on the caret shows the menu without a selection" {
    var t = try open(.field);
    defer t.deinit();
    // A tap past the text focuses the field with the caret at its end.
    try touch(.press, 0.8, 0.1);
    try frameAfter(16);
    try touch(.release, 0.8, 0.1);
    try frameAfter(16);
    try frameAfter(16);
    try std.testing.expectEqual(field_id, dvui.focusedWidgetId());
    try std.testing.expect(SelectionControls.test_last_menu == null);

    const x = (caret.x + caret.w / 2) / 300.0;
    const y = (caret.y + caret.h / 2) / 200.0;
    // Far enough from the first tap not to be its double tap.
    try touch(.press, x, y);
    try frameAfter(16);
    try touch(.release, x, y);
    try frameAfter(16);
    try frameAfter(16);
    try std.testing.expect(selection.empty());
    try std.testing.expectEqual(2, SelectionControls.test_last_menu.?.labels);
}
