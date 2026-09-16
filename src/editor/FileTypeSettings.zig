//! File Types settings pane — searchable via the settings tree, modeled on `KeybindSettings`.
//!
//! One flat table of "extension → which plugin opens it". Unlike keybinds this data is naturally
//! extension-keyed rather than owner-keyed, so there is one grid with no per-owner tree branches.
//! The grid chrome — fill, banding, sortable headers, column rigidity, compact cell controls —
//! matches `KeybindSettings` so the two panes read as one table style.
//!
//! **This is the permanent home of a decision the install-time dialog only asks about once.**
//! Ownership is an explicit, persisted user choice (`.plugins.<id>.extensions` in `settings.zon`),
//! and every route to changing it — this pane's dropdown and `Dialogs.FileTypeDefaults`' Confirm — goes through the
//! single writer, `Editor.resolveExtensionConflict`.
//!
//! **Conflicts are surfaced, not silently resolved.** `Editor.rebuildExtensionOwnerCache` is
//! deliberately read-only (it must not race the live `settings.zon` watcher), so a hand-edited
//! file naming two owners for one extension, or naming an extension a plugin no longer offers,
//! is *interpreted* deterministically and reported here — banner plus flagged rows, exactly as
//! `KeybindSettings` reports `Keymap.conflicts()`. Picking any owner in a flagged row is what
//! actually repairs the file, because that is the only path allowed to write.
//!
//! **The grid never reports a width to the explorer** — `max_size_content = .width(0)`, for the
//! width-ratchet reason spelled out at length in `KeybindSettings`' header comment.
const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const core = @import("core");
const fizzy = @import("../fizzy.zig");

const fuzzy = core.fuzzy;

/// Shown in place of a plugin name for the fallback editor, which owns everything nothing else
/// does. Its claim set is unbounded, so it is never a "claimant" — only ever this option.
const fallback_label = "Text (fallback)";

/// Terms that name the *table itself* rather than any one extension, so searching "file types"
/// finds the whole list. Scored one term at a time, for the reason `KeybindSettings` explains.
const table_keywords = [_][]const u8{
    "file",         "files",   "filetype", "filetypes", "file type",
    "extension",    "default", "defaults", "opens",     "associate",
    "associations",
};

/// One extension's row, built fresh each pass from the live plugin set — never cached across
/// frames, since a plugin can unload between them and every string here would then point into an
/// unmapped dylib image. All slices are arena- or plugin-owned and valid for this frame only.
const Row = struct {
    ext: []const u8,
    /// The plugin that opens `ext` today, or null if nothing does.
    owner: ?*fizzy.sdk.Plugin,
    /// Display name for `owner`, already resolved to `fallback_label` where appropriate.
    owner_name: []const u8,
    /// Plugins that offer `ext` via `fileTypes`, alphabetical by id. The fallback editor is not
    /// in here — it is appended as a separate dropdown choice.
    candidates: []const *fizzy.sdk.Plugin,
    /// A persisted entry for this extension could not be honored — see `Editor.ExtensionConflict`.
    flagged: bool,
    score: f64,
    tie: usize,
};

fn lowerRow(_: void, a: Row, b: Row) bool {
    if (a.score != b.score) return a.score < b.score;
    return a.tie < b.tie;
}

