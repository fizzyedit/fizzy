//! What each region shows, and the control that changes it.
//!
//! **This is the half of keyword matching that makes the other half safe.** A plugin declares the
//! *kind* of place its surface belongs — `{"sidebar", "explorer"}` — and an app's regions declare
//! what they accept; a surface draws where the two intersect. That is a good default and a
//! guess, and a guess needs a way to be wrong without being fatal. Here the fix costs two
//! clicks, and the plugin's keywords become advice.
//!
//! The table is by *region*, not by surface, because the user's question is "what goes here" —
//! they are looking at a place in the window, not at a plugin's manifest. Answering per region
//! also says two things a per-surface control never could: the same surface in two places, and
//! a region left empty on purpose.
//!
//! A surface that appears nowhere is listed too, under **Unplaced**. That is the failure mode
//! free-form strings would otherwise have: a typo, or an app whose regions this plugin has never
//! heard of, and the panel simply never appears with nothing to say why.
const std = @import("std");
const dvui = @import("dvui");
const fizzy = @import("../fizzy.zig");
const core = @import("core");
const fuzzy = core.fuzzy;

const Editor = @import("Editor.zig");
const Surface = fizzy.sdk.Surface;

/// Search terms for the row when the settings search is asking whether this section matches.
const section_keywords = [_][]const u8{ "layout", "placement", "region", "regions", "panel", "sidebar", "move", "surface", "unplaced" };

pub fn score(query: *const fuzzy.Query) ?f64 {
    if (query.isEmpty()) return 0;
    const editor = fizzy.editor();
    var best: ?f64 = fuzzy.scoreBest(&section_keywords, query, .{ .plain = true });
    // Every surface's and region's name is searchable: looking for "sprites" should find the
    // row that holds pixi's sprite panel, not just a section called Layout.
    for (editor.app.host.surfaces.items) |*s| {
        const sc = fuzzy.score(s.title, query, .{ .plain = true }) orelse continue;
        if (best == null or sc < best.?) best = sc;
    }
    for (editor.app.layout.regions.items) |r| {
        if (r.kind_slot) continue; // not listed, so not searchable — see `draw`
        const sc = fuzzy.score(r.name, query, .{ .plain = true }) orelse continue;
        if (best == null or sc < best.?) best = sc;
    }
    return best;
}

pub fn draw(query: *const fuzzy.Query) void {
    const editor = fizzy.editor();
    const theme = dvui.themeGet();
    const arena = dvui.currentWindow().arena();

    const regions = editor.app.layout.regions.items;
    if (regions.len == 0) {
        dvui.labelNoFmt(@src(), "This layout declares no regions to place panels in.", .{}, .{
            .color_text = .{ .color = theme.color(.control, .text) },
        });
        return;
    }

    // The same resolver the layout uses, so a row shows exactly what the region draws.
    var layout = Editor.Layout.init(&editor.app.host, &editor.app.layout, editor.app.gpa, arena);

    // A query that found this section by its own name ("layout", "region") wants the whole
    // table; one that found it through a region or panel name wants just those rows.
    const filter_rows = !query.isEmpty() and fuzzy.scoreBest(&section_keywords, query, .{ .plain = true }) == null;

    var any = false;
    for (regions, 0..) |r, i| {
        if (r.name.len == 0) continue;
        // A plugin's own slot ("Pane 0", one per workbench document group) is not the app's
        // furniture: what it holds is the plugin's to manage — tabs, drags, open and close —
        // and it appears and disappears with the panes themselves. Offering it a row here put a
        // name the user never chose beside Sidebar/Main/Panel, with a picker whose list is
        // whatever documents happen to be open. Those regions are still reachable where they
        // make sense: the pane's own corner button, and dropping a view onto it.
        if (r.kind_slot) continue;
        if (filter_rows and !rowMatches(r.name, layout.matchingIn(&r), query)) continue;
        any = true;
        drawRow(editor, &layout, r, i);
    }

    const stray = layout.unplaced();
    if (stray.len > 0) {
        var block = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .margin = .{ .y = 4, .h = 4 } });
        defer block.deinit();
        dvui.labelNoFmt(@src(), "Unplaced", .{}, .{ .font = dvui.Font.theme(.title), .color_text = .{ .color = theme.color(.err, .fill) } });
        var titles = std.ArrayListUnmanaged(u8).empty;
        for (stray, 0..) |s, i| {
            if (i > 0) titles.appendSlice(arena, ", ") catch break;
            titles.appendSlice(arena, s.title) catch break;
        }
        var tl = dvui.textLayout(@src(), .{ .break_lines = true }, .{
            .expand = .horizontal,
            .margin = .{ .x = 12 },
            .padding = .{},
            .background = false,
            .color_text = .{ .color = theme.color(.err, .fill) },
        });
        tl.addText(titles.items, .{});
        tl.deinit();
    }

    if (!any) {
        dvui.labelNoFmt(@src(), "No matching regions", .{}, .{
            .color_text = .{ .color = theme.color(.control, .text) },
        });
    }
}

