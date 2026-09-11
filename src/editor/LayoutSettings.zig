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
    for (editor.host.surfaces.items) |*s| {
        const sc = fuzzy.score(s.title, query, .{ .plain = true }) orelse continue;
        if (best == null or sc < best.?) best = sc;
    }
    for (editor.layout.regions.items) |r| {
        const sc = fuzzy.score(r.name, query, .{ .plain = true }) orelse continue;
        if (best == null or sc < best.?) best = sc;
    }
    return best;
}

/// Which region's picker is open, by index into the live registry. One picker at a time.
var picker_open: bool = false;
var picker_region: usize = 0;

pub fn draw(query: *const fuzzy.Query) void {
    const editor = fizzy.editor();
    const theme = dvui.themeGet();
    const arena = dvui.currentWindow().arena();

    const regions = editor.layout.regions.items;
    if (regions.len == 0) {
        dvui.labelNoFmt(@src(), "This layout declares no regions to place panels in.", .{}, .{
            .color_text = theme.color(.control, .text),
        });
        return;
    }

    // The same resolver the layout uses, so a row shows exactly what the region draws.
    var layout = Editor.Layout.init(&editor.host, &editor.layout, editor.gpa, arena);

    // A query that found this section by its own name ("layout", "region") wants the whole
    // table; one that found it through a region or panel name wants just those rows.
    const filter_rows = !query.isEmpty() and fuzzy.scoreBest(&section_keywords, query, .{ .plain = true }) == null;

    var any = false;
    for (regions, 0..) |r, i| {
        if (r.name.len == 0) continue;
        if (filter_rows and !rowMatches(r.name, layout.matching(r.keywords), query)) continue;
        any = true;
        drawRow(editor, &layout, r, i);
    }

    const stray = layout.unplaced();
    if (stray.len > 0) {
        var block = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .margin = .{ .y = 4, .h = 4 } });
        defer block.deinit();
        dvui.labelNoFmt(@src(), "Unplaced", .{}, .{ .font = dvui.Font.theme(.title), .color_text = theme.color(.err, .fill) });
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
            .color_text = theme.color(.err, .fill),
        });
        tl.addText(titles.items, .{});
        tl.deinit();
    }

    if (!any) {
        dvui.labelNoFmt(@src(), "No matching regions", .{}, .{
            .color_text = theme.color(.control, .text),
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
    const assigned = editor.layout.assignment(region.name) != null;
    const contents = layout.matching(region.keywords);

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
        // The button anchors the picker; the popup opens beside it on the next frame.
        if (dvui.button(@src(), "Choose…", .{}, .{ .gravity_y = 0.5, .gravity_x = 1.0 })) {
            picker_open = true;
            picker_region = idx;
        }
        if (picker_open and picker_region == idx) {
            const anchor = head.data().rectScale().r.toNatural().bottomLeft();
            drawPicker(editor, region, contents, anchor);
        }
    }

    const arena = dvui.currentWindow().arena();
    const line: []const u8 = if (contents.len == 0)
        (if (assigned) "Empty" else "Nothing matches")
    else blk: {
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
        .color_text = theme.color(.control, .text),
    });
    tl.addText(line, .{});
    tl.deinit();
}

/// Every surface, checked if this region shows it; a "back to defaults" item at the end.
///
/// Toggling writes the region's full list — what it shows now, plus or minus one — so the first
/// toggle on a never-assigned region turns the keyword match it was showing into an explicit
/// assignment. That is the honest reading of the click: the user has now chosen this region's
/// contents, and a plugin loaded later will no longer walk in by keyword until they choose again.
fn drawPicker(editor: *Editor, region: Editor.Region, contents: []const *Surface, anchor: dvui.Point.Natural) void {
    var popup = dvui.popup(@src(), .{ .open_flag = &picker_open, .from = anchor }, .{ .min_size_content = .{ .w = 240 } }) orelse return;
    defer popup.deinit();

    dvui.labelNoFmt(@src(), region.name, .{}, .{ .font = dvui.Font.theme(.heading), .padding = .{ .h = 4 } });

    for (editor.host.surfaces.items, 0..) |*s, i| {
        if (s.hidden) continue;
        var on = contains(contents, s.id);
        if (dvui.checkbox(@src(), &on, s.title, .{ .id_extra = i, .expand = .horizontal })) {
            const arena = dvui.currentWindow().arena();
            var ids = std.ArrayListUnmanaged([]const u8).initCapacity(arena, contents.len + 1) catch return;
            for (contents) |c| if (!std.mem.eql(u8, c.id, s.id)) ids.appendAssumeCapacity(c.id);
            if (on) ids.appendAssumeCapacity(s.id);
            editor.assignRegion(region.name, ids.items) catch |err| {
                dvui.log.err("failed to assign '{s}': {t}", .{ region.name, err });
            };
            dvui.refresh(null, @src(), null);
        }
    }

    if (editor.layout.assignment(region.name) != null) {
        _ = dvui.separator(@src(), .{ .expand = .horizontal, .margin = .{ .y = 4, .h = 4 } });
        if (dvui.button(@src(), "Back to defaults", .{}, .{ .expand = .horizontal })) {
            editor.assignRegion(region.name, null) catch |err| {
                dvui.log.err("failed to reset '{s}': {t}", .{ region.name, err });
            };
            picker_open = false;
            dvui.refresh(null, @src(), null);
        }
    }
}

fn contains(list: []const *Surface, id: []const u8) bool {
    for (list) |s| if (std.mem.eql(u8, s.id, id)) return true;
    return false;
}
