//! One setting's chrome, drawn identically for the shell's own settings and every plugin's.
//!
//! A setting reads as a small self-contained group, VSCode-style:
//!
//!     Insert spaces on tab          ← name (`header`), sentence case, bold
//!     insert_spaces_on_tab          ← the key it has in settings.zon, dim and smaller
//!     Insert spaces instead of a…   ← description (`description`), wrapped
//!     [▁▁▁▁▁ control ▁▁▁▁▁]         ← the control, full width
//!
//! Booleans are the one exception: their checkbox sits *before* the description on one line
//! (`beginInlineControl`), because a full-width control for two states is all frame and no
//! information.
//!
//! Name and key are both search-highlighted — the settings search matches either, so a row that
//! survived on a key match has to be able to show why.
//!
//! `SettingsTree` owns *which* rows appear and in what order; this file owns what one row looks
//! like. Control bodies live in `PluginSettingsPane` (plugin settings) and
//! `explorer/settings.zig` (the shell's own).
const std = @import("std");
const dvui = @import("dvui");
const core = @import("core");

const fuzzy = core.fuzzy;
const wdvui = core.dvui;

/// Horizontal inset shared by every line in a row, so name/key/description/control all start on
/// the same left edge.
const inset: f32 = 3;

/// Name + key. Call once per setting, before the description and control.
pub fn header(name: []const u8, key: []const u8, query: *const fuzzy.Query) void {
    {
        var tl = dvui.textLayout(@src(), .{ .break_lines = false }, .{
            .background = false,
            .expand = .horizontal,
            .margin = dvui.Rect.all(0),
            .padding = .{ .x = inset, .w = inset, .h = 1 },
            .font = dvui.Font.theme(.body).withWeight(.bold),
        });
        wdvui.addHighlightedText(tl, name, query, true, dvui.themeGet().color(.control, .text));
        tl.deinit();
    }

    // The key is what the user types in settings.zon, so it gets the mono face — and enough
    // dimming that the pane reads as a list of names, not a list of identifiers.
    var tl = dvui.textLayout(@src(), .{ .break_lines = false }, .{
        .background = false,
        .expand = .horizontal,
        .margin = dvui.Rect.all(0),
        .padding = .{ .x = inset, .w = inset, .h = 2 },
        .font = dvui.Font.theme(.mono),
    });
    wdvui.addHighlightedText(tl, key, query, true, mutedText(0.55));
    tl.deinit();
}

/// The wrapped description, drawn above the control (VSCode's order).
///
/// No `gravity_y`: inside the row's vertical box a non-zero vertical gravity is measured against
/// the *whole* box's spare height, which slides the description up over the key line.
pub fn description(text: []const u8) void {
    drawDescription(text, .{
        .padding = .{ .x = inset, .w = inset, .h = 3 },
    });
}

/// The same description on a checkbox's line — vertically centred against the checkbox, and
/// inset far enough to clear it.
pub fn descriptionInline(text: []const u8) void {
    drawDescription(text, .{
        .gravity_y = 0.5,
        .padding = .{ .w = inset, .h = 1 },
    });
}

fn drawDescription(text: []const u8, over: dvui.Options) void {
    const defaults: dvui.Options = .{
        .background = false,
        .expand = .horizontal,
        .margin = dvui.Rect.all(0),
        .font = dvui.Font.theme(.body),
    };
    var tl = dvui.textLayout(@src(), .{ .break_lines = true }, defaults.override(over));
    tl.addText(text, .{ .color_text = mutedText(0.8) });
    tl.deinit();
}

/// Row for a control that shares its line with the description — the checkbox goes in first, the
/// description wraps in whatever width is left. Caller deinits.
pub fn beginInlineControl() *dvui.BoxWidget {
    return dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .background = false,
        .margin = .{ .x = inset - 1, .y = 1, .h = 2 },
        .padding = dvui.Rect.all(0),
    });
}

fn mutedText(alpha: f32) dvui.Color {
    return dvui.themeGet().color(.control, .text).opacity(alpha);
}
