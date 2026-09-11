//! Where each plugin's panels draw, and the control that moves one somewhere else.
//!
//! **This is the half of keyword matching that makes the other half safe.** A plugin declares the
//! *kind* of place its surface belongs — `{"sidebar", "explorer"}` — and an app's regions declare
//! what they accept; a surface draws where the two intersect. That is a good default and a
//! guess, and a guess needs a way to be wrong without being fatal. Here it costs two clicks: pick
//! a region, and the surface moves on the next frame and stays there across restarts.
//!
//! Without this the design would be worse than the enum it replaced — a wrong placement would
//! need a plugin release to fix. With it, the plugin's keywords are advice.
//!
//! A surface that matches nothing is listed too, under **Unplaced**. That is the failure mode
//! free-form strings would otherwise have: a typo, or an app whose regions this plugin has never
//! heard of, and the panel simply never appears with nothing to say why.
const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const fizzy = @import("../fizzy.zig");
const core = @import("core");
const fuzzy = core.fuzzy;

const Editor = @import("Editor.zig");

/// Search terms for the row when the settings search is asking whether this section matches.
const section_keywords = [_][]const u8{ "layout", "placement", "region", "panel", "sidebar", "move", "surface", "unplaced" };

pub fn score(query: *const fuzzy.Query) ?f64 {
    if (query.isEmpty()) return 0;
    const editor = fizzy.editor();
    var best: ?f64 = fuzzy.scoreBest(&section_keywords, query, .{ .plain = true });
    // Every surface's title is searchable: looking for "sprites" should find the row that moves
    // pixi's sprite panel, not just a section called Layout.
    for (editor.host.surfaces.items) |*s| {
        const sc = fuzzy.score(s.title, query, .{ .plain = true }) orelse continue;
        if (best == null or sc < best.?) best = sc;
    }
    return best;
}

pub fn draw(query: *const fuzzy.Query) void {
    const editor = fizzy.editor();
    const theme = dvui.themeGet();

    const regions = editor.layout.regions.items;
    if (regions.len == 0) {
        dvui.labelNoFmt(@src(), "This layout declares no regions to place panels in.", .{}, .{
            .color_text = theme.color(.control, .text),
        });
        return;
    }

    var any = false;
    for (editor.host.surfaces.items, 0..) |*surface, i| {
        if (!query.isEmpty() and fuzzy.score(surface.title, query, .{ .plain = true }) == null) continue;
        any = true;
        drawRow(editor, surface, regions, i);
    }

    if (!any) {
        dvui.labelNoFmt(@src(), "No matching panels", .{}, .{
            .color_text = theme.color(.control, .text),
        });
    }
}

/// One surface: what it is, where it draws, and a picker to move it.
fn drawRow(
    editor: *Editor,
    surface: *fizzy.sdk.Surface,
    regions: []const Editor.Region,
    id_extra: usize,
) void {
    const theme = dvui.themeGet();

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = id_extra,
        .expand = .horizontal,
        .margin = .{ .y = 2, .h = 2 },
    });
    defer row.deinit();

    dvui.labelNoFmt(@src(), surface.title, .{}, .{
        .id_extra = id_extra,
        .gravity_y = 0.5,
        .min_size_content = .{ .w = 140 },
    });

    // Which region currently shows it — resolved the same way the layout resolves it, through the
    // *effective* keywords, so a row reflects an override the moment it is made.
    const effective = editor.layout.keyword_overrides.get(surface.id) orelse surface.keywords;
    var current: usize = regions.len; // == len means "unplaced"
    for (regions, 0..) |r, ri| {
        if (fizzy.sdk.keywords.intersects(effective, r.keywords)) {
            current = ri;
            break;
        }
    }

    // The picker: every region this app declared, plus the honest "nowhere" entry at the end.
    const arena = dvui.currentWindow().arena();
    var names = arena.alloc([]const u8, regions.len + 1) catch return;
    for (regions, 0..) |r, ri| names[ri] = if (r.name.len > 0) r.name else "(unnamed region)";
    names[regions.len] = "Unplaced";

    var choice: usize = current;
    if (dvui.dropdown(@src(), names, .{ .choice = &choice }, .{}, .{
        .id_extra = id_extra,
        .gravity_y = 0.5,
        .min_size_content = .{ .w = 160 },
        .color_text = if (current == regions.len) theme.color(.err, .fill) else theme.color(.control, .text),
    })) {
        if (choice != current) {
            // "Unplaced" is a real choice, not an error state: an empty keyword set matches no
            // region, which is how a user switches a panel off without disabling its plugin.
            const keywords: []const []const u8 = if (choice == regions.len) &.{} else regions[choice].keywords;
            // Fizzy's own surfaces have no owning plugin, so their override is recorded under a
            // block named for the application rather than for a plugin that does not exist.
            const block_id = if (surface.owner) |p| p.id else fizzy_block_id;
            editor.setSurfaceKeywords(block_id, surface.id, keywords) catch |err| {
                dvui.log.err("failed to move '{s}': {t}", .{ surface.id, err });
            };
            dvui.refresh(null, @src(), null);
        }
    }
}

/// The `.plugins.<id>` block fizzy's own surfaces record their placement in. Not a plugin id — no
/// plugin may use it — and deliberately the app's short name so a settings file reads as owning
/// its own choices.
const fizzy_block_id = "fizzy";
