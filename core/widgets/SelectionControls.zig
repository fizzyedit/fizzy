//! The menu over a touch selection: one row of text buttons (Cut, Copy, Paste, Select all) above
//! the selected text, or below it where there is no room above, drawn from dvui's own selection
//! state (`selection`, `state.touch_editing`, `state.sel_start_r` / `sel_end_r`) and the bit
//! `takeWanted` keeps of dvui's wish to show its menu.
//!
//! It is fizzy's because dvui draws its own inside `dvui.textLayout`
//! (`TextLayoutWidget.touchEditingMenu`) and `TextEntryWidget.init`, before a caller can reach
//! it: 20-point icons with no labels at the layout's corner, a field's Paste even where the
//! clipboard cannot be read. Here the buttons say what they do and are tall enough for a finger,
//! the selection itself stays dvui's.
const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const clipboard = @import("clipboard.zig");

/// How the menu looks and reports. Sizes are in points.
pub const Style = struct {
    /// The height of each button, and so of the row inside its 1-point border.
    button_h: f32 = 44,
    /// The space between the menu and the line of the selection it sits above or below.
    gap: f32 = 6,
    /// The menu's fill. Null is the theme's `.window` fill.
    fill: ?dvui.Color = null,
    /// The buttons' label colour. Null is the theme's `.window` text.
    text: ?dvui.Color = null,
    /// The buttons' label font. Null is the theme's body font.
    font: ?dvui.Font = null,
    /// Called after a button has done its action, in the frame of the tap.
    on_action: ?*const fn (Action) void = null,
};

/// What a button of the menu does.
pub const Action = enum { select_all, copy, cut, paste };

/// What the menu acts on.
pub const Target = union(enum) {
    /// Read-only text: Copy and Select all.
    layout: *dvui.TextLayoutWidget,
    /// A text field: Cut, Copy, Paste and Select all. Its layout is `entry.textLayout`.
    entry: *dvui.TextEntryWidget,

    fn textLayout(target: Target) *dvui.TextLayoutWidget {
        return switch (target) {
            .layout => |tl| tl,
            .entry => |entry| &entry.textLayout,
        };
    }

    /// The widget that holds focus while the text is edited: the field, not its layout.
    fn focusId(target: Target) dvui.Id {
        return switch (target) {
            .layout => |tl| tl.data().id,
            .entry => |entry| entry.data().id,
        };
    }
};

/// The order buttons take in the row, when shown.
const order = [_]Action{ .cut, .copy, .paste, .select_all };

/// The last menu `menu` drew, in natural pixels, and how many buttons it had. Tests only.
pub var test_last_menu: ?struct { rect: dvui.Rect, labels: u8 } = null;

/// Takes dvui's wish to show its touch menu over `tl` and keeps it as fizzy's: stores
/// `tl.state.te_show_context_menu` under the layout as `_menu`, clears dvui's flag, and returns
/// the stored bit. Call it before `tl.deinit()`.
pub fn takeWanted(tl: *dvui.TextLayoutWidget) bool {
    const wanted = tl.state.te_show_context_menu;
    dvui.dataSet(null, tl.data().id, "_menu", wanted);
    // dvui's next `textLayout` draws its own menu when this is set, before it returns to a caller.
    tl.state.te_show_context_menu = false;
    return wanted;
}

/// Puts the bit `takeWanted` stored back into dvui's flag, so the touch events of the frame
/// (a press hides the menu, a release shows it) act on it in order. Call it after `dvui.textLayout`.
pub fn restoreWanted(tl: *dvui.TextLayoutWidget) void {
    if (dvui.dataGet(null, tl.data().id, "_menu", bool) orelse false) tl.state.te_show_context_menu = true;
}

/// Whether `win`, a press's `floating_win`, is the window of the menu drawn for `target`.
pub fn isMenuWindow(target: Target, win: dvui.Id) bool {
    return dvui.dataGet(null, target.textLayout().data().id, "_menu_win", dvui.Id) == win;
}

