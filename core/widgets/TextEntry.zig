//! A text field whose touch focus waits for a tap and whose selection waits for a hold.
//! dvui adds a `.focus` before every press (`Window.addEventMouseButton`), so otherwise a
//! finger landing on a field to scroll enters it. Wrap its widget and suppress that focus;
//! the mouse, text editing and selection handles remain dvui's. The touch menu is fizzy's,
//! `SelectionControls`, drawn at the end of `init`; `deinit` turns dvui's off.
const std = @import("std");
const dvui = @import("dvui");
const field_edit = @import("glass").field_edit;
const field_hints = @import("glass").field_hints;
const TouchHold = @import("../TouchHold.zig");
const touch = @import("touch.zig");
const SelectableText = @import("SelectableText.zig");
const SelectionControls = @import("SelectionControls.zig");
const widgets = @import("../widgets.zig");
const platform = @import("../platform.zig");

const TextEntry = @This();
entry: *dvui.TextEntryWidget,
hold: *TouchHold,
style: SelectionControls.Style,
/// The field's text and caret once this frame's events were done, for `deinit` to tell an edit
/// the app made after them (`te.entry.textSet`). Null when the field had no focus then.
ime_after: ?ImeSeen,
/// Whether the app, not the keyboard, changed the text or caret this frame
/// (`platform.requestImeReset`, asked in `deinit`).
ime_stale: bool,

/// The field's text and caret at the end of the last frame it had focus, under `_ime_seen`. The
/// hash tells a same-length replacement (`textSet("world")` over `hello`) from no edit.
const ImeSeen = struct {
    len: usize,
    cursor: usize,
    hash: u64,

    fn of(entry: *dvui.TextEntryWidget) ImeSeen {
        return .{
            .len = entry.len,
            .cursor = entry.textLayout.selection.cursor,
            .hash = std.hash.Wyhash.hash(0, entry.getText()),
        };
    }
};

/// Starts the field, reads this frame's touch events and draws it. Call `deinit`, as for `dvui.textEntry`.
pub fn init(src: std.lang.SourceLocation, init_opts: dvui.TextEntryWidget.InitOptions, opts: dvui.Options) TextEntry {
    return initStyled(src, init_opts, opts, .{});
}

/// `init`, with the selection menu drawn in `style`.
pub fn initStyled(src: std.lang.SourceLocation, init_opts: dvui.TextEntryWidget.InitOptions, opts: dvui.Options, style: SelectionControls.Style) TextEntry {
    const unhandled = touch.unhandledPresses();
    const entry = dvui.widgetAlloc(dvui.TextEntryWidget);
    entry.init(src, init_opts, opts);
    SelectionControls.restoreWanted(&entry.textLayout);
    const id = entry.data().id;
    // The owner changed the buffer between frames (a console clearing its box after Send). Before
    // the keyboard's own edits below, which are not the app's.
    var ime_stale = false;
    if (dvui.focusedWidgetId() == id) if (dvui.dataGet(null, id, "_ime_seen", ImeSeen)) |seen| {
        ime_stale = !std.meta.eql(seen, ImeSeen.of(entry));
    };
    // Unfocused fields leave edits queued so only the intended focused field consumes them.
    if (dvui.focusedWidgetId() == entry.data().id) {
        for (field_edit.take()) |edit| {
            const range = switch (edit) {
                .replace => |r| r.range,
                .select => |r| r,
            };
            var start = @min(@min(range.start, range.end), entry.len);
            var end = @min(@max(range.start, range.end), entry.len);
            while (start > 0 and start < entry.len and
                std.unicode.utf8ByteSequenceLength(entry.text[start]) == error.Utf8InvalidStartByte) : (start -= 1)
            {}
            while (end < entry.len and
                std.unicode.utf8ByteSequenceLength(entry.text[end]) == error.Utf8InvalidStartByte) : (end += 1)
            {}
            entry.textLayout.selection.start = start;
            entry.textLayout.selection.end = end;
            entry.textLayout.selection.cursor = end;
            switch (edit) {
                .replace => |r| entry.textTyped(r.text, false),
                .select => {
                    entry.textLayout.scroll_to_cursor = true;
                    dvui.refresh(null, @src(), entry.data().id);
                },
            }
        }
    }
    var self: TextEntry = .{
        .entry = entry,
        .hold = dvui.dataGetPtrDefault(null, id, "_hold", TouchHold, .{}),
        .style = style,
        .ime_after = null,
        .ime_stale = ime_stale,
    };
    self.keepFocusOnTouchdown();
    // dvui turns the menu and handles on when a touch-editing finger lifts.
    const touch_editing = entry.textLayout.state.touch_editing;
    const sel_before = selectionOf(entry);
    entry.processEvents();
    const touched = self.processTouch(unhandled, touch_editing);
    // A tap's caret lands in `draw`, where the layout applies it.
    entry.draw();
    if (!std.meta.eql(sel_before, selectionOf(entry)) and (touched or self.mouseOnField())) self.ime_stale = true;
    const menu_sel = selectionOf(entry);
    const menu_len = entry.len;
    // A hold selects with the finger still down; the menu waits for its release.
    SelectionControls.menu(.{ .entry = entry }, entry.textLayout.state.te_show_context_menu and !self.hold.armed, style);
    if (entry.len != menu_len or !std.meta.eql(menu_sel, selectionOf(entry))) self.ime_stale = true;
    // Only the focused field is compared in `deinit`; skip hashing the others.
    if (dvui.focusedWidgetId() == id) self.ime_after = .of(entry);
    if (dvui.focusedWidgetId() == entry.data().id) {
        const sel = entry.textLayout.selection;
        const text = entry.getText();
        // Limit the borrowed window to 4 KB, with context on both sides of the caret.
        var offset: usize = if (text.len <= 4096) 0 else @min(sel.cursor -| 2048, text.len - 4096);
        while (offset > 0 and std.unicode.utf8ByteSequenceLength(text[offset]) == error.Utf8InvalidStartByte) : (offset -= 1) {}
        field_edit.publish(.{
            .text = text[offset..@min(text.len, offset + 4096)],
            .offset = offset,
            .sel = .{ .start = if (sel.cursor == sel.start) sel.end else sel.start, .end = sel.cursor },
            .hints = field_hints.current() orelse .{},
        });
    }
    return self;
}

