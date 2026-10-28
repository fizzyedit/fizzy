//! Read-only text a finger can select the way a phone's own text does: hold to select the word
//! under the finger, tap to clear, drag the handles to extend, Copy / Select all in the menu.
//!
//! This wraps `dvui.textLayout` rather than copying it: `tl` is the layout, so `addText`,
//! `addLink`, `addTextClick` and the rest are dvui's, and the mouse (click, double-click, drag)
//! is dvui's, unchanged. What differs is when a touch selects. dvui selects a word on the first
//! tap and toggles editing on a tap of focused text; here a tap never selects, so a finger that
//! lands on a chat message to scroll it does not select it. `init` turns those rules off
//! (`touch_edit_just_focused`, `te_first`, `te_focus_on_touchdown`) and runs `core/TouchHold.zig`
//! over the frame's touch events instead; its hold sets the same `sel_move` and `touch_editing`
//! dvui's own tap would, so dvui draws the handles and the menu and moves the ends on a drag.
//!
//! A finger that drags is a scroll: past `dvui.Dragging.threshold` dvui's text layout lets go of
//! the capture (`processEvent`, touch motion) so an enclosing `ScrollArea` takes it, and the hold
//! ends with the capture. The content has moved under the finger, so the word it would select is
//! not the one pressed. `TouchHold`'s slop bounds the drift when nothing lets go first.
//!
//! A touch anywhere else clears the selection, in another floating window too. Only the layout's
//! own Copy / Select all menu and selection handles are not elsewhere: they are windows of their
//! own, and `dvui.textLayout` takes a press on one before it returns, in the same frame as the
//! release if need be, so ownership is read per press: a press the call handled (a menu button),
//! or one on a window holding a handle's `_offset`.
const std = @import("std");
const dvui = @import("dvui");
const touch_press = @import("touch.zig");
const TouchHold = @import("../TouchHold.zig");

const SelectableText = @This();

tl: *dvui.TextLayoutWidget,
hold: *TouchHold,

/// Starts the layout and reads this frame's touch events. Call `deinit` on the result, as for `dvui.textLayout`.
pub fn init(src: std.builtin.SourceLocation, init_opts: dvui.TextLayoutWidget.InitOptions, opts: dvui.Options) SelectableText {
    var tl_opts = init_opts;
    tl_opts.touch_edit_just_focused = false;
    const unhandled = touch_press.unhandledPresses();
    const tl = dvui.textLayout(src, tl_opts, opts);
    const self: SelectableText = .{
        .tl = tl,
        .hold = dvui.dataGetPtrDefault(null, tl.data().id, "_hold", TouchHold, .{}),
    };
    self.processTouch(unhandled);
    return self;
}

/// Ends the layout and puts back the tap rules `init` turned off.
pub fn deinit(self: *SelectableText) void {
    // `te_first` starts set and a touch-down sets `te_focus_on_touchdown`; either makes dvui's
    // next touch release select a word or toggle editing, the tap rules `init` turned off.
    self.tl.state.te_first = false;
    self.tl.state.te_focus_on_touchdown = false;
    self.tl.deinit();
    self.* = undefined;
}

/// `unhandled` is `unhandledPresses` as it was before `dvui.textLayout` ran.
fn processTouch(self: SelectableText, unhandled: touch_press.Presses) void {
    const tl = self.tl;
    const hold = self.hold;
    const rs = tl.data().borderRectScale();
    const slop = TouchHold.slop_pt * dvui.windowNaturalScale();

    for (dvui.events(), 0..) |*e, i| {
        if (e.evt != .mouse or !e.evt.mouse.button.touch()) continue;
        const me = e.evt.mouse;
        switch (me.action) {
            .press => {
                if (me.floating_win != dvui.subwindowCurrentId()) {
                    if (!touch_press.tookPress(unhandled, i, e)) {
                        hold.cancel();
                        clear(tl);
                    }
                } else if (rs.r.contains(me.p) and dvui.clipGet().contains(me.p)) {
                    hold.press(me.p.x, me.p.y, dvui.frameTimeNS(), slop);
                } else {
                    hold.cancel();
                    clear(tl);
                }
            },
            .motion => hold.move(me.p.x, me.p.y, slop),
            .release => switch (hold.release(dvui.frameTimeNS())) {
                .none => {},
                .tap => clear(tl),
                .double_tap => selectWordAt(tl, tl.data().id, me.p.x, me.p.y),
            },
            else => {},
        }
    }
    // A press the layout did not take, or a drag it let go of, is not a hold.
    if (hold.armed and !hold.fired and !dvui.captured(tl.data().id)) hold.cancel();

    if (hold.due(dvui.frameTimeNS())) selectWordAt(tl, tl.data().id, hold.x, hold.y);
    if (hold.remaining(dvui.frameTimeNS())) |ns| {
        dvui.timer(tl.data().id, @intCast(@divTrunc(ns, std.time.ns_per_us) + 1));
    }
}

