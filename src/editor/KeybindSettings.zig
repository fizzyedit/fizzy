//! Keyboard Shortcuts settings pane — searchable via the settings tree under Fizzy.
//!
//! Lists every Host command with its current chord(s), lets the user click to record a new
//! binding (written to `keybinds.zon`), reset to default, and surfaces `Keymap.conflicts()`.
//!
//! Rows are laid out with `dvui.grid` (sortable headers), one grid per owner (Fizzy, or a
//! plugin), each inside a collapsible tree branch that starts closed.
//!
//! **This pane is part of the settings search.** `score` is the data pass the settings tree runs
//! before anything is drawn (see `SettingsTree`'s header comment); `draw` re-runs the same
//! `collectGroups` and renders only the commands that survived, with the matched characters of
//! each title tinted. A query that matches one keybind draws one branch with one row.
//!
//! **Column layout matches dvui's grid "fit window" demo:** every frame
//! `columnLayoutProportional` sizes columns to the grid's content width (Command flexes;
//! Shortcut/Reset stay fixed). No header resize handles — those are a separate demo mode
//! (`user_resizable`) and only mutate one column, which fights a fit-to-pane layout.
//!
//! **The grids never report a width to the explorer.** The explorer pane is a horizontally
//! scrolling area, so a child that asks for more width than the viewport makes the pane scroll —
//! and because a scroll container hands its children `max(virtual_size.w, viewport.w)`, a grid
//! sized from its parent's width would then ask for that new, larger width the next frame and
//! ratchet wider every frame. The grid is capped with `max_size_content = .width(0)` so it
//! contributes nothing to the pane's virtual width.
const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const icons = @import("icons");
const core = @import("core");
const fizzy = @import("../fizzy.zig");
const keymap = @import("keymap/keymap.zig");
const adapter = @import("keymap/dvui_adapter.zig");
const Keybinds = @import("Keybinds.zig");

const wdvui = core.dvui;
const fuzzy = core.fuzzy;

/// Command id currently waiting for a key press, or null when idle. Points into
/// `host.commands` (stable for the session while the plugin stays loaded).
var recording: ?[]const u8 = null;

/// Shared column widths across every owner grid.
var col_widths: [3]f32 = .{ 0, 0, 0 };

/// Owners present in this set are expanded. Default (absent) is collapsed — the pane opens as a
/// short list of owners rather than a wall of tables.
var open_owners: std.AutoHashMapUnmanaged(u64, void) = .empty;

/// Terms that name the *table itself* rather than any one command, so searching "shortcuts"
/// finds the whole list. Scored one term at a time rather than as a single sentence: against one
/// long string a query only has to be a scattered subsequence of it ("copy" picking up letters
/// from four different words), and every such accident would flood the pane with every command.
const table_keywords = [_][]const u8{
    "keybind",   "keybinding", "keybindings", "keyboard", "shortcut",
    "shortcuts", "hotkey",     "hotkeys",     "chord",    "chords",
    "keys",      "remap",      "bindings",
};

/// Whether a chord is being captured right now.
///
/// While this is true the app has to stop treating keys as commands, on both of the paths that
/// can consume one before `pollRecording` ever sees it:
///
///  - dvui events — `Keybinds.tick` and every plugin's `tickKeybinds` are skipped by the frame
///    loop, the same way they are while the command palette owns the keyboard.
///  - the macOS menu bar — AppKit matches an `NSMenu` key equivalent and fires its action
///    *before* the key ever reaches SDL, so no amount of dvui-side event handling can stop it.
///    `FizzyNativeMenuActionEnabled` reports every item disabled while recording, and AppKit
///    will not perform a disabled item's key equivalent. Without this, recording `cmd+o` opened
///    the folder picker instead of being captured.
pub fn isRecording() bool {
    return recording != null;
}

pub fn deinit(gpa: std.mem.Allocator) void {
    open_owners.deinit(gpa);
}

/// Proportional layout ratios for `columnLayoutProportional`: negative = flex share of leftover,
/// positive = fixed px. Command takes the remainder; Shortcut/Reset keep a comfortable width.
const col_ratios = [3]f32{ -1, 140, 64 };

