//! A text field whose touch focus waits for a tap and whose selection waits for a hold.
//! dvui adds a `.focus` before every press (`Window.addEventMouseButton`), so otherwise a
//! finger landing on a field to scroll enters it. Wrap its widget and suppress that focus;
//! the mouse, text editing, selection handles and menu remain dvui's.
const std = @import("std");
const dvui = @import("dvui");
const TouchHold = @import("../TouchHold.zig");
const touch = @import("touch.zig");
const SelectableText = @import("SelectableText.zig");
const field_edit = @import("glass").field_edit;
const field_hints = @import("glass").field_hints;
const widgets = @import("../widgets.zig");

const TextEntry = @This();
entry: *dvui.TextEntryWidget,
hold: *TouchHold,

/// Starts and draws the field. Call `deinit`, as for `dvui.textEntry`.
/// Queued edits wait for focus so another field cannot consume them.
pub fn init(src: std.lang.SourceLocation, init_opts: dvui.TextEntryWidget.InitOptions, opts: dvui.Options) TextEntry {
    const unhandled = touch.unhandledPresses();
    const entry = dvui.widgetAlloc(dvui.TextEntryWidget);
    entry.init(src, init_opts, opts);
    if (dvui.focusedWidgetId() == entry.data().id) {
        for (field_edit.take()) |edit| {
            const range = widen(entry, switch (edit) {
                .replace => |r| r.range,
                .select => |r| r,
            });
            entry.textLayout.selection.* = .{ .start = @intCast(range.start), .end = @intCast(range.end), .cursor = @intCast(range.end) };
            switch (edit) {
                .replace => |r| entry.textTyped(r.text, false),
                .select => |r| {
                    if (r.start > r.end) entry.textLayout.selection.cursor = range.start;
                    dvui.refresh(null, @src(), entry.data().id);
                },
            }
        }
    }
    const self: TextEntry = .{
        .entry = entry,
        .hold = dvui.dataGetPtrDefault(null, entry.data().id, "_hold", TouchHold, .{}),
    };
    self.keepFocusOnTouchdown();
    // dvui turns the menu and handles on when a touch-editing finger lifts.
    const touch_editing = entry.textLayout.state.touch_editing;
    entry.processEvents();
    self.processTouch(unhandled, touch_editing);
    entry.draw();
    if (dvui.focusedWidgetId() == entry.data().id) {
        const sel = entry.textLayout.selection;
        const text = entry.text[0..entry.len];
        const caret = @min(sel.cursor, text.len);
        // A 4 KB window bounds publication cost while keeping the caret in view.
        var offset = if (text.len <= 4096) 0 else @min(caret -| 2048, text.len - 4096);
        while (offset > 0 and (std.unicode.utf8ByteSequenceLength(text[offset]) catch 0) == 0) offset -= 1;
        field_edit.publish(.{
            .text = text[offset..@min(offset + 4096, text.len)],
            .offset = offset,
            .sel = .{ .start = if (sel.cursor == sel.start) sel.end else sel.start, .end = sel.cursor },
            .hints = field_hints.current() orelse .{},
        });
    }
    return self;
}

/// Ends the field and scrolls its enclosing area to it when focus or its size changes.
pub fn deinit(self: *TextEntry) void {
    widgets.textEntryDeinit(self.entry);
    self.* = undefined;
}

fn keepFocusOnTouchdown(self: TextEntry) void {
    const rs = self.entry.data().borderRectScale();
    for (dvui.events()) |*e| {
        if (e.handled or e.evt != .mouse) continue;
        const me = e.evt.mouse;
        if (me.action == .focus and me.button.touch() and
            me.floating_win == dvui.subwindowCurrentId() and
            rs.r.contains(me.p) and dvui.clipGet().contains(me.p))
        {
            e.handle(@src(), self.entry.data());
        }
    }
}

fn processTouch(self: TextEntry, unhandled: touch.Presses, touch_editing: bool) void {
    const tl = &self.entry.textLayout;
    const hold = self.hold;
    const rs = self.entry.data().borderRectScale();
    const slop = TouchHold.slop_pt * dvui.windowNaturalScale();
    const focused = self.entry.data().id == dvui.focusedWidgetId();
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
                } else if (rs.r.contains(me.p) and dvui.clipGet().contains(me.p)) {
                    hold.press(me.p.x, me.p.y, dvui.frameTimeNS(), slop);
                } else {
                    hold.cancel();
                    tl.state.touch_editing = false;
                }
            },
            .motion => hold.move(me.p.x, me.p.y, slop),
            .release => {
                // A scroll cleared the layout's capture, even if press and release share a frame.
                if (e.target_widgetId != tl.data().id) hold.cancel();
                switch (hold.release(dvui.frameTimeNS())) {
                    .none => {},
                    .tap => self.tap(me.p, focused, slop, e.num, touch_editing),
                    .double_tap => SelectableText.selectWordAt(tl, self.entry.data().id, me.p.x, me.p.y),
                }
            },
            else => {},
        }
    }
    if (hold.armed and !hold.fired and !dvui.captured(tl.data().id)) hold.cancel();
    if (hold.due(dvui.frameTimeNS())) SelectableText.selectWordAt(tl, self.entry.data().id, hold.x, hold.y);
    if (hold.remaining(dvui.frameTimeNS())) |ns| {
        dvui.timer(tl.data().id, @intCast(@divTrunc(ns, std.time.ns_per_us) + 1));
    }
    tl.state.te_first = false;
    tl.state.te_focus_on_touchdown = false;
}

fn tap(self: TextEntry, p: dvui.Point.Physical, was_focused: bool, slop: f32, event_num: u16, touch_editing: bool) void {
    const tl = &self.entry.textLayout;
    const on_caret = was_focused and tl.selection.empty() and
        tl.screenRectScale(tl.state.sel_end_r).r.outset(.all(slop)).contains(p);
    dvui.focusWidget(self.entry.data().id, null, event_num);
    if (on_caret) {
        tl.state.touch_editing = !touch_editing;
        tl.state.te_show_draggables = !touch_editing;
        tl.state.te_show_context_menu = !touch_editing;
    } else {
        tl.sel_move = .{ .mouse = .{ .down_pt = tl.data().contentRectScale().pointFromPhysical(p) } };
        tl.scroll_to_cursor = true;
        tl.state.touch_editing = false;
        tl.state.te_show_draggables = false;
        tl.state.te_show_context_menu = false;
    }
}

fn widen(entry: *dvui.TextEntryWidget, range: field_edit.Range) field_edit.Range {
    var start = @min(@min(range.start, range.end), entry.len);
    var end = @min(@max(range.start, range.end), entry.len);
    while (start > 0 and start < entry.len and (std.unicode.utf8ByteSequenceLength(entry.text[start]) catch 0) == 0) start -= 1;
    while (end < entry.len and (std.unicode.utf8ByteSequenceLength(entry.text[end]) catch 0) == 0) end += 1;
    return .{ .start = start, .end = end };
}