/// Selects the word under the physical point (`x`, `y`) of `tl` and shows its handles and menu:
/// what a hold or a double tap does, for read-only text and for a text entry alike. dvui shows the
/// menu and handles only for the focused layout, so this focuses `focus_id`, the widget that owns
/// `tl` (the layout itself, or the entry around it).
pub fn selectWordAt(tl: *dvui.TextLayoutWidget, focus_id: dvui.Id, x: f32, y: f32) void {
    tl.sel_move = .{ .expand_pt = .{ .which = .word, .pt = tl.data().contentRectScale().pointFromPhysical(.{ .x = x, .y = y }) } };
    tl.state.touch_editing = true;
    tl.state.te_show_draggables = true;
    tl.state.te_show_context_menu = true;
    dvui.focusWidget(focus_id, null, null);
    dvui.refresh(null, @src(), tl.data().id);
}

fn clear(tl: *dvui.TextLayoutWidget) void {
    tl.selection.start = 0;
    tl.selection.end = 0;
    tl.selection.cursor = 0;
    tl.state.touch_editing = false;
    // dvui's own release, run inside `textLayout` before `processTouch`, may have queued a word.
    tl.sel_move = .none;
}

const t_text = "alpha beta gamma delta";
// Written by `testFrame` and read by the test that drives it, on the one test thread.
var t_selection: dvui.TextLayoutWidget.Selection = .{};
var t_touch_editing = false;

var t_scroll: dvui.ScrollInfo = .{};
// Where the end handle of the selection is, in physical pixels.
var t_end_handle: dvui.Point.Physical = .{};

fn testFrame() !dvui.App.Result {
    var box = dvui.box(@src(), .{}, .{ .expand = .both });
    defer box.deinit();
    var st = SelectableText.init(@src(), .{}, .{ .expand = .horizontal });
    defer st.deinit();
    st.tl.addText(t_text, .{});
    t_selection = st.tl.selection.*;
    t_touch_editing = st.tl.state.touch_editing;
    // dvui puts the end handle, a 36-point square, below the line at the end of the selection.
    var r = st.tl.state.sel_end_r;
    r.y += r.h;
    const rs = st.tl.screenRectScale(r);
    t_end_handle = rs.r.topLeft().plus(.{ .x = 18 * rs.s, .y = 18 * rs.s });
    return .ok;
}

/// The text in a scroll area too short for it.
fn testScrollFrame() !dvui.App.Result {
    var scroll = dvui.scrollArea(@src(), .{ .scroll_info = &t_scroll }, .{ .expand = .both });
    defer scroll.deinit();
    var st = SelectableText.init(@src(), .{}, .{ .expand = .horizontal });
    defer st.deinit();
    for (0..40) |_| st.tl.addText(t_text ++ "\n", .{});
    t_selection = st.tl.selection.*;
    return .ok;
}

/// The text, and an unrelated floating window in the bottom right corner.
fn testFloatingFrame() !dvui.App.Result {
    _ = try testFrame();
    const widgets = @import("../widgets.zig");
    var fw = widgets.floatingWindow(@src(), .{}, .{ .rect = .{ .x = 200, .y = 120, .w = 90, .h = 70 } });
    defer fw.deinit();
    dvui.label(@src(), "panel", .{}, .{});
    return .ok;
}

