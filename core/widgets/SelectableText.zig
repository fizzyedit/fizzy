//! Read-only text a finger can select the way a phone's own text does: hold to select the word
//! under the finger, tap to clear, drag the handles to extend, Copy / Select all in the menu.
//!
//! Local copy of `dvui.textLayout`'s setup and event loop (dvui-dev 3d90fdd), with a
//! different touch policy: only a stationary hold selects. The layout, spans, links, mouse
//! selection, handles and Copy / Select all menu remain dvui's. `tl` exposes the same
//! `addText`, `addLink` and `addTextClick` API, including markdown spans.
//!
//! Touch motion within 14 pt belongs to the pending hold. Beyond that distance the layout
//! releases capture and the enclosing scroll area takes the motion. No dvui patch is needed.
const std = @import("std");
const dvui = @import("dvui");
const TouchHold = @import("../TouchHold.zig");

const SelectableText = @This();

tl: *dvui.TextLayoutWidget,
hold: *TouchHold,
finger: *dvui.enums.Button,

/// Starts the layout and reads this frame's touch events. Call `deinit` on the result, as for `dvui.textLayout`.
pub fn init(src: std.builtin.SourceLocation, init_opts: dvui.TextLayoutWidget.InitOptions, opts: dvui.Options) SelectableText {
    var tl_opts = init_opts;
    tl_opts.touch_edit_just_focused = false;
    const tl = dvui.widgetAlloc(dvui.TextLayoutWidget);
    const capture_before = dvui.captureMouseGet();
    tl.init(src, tl_opts, opts);
    const capture_after = dvui.captureMouseGet();
    // The layout's handle code captures its floating widget, but leaves its focus event
    // for the root. Keep keyboard focus on the text when that handle was just pressed.
    const handle_focus = if (capture_after) |cap|
        if (cap.id == cap.subwindow_id and
            (capture_before == null or capture_before.?.id != cap.id)) cap.id else null
    else
        null;
    tl.state.te_first = false;
    tl.state.te_focus_on_touchdown = false;
    var menu_window: ?dvui.Id = null;
    if (tl.touchEditing()) |floating| {
        menu_window = floating.data().id;
        defer floating.deinit();
        tl.touchEditingMenu();
    }
    const self: SelectableText = .{
        .tl = tl,
        .hold = dvui.dataGetPtrDefault(null, tl.data().id, "_hold", TouchHold, .{}),
        .finger = dvui.dataGetPtrDefault(null, tl.data().id, "_hold_finger", dvui.enums.Button, .none),
    };
    self.processTouch(handle_focus, menu_window);
    return self;
}

/// Ends the layout and saves its selection for the next frame.
pub fn deinit(self: *SelectableText) void {
    // Both are set by a touch-down for the tap rules `init` turned off; leaving them set would
    // make the release select.
    self.tl.state.te_first = false;
    self.tl.state.te_focus_on_touchdown = false;
    self.tl.deinit();
    self.* = undefined;
}

fn processTouch(self: SelectableText, handle_focus: ?dvui.Id, menu_window: ?dvui.Id) void {
    const tl = self.tl;
    const hold = self.hold;
    const rs = tl.data().borderRectScale();
    const slop = TouchHold.slop_pt * dvui.windowNaturalScale();

    for (dvui.events()) |*e| {
        const matches = tl.matchEvent(e);
        if (e.evt == .mouse and e.evt.mouse.button.touch()) {
            const me = e.evt.mouse;
            if (me.action == .focus and handle_focus == me.floating_win) {
                e.handle(@src(), tl.data());
                dvui.focusWidget(tl.data().id, null, e.num);
                continue;
            }
            switch (me.action) {
                .press => {
                    // Handles and the menu are separate subwindows, owned by this layout.
                    if (me.floating_win != handle_focus and me.floating_win != menu_window) {
                        hold.cancel();
                        self.finger.* = .none;
                        if (matches and rs.r.contains(me.p) and dvui.clipGet().contains(me.p)) {
                            hold.press(me.p.x, me.p.y, dvui.frameTimeNS());
                            self.finger.* = me.button;
                        } else {
                            clear(tl);
                        }
                    }
                },
                .motion => if (me.button == self.finger.*) {
                    hold.move(me.p.x, me.p.y, slop);
                    if (hold.armed and dvui.captured(tl.data().id)) {
                        // Keep small drift out of both dvui's drag threshold and the parent scroller.
                        e.handle(@src(), tl.data());
                        continue;
                    }
                },
                .release => if (me.button == self.finger.*) {
                    if (hold.release()) clear(tl);
                    self.finger.* = .none;
                },
                else => {},
            }
        }
        if (matches) {
            // A press and release can arrive in one frame: disable the tap rules before
            // each event, including the release, rather than correcting a queued selection.
            tl.state.te_first = false;
            tl.state.te_focus_on_touchdown = false;
            tl.processEvent(e);
        }
    }
    if (hold.armed and !dvui.captured(tl.data().id)) hold.cancel();

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
    tl.sel_move = .none;
}