// ---- match model --------------------------------------------------------------------------

const Row = struct {
    cmd: fizzy.sdk.Host.Command,
    keys: []const u8,
    score: f64,
    tie: usize,
};

const Group = struct {
    owner: []const u8,
    title: []const u8,
    key: u64,
    /// Best score among this group's rows — drives branch order while searching. Kept separate
    /// from `owner_hit`: folding the two together made the *first* matching command lower
    /// `score` below `floatMax`, which then read as "the owner matched" and let every later
    /// command in the group through the filter.
    score: f64,
    /// Set when the query matched the owner's own name — that keeps all of its commands.
    owner_hit: ?f64,
    tie: usize,
    rows: std.ArrayListUnmanaged(Row) = .empty,
};

fn ownerKey(owner: []const u8) u64 {
    return std.hash.Wyhash.hash(0xb17d5, owner);
}

fn isOwnerOpen(key: u64) bool {
    return open_owners.contains(key);
}

fn setOwnerOpen(key: u64, open: bool) void {
    if (open) {
        open_owners.put(fizzy.app.allocator, key, {}) catch {};
    } else {
        _ = open_owners.remove(key);
    }
}

fn ownerPrefix(id: []const u8) []const u8 {
    return if (std.mem.indexOfScalar(u8, id, '.')) |dot| id[0..dot] else id;
}

fn ownerLabel(owner: []const u8) []const u8 {
    if (std.mem.eql(u8, owner, "fizzy")) return "Fizzy";
    const editor = fizzy.editor;
    if (editor.host.pluginById(owner)) |p| return p.display_name;
    return owner;
}

/// Group every command by owner, keeping only what `query` matched. Rebuilt from scratch (into
/// the frame arena) by both `score` and `draw` so the two can't disagree about what matched.
fn collectGroups(
    arena: std.mem.Allocator,
    query: *const fuzzy.Query,
    platform: keymap.Platform,
) std.ArrayListUnmanaged(Group) {
    const editor = fizzy.editor;
    var groups: std.ArrayListUnmanaged(Group) = .empty;

    // A hit on the table's own name shows the whole list — but only as a *fallback*, applied
    // below once it's clear no individual command matched. Applied per row instead, a query that
    // matched three commands and also happened to brush a keyword would draw all of them.
    const table_hit = fuzzy.scoreBest(&table_keywords, query, .{ .plain = true });
    var any_row = false;

    for (editor.host.commands.items, 0..) |c, ci| {
        const owner = ownerPrefix(c.id);
        const group = blk: {
            for (groups.items) |*g| {
                if (std.mem.eql(u8, g.owner, owner)) break :blk g;
            }
            const title = ownerLabel(owner);
            // A hit on the owner's name ("text") shows all of that plugin's commands.
            const owner_hit = fuzzy.scoreBest(&.{ title, owner }, query, .{ .plain = true });
            groups.append(arena, .{
                .owner = owner,
                .title = title,
                .key = ownerKey(owner),
                .score = owner_hit orelse std.math.floatMax(f64),
                .owner_hit = owner_hit,
                .tie = groups.items.len,
            }) catch continue;
            break :blk &groups.items[groups.items.len - 1];
        };

        const cmd_hit = fuzzy.scoreBest(&.{ c.title, c.id }, query, .{ .plain = true });
        const s = cmd_hit orelse group.owner_hit orelse continue;

        const keys = if (shortcutFor(editor, c.id, platform)) |sc| sc.keys else "";
        group.rows.append(arena, .{ .cmd = c, .keys = keys, .score = s, .tie = ci }) catch continue;
        if (s < group.score) group.score = s;
        any_row = true;
    }

    // Nothing matched by name, but the query named the table itself ("shortcuts") — then the
    // whole list is the answer.
    if (!any_row) {
        const s = table_hit orelse return .empty;
        for (groups.items) |*g| {
            g.score = s;
            for (editor.host.commands.items, 0..) |c, ci| {
                if (!std.mem.eql(u8, ownerPrefix(c.id), g.owner)) continue;
                const keys = if (shortcutFor(editor, c.id, platform)) |sc| sc.keys else "";
                g.rows.append(arena, .{ .cmd = c, .keys = keys, .score = s, .tie = ci }) catch {};
            }
        }
    }

    // Drop owners whose commands all missed, then rank best-first while searching. With an empty
    // query every score is 0 and registration order is the intended reading order.
    var kept: std.ArrayListUnmanaged(Group) = .empty;
    for (groups.items) |g| {
        if (g.rows.items.len == 0) continue;
        kept.append(arena, g) catch {};
    }
    if (!query.isEmpty()) {
        std.sort.block(Group, kept.items, {}, lowerGroup);
        for (kept.items) |*g| std.sort.block(Row, g.rows.items, {}, lowerRow);
    }
    return kept;
}

