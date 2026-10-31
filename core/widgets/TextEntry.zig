//! A text field a finger can use the way a phone's own fields work: a tap focuses and puts the
//! caret under it, a hold selects the word, a double tap selects the word, a tap on the caret
//! toggles the Cut / Copy / Paste / Select all menu, and a drag is a scroll that leaves the field alone.
//!
//! This wraps `dvui.textEntry` rather than copying it: `entry` is dvui's widget, so `getText`,
//! `textSet` and the rest are unchanged, and mouse and pen are dvui's. What differs is when a touch
//! focuses and selects. dvui adds a `.focus` event before every press (`Window.addEventMouseButton`),
//! so a finger that lands on a field to scroll the page enters it; `init` marks that event handled
//! for a touch inside the field and focuses on the release of a tap instead (`core/TouchHold.zig`
//! decides tap, double tap and hold). dvui's own tap rules (`te_first`, `te_focus_on_touchdown`,
//! which select a word or toggle the menu on any release) are turned off the same way as in
//! `SelectableText`, whose `selectWordAt` a hold and a double tap share.
//!
//! A drag past `dvui.Dragging.threshold` makes dvui's text layout let go of the capture so the
//! enclosing `ScrollArea` or pager takes it, and the hold ends with the capture.
const std = @import("std");
const dvui = @import("dvui");
const TouchHold = @import("../TouchHold.zig");
const touch_press = @import("touch.zig");
const SelectableText = @import("SelectableText.zig");

const TextEntry = @This();

entry: *dvui.TextEntryWidget,
hold: *TouchHold,

/// Starts the field, reads this frame's touch events and draws it. Call `deinit` on the result,
/// as for `dvui.textEntry`.
pub fn init(src: std.lang.SourceLocation, init_opts: dvui.TextEntryWidget.InitOptions, opts: dvui.Options) TextEntry {
    // Taken before dvui draws the entry's menu and handles, which take their presses there.
    const unhandled = touch_press.unhandledPresses();
    const entry = dvui.widgetAlloc(dvui.TextEntryWidget);
    entry.init(src, init_opts, opts);
    const self: TextEntry = .{
        .entry = entry,
        .hold = dvui.dataGetPtrDefault(null, entry.data().id, "_hold", TouchHold, .{}),
    };
    self.keepFocusOnTouchdown();
    const touch_editing = entry.textLayout.state.touch_editing;
    entry.processEvents();
    self.processTouch(unhandled, touch_editing);
    entry.draw();
    return self;
}

/// Ends the field.
pub fn deinit(self: *TextEntry) void {
    self.entry.deinit();
    self.* = undefined;
}

/// Marks the `.focus` event of a touch press inside the field handled, so dvui's layout does not
/// focus it on the press.
fn keepFocusOnTouchdown(self: TextEntry) void {
    const rs = self.entry.data().borderRectScale();
    for (dvui.events()) |*e| {
        if (e.evt != .mouse or e.handled) continue;
        const me = e.evt.mouse;
        if (me.action != .focus or !me.button.touch()) continue;
        if (me.floating_win == dvui.subwindowCurrentId() and rs.r.contains(me.p) and dvui.clipGet().contains(me.p)) {
            e.handle(@src(), self.entry.data());
        }
    }
}

/// `unhandled` is `touch_press.unhandledPresses` as it was before the entry was drawn.
fn processTouch(self: TextEntry, unhandled: touch_press.Presses, touch_editing: bool) void {
    const entry = self.entry;
    const tl = &entry.textLayout;
    const hold = self.hold;
    const rs = entry.data().borderRectScale();
    const slop = TouchHold.slop_pt * dvui.windowNaturalScale();
    const focused = dvui.focusedWidgetId() == entry.data().id;

    for (dvui.events(), 0..) |*e, i| {
        if (e.evt != .mouse or !e.evt.mouse.button.touch()) continue;
        const me = e.evt.mouse;
        switch (me.action) {
            .press => {
                if (me.floating_win != dvui.subwindowCurrentId()) {
                    if (!touch_press.tookPress(unhandled, i, e)) {
                        hold.cancel();
                        tl.state.touch_editing = false;
                    }
                } else if (rs.r.contains(me.p) and dvui.clipGet().contains(me.p)) {
                    hold.press(me.p.x, me.p.y, dvui.frameTimeNS(), slop);
                } else {
                    hold.cancel();
                    tl.state.touch_editing = false;
                }
            },
            .motion => hold.move(me.p.x, me.p.y, slop),
            .release => {
                // A normal release clears capture after this event; a scroll clears it before.
                if (e.target_widgetId != tl.data().id) hold.cancel();
                switch (hold.release(dvui.frameTimeNS())) {
                    .none => {},
                    .tap => self.tap(me.p, focused, slop, e.num, touch_editing),
                    .double_tap => SelectableText.selectWordAt(tl, entry.data().id, me.p.x, me.p.y),
                }
            },
            else => {},
        }
    }
    // A press the layout did not take, or a drag it let go of, is not a hold.
    if (hold.armed and !hold.fired and !dvui.captured(tl.data().id)) hold.cancel();

    if (hold.due(dvui.frameTimeNS())) SelectableText.selectWordAt(tl, entry.data().id, hold.x, hold.y);
    if (hold.remaining(dvui.frameTimeNS())) |ns| {
        dvui.timer(tl.data().id, @intCast(@divTrunc(ns, std.time.ns_per_us) + 1));
    }

    // dvui's tap rules run on every touch release; off, they leave the state to this file.
    tl.state.te_first = false;
    tl.state.te_focus_on_touchdown = false;
}