fn rowMatches(name: []const u8, contents: []const *Surface, query: *const fuzzy.Query) bool {
    if (fuzzy.score(name, query, .{ .plain = true }) != null) return true;
    for (contents) |s| if (fuzzy.score(s.title, query, .{ .plain = true }) != null) return true;
    return false;
}

/// One region: its name and the picker button on one line, what it shows wrapped beneath.
/// Two lines rather than one because this draws in the sidebar, whose width is the user's; a
/// row of tiles either truncates or pushes the button out of sight.
fn drawRow(editor: *Editor, layout: *Editor.Layout, region: Editor.Region, idx: usize) void {
    const theme = dvui.themeGet();
    const assigned = editor.app.layout.assignment(region.name) != null;
    const contents = layout.matchingIn(&region);

    var block = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = idx,
        .expand = .horizontal,
        .margin = .{ .y = 4, .h = 4 },
    });
    defer block.deinit();

    {
        var head = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer head.deinit();
        dvui.labelNoFmt(@src(), region.name, .{}, .{ .gravity_y = 0.5, .font = dvui.Font.theme(.title) });
        // The picker itself is framework (`app/layout/Picker.zig`), drawn by the frame above
        // everything; this only opens it, anchored under this row.
        if (dvui.button(@src(), "Settings…", .{}, .{ .gravity_y = 0.5, .gravity_x = 1.0 })) {
            editor.app.layout.openPicker(editor.app.gpa, region.name, head.data().rectScale().r.toNatural().bottomLeft());
        }
    }

    const arena = dvui.currentWindow().arena();
    const line: []const u8 = if (contents.len == 0)
        (if (assigned) "Empty" else "Nothing matches")
    else if (region.shows == .one) blk: {
        // A region that draws one surface must not read as holding all of them. Listing every
        // keyword match here is what made the main area look like it held three panels when it
        // was showing one and hiding two.
        const sel = layout.selected(region.keywords) orelse break :blk contents[0].title;
        if (contents.len == 1) break :blk sel.title;
        break :blk std.fmt.allocPrint(arena, "{s} — 1 of {d} that fit here", .{ sel.title, contents.len }) catch sel.title;
    } else blk: {
        var titles = std.ArrayListUnmanaged(u8).empty;
        for (contents, 0..) |s, i| {
            if (i > 0) titles.appendSlice(arena, ", ") catch break;
            titles.appendSlice(arena, s.title) catch break;
        }
        break :blk titles.items;
    };
    var tl = dvui.textLayout(@src(), .{ .break_lines = true }, .{
        .expand = .horizontal,
        .margin = .{ .x = 12 },
        .padding = .{},
        .background = false,
        .color_text = .{ .color = theme.color(.control, .text) },
    });
    tl.addText(line, .{});
    tl.deinit();
}