fn lowerGroup(_: void, a: Group, b: Group) bool {
    if (a.score != b.score) return a.score < b.score;
    return a.tie < b.tie;
}

fn lowerRow(_: void, a: Row, b: Row) bool {
    if (a.score != b.score) return a.score < b.score;
    return a.tie < b.tie;
}

/// Settings-tree search hook: the best score among the commands this pane would draw, or null
/// when nothing matches (the whole "Keyboard Shortcuts" row then disappears from the tree).
pub fn score(query: *const fuzzy.Query) ?f64 {
    if (comptime builtin.target.cpu.arch == .wasm32) {
        // No keybinds on web — the pane draws an explanatory line, so only match its own name.
        return fuzzy.scoreBest(&table_keywords, query, .{ .plain = true });
    }
    if (query.isEmpty()) return 0;

    const platform: keymap.Platform = if (fizzy.platform.isMacOS()) .mac else .other;
    const groups = collectGroups(dvui.currentWindow().arena(), query, platform);
    var best: ?f64 = null;
    for (groups.items) |g| {
        if (best == null or g.score < best.?) best = g.score;
    }
    return best;
}

// ---- drawing ------------------------------------------------------------------------------

pub fn draw(query: *const fuzzy.Query) void {
    if (comptime builtin.target.cpu.arch == .wasm32) {
        dvui.label(@src(), "Keybindings are not available on the web build.", .{}, .{
            .color_text = dvui.themeGet().color(.window, .text).opacity(0.6),
        });
        return;
    }

    const editor = fizzy.editor;
    const theme = dvui.themeGet();
    const platform: keymap.Platform = if (fizzy.platform.isMacOS()) .mac else .other;
    const arena = dvui.currentWindow().arena();

    drawConflicts(editor, platform, theme);

    // No banner: the row being recorded says so itself. A strip appearing above the tree pushed
    // every row down the moment you clicked one, so the shortcut you were aiming at moved.
    if (recording) |id| {
        if (pollRecording(editor, id, platform)) {
            recording = null;
        }
    }

    const searching = !query.isEmpty();
    const groups = collectGroups(arena, query, platform);
    if (groups.items.len == 0) return;

    // Two trees, one per mode: a search force-expands branches and `TreeWidget` keeps expansion
    // per widget id, so sharing one id space would bleed "expanded because searching" into the
    // browsing tree's animation state (same split `SettingsTree` uses).
    var tree = wdvui.TreeWidget.tree(@src(), .{}, .{
        .id_extra = @intFromBool(searching),
        .expand = .horizontal,
        .background = false,
    });
    defer tree.deinit();

    for (groups.items, 0..) |*group, gi| {
        drawOwnerBranch(tree, editor, group, query, searching, gi, platform, theme);
    }
}

