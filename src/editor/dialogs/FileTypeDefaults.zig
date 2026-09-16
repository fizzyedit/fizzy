//! Shown right after a plugin is installed (or first-loaded as a drop-in), when the extensions it offers
//! (`Plugin.fileTypes`) overlap something another plugin already opens — including the very
//! common case where the prior owner was only the `text` fallback ("a new plugin wants `.txt`").
//!
//! **Why this exists.** Which plugin opens a file is an explicit, persisted user decision, not
//! a priority contest between plugin authors, and this window is where that decision gets made
//! the first time it comes up.
//!
//! **Why it never nags.** There is deliberately no *per-extension* "already asked" record on disk
//! — such a record cannot tell "nothing has changed since we asked" apart from "a *different* new
//! plugin has just shown up also wanting this extension", which is exactly the case that must
//! still prompt. Instead the check is *scoped to arrival*: `Editor.maybeShowFileTypeDialog` runs
//! only when a plugin turns up for the first time — a store install (`installAndLoadPlugin`) or
//! the first load of a dropped-in build (`setPluginEnabled`, undecided → enabled). Not on the
//! ordinary startup load path, so a restart cannot resurface a dismissed prompt; not on
//! `updatePlugin`, so store updates and local rebuilds of a plugin you already answered for stay
//! silent; and not on enable/disable, which are decisions about loading, not about file types.
//!
//! The one coarse record that does exist is `.plugins.<id>.enabled`'s *presence* in settings.zon:
//! it means "fizzy has asked about this plugin at all". `Editor.uninstallPlugin` erases it (and
//! the plugin's `.extensions`), so uninstalling and reinstalling deliberately does ask again.
//!
//! Dismissing writes nothing at all: ownership is left exactly as it was, and the same unresolved
//! conflict is recomputed the next time this specific plugin arrives again (install or first load).
const std = @import("std");
const fizzy = @import("../../fizzy.zig");
const dvui = @import("dvui");

/// The list stops growing here and scrolls instead, so a plugin offering a dozen extensions gets
/// a scrollbar rather than a window clipped by the dialog's own `max_size`.
const max_list_h: f32 = 260;

/// Fixed column widths, so the header and every row line up into a real table without the
/// `GridWidget` machinery Settings › File Types needs (that pane sizes columns against a
/// resizable pane and a search filter; this window is a fixed 560 wide with three columns).
const col_ext_w: f32 = 76;
const col_current_w: f32 = 150;

/// One owner the user may pick for an extension.
///
/// Every string is duped and owned by this module, for the same reason `Row` is: a `*Plugin` or a
/// slice borrowed from `plugin.id` / `plugin.display_name` would dangle the moment the owning
/// dylib is `dlclose`d — which an unload does, between this window opening and the user answering.
pub const Choice = struct {
    id: []const u8,
    /// Display name, already resolved to `"Text (fallback)"` for the fallback editor.
    name: []const u8,
    /// Shipped inside fizzy rather than installed. Tagged and grouped separately in the dropdown
    /// so picking "Image" or "Text (fallback)" visibly means fizzy's own viewer, not a plugin the
    /// user went and got.
    builtin: bool,
};

/// One extension awaiting a decision, with every owner it could be given to.
pub const Row = struct {
    /// Extension with dot, e.g. ".png".
    ext: []const u8,
    /// Selectable owners, pre-ordered by the builder: the arriving plugin first, then other
    /// loaded plugins, then fizzy's built-ins. Never empty — the arriving plugin is always in it.
    choices: []const Choice,
    /// Index of what opens `ext` today, or null when nothing does.
    current: ?usize,
    /// Index this row will be assigned to on Confirm. Starts at 0 — the arriving plugin takes
    /// everything it offers unless the user says otherwise, which is the answer people want in
    /// the overwhelmingly common case (they just installed it *to* open these files).
    selected: usize = 0,
};

/// Live state for the one open window. Module-level because `request` returns immediately and
/// `dialog` runs per frame off dvui's dialog list.
var rows: []Row = &.{};
var plugin_id: []const u8 = "";
var plugin_name: []const u8 = "";

/// Latched once this window has asked to close, so the request is made exactly once — see the
/// same latch in `PluginUpdates.zig` for why re-asking chases a runaway close animation.
var closing = false;

pub fn active(win: *dvui.Window) bool {
    var it = win.dialogs.iterator(null);
    while (it.next()) |d| {
        const df = dvui.dataGet(null, d.id, "_displayFn", fizzy.core.dialogs.DisplayFn) orelse continue;
        if (df == dialog) return true;
    }
    return false;
}