/// Every extension worth showing a row for: what loaded plugins offer, plus anything the user has
/// already made a decision about (so an extension assigned to the fallback editor, which offers
/// nothing, still has a row), plus anything named by a conflict (so a flagged row is reachable —
/// that row's dropdown is the only way to repair the file).
fn collectRows(arena: std.mem.Allocator, query: *const fuzzy.Query) std.ArrayListUnmanaged(Row) {
    var rows: std.ArrayListUnmanaged(Row) = .empty;
    if (comptime builtin.target.cpu.arch == .wasm32) return rows;

    const editor = fizzy.editor();
    const table_hit = fuzzy.scoreBest(&table_keywords, query, .{ .plain = true });

    var exts: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (editor.app.host.plugins.items) |plugin| {
        for (plugin.fileTypes()) |e| exts.put(arena, e, {}) catch return rows;
    }
    for (editor.app.extension_owner.keys()) |e| exts.put(arena, e, {}) catch return rows;
    for (editor.app.extension_conflicts.items) |c| exts.put(arena, c.ext, {}) catch return rows;

    const keys = arena.dupe([]const u8, exts.keys()) catch return rows;
    std.mem.sort([]const u8, keys, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    for (keys, 0..) |ext, i| {
        const owner = editor.app.host.pluginForExtension(ext);
        const owner_name = if (owner) |o|
            (if (o == editor.app.host.fallback_editor) fallback_label else o.display_name)
        else
            "—";

        var candidates: std.ArrayListUnmanaged(*fizzy.sdk.Plugin) = .empty;
        for (editor.app.host.plugins.items) |plugin| {
            if (plugin == editor.app.host.fallback_editor) continue;
            for (plugin.fileTypes()) |e| {
                if (std.mem.eql(u8, e, ext)) {
                    candidates.append(arena, plugin) catch {};
                    break;
                }
            }
        }
        std.mem.sort(*fizzy.sdk.Plugin, candidates.items, {}, struct {
            fn lt(_: void, a: *fizzy.sdk.Plugin, b: *fizzy.sdk.Plugin) bool {
                return std.mem.lessThan(u8, a.id, b.id);
            }
        }.lt);

        var flagged = false;
        for (editor.app.extension_conflicts.items) |c| {
            if (std.mem.eql(u8, c.ext, ext)) {
                flagged = true;
                break;
            }
        }

        // A row matches on its extension or on its current owner's name, and the whole table
        // matches when the query names the table itself.
        const row_hit = fuzzy.scoreBest(&.{ ext, owner_name }, query, .{ .plain = true });
        const best = blk: {
            if (query.isEmpty()) break :blk @as(f64, 0);
            if (row_hit) |r| {
                if (table_hit) |t| break :blk @min(r, t);
                break :blk r;
            }
            break :blk table_hit orelse continue;
        };

        rows.append(arena, .{
            .ext = ext,
            .owner = owner,
            .owner_name = owner_name,
            .candidates = candidates.items,
            .flagged = flagged,
            .score = best,
            .tie = i,
        }) catch return rows;
    }

    std.mem.sort(Row, rows.items, {}, lowerRow);
    return rows;
}

/// Settings-tree search hook: the best score among the rows this pane would draw, or null when
/// nothing matches (the whole "File Types" row then disappears from the tree).
pub fn score(query: *const fuzzy.Query) ?f64 {
    if (comptime builtin.target.cpu.arch == .wasm32) {
        return fuzzy.scoreBest(&table_keywords, query, .{ .plain = true });
    }
    if (query.isEmpty()) return 0;
    const rows = collectRows(dvui.currentWindow().arena(), query);
    var best: ?f64 = null;
    for (rows.items) |r| {
        if (best == null or r.score < best.?) best = r.score;
    }
    return best;
}

pub fn draw(query: *const fuzzy.Query) void {
    if (comptime builtin.target.cpu.arch == .wasm32) {
        dvui.label(@src(), "Plugins are not installable on the web build, so there is nothing to assign.", .{}, .{
            .color_text = .{ .color = dvui.themeGet().color(.window, .text).opacity(0.6) },
        });
        return;
    }

    const theme = dvui.themeGet();
    const arena = dvui.currentWindow().arena();

    drawConflicts(theme);

    const rows = collectRows(arena, query);
    if (rows.items.len == 0) return;

    drawGrid(rows.items, query, theme);
}

fn drawConflicts(theme: dvui.Theme) void {
    const conflicts = fizzy.editor().app.extension_conflicts.items;
    if (conflicts.len == 0) return;

    var box = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = .{ .color = theme.color(.err, .fill).opacity(0.25) },
        .corners = .all(6),
        .padding = dvui.Rect.all(6),
        .margin = .{ .h = 8 },
    });
    defer box.deinit();

    dvui.label(@src(), "Conflicts", .{}, .{
        .font = dvui.Font.theme(.heading),
        .expand = .horizontal,
    });
    // Said explicitly because the file is *not* being rewritten: fizzy interprets it and moves on,
    // so the user needs to know the fix is theirs to trigger. `textLayout`, not `label`, because
    // this sentence is longer than the settings pane is wide and a label would ellipsize it.
    {
        var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .background = false });
        defer tl.deinit();
        tl.addText(
            "settings.zon was edited by hand. Fizzy left the file alone — pick an owner below to repair it.",
            .{ .color_text = .{ .color = theme.color(.window, .text).opacity(0.7) } },
        );
    }
    for (conflicts, 0..) |c, i| {
        switch (c.kind) {
            .duplicate => dvui.label(@src(), "{s}: {s} and {s} both claim it — {s} wins.", .{
                c.ext, c.winner orelse "?", c.loser, c.winner orelse "?",
            }, .{
                .id_extra = i,
                .expand = .horizontal,
                .color_text = .{ .color = theme.color(.window, .text).opacity(0.85) },
            }),
            .stale => dvui.label(@src(), "{s}: assigned to {s}, which no longer opens it — ignored.", .{
                c.ext, c.loser,
            }, .{
                .id_extra = i,
                .expand = .horizontal,
                .color_text = .{ .color = theme.color(.window, .text).opacity(0.85) },
            }),
        }
    }
}