fn drawOwnerBranch(
    tree: *wdvui.TreeWidget,
    editor: *fizzy.Editor,
    group: *const Group,
    query: *const fuzzy.Query,
    searching: bool,
    id_extra: usize,
    platform: keymap.Platform,
    theme: dvui.Theme,
) void {
    // While searching every branch is forced open and `open_owners` is left untouched, so
    // clearing the query drops straight back to whatever the user had expanded.
    const want_open = searching or isOwnerOpen(group.key);

    const b = tree.branch(@src(), .{
        .expanded = want_open,
        .animation_duration = 450_000,
        .animation_easing = dvui.easing.outBack,
    }, .{
        .id_extra = id_extra,
        .expand = .horizontal,
        .color_fill_hover = theme.color(.control, .fill).opacity(0.5),
        .color_fill_press = theme.color(.control, .fill_press),
        .color_fill = .transparent,
        .padding = dvui.Rect.all(1),
    });
    defer b.deinit();

    {
        const icon_color = theme.color(.control, .fill);
        {
            var slot = wdvui.treeRowGlyph(@src(), .{});
            defer slot.deinit();
            _ = dvui.icon(
                @src(),
                "KeybindOwnerCaret",
                if (b.expanded) icons.tvg.entypo.@"down-open" else icons.tvg.entypo.@"right-open",
                .{ .fill_color = icon_color, .stroke_color = icon_color },
                wdvui.treeRowIconOptions(.{}),
            );
        }
        {
            var slot = wdvui.treeRowGlyph(@src(), .{ .margin = .{ .w = 2 } });
            defer slot.deinit();
            _ = dvui.icon(
                @src(),
                "KeybindOwnerIcon",
                icons.tvg.entypo.folder,
                .{ .fill_color = icon_color, .stroke_color = icon_color },
                wdvui.treeRowIconOptions(.{}),
            );
        }
        // Same text colour and match-tinting as every other row in the pane.
        wdvui.labelHighlighted(@src(), group.title, query, true, .{
            .gravity_y = 0.5,
            .expand = .horizontal,
            .font = dvui.Font.theme(.body),
            .color_text = theme.color(.control, .text),
            .margin = .all(0),
            .padding = dvui.Rect.all(3),
        });
    }

    if (b.expander(@src(), .{ .indent = 14 }, .{
        .expand = .horizontal,
        .corners = .all(8),
    })) {
        drawOwnerGrid(editor, group, query, id_extra, platform, theme);
    }

    if (!searching) setOwnerOpen(group.key, b.expanded);
}

/// Solid dot, drawn rather than iconified — lucide's circles are stroked outlines, and a
/// recording indicator wants a filled disc.
fn recordingDot() void {
    const size = dvui.Font.theme(.body).textHeight() * 0.55;
    var b = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .min_size_content = .{ .w = size, .h = size },
        .expand = .none,
        .gravity_y = 0.5,
        .margin = .{ .x = 2, .w = 4 },
        .padding = dvui.Rect.all(0),
    });
    defer b.deinit();

    const r = b.data().borderRectScale().r;
    r.fill(.all(r.h / 2), .{ .color = dvui.themeGet().color(.err, .fill) });
}

fn drawConflicts(editor: *fizzy.Editor, platform: keymap.Platform, theme: dvui.Theme) void {
    const conflicts = editor.keybind_conflicts orelse return;
    if (conflicts.len == 0) return;

    var box = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = theme.color(.err, .fill).opacity(0.25),
        .corners = .all(6),
        .padding = dvui.Rect.all(6),
        .margin = .{ .h = 8 },
    });
    defer box.deinit();

    dvui.label(@src(), "Conflicts", .{}, .{
        .font = dvui.Font.theme(.heading),
        .expand = .horizontal,
    });
    for (conflicts, 0..) |c, i| {
        const keys = keymap.formatKeys(dvui.currentWindow().arena(), c.stroke, platform) catch "?";
        dvui.label(@src(), "{s}: {s} shadows {s}", .{ keys, c.winner, c.loser }, .{
            .id_extra = i,
            .expand = .horizontal,
            .color_text = theme.color(.window, .text).opacity(0.85),
        });
    }
}

/// Last-column heading with no trailing separator — `gridHeading(…, null, …)` still draws one,
/// which read as a tiny fourth column.
fn drawResetHeading(grid: *dvui.GridWidget, cell_style: dvui.GridWidget.CellStyle) void {
    const cell_pos: dvui.GridWidget.Cell = .colRow(2, 0);
    var cell = grid.headerCell(@src(), 2, cell_style.cellOptions(cell_pos));
    defer cell.deinit();

    dvui.labelNoFmt(@src(), "Reset", .{}, cell_style.options(cell_pos).override(.{
        .expand = .horizontal,
        .gravity_x = 0.5,
        .gravity_y = 0.5,
        .background = false,
        .corners = .{},
    }));
}

