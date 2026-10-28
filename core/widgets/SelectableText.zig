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
//! A finger that moves past the slop is a scroll: dvui's text layout lets go of the capture
//! (`processEvent`, touch motion), so an enclosing `ScrollArea` takes it.
const std = @import("std");
const dvui = @import("dvui");
const TouchHold = @import("../TouchHold.zig");

const SelectableText = @This();

tl: *dvui.TextLayoutWidget,
hold: *TouchHold,

/// Starts the layout and reads this frame's touch events. Call `deinit` on the result, as for `dvui.textLayout`.
pub fn init(src: std.builtin.SourceLocation, init_opts: dvui.TextLayoutWidget.InitOptions, opts: dvui.Options) SelectableText {
    var tl_opts = init_opts;
    tl_opts.touch_edit_just_focused = false;
    const tl = dvui.textLayout(src, tl_opts, opts);
    const self: SelectableText = .{
        .tl = tl,
        .hold = dvui.dataGetPtrDefault(null, tl.data().id, "_hold", TouchHold, .{}),
    };
    self.processTouch();
    return self;
}

/// Ends the layout and puts back the tap rules `init` turned off.
pub fn deinit(self: *SelectableText) void {
    // Both are set by a touch-down for the tap rules `init` turned off; leaving them set would
    // make the release select.
    self.tl.state.te_first = false;
    self.tl.state.te_focus_on_touchdown = false;
    self.tl.deinit();
    self.* = undefined;
}

fn processTouch(self: SelectableText) void {
    const tl = self.tl;
    const hold = self.hold;
    const rs = tl.data().borderRectScale();
    const slop = TouchHold.slop_pt * dvui.windowNaturalScale();

    for (dvui.events()) |*e| {
        if (e.evt != .mouse or !e.evt.mouse.button.touch()) continue;
        const me = e.evt.mouse;
        // The Copy / Select all menu is a window of its own: a press on it is not outside the text.
        if (me.floating_win != dvui.subwindowCurrentId()) continue;
        switch (me.action) {
            .press => {
                if (rs.r.contains(me.p) and dvui.clipGet().contains(me.p)) {
                    hold.press(me.p.x, me.p.y, dvui.frameTimeNS());
                } else {
                    hold.cancel();
                    clear(tl);
                }
            },
            .motion => hold.move(me.p.x, me.p.y, slop),
            .release => if (hold.release()) clear(tl),
            else => {},
        }
    }

    if (hold.due(dvui.frameTimeNS())) {
        tl.sel_move = .{ .expand_pt = .{ .which = .word, .pt = tl.data().contentRectScale().pointFromPhysical(.{ .x = hold.x, .y = hold.y }) } };
        tl.state.touch_editing = true;
        tl.state.te_show_draggables = true;
        tl.state.te_show_context_menu = true;
        // dvui shows the menu and handles only for the focused layout.
        dvui.focusWidget(tl.data().id, null, null);
        dvui.refresh(null, @src(), tl.data().id);
    }
    if (hold.remaining(dvui.frameTimeNS())) |ns| {
        dvui.timer(tl.data().id, @intCast(@divTrunc(ns, std.time.ns_per_us) + 1));
    }
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

fn testFrame() !dvui.App.Result {
    var box = dvui.box(@src(), .{}, .{ .expand = .both });
    defer box.deinit();
    var st = SelectableText.init(@src(), .{}, .{ .expand = .horizontal });
    defer st.deinit();
    st.tl.addText(t_text, .{});
    t_selection = st.tl.selection.*;
    t_touch_editing = st.tl.state.touch_editing;
    return .ok;
}

/// One frame `ms` after the last.
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