/// One frame `ms` after the last.
fn frameAfter(ms: u64) !void {
    try frameOfAfter(testFrame, ms);
}

fn frameOfAfter(frame: dvui.App.frameFunction, ms: u64) !void {
    const cw = dvui.currentWindow();
    _ = try frame();
    _ = try cw.end(.{});
    try cw.begin(cw.frame_time_ns + @as(i128, ms) * std.time.ns_per_ms);
}

fn touch(action: dvui.Event.Mouse.Action, x: f32, y: f32) !void {
    const cw = dvui.currentWindow();
    _ = try cw.addEventPointer(.{ .button = .touch0, .action = action, .xynorm = .{ .x = x, .y = y } });
}

// The first letters of the text, a little inside the layout's padding.
const on_text_x = 0.1;
const on_text_y = 0.05;

fn selected() bool {
    return t_selection.start != t_selection.end;
}

test "a tap on text leaves the selection alone" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 200 } });
    defer t.deinit();
    try dvui.testing.settle(testFrame);
    try touch(.press, on_text_x, on_text_y);
    try frameAfter(50);
    try touch(.release, on_text_x, on_text_y);
    try frameAfter(50);
    try frameAfter(600);
    try std.testing.expect(!selected());
    try std.testing.expect(!t_touch_editing);
}

test "a tap whose press and release land in one frame leaves the selection alone" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 200 } });
    defer t.deinit();
    try dvui.testing.settle(testFrame);
    // Hold to select, so the text keeps focus; then a tap arrives as one frame's events.
    try touch(.press, on_text_x, on_text_y);
    try frameAfter(500);
    try frameAfter(16);
    try frameAfter(16);
    try touch(.release, on_text_x, on_text_y);
    try frameAfter(16);
    try touch(.press, on_text_x, on_text_y);
    try touch(.release, on_text_x, on_text_y);
    try frameAfter(16);
    try frameAfter(16);
    try std.testing.expect(!selected());
    try std.testing.expect(!t_touch_editing);
}

test "a finger held still selects the word under it after the delay, and no sooner" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 200 } });
    defer t.deinit();
    try dvui.testing.settle(testFrame);
    try touch(.press, on_text_x, on_text_y);
    try frameAfter(300);
    try frameAfter(100);
    try std.testing.expect(!selected());
    try frameAfter(100);
    try frameAfter(16);
    try frameAfter(16);
    try std.testing.expect(selected());
    try std.testing.expect(t_touch_editing);
    try std.testing.expectEqualStrings("alpha", t_text[t_selection.start..t_selection.end]);
}

test "lifting the held finger keeps the selection, and a tap on the text clears it" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 200 } });
    defer t.deinit();
    try dvui.testing.settle(testFrame);
    try touch(.press, on_text_x, on_text_y);
    try frameAfter(500);
    try frameAfter(16);
    try frameAfter(16);
    try touch(.release, on_text_x, on_text_y);
    try frameAfter(16);
    try frameAfter(16);
    try std.testing.expect(selected());

    try touch(.press, on_text_x, on_text_y);
    try frameAfter(50);
    try touch(.release, on_text_x, on_text_y);
    try frameAfter(16);
    try frameAfter(16);
    try std.testing.expect(!selected());
    try std.testing.expect(!t_touch_editing);
}

test "a touch elsewhere clears the selection" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 200 } });
    defer t.deinit();
    try dvui.testing.settle(testFrame);
    try touch(.press, on_text_x, on_text_y);
    try frameAfter(500);
    try frameAfter(16);
    try frameAfter(16);
    try touch(.release, on_text_x, on_text_y);
    try frameAfter(16);
    try std.testing.expect(selected());

    try touch(.press, 0.5, 0.9);
    try frameAfter(16);
    try frameAfter(16);
    try std.testing.expect(!selected());
}

test "a drag past the slop cancels the hold" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 200 } });
    defer t.deinit();
    try dvui.testing.settle(testFrame);
    try touch(.press, on_text_x, on_text_y);
    try frameAfter(50);
    // 30 points down on a 200-point window.
    const cw = dvui.currentWindow();
    _ = try cw.addEventTouchMotion(.touch0, on_text_x, on_text_y + 30.0 / 200.0, 0, 30.0 / 200.0);
    try frameAfter(600);
    try frameAfter(16);
    try std.testing.expect(!selected());
}

