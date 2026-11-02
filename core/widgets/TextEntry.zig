//! A text entry whose touch focus waits for a tap and whose selection waits for a hold.
//! dvui adds a `.focus` before every press (`Window.addEventMouseButton`), so a finger
//! landing on a field to scroll would otherwise enter it. Mouse input stays dvui's.
const std = @import("std");
const dvui = @import("dvui");
const touch = @import("touch.zig");
const TouchHold = @import("../TouchHold.zig");
const SelectableText = @import("SelectableText.zig");

const TextEntry = @This();

entry: *dvui.TextEntryWidget,
hold: *TouchHold,

/// Starts the field, reads this frame's touch events and draws it. Call `deinit`, as for `dvui.textEntry`.
pub fn init(src: std.lang.SourceLocation, init_opts: dvui.TextEntryWidget.InitOptions, opts: dvui.Options) TextEntry {
    // The entry draws its selection menu during init, which can take a press in another window.
    const unhandled = touch.unhandledPresses();
    const entry = dvui.widgetAlloc(dvui.TextEntryWidget);
    entry.init(src, init_opts, opts);
    const self: TextEntry = .{
        .entry = entry,
        .hold = dvui.dataGetPtrDefault(null, entry.data().id, "_hold", TouchHold, .{}),
    };
    self.keepFocusOnTouchdown();
    entry.processEvents();
    self.processTouch(unhandled);
    entry.draw();
    return self;
}

/// Ends the field and restores its parent and clip.
pub fn deinit(self: *TextEntry) void {
    self.entry.deinit();
    self.* = undefined;
}

fn keepFocusOnTouchdown(self: TextEntry) void {
    const rect = self.entry.data().borderRectScale().r;
    for (dvui.events()) |*e| {
        if (e.handled or e.evt != .mouse) continue;
        const me = e.evt.mouse;
        if (me.action == .focus and me.button.touch() and
            me.floating_win == dvui.subwindowCurrentId() and
            rect.contains(me.p) and dvui.clipGet().contains(me.p)) e.handle(@src(), self.entry.data());
    }
}

fn processTouch(self: TextEntry, unhandled: touch.Presses) void {
    const entry = self.entry;
    const tl = &entry.textLayout;
    const hold = self.hold;
    const rect = entry.data().borderRectScale().r;
    const slop = TouchHold.slop_pt * dvui.windowNaturalScale();
    for (dvui.events(), 0..) |*e, i| {
        if (e.evt != .mouse or !e.evt.mouse.button.touch()) continue;
        const me = e.evt.mouse;
        switch (me.action) {
            .press => {
                if (me.floating_win != dvui.subwindowCurrentId()) {
                    if (!touch.tookPress(unhandled, i, e)) {
                        hold.cancel();
                        tl.state.touch_editing = false;
                    }
                } else if (rect.contains(me.p) and dvui.clipGet().contains(me.p)) {
                    hold.press(me.p.x, me.p.y, dvui.frameTimeNS(), slop);
                } else {
                    hold.cancel();
                    tl.state.touch_editing = false;
                }
            },
            .motion => hold.move(me.p.x, me.p.y, slop),
            .release => {
                // A scroll clears the capture even when the release shares the press's frame.
                if (e.target_widgetId != tl.data().id) hold.cancel();
                switch (hold.release(dvui.frameTimeNS())) {
                    .none => {},
                    .tap, .double_tap => {
                        dvui.focusWidget(entry.data().id, null, e.num);
                        tl.state.touch_editing = false;
                        tl.sel_move = .{ .mouse = .{ .down_pt = tl.data().contentRectScale().pointFromPhysical(me.p) } };
                        tl.scroll_to_cursor = true;
                    },
                }
            },
            else => {},
        }
    }
    if (hold.armed and !hold.fired and !dvui.captured(tl.data().id)) hold.cancel();
    if (hold.due(dvui.frameTimeNS())) SelectableText.selectWordAt(tl, entry.data().id, hold.x, hold.y);
    if (hold.remaining(dvui.frameTimeNS())) |ns| {
        dvui.timer(entry.data().id, @intCast(@divTrunc(ns, std.time.ns_per_us) + 1));
    }
    // Disable dvui's release-to-select and release-to-toggle rules for the next frame.
    tl.state.te_first = false;
    tl.state.te_focus_on_touchdown = false;
}