/// Draws the menu for `target` when `wanted`, the text is touch editing, focused and visible.
/// Draw a `.layout`'s before the text is added: dvui applies its `copy` while adding text. Draw
/// an `.entry`'s after `entry.draw()`, where the selection's rects are this frame's.
pub fn menu(target: Target, wanted: bool, style: Style) void {
    const tl = target.textLayout();
    if (!wanted or !tl.state.touch_editing or dvui.focusedWidgetId() != target.focusId() or !tl.data().visible()) return;

    var actions: [order.len]Action = undefined;
    var n: usize = 0;
    for (order) |action| if (shown(target, action)) {
        actions[n] = action;
        n += 1;
    };
    if (n == 0) return;

    // The row's size from the last frame it was drawn; the first frame lays it out at none.
    const id = tl.data().id;
    const size = if (dvui.dataGet(null, id, "_menu_win", dvui.Id)) |win| dvui.minSizeGet(win) orelse dvui.Size{} else dvui.Size{};
    var fw: dvui.FloatingWidget = undefined;
    fw.init(@src(), .{}, .{ .rect = place(tl, size, style.gap) });
    defer fw.deinit();
    dvui.dataSet(null, id, "_menu_win", fw.data().id);

    const fill: ?dvui.ColorOrGradient = if (style.fill) |c| .{ .color = c } else null;
    const text: ?dvui.ColorOrGradient = if (style.text) |c| .{ .color = c } else null;
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .style = .window,
        .background = true,
        .color_fill = fill,
        .border = .all(1),
        .corners = .default,
    });
    defer row.deinit();
    for (actions[0..n], 0..) |action, i| {
        if (dvui.button(@src(), label(action), .{ .draw_focus = false }, .{
            .id_extra = i,
            .style = .window,
            .color_fill = fill,
            .color_text = text,
            .font = style.font,
            .corners = .default,
            .margin = .{},
            .padding = .{ .x = 12, .w = 12 },
            .min_size_content = .{ .h = style.button_h },
        })) {
            apply(target, action);
            if (style.on_action) |on_action| on_action(action);
        }
    }
    if (builtin.is_test) test_last_menu = .{ .rect = fw.data().rect, .labels = @intCast(n) };
}

fn shown(target: Target, action: Action) bool {
    return switch (target) {
        .layout => |tl| switch (action) {
            .copy => tl.selection.start != tl.selection.end,
            .select_all => true,
            .cut, .paste => false,
        },
        .entry => |entry| switch (action) {
            .cut, .copy => !entry.textLayout.selection.empty(),
            .paste => clipboard.canPaste(),
            .select_all => true,
        },
    };
}

fn apply(target: Target, action: Action) void {
    switch (target) {
        .layout => |tl| switch (action) {
            .copy => {
                tl.copy();
                // The text is on the clipboard; the selection stays for the next thing done with it.
                tl.state.te_show_context_menu = false;
                dvui.dataSet(null, tl.data().id, "_menu", false);
            },
            .select_all => tl.selection.selectAll(),
            .cut, .paste => {},
        },
        .entry => |entry| {
            switch (action) {
                .cut => entry.cut(),
                .copy => entry.copy(),
                .paste => entry.paste(),
                .select_all => return entry.textLayout.selection.selectAll(),
            }
            // The edit is done; the selection, or the caret a cut or paste leaves, stays.
            entry.textLayout.state.te_show_context_menu = false;
            dvui.dataSet(null, entry.textLayout.data().id, "_menu", false);
        },
    }
}

fn label(action: Action) []const u8 {
    return switch (action) {
        .select_all => "Select all",
        .copy => "Copy",
        .cut => "Cut",
        .paste => "Paste",
    };
}

/// A `size` rect centred over the selection, `gap` above its first line, or `gap` below its
/// last where above leaves the window, kept inside the window. Natural pixels.
fn place(tl: *dvui.TextLayoutWidget, size: dvui.Size, gap: f32) dvui.Rect {
    const wrs = dvui.windowRectScale();
    const start = wrs.rectFromPhysical(tl.screenRectScale(tl.state.sel_start_r).r);
    const end = wrs.rectFromPhysical(tl.screenRectScale(tl.state.sel_end_r).r);
    const win: dvui.Rect = .cast(dvui.windowRect());
    var r: dvui.Rect = .{ .x = (start.x + end.x - size.w) / 2, .y = start.y - gap - size.h, .w = size.w, .h = size.h };
    if (r.y < win.y) r.y = end.y + end.h + gap;
    r.x = @max(win.x, @min(r.x, win.x + win.w - r.w));
    r.y = @max(win.y, @min(r.y, win.y + win.h - r.h));
    return r;
}