/// A tap: focus, caret under the finger, and the menu toggled only by a tap on the caret.
fn tap(self: TextEntry, p: dvui.Point.Physical, was_focused: bool, slop: f32, event_num: u16, touch_editing: bool) void {
    const entry = self.entry;
    const tl = &entry.textLayout;
    const caret = tl.screenRectScale(tl.state.sel_end_r).r.outset(.all(slop));
    const on_caret = was_focused and tl.selection.empty() and caret.contains(p);

    dvui.focusWidget(entry.data().id, null, event_num);
    if (on_caret) {
        // dvui may toggle on this release before our tap policy runs.
        tl.state.touch_editing = !touch_editing;
        tl.state.te_show_draggables = tl.state.touch_editing;
        tl.state.te_show_context_menu = tl.state.touch_editing;
    } else {
        tl.state.touch_editing = false;
        tl.sel_move = .{ .mouse = .{ .down_pt = tl.data().contentRectScale().pointFromPhysical(p) } };
        tl.scroll_to_cursor = true;
    }
    dvui.refresh(null, @src(), tl.data().id);
}

// Written by testFrame and the field on the serial test runner thread.
var t_buf: [64]u8 = undefined;
// Written by testFrame on the serial test runner thread.
var t_selection: dvui.TextLayoutWidget.Selection = .{};
// Written by testFrame on the serial test runner thread.
var t_touch_editing = false;
// Written by testFrame on the serial test runner thread.
var t_focused = false;

// Written by testFrame on the serial test runner thread.
var t_caret: dvui.Point.Physical = .{};
// Written by testFrame on the serial test runner thread.
var t_show_draggables = false;
// Written by testFrame on the serial test runner thread.
var t_show_context_menu = false;

fn testFrame() !dvui.App.Result {
    var box = dvui.box(@src(), .{}, .{ .expand = .both });
    defer box.deinit();
    var te = TextEntry.init(@src(), .{ .text = .{ .buffer = &t_buf } }, .{ .expand = .horizontal });
    defer te.deinit();
    if (dvui.firstFrame(te.entry.data().id)) te.entry.textSet("alpha beta gamma", false);
    t_caret = te.entry.textLayout.screenRectScale(te.entry.textLayout.state.sel_end_r).r.center();
    t_selection = te.entry.textLayout.selection.*;
    t_touch_editing = te.entry.textLayout.state.touch_editing;
    t_show_draggables = te.entry.textLayout.state.te_show_draggables;
    t_show_context_menu = te.entry.textLayout.state.te_show_context_menu;
    t_focused = dvui.focusedWidgetId() == te.entry.data().id;
    return .ok;
}

fn frameAfter(ms: u64) !void {
    const cw = dvui.currentWindow();
    _ = try testFrame();
    _ = try cw.end(.{});
    try cw.begin(cw.frame_time_ns + @as(i128, ms) * std.time.ns_per_ms);
}

fn touch(action: dvui.Event.Mouse.Action, x: f32, y: f32) !void {
    const cw = dvui.currentWindow();
    _ = try cw.addEventPointer(.{ .button = .touch0, .action = action, .xynorm = .{ .x = x, .y = y } });
}

// The first letters of the text, a little inside the field's padding.
const on_text_x = 0.1;
const on_text_y = 0.05;

fn selectedWord() []const u8 {
    return t_buf[t_selection.start..t_selection.end];
}

fn selectedAny() bool {
    return t_selection.start != t_selection.end;
}

test "a touch press does not focus the field; the release of a tap does" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 200 } });
    defer t.deinit();
    try dvui.testing.settle(testFrame);
    try std.testing.expect(!t_focused);
    try touch(.press, on_text_x, on_text_y);
    try frameAfter(50);
    try std.testing.expect(!t_focused);
    try touch(.release, on_text_x, on_text_y);
    try frameAfter(16);
    try frameAfter(16);
    try std.testing.expect(t_focused);
    try std.testing.expect(!t_touch_editing);
}

test "a press and release in one frame focus the field" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 200 } });
    defer t.deinit();
    try dvui.testing.settle(testFrame);
    try touch(.press, on_text_x, on_text_y);
    try touch(.release, on_text_x, on_text_y);
    try frameAfter(16);
    try frameAfter(16);
    try std.testing.expect(t_focused);
    try std.testing.expect(!selectedAny());
}