/// Ends the field and scrolls its enclosing area to it when focus or its size changes.
pub fn deinit(self: *TextEntry) void {
    // dvui's set flag draws dvui's own menu in the next `TextEntryWidget.init`; `init` draws
    // fizzy's from the bit kept. The layout's `deinit` runs dvui's `matchEvent` again, which sets
    // the flag on a touch release, so it is cleared once more through the state, which outlives
    // the widget.
    const state = self.entry.textLayout.state;
    const id = self.entry.data().id;
    if (id == dvui.focusedWidgetId()) {
        const seen: ImeSeen = .of(self.entry);
        // Focus came this frame, or the app edited the field: between frames, with the pointer
        // or the touch menu, or after the events (`textSet`, a context menu's Paste).
        if (self.ime_stale or !std.meta.eql(@as(?ImeSeen, seen), self.ime_after) or
            dvui.dataGet(null, id, "_ime_seen", ImeSeen) == null)
        {
            platform.requestImeReset(self.entry.getText(), seen.cursor);
        }
        dvui.dataSet(null, id, "_ime_seen", seen);
    } else dvui.dataRemove(null, id, "_ime_seen");
    _ = SelectionControls.takeWanted(&self.entry.textLayout);
    widgets.textEntryDeinit(self.entry);
    state.te_show_context_menu = false;
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

/// The selection's ends and caret, to tell whether something moved them.
fn selectionOf(entry: *dvui.TextEntryWidget) [3]usize {
    const sel = entry.textLayout.selection;
    return .{ sel.start, sel.cursor, sel.end };
}

/// Whether a mouse press, release or drag of this frame went to the field or its layout.
fn mouseOnField(self: TextEntry) bool {
    const entry_id = self.entry.data().id;
    const layout_id = self.entry.textLayout.data().id;
    for (dvui.events()) |e| {
        if (e.evt != .mouse) continue;
        switch (e.evt.mouse.action) {
            .press, .release, .motion => {},
            else => continue,
        }
        if (e.target_widgetId == entry_id or e.target_widgetId == layout_id) return true;
    }
    return false;
}

/// Reads this frame's touches on the field; returns whether a tap, double tap or hold placed the
/// caret or a selection.
fn processTouch(self: TextEntry, unhandled: touch.Presses, touch_editing: bool) bool {
    var placed = false;
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
                    if (SelectionControls.isMenuWindow(.{ .entry = self.entry }, me.floating_win)) {
                        // A button of the menu, drawn after this, takes it.
                    } else if (!touch.tookPress(unhandled, i, e)) {
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
                    .tap => {
                        self.tap(me.p, focused, slop, e.num, touch_editing);
                        placed = true;
                    },
                    .double_tap => {
                        SelectableText.selectWordAt(tl, self.entry.data().id, me.p.x, me.p.y);
                        placed = true;
                    },
                }
            },
            else => {},
        }
    }
    if (SelectableText.endHold(hold, tl, self.entry.data().id)) placed = true;
    tl.state.te_first = false;
    tl.state.te_focus_on_touchdown = false;
    return placed;
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