/// Zebra striping for the body rows, same as `KeybindSettings`' — dvui's grid dropped its own
/// banded cell style when it was reworked.
const Banded = struct {
    theme: dvui.Theme,

    fn cellOptions(self: Banded, row: usize) dvui.Options {
        return .{
            .padding = .{ .x = 6, .y = 2, .w = 4, .h = 2 },
            .background = true,
            .color_fill = if (row % 2 == 1) .{ .color = self.theme.color(.control, .fill).opacity(0.22) } else null,
        };
    }
};

fn drawGrid(rows: []Row, query: *const fuzzy.Query, theme: dvui.Theme) void {
    var grid = dvui.grid(@src(), .{
        .scroll_opts = .{
            .horizontal = .auto,
            .vertical = .none,
            .horizontal_bar = .auto_overlay,
            .vertical_bar = .hide,
        },
        // Opens in and Reopen stay at the width their contents need; Extension absorbs the
        // leftover — same division of labour as Command / Shortcut / Reset.
    }, .{
        .expand = .horizontal,
        .max_size_content = .width(0),
        .padding = .all(0),
        .background = true,
        .color_fill = .{ .color = theme.color(.window, .fill).opacity(0.25) },
        .corners = .all(4),
        .border = .{},
    });

    // Re-fit whenever the row set changes; unconditional `autoSize` leaves the grid in a
    // permanent relayout loop (see `KeybindSettings`).
    const content_key = blk: {
        var h = std.hash.Wyhash.init(0x5e17c);
        for (rows) |row| {
            h.update(row.ext);
            h.update(row.owner_name);
        }
        break :blk h.final();
    };
    const key_id = "__fizzy_content_key";
    if (dvui.dataGet(null, grid.data().id, key_id, u64) != content_key) {
        dvui.dataSet(null, grid.data().id, key_id, content_key);
        grid.autoSize(.both);
    }

    // Alphabetical by extension until the user clicks a heading. `.unsorted` is only ever the
    // grid's *initial* state — a click always leaves it ascending or descending, and that is
    // what the grid persists — so this can't stomp a sort the user picked.
    if (grid.sort_dir == .unsorted) {
        grid.sort_col = 0;
        grid.sort_dir = .ascending;
    }

    const banded: Banded = .{ .theme = theme };

    const heading_cell_opts: dvui.Options = .{
        .padding = .{ .x = 6, .y = 2, .w = 4, .h = 2 },
        .background = true,
        .color_fill = .{ .color = theme.color(.control, .fill).opacity(0.35) },
    };
    const heading_label_opts: dvui.Options = .{
        .expand = .horizontal,
        .gravity_y = 0.5,
        .background = false,
        .corners = .{},
        .font = dvui.Font.theme(.body).withWeight(.bold),
        .color_text = .{ .color = theme.color(.window, .text).opacity(0.7) },
    };

    inline for (.{ .{ 0, "Extension" }, .{ 1, "Opens in" } }) |heading| {
        const cell = grid.colHeader(.{ .col = heading[0] }, heading_cell_opts);
        defer cell.deinit();
        _ = cell.headerSortable(heading[1], heading_label_opts);
    }
    drawReopenHeading(grid, heading_cell_opts, heading_label_opts);

    if (grid.sort_dir != .unsorted) {
        const asc = grid.sort_dir == .ascending;
        std.sort.pdq(Row, rows, SortCtx{ .col = grid.sort_col, .asc = asc }, SortCtx.lessThan);
    }

    for (rows, 0..) |row, ri| drawRow(grid, row, query, ri, theme, banded);

    const grid_rs = grid.data().borderRectScale();
    const si = grid.msi.*;
    grid.deinit();
    core.draw.drawScrollEdgeShadows(null, grid_rs, &si, .{});
}