test "a drag past the slop that starts on the field leaves it unfocused" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 200 } });
    defer t.deinit();
    try dvui.testing.settle(testFrame);
    try touch(.press, on_text_x, on_text_y);
    try frameAfter(50);
    const cw = dvui.currentWindow();
    _ = try cw.addEventTouchMotion(.touch0, on_text_x, on_text_y + 30.0 / 200.0, 0, 30.0 / 200.0);
    try frameAfter(16);
    try touch(.release, on_text_x, on_text_y + 30.0 / 200.0);
    try frameAfter(600);
    try frameAfter(16);
    try std.testing.expect(!t_focused);
    try std.testing.expect(!selectedAny());
}

test "a small drag and release in one frame leave the field unfocused" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 200 } });
    defer t.deinit();
    try dvui.testing.settle(testFrame);
    try touch(.press, on_text_x, on_text_y);
    try frameAfter(50);
    // Past dvui's drag threshold, but inside TouchHold's slop.
    const dy = 6.0 / 200.0;
    _ = try dvui.currentWindow().addEventTouchMotion(.touch0, on_text_x, on_text_y + dy, 0, dy);
    try touch(.release, on_text_x, on_text_y + dy);
    try frameAfter(16);
    try frameAfter(16);
    try std.testing.expect(!t_focused);
    try std.testing.expect(!selectedAny());
    try std.testing.expect(!t_touch_editing);
}

test "a hold selects the word under the finger, focuses and shows the menu" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 200 } });
    defer t.deinit();
    try dvui.testing.settle(testFrame);
    try touch(.press, on_text_x, on_text_y);
    try frameAfter(300);
    try frameAfter(100);
    try std.testing.expect(!selectedAny());
    try frameAfter(100);
    try frameAfter(16);
    try frameAfter(16);
    try std.testing.expect(t_focused);
    try std.testing.expect(t_touch_editing);
    try std.testing.expectEqualStrings("alpha", selectedWord());
    // Lifting the finger keeps the word and the menu.
    try touch(.release, on_text_x, on_text_y);
    try frameAfter(16);
    try frameAfter(16);
    try std.testing.expectEqualStrings("alpha", selectedWord());
    try std.testing.expect(t_touch_editing);
}

test "a double tap selects the word" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 200 } });
    defer t.deinit();
    try dvui.testing.settle(testFrame);
    try touch(.press, on_text_x, on_text_y);
    try frameAfter(30);
    try touch(.release, on_text_x, on_text_y);
    try frameAfter(100);
    try touch(.press, on_text_x, on_text_y);
    try frameAfter(30);
    try touch(.release, on_text_x, on_text_y);
    try frameAfter(16);
    try frameAfter(16);
    try std.testing.expectEqualStrings("alpha", selectedWord());
    try std.testing.expect(t_touch_editing);
}

test "two taps more than 300 ms apart do not select" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 200 } });
    defer t.deinit();
    try dvui.testing.settle(testFrame);
    try touch(.press, on_text_x, on_text_y);
    try touch(.release, on_text_x, on_text_y);
    try frameAfter(400);
    try touch(.press, on_text_x, on_text_y);
    try touch(.release, on_text_x, on_text_y);
    try frameAfter(16);
    try frameAfter(16);
    try std.testing.expect(!selectedAny());
    try std.testing.expect(!t_touch_editing);
}

test "a tap on the focused caret opens the menu and another closes it" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 200 } });
    defer t.deinit();
    try dvui.testing.settle(testFrame);
    try touch(.press, on_text_x, on_text_y);
    try touch(.release, on_text_x, on_text_y);
    // Beyond the double-tap interval: each release must toggle, rather than select a word.
    try frameAfter(400);
    try frameAfter(16);
    try std.testing.expect(t_focused);
    try std.testing.expect(!t_touch_editing);
    try touch(.press, t_caret.x / dvui.currentWindow().rect_pixels.w, t_caret.y / dvui.currentWindow().rect_pixels.h);
    try touch(.release, t_caret.x / dvui.currentWindow().rect_pixels.w, t_caret.y / dvui.currentWindow().rect_pixels.h);
    try frameAfter(400);
    try frameAfter(16);
    try std.testing.expect(t_touch_editing);
    try std.testing.expect(t_show_draggables);
    try std.testing.expect(t_show_context_menu);
    try touch(.press, t_caret.x / dvui.currentWindow().rect_pixels.w, t_caret.y / dvui.currentWindow().rect_pixels.h);
    try touch(.release, t_caret.x / dvui.currentWindow().rect_pixels.w, t_caret.y / dvui.currentWindow().rect_pixels.h);
    try frameAfter(400);
    try frameAfter(16);
    try std.testing.expect(!t_touch_editing);
    try std.testing.expect(!t_show_draggables);
    try std.testing.expect(!t_show_context_menu);
}