fn drawOwnerGrid(
    editor: *fizzy.Editor,
    group: *const Group,
    query: *const fuzzy.Query,
    id_extra: usize,
    platform: keymap.Platform,
    theme: dvui.Theme,
) void {
    var grid = dvui.grid(@src(), .colWidths(&col_widths), .{
        .scroll_opts = .{
            // Vertical: none — the grid grows with its rows and the explorer pane scrolls.
            // Horizontal: none — columns are fit to the grid width every frame (dvui "fit window").
            .horizontal = .none,
            .vertical = .none,
            .horizontal_bar = .hide,
            .vertical_bar = .hide,
        },
        .resize_rows = false,
    }, .{
        .id_extra = id_extra,
        .expand = .horizontal,
        // Ask the pane for nothing: see this file's header comment. Height is left unbounded so
        // the grid still reports its full row stack and grows to fit.
        .max_size_content = .width(0),
        .padding = .all(0),
        .background = true,
        .color_fill = theme.color(.window, .fill).opacity(0.25),
        .corners = .all(4),
    });
    defer grid.deinit();

    // Same pattern as dvui's grid demo `.fit_window`: recompute widths from the grid's content
    // rect every frame so the table tracks the pane. Positive ratios are fixed; `-1` flexes.
    //
    // `columnLayoutProportional` always subtracts `scrollbar_padding_defaults.w` (room for a
    // vertical bar). We hide that bar, so add it back — otherwise a ~10px strip of grid
    // background shows past the last column and the row/header fills don't reach the edge.
    dvui.columnLayoutProportional(
        &col_ratios,
        &col_widths,
        grid.data().contentRect().w + dvui.GridWidget.scrollbar_padding_defaults.w,
    );

    // Alphabetical by command until the user clicks a heading. `.unsorted` is only ever the
    // grid's *initial* state — a click always leaves it ascending or descending, and that is
    // what the grid persists — so this can't stomp a sort the user picked.
    if (grid.sort_direction == .unsorted) grid.colSortSet(0, .ascending);

    const banded: dvui.GridWidget.CellStyle.Banded = .{
        .cell_opts = .{
            .padding = .{ .x = 6, .y = 2, .w = 4, .h = 2 },
            .background = true,
        },
        .alt_cell_opts = .{
            .padding = .{ .x = 6, .y = 2, .w = 4, .h = 2 },
            .background = true,
            .color_fill = theme.color(.control, .fill).opacity(0.22),
        },
    };

    const heading_style: dvui.GridWidget.CellStyle = .{
        .cell_opts = .{
            .padding = .{ .x = 6, .y = 2, .w = 4, .h = 2 },
            .background = true,
            .color_fill = theme.color(.control, .fill).opacity(0.35),
        },
        .opts = .{
            .expand = .horizontal,
            .gravity_y = 0.5,
            .font = dvui.Font.theme(.body).withWeight(.bold),
            .color_text = theme.color(.window, .text).opacity(0.7),
        },
    };

    var plain_heading_style = heading_style;
    plain_heading_style.opts.background = false;

    // Sortable headers with static separators only (fit-window mode — not user-resizable).
    var sort_dir: dvui.GridWidget.SortDirection = .unsorted;
    _ = dvui.gridHeadingSortable(@src(), grid, 0, "Command", &sort_dir, null, heading_style);
    _ = dvui.gridHeadingSortable(@src(), grid, 1, "Shortcut", &sort_dir, null, heading_style);
    drawResetHeading(grid, plain_heading_style);

    // Sorting reorders the rows this branch already filtered down to, so it composes with search.
    const rows = dvui.currentWindow().arena().dupe(Row, group.rows.items) catch group.rows.items;
    if (sort_dir != .unsorted) {
        const sort_col = grid.sort_col_number;
        const asc = sort_dir == .ascending;
        std.sort.pdq(Row, rows, SortCtx{ .col = sort_col, .asc = asc }, SortCtx.lessThan);
    }

    for (rows, 0..) |row, ri| {
        drawCommandRow(grid, editor, row.cmd, query, ri, platform, theme, banded);
    }
}