test "a slow drag in a scroll area scrolls and selects nothing" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 200 } });
    defer t.deinit();
    t_scroll = .{};
    try dvui.testing.settle(testScrollFrame);
    const cw = dvui.currentWindow();
    const y = 0.5;
    try touch(.press, on_text_x, y);
    try frameOfAfter(testScrollFrame, 16);
    // 5 points up, one at a time, inside the hold's slop but past dvui's drag threshold.
    for (1..6) |i| {
        _ = try cw.addEventTouchMotion(.touch0, on_text_x, y - @as(f32, @floatFromInt(i)) / 200.0, 0, -1.0 / 200.0);
        try frameOfAfter(testScrollFrame, 16);
    }
    try frameOfAfter(testScrollFrame, 600);
    try frameOfAfter(testScrollFrame, 16);
    try std.testing.expect(t_scroll.viewport.y > 0);
    try std.testing.expect(!selected());
}

test "a touch in another floating window clears the selection" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 200 } });
    defer t.deinit();
    try dvui.testing.settle(testFloatingFrame);
    try touch(.press, on_text_x, on_text_y);
    try frameOfAfter(testFloatingFrame, 500);
    try frameOfAfter(testFloatingFrame, 16);
    try frameOfAfter(testFloatingFrame, 16);
    try touch(.release, on_text_x, on_text_y);
    try frameOfAfter(testFloatingFrame, 16);
    try std.testing.expect(selected());

    try touch(.press, 245.0 / 300.0, 170.0 / 200.0);
    try frameOfAfter(testFloatingFrame, 16);
    try frameOfAfter(testFloatingFrame, 16);
    try std.testing.expect(!selected());
}

test "a touch on the selection's handle keeps it" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 200 } });
    defer t.deinit();
    try dvui.testing.settle(testFrame);
    try touch(.press, on_text_x, on_text_y);
    try frameAfter(500);
    try frameAfter(16);
    try frameAfter(16);
    try touch(.release, on_text_x, on_text_y);
    try frameAfter(16);
    try frameAfter(16);
    try std.testing.expect(selected());

    const wr = dvui.windowRectPixels();
    try touch(.press, t_end_handle.x / wr.w, t_end_handle.y / wr.h);
    try frameAfter(16);
    try frameAfter(16);
    try std.testing.expect(selected());
    try std.testing.expect(t_touch_editing);
}

/// Holds to select "alpha", lets go, and settles with the menu and handles showing.
fn selectAlpha() !void {
    try touch(.press, on_text_x, on_text_y);
    try frameAfter(500);
    try frameAfter(16);
    try frameAfter(16);
    try touch(.release, on_text_x, on_text_y);
    try frameAfter(16);
    try frameAfter(16);
    try std.testing.expect(selected());
}

test "a tap on a button of the menu, press and release in one frame, keeps the selection" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 200 } });
    defer t.deinit();
    try dvui.testing.settle(testFrame);
    try selectAlpha();

    // dvui puts the menu at the layout's top right, pushed back onto the window: the last of its
    // buttons is under this point.
    const x = 286.0 / 300.0;
    const y = 14.0 / 200.0;
    try touch(.press, x, y);
    try touch(.release, x, y);
    try frameAfter(16);
    try frameAfter(16);
    try std.testing.expect(selected());
}

test "a tap on the selection's handle, press and release in one frame, keeps it" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 200 } });
    defer t.deinit();
    try dvui.testing.settle(testFrame);
    try selectAlpha();

    const wr = dvui.windowRectPixels();
    try touch(.press, t_end_handle.x / wr.w, t_end_handle.y / wr.h);
    try touch(.release, t_end_handle.x / wr.w, t_end_handle.y / wr.h);
    try frameAfter(16);
    try frameAfter(16);
    try std.testing.expect(selected());
    try std.testing.expect(t_touch_editing);
}