const t_text = "alpha beta gamma delta";
// Written by `testFrame` and read by the test that drives it, on the one test thread.
var t_selection: dvui.TextLayoutWidget.Selection = .{};
var t_touch_editing = false;
// Set by the outside-subwindow test and read by its frame callback on the test thread.
var t_other_window = false;
// Written by the frame callbacks and inspected by tests on the same test thread.
var t_end_handle: dvui.Point.Physical = .{};
var t_scroll_info: dvui.ScrollInfo = .{ .vertical = .given, .virtual_size = .{ .h = 2000 } };

fn testFrame() !dvui.App.Result {
    var box = dvui.box(@src(), .{}, .{ .expand = .both });
    defer box.deinit();
    var st = SelectableText.init(@src(), .{}, .{ .expand = .horizontal });
    defer st.deinit();
    st.tl.addText(t_text, .{});
    t_selection = st.tl.selection.*;
    t_touch_editing = st.tl.state.touch_editing;
    const end = st.tl.state.sel_end_r;
    t_end_handle = st.tl.screenRectScale(end).r.bottomLeft().plus(.{ .x = 18, .y = 18 });
    if (t_other_window) {
        var floating: dvui.FloatingWidget = undefined;
        floating.init(@src(), .{}, .{ .rect = .{ .x = 200, .y = 100, .w = 100, .h = 100 } });
        floating.deinit();
    }
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

fn scrollingFrame() !dvui.App.Result {
    const ScrollArea = @import("ScrollArea.zig");
    var scroll = ScrollArea.init(@src(), .{
        .scroll_info = &t_scroll_info,
        .horizontal = .none,
        .vertical_bar = .hide,
    }, .{ .expand = .both });
    defer scroll.deinit();
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .h = 50 } });
    return testFrame();
}

fn scrollFrameAfter(ms: u64) !void {
    const cw = dvui.currentWindow();
    _ = try scrollingFrame();
    _ = try cw.end(.{});
    try cw.begin(cw.frame_time_ns + @as(i128, ms) * std.time.ns_per_ms);
}

test "small touch drift holds still and a drag past 14 points scrolls" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 200 } });
    defer t.deinit();
    t_scroll_info = .{ .vertical = .given, .virtual_size = .{ .h = 2000 } };
    try dvui.testing.settle(scrollingFrame);
    const cw = dvui.currentWindow();
    try touch(.press, on_text_x, 0.3);
    try scrollFrameAfter(50);
    _ = try cw.addEventTouchMotion(.touch0, on_text_x, 0.3 - 5.0 / 200.0, 0, -5.0 / 200.0);
    try scrollFrameAfter(50);
    try std.testing.expectEqual(@as(f32, 0), t_scroll_info.viewport.y);
    _ = try cw.addEventTouchMotion(.touch0, on_text_x, 0.3 - 20.0 / 200.0, 0, -15.0 / 200.0);
    try scrollFrameAfter(500);
    try std.testing.expect(t_scroll_info.viewport.y > 0);
    try scrollFrameAfter(16);
    try std.testing.expect(!selected());
}

test "dragging a selection handle extends the held word and release keeps it" {
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
    try std.testing.expectEqualStrings("alpha", t_text[t_selection.start..t_selection.end]);
    const handle = t_end_handle;
    const scale = dvui.windowNaturalScale();
    const width = 300 * scale;
    const height = 200 * scale;
    try touch(.press, handle.x / width, handle.y / height);
    try frameAfter(16);
    const cw = dvui.currentWindow();
    _ = try cw.addEventTouchMotion(.touch0, (handle.x + 120) / width, handle.y / height, 120 / width, 0);
    try frameAfter(16);
    try frameAfter(16);
    try std.testing.expect(t_selection.end > "alpha".len);
    const extended = t_selection;
    try touch(.release, (handle.x + 120) / width, handle.y / height);
    try frameAfter(16);
    try frameAfter(16);
    try std.testing.expectEqual(extended, t_selection);
}

test "mouse double click selects a word and a drag extends the selection" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 200 } });
    defer t.deinit();
    try dvui.testing.settle(testFrame);
    const cw = dvui.currentWindow();
    for (0..2) |_| {
        _ = try cw.addEventPointer(.{ .button = .left, .action = .press, .xynorm = .{ .x = on_text_x, .y = on_text_y } });
        try frameAfter(16);
        _ = try cw.addEventPointer(.{ .button = .left, .action = .release, .xynorm = .{ .x = on_text_x, .y = on_text_y } });
        try frameAfter(16);
    }
    try std.testing.expectEqualStrings("alpha", t_text[t_selection.start..t_selection.end]);
    _ = try cw.addEventPointer(.{ .button = .left, .action = .press, .xynorm = .{ .x = on_text_x, .y = on_text_y } });
    try frameAfter(16);
    _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = 200, .y = 20 } });
    try frameAfter(16);
    try std.testing.expect(t_selection.end > "alpha".len);
    try std.testing.expect(!t_touch_editing);
}

test "a touch in another subwindow clears the selection" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 200 } });
    defer t.deinit();
    t_other_window = true;
    defer t_other_window = false;
    try dvui.testing.settle(testFrame);
    try touch(.press, on_text_x, on_text_y);
    try frameAfter(500);
    try frameAfter(16);
    try frameAfter(16);
    try touch(.release, on_text_x, on_text_y);
    try frameAfter(16);
    try std.testing.expect(selected());
    try touch(.press, 0.9, 0.9);
    try frameAfter(16);
    try std.testing.expect(!selected());
}