const SortCtx = struct {
    col: usize,
    asc: bool,

    fn lessThan(ctx: SortCtx, a: Row, b: Row) bool {
        const order: std.math.Order = switch (ctx.col) {
            0 => std.ascii.orderIgnoreCase(a.cmd.title, b.cmd.title),
            1 => std.mem.order(u8, a.keys, b.keys),
            else => .eq,
        };
        return if (ctx.asc) order == .lt else order == .gt;
    }
};

fn drawCommandRow(
    grid: *dvui.GridWidget,
    editor: *fizzy.Editor,
    c: fizzy.sdk.Host.Command,
    query: *const fuzzy.Query,
    row: usize,
    platform: keymap.Platform,
    theme: dvui.Theme,
    banded: dvui.GridWidget.CellStyle.Banded,
) void {
    const shortcut = shortcutFor(editor, c.id, platform);
    const keys_text = if (shortcut) |s| s.keys else "—";
    const inherited = if (shortcut) |s| s.inherited else false;
    const is_recording = if (recording) |r| std.mem.eql(u8, r, c.id) else false;
    const has_override = Keybinds.hasUserOverride(editor, c.id);

    {
        const cell_pos: dvui.GridWidget.Cell = .colRow(0, row);
        var cell = grid.bodyCell(@src(), cell_pos, banded.cellOptions(cell_pos));
        defer cell.deinit();

        var left = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .both,
            .gravity_y = 0.5,
            .margin = .all(0),
            .padding = .all(0),
        });
        defer left.deinit();
        wdvui.labelHighlighted(@src(), c.title, query, true, .{
            .expand = .horizontal,
            .margin = .all(0),
            .padding = .all(0),
        });
        wdvui.labelHighlighted(@src(), c.id, query, true, .{
            .expand = .horizontal,
            .margin = .all(0),
            .padding = .all(0),
            .color_text = theme.color(.window, .text).opacity(0.45),
        });
    }

    {
        const cell_pos: dvui.GridWidget.Cell = .colRow(1, row);
        var cell = grid.bodyCell(@src(), cell_pos, banded.cellOptions(cell_pos));
        defer cell.deinit();

        // Hand-built rather than `dvui.button` so the recording state can put a dot next to the
        // label. Same widget id either way, so starting a recording doesn't reset the button's
        // hover/press state. Column width is fixed — only the label text changes.
        const clicked = blk: {
            var bw: dvui.ButtonWidget = undefined;
            bw.init(@src(), .{}, .{
                .expand = .horizontal,
                .gravity_y = 0.5,
                .margin = .{ .x = 0, .y = 1, .w = 0, .h = 1 },
                .padding = .{ .x = 4, .y = 2, .w = 4, .h = 2 },
                // Recording is now signalled here and nowhere else (there is no banner), so the
                // row carries it: a fully-rounded red pill. The radius is deliberately far larger
                // than the button — dvui clamps it to half the height, which is what makes the
                // ends semicircular at any row height.
                .corners = if (is_recording) .all(10_000_000) else null,
                .color_fill = if (is_recording) theme.color(.err, .fill).opacity(0.18) else null,
            });
            defer bw.deinit();
            bw.processEvents();
            bw.drawBackground();

            {
                var inner = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .expand = .both,
                    .margin = .all(0),
                    .padding = .all(0),
                });
                defer inner.deinit();

                if (is_recording) recordingDot();
                dvui.labelNoFmt(@src(), if (is_recording) "Recording…" else keys_text, .{}, .{
                    .gravity_x = if (is_recording) 0.0 else 0.5,
                    .gravity_y = 0.5,
                    .expand = .horizontal,
                    .color_text = if (is_recording)
                        theme.color(.err, .fill)
                    else if (inherited)
                        theme.color(.control, .text).opacity(0.55)
                    else
                        null,
                });
            }

            break :blk bw.clicked();
        };
        if (clicked) {
            recording = if (is_recording) null else c.id;
        }
    }

    {
        const cell_pos: dvui.GridWidget.Cell = .colRow(2, row);
        var cell = grid.bodyCell(@src(), cell_pos, banded.cellOptions(cell_pos));
        defer cell.deinit();

        // Always occupy the reset column so binding/unbinding never shifts column widths.
        if (has_override) {
            if (dvui.button(@src(), "Reset", .{}, .{
                .expand = .horizontal,
                .gravity_y = 0.5,
                .margin = .{ .x = 0, .y = 1, .w = 0, .h = 1 },
                .padding = .{ .x = 4, .y = 2, .w = 4, .h = 2 },
            })) {
                Keybinds.clearUserBinding(editor, c.id) catch |err| {
                    dvui.log.err("clear keybind for '{s}' failed: {s}", .{ c.id, @errorName(err) });
                };
                if (recording) |r| {
                    if (std.mem.eql(u8, r, c.id)) recording = null;
                }
            }
        } else {
            _ = dvui.spacer(@src(), .{
                .expand = .horizontal,
                .min_size_content = .{ .w = 0, .h = 1 },
            });
        }
    }
}