/// Take ownership of `new_rows` (and every string in them) and show the window. `id` and
/// `display_name` are duped here. No-op if a window is already up — the caller frees its rows.
pub fn request(id: []const u8, display_name: []const u8, new_rows: []Row) void {
    if (new_rows.len == 0) return;
    if (active(dvui.currentWindow())) return;

    const gpa = fizzy.entry().allocator;
    reset();
    plugin_id = gpa.dupe(u8, id) catch return;
    plugin_name = gpa.dupe(u8, display_name) catch {
        gpa.free(plugin_id);
        plugin_id = "";
        return;
    };
    rows = new_rows;
    closing = false;

    var mutex = fizzy.core.dialogs.dialog(@src(), .{
        .displayFn = dialog,
        .callafterFn = callAfter,
        .title = "File types",
        .ok_label = "",
        .cancel_label = "",
        .resizeable = false,
        .default = .cancel,
        .hide_footer = true,
        .max_size = .{ .w = 560, .h = 480 },
        .header_kind = .info,
    });
    mutex.mutex.unlock(dvui.io);
}

/// Free everything this module owns. Safe to call twice.
fn reset() void {
    const gpa = fizzy.entry().allocator;
    for (rows) |r| {
        gpa.free(r.ext);
        for (r.choices) |c| {
            gpa.free(c.id);
            gpa.free(c.name);
        }
        if (r.choices.len > 0) gpa.free(r.choices);
    }
    if (rows.len > 0) gpa.free(rows);
    rows = &.{};
    if (plugin_id.len > 0) gpa.free(plugin_id);
    if (plugin_name.len > 0) gpa.free(plugin_name);
    plugin_id = "";
    plugin_name = "";
}

fn dialogButton(src: std.builtin.SourceLocation, label_text: []const u8, style: dvui.Theme.Style.Name, tab_idx: u16, id_extra: usize) bool {
    const opts: dvui.Options = .{
        .tab_index = tab_idx,
        .style = style,
        .id_extra = id_extra,
        .box_shadow = .{
            .color = .black,
            .alpha = 0.25,
            .offset = .{ .x = -4, .y = 4 },
            .fade = 8,
        },
    };
    var button: dvui.ButtonWidget = undefined;
    button.init(src, .{}, opts);
    defer button.deinit();
    button.processEvents();
    button.drawFocus();
    button.drawBackground();
    dvui.labelNoFmt(src, label_text, .{}, opts.strip().override(button.style()).override(.{ .gravity_x = 0.5, .gravity_y = 0.5 }));
    return button.clicked();
}

pub fn dialog(_: dvui.Id) anyerror!bool {
    const theme = dvui.themeGet();
    const body = dvui.Font.theme(.body);
    const arena = dvui.currentWindow().arena();

    if (rows.len == 0) {
        if (!closing) {
            closing = true;
            fizzy.core.dialogs.closeFloatingDialogAnchored();
        }
        return true;
    }

    var outer = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .padding = .all(8) });
    defer outer.deinit();

    const intro = if (rows.len == 1)
        std.fmt.allocPrint(arena, "{s} can also open this file type.", .{plugin_name}) catch
            "This plugin can also open some file types."
    else
        std.fmt.allocPrint(arena, "{s} can also open these {d} file types.", .{ plugin_name, rows.len }) catch
            "This plugin can also open some file types.";
    dvui.labelNoFmt(@src(), intro, .{}, .{ .font = body, .gravity_x = 0.5 });

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 8 } });

    {
        var head = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 4, .y = 2, .w = 4, .h = 2 },
        });
        defer head.deinit();
        const head_opts: dvui.Options = .{
            .font = body.larger(-1.0),
            .color_text = .{ .color = theme.color(.content, .text).opacity(0.7) },
            .gravity_y = 0.5,
        };
        dvui.labelNoFmt(@src(), "TYPE", .{}, head_opts.override(.{ .min_size_content = .{ .w = col_ext_w, .h = 0 } }));
        dvui.labelNoFmt(@src(), "OPENS IN", .{}, head_opts.override(.{ .min_size_content = .{ .w = col_current_w, .h = 0 } }));
        dvui.labelNoFmt(@src(), "CHANGE TO", .{}, head_opts);
    }
    _ = dvui.separator(@src(), .{ .expand = .horizontal, .margin = .{ .y = 2, .h = 2 } });

    // Sized to its content up to `max_list_h`, then scrolls — `.expand = .both` would claim the
    // whole capped window height and leave a two-row list floating in empty space.
    {
        var scroll = dvui.scrollArea(@src(), .{}, .{
            .expand = .horizontal,
            .background = false,
            .max_size_content = .{ .w = std.math.floatMax(f32), .h = max_list_h },
        });
        defer scroll.deinit();

        for (rows, 0..) |*row, i| {
            var line = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = i,
                .expand = .horizontal,
                .padding = .{ .x = 4, .y = 3, .w = 4, .h = 3 },
            });
            defer line.deinit();

            dvui.labelNoFmt(@src(), row.ext, .{}, .{
                .font = dvui.Font.theme(.mono),
                .gravity_y = 0.5,
                .min_size_content = .{ .w = col_ext_w, .h = 0 },
            });

            // Full text colour, not a ghost: which plugin you are taking the type *away from* is
            // the whole basis for the decision this row is asking about.
            dvui.labelNoFmt(@src(), if (row.current) |c| row.choices[c].name else "nothing", .{}, .{
                .font = body,
                .gravity_y = 0.5,
                .min_size_content = .{ .w = col_current_w, .h = 0 },
            });

            drawOwnerDropdown(row, i);
        }
    }

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 8 } });

    {
        var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .background = false });
        defer tl.deinit();
        tl.addText(
            "Whatever you choose is remembered, and files already open stay where they are. " ++
                "You can change any of this later in Settings › File Types.",
            .{ .font = body.larger(-1.0) },
        );
    }

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 16 } });

    var row_box = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    defer row_box.deinit();

    var btn_row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .none, .gravity_x = 0.5 });
    defer btn_row.deinit();

    // Not "Cancel": nothing is undone, nothing is written, and the plugin stays installed. The
    // question simply goes unanswered until this plugin next arrives (reinstall or first load).
    if (dialogButton(@src(), "Not now", .control, 1, 0) and !closing) {
        closing = true;
        fizzy.core.dialogs.closeFloatingDialogAnchored();
    }
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 10, .h = 1 } });
    if (dialogButton(@src(), "Confirm", .highlight, 2, 1) and !closing) {
        confirm();
        closing = true;
        fizzy.core.dialogs.closeFloatingDialogAnchored();
    }

    return true;
}