/// Last-column heading. Not sortable — there is nothing to order by — so it stays a plain label
/// rather than dvui's sortable heading button, same as `KeybindSettings.drawResetHeading`.
fn drawReopenHeading(grid: *dvui.GridWidget, cell_opts: dvui.Options, label_opts: dvui.Options) void {
    const cell = grid.colHeader(.{ .col = 2 }, cell_opts);
    defer cell.deinit();

    dvui.labelNoFmt(@src(), "Reopen", .{}, label_opts.override(.{
        .gravity_x = 0.5,
        .gravity_y = 0.5,
    }));
}

const SortCtx = struct {
    col: usize,
    asc: bool,

    fn lessThan(ctx: SortCtx, a: Row, b: Row) bool {
        const order: std.math.Order = switch (ctx.col) {
            0 => std.ascii.orderIgnoreCase(a.ext, b.ext),
            1 => std.ascii.orderIgnoreCase(a.owner_name, b.owner_name),
            else => .eq,
        };
        return if (ctx.asc) order == .lt else order == .gt;
    }
};

fn drawRow(
    grid: *dvui.GridWidget,
    row: Row,
    query: *const fuzzy.Query,
    ri: usize,
    theme: dvui.Theme,
    banded: Banded,
) void {
    {
        const cell = grid.cell(.{ .col = 0, .row = ri }, banded.cellOptions(ri));
        defer cell.deinit();

        var left = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .both,
            .gravity_y = 0.5,
            .margin = .all(0),
            .padding = .all(0),
        });
        defer left.deinit();

        if (row.flagged) {
            core.icon.icon(@src(), "file_type_conflict", dvui.entypo.warning, .{
                .stroke_color = .{ .color = theme.color(.err, .fill) },
                .fill_color = .{ .color = theme.color(.err, .fill) },
            }, .{ .gravity_y = 0.5, .min_size_content = .{ .w = 12, .h = 12 } });
            _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 4, .h = 1 } });
        }
        core.draw.labelHighlighted(@src(), row.ext, query, true, .{
            .expand = .horizontal,
            .font = dvui.Font.theme(.mono),
            .gravity_y = 0.5,
            .margin = .all(0),
            .padding = .all(0),
        });
    }

    {
        const cell = grid.cell(.{ .col = 1, .row = ri }, banded.cellOptions(ri));
        defer cell.deinit();
        drawOwnerDropdown(row, ri);
    }

    {
        const cell = grid.cell(.{ .col = 2, .row = ri }, banded.cellOptions(ri));
        defer cell.deinit();
        drawReopenAction(row, ri);
    }
}