const Shortcut = struct {
    keys: []const u8,
    /// The chord belongs to a Fizzy forwarder this command is reached through, not to this
    /// command. Drawn dimmed so it doesn't read as an override the Reset button could clear.
    inherited: bool = false,
};

fn shortcutFor(editor: *fizzy.Editor, id: []const u8, platform: keymap.Platform) ?Shortcut {
    if (directShortcut(editor, id, platform)) |keys| return .{ .keys = keys };

    // A plugin's document verb (`pixi.copy`) is invoked through the Fizzy forwarder that owns
    // the chord (`fizzy.copy` on `cmd+c`), so it has no binding of its own to find. Showing the
    // forwarder's chord is the truth about what key runs this command; showing "—" implied it
    // had no shortcut at all.
    const source = Keybinds.inheritedChordSource(id) orelse return null;
    const keys = directShortcut(editor, source, platform) orelse return null;
    return .{ .keys = keys, .inherited = true };
}

fn directShortcut(editor: *fizzy.Editor, id: []const u8, platform: keymap.Platform) ?[]const u8 {
    const arena = dvui.currentWindow().arena();
    const found = editor.keymap.bindingsFor(arena, id) catch return null;
    if (found.len == 0) return null;
    // Prefer the highest-source binding (user > plugin > profile > dvui).
    var best = found[0];
    for (found[1..]) |b| {
        if (@intFromEnum(b.source) >= @intFromEnum(best.source)) best = b;
    }
    return keymap.formatKeys(arena, best.stroke, platform) catch null;
}

/// Returns true when recording finished (a chord was captured).
///
/// Nothing is exempt: Esc binds like any other key rather than cancelling, so a command *can* be
/// put on it. The ways out are clicking the row again (which toggles recording off) and the row's
/// Reset button. The one thing still skipped is a bare modifier — those are waited on, since
/// every press of one is the start of a chord the user hasn't finished typing.
fn pollRecording(editor: *fizzy.Editor, command: []const u8, platform: keymap.Platform) bool {
    for (dvui.events()) |*e| {
        if (e.handled) continue;
        if (e.evt != .key) continue;
        const ke = e.evt.key;
        if (ke.action != .down) continue;

        const chord = adapter.chordFrom(ke) orelse continue;
        if (keymap.keyIsModifier(chord.key)) continue;

        e.handle(@src(), dvui.currentWindow().data());
        const keys = keymap.formatKeys(editor.host.allocator, .{ .first = chord }, platform) catch return true;
        defer editor.host.allocator.free(keys);
        Keybinds.setUserBinding(editor, command, keys) catch |err| {
            dvui.log.err("set keybind for '{s}' failed: {s}", .{ command, @errorName(err) });
        };
        return true;
    }
    return false;
}