/// Persist every row, changed or not. Leaving a row on its current owner is a real decision —
/// "no, keep opening these in Image" — and recording it explicitly is what makes the answer
/// survive a later reinstall of either plugin, rather than being re-derived from whatever the
/// resolution order happens to say that day.
fn confirm() void {
    for (rows) |row| {
        if (row.selected >= row.choices.len) continue;
        const chosen = row.choices[row.selected].id;
        fizzy.editor().resolveExtensionConflict(row.ext, chosen) catch |err|
            dvui.log.err("file types: could not assign '{s}' to '{s}': {s}", .{ row.ext, chosen, @errorName(err) });
    }
}

/// The one control that changes an assignment: every eligible owner for this extension, grouped
/// so fizzy's own built-in viewers are visibly not third-party plugins. Deliberately the same
/// shape as the dropdown in Settings › File Types (`FileTypeSettings.drawOwnerDropdown`), which
/// is where the user comes back to change any of this later.
fn drawOwnerDropdown(row: *Row, ri: usize) void {
    const selected = row.choices[row.selected];

    var dropdown: dvui.DropdownWidget = undefined;
    dropdown.init(@src(), .{ .selected_index = row.selected }, .{
        .id_extra = ri,
        .expand = .horizontal,
        .gravity_y = 0.5,
        .corners = dvui.CornerRect.all(1000),
    });
    defer dropdown.deinit();

    {
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .vertical });
        defer hbox.deinit();
        dvui.labelNoFmt(@src(), selected.name, .{}, .{ .margin = .all(0), .padding = .all(0), .gravity_y = 0.5 });
        fizzy.core.icon.icon(@src(), "dropdown_triangle", dvui.entypo.triangle_down, .{}, .{ .gravity_x = 1.0, .gravity_y = 0.5 });
    }

    if (!dropdown.dropped()) return;

    // `choices` arrives pre-grouped (plugins, then built-ins), so a single pass in order produces
    // the grouping; the tag on each entry is what actually names the group.
    for (row.choices, 0..) |choice, ci| {
        if (addOwnerChoice(&dropdown, choice)) {
            row.selected = ci;
            return;
        }
    }
}

/// `DropdownWidget.addChoiceLabel` with a dim right-aligned tag — "Built-in" or "Plugin" — so the
/// list reads as two groups without inventing a non-selectable heading row the widget has no API
/// for. Returns true when this entry was chosen.
fn addOwnerChoice(dropdown: *dvui.DropdownWidget, choice: Choice) bool {
    var mi = dropdown.addChoice();
    defer mi.deinit();

    const opts = mi.data().options.strip().override(mi.style());
    {
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, opts.override(.{ .expand = .horizontal }));
        defer hbox.deinit();
        dvui.labelNoFmt(@src(), choice.name, .{}, opts.override(.{ .gravity_y = 0.5 }));
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 12, .h = 1 } });
        dvui.labelNoFmt(@src(), if (choice.builtin) "Built-in" else "Plugin", .{}, opts.override(.{
            .font = dvui.Font.theme(.body).larger(-1.0),
            .color_text = .{ .color = dvui.themeGet().color(.content, .text).opacity(0.6) },
            .gravity_x = 1.0,
            .gravity_y = 0.5,
        }));
    }

    if (mi.activeRect()) |_| {
        dropdown.close();
        return true;
    }
    return false;
}

pub fn callAfter(_: dvui.Id, _: dvui.enums.DialogResponse) !void {
    reset();
}