/// The one control that changes ownership. Lists every plugin offering this extension plus the
/// fallback editor, and routes the choice through `Editor.resolveExtensionConflict` — which adds
/// the entry to the chosen plugin *and* strips it from every other block, so picking anything
/// here also repairs a flagged row.
fn drawOwnerDropdown(row: Row, ri: usize) void {
    const editor = fizzy.editor();

    var dropdown: dvui.DropdownWidget = undefined;
    dropdown.init(@src(), .{}, .{
        .id_extra = ri,
        .expand = .horizontal,
        .gravity_y = 0.5,
        // Same compact chrome as the Shortcut / Reset buttons in `KeybindSettings`.
        .margin = .{ .x = 0, .y = 1, .w = 0, .h = 1 },
        .padding = .{ .x = 4, .y = 2, .w = 4, .h = 2 },
        .corners = .default,
    });
    defer dropdown.deinit();

    {
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .both,
            .margin = .all(0),
            .padding = .all(0),
        });
        defer hbox.deinit();
        dvui.label(@src(), "{s}", .{row.owner_name}, .{
            .expand = .horizontal,
            .gravity_y = 0.5,
            .margin = .all(0),
            .padding = .all(0),
        });
        core.icon.icon(@src(), "dropdown_triangle", dvui.entypo.triangle_down, .{}, .{ .gravity_y = 0.5 });
    }

    if (!dropdown.dropped()) return;

    for (row.candidates) |plugin| {
        if (dropdown.addChoiceLabel(plugin.display_name)) {
            assign(editor, row.ext, plugin.id);
            return;
        }
    }
    if (editor.app.host.fallback_editor) |text| {
        if (dropdown.addChoiceLabel(fallback_label)) {
            assign(editor, row.ext, text.id);
            return;
        }
    }
}

fn assign(editor: *fizzy.Editor, ext: []const u8, id: []const u8) void {
    // `resolveExtensionConflict` writes through `id`, and `id` lives in the chosen plugin's own
    // image — fine here (the plugin is loaded and stays loaded across this call), but the entry
    // it persists is duped on the way into the pending map.
    editor.resolveExtensionConflict(ext, id) catch |err|
        dvui.log.err("file types: could not assign '{s}' to '{s}': {s}", .{ ext, id, @errorName(err) });
    dvui.refresh(null, @src(), null);
}

/// Reassigning an extension never touches documents that are already open — they keep their
/// original owner and keep working, because routing is by `DocHandle.owner` and not re-derived
/// from the path. That is deliberately safe rather than silent: when a reassignment leaves such
/// documents behind, this offers to reopen them, and says so per row instead of hoping the user
/// notices that the setting only applies to the next file they open.
fn drawReopenAction(row: Row, ri: usize) void {
    const editor = fizzy.editor();
    const arena = dvui.currentWindow().arena();
    const stale = editor.app.staleOpenDocsForExtension(arena, row.ext) catch &.{};

    // Always occupy the column so showing/hiding a button never shifts widths — same as Reset.
    if (stale.len == 0) {
        _ = dvui.spacer(@src(), .{
            .expand = .horizontal,
            .min_size_content = .{ .w = 0, .h = 1 },
        });
        return;
    }

    const label = std.fmt.allocPrint(arena, "Reopen {d}", .{stale.len}) catch "Reopen";
    if (dvui.button(@src(), label, .{}, .{
        .id_extra = ri,
        .expand = .horizontal,
        .gravity_y = 0.5,
        .margin = .{ .x = 0, .y = 1, .w = 0, .h = 1 },
        .padding = .{ .x = 4, .y = 2, .w = 4, .h = 2 },
    })) {
        const reopened, const skipped = editor.reopenDocsUnderCurrentOwner(stale);
        if (skipped > 0) {
            // Unsaved work is never closed to satisfy a preference — say which files were left.
            dvui.toast(@src(), .{ .message = std.fmt.allocPrint(
                arena,
                "Reopened {d}; left {d} with unsaved changes alone.",
                .{ reopened, skipped },
            ) catch "Some files have unsaved changes." });
        }
        dvui.refresh(null, @src(), null);
    }
}
