//! The Settings sidebar tab: one searchable tree instead of a stack of labelled group boxes.
//!
//! Shape:
//!
//!     [search] Search settings…
//!     ▾ Fizzy            ← the shell's own settings (`explorer/settings.zig`'s `groups`)
//!       ▾ Appearance
//!       ▾ Input
//!       ▾ Keyboard Shortcuts
//!       ▾ Debugging
//!     ▾ Text             ← one branch per plugin that registered a settings schema
//!     ▾ Pixi
//!
//! Everything a plugin contributes is still drawn by `PluginSettingsPane.drawField`, so plugin
//! controls and shell controls look identical. This file owns *what* is shown, *where*, and the
//! per-leaf setting name (with search-match highlighting); control drawers only draw the widget.
//!
//! **Search is a data pass, not a draw pass.** `collect` scores every leaf with `core.fuzzy`
//! before a single widget exists, so a branch whose leaves all missed is simply never drawn (the
//! requirement that empty branches disappear). Drawing first and hiding afterwards would leave
//! empty animated branches behind.
const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const assets = @import("assets");
const core = @import("core");
const fizzy = @import("../fizzy.zig");
const PluginSettingsPane = @import("PluginSettingsPane.zig");
const SettingRow = @import("SettingRow.zig");
const PluginStore = @import("PluginStore.zig");
const shell_settings = @import("explorer/settings.zig");

const fuzzy = core.fuzzy;
const wdvui = core.dvui;
const settings = fizzy.sdk.settings;

/// The shell's own branch. Named for the app so it reads as a peer of the plugin branches
/// rather than as a special case.
const shell_branch_title = "Fizzy";

/// Expand/collapse state, keyed by a hash of the branch's path through the tree
/// ("Fizzy/Appearance", a plugin id, …) rather than by its widget id.
///
/// Two reasons it can't be the widget id. First, `TreeWidget.Branch` derives its expansion from
/// `init_options.expanded` on the *same* call that creates the widget, so a key only available
/// afterwards forces a provisional guess that renders wrong for a frame — which is exactly what
/// made a collapsed plugin flash open on first draw. Second, `Branch` rewrites its own
/// `_expanded` dvui data every frame, so force-expanding during a search would destroy the user's
/// hand-picked state with nothing left to restore; a separate map (the same thing the file tree
/// does with `Explorer.open_branches`) lets a search pass `expanded = true` freely as long as it
/// doesn't *write back*. A path key also survives rows being reordered by relevance.
var open_branches: std.AutoHashMapUnmanaged(u64, void) = .empty;

pub fn deinit(gpa: std.mem.Allocator) void {
    open_branches.deinit(gpa);
}

fn branchKey(path: []const u8) u64 {
    return std.hash.Wyhash.hash(0x5e7714, path);
}

fn isOpen(key: u64) bool {
    return open_branches.contains(key);
}

fn setOpen(key: u64, open: bool) void {
    if (open) {
        open_branches.put(fizzy.app.allocator, key, {}) catch return;
    } else {
        _ = open_branches.remove(key);
    }
}

// ---- match model --------------------------------------------------------------------------

/// A leaf that survived the filter. `score`/`tie` order it within its branch; `path` is what the
/// query was matched against and is kept so highlighting doesn't have to rebuild it.
const Leaf = struct {
    /// Index into the owning source (`Group.items` or `SettingsSchema.fields`).
    index: usize,
    label: []const u8,
    /// The name this setting has in `settings.zon` — drawn under the label and matched by the
    /// search, so someone who only knows the zon key can still find the row.
    key: []const u8 = "",
    /// Only read for a `settings.Search` leaf, whose own drawer needs it above its table; other
    /// leaves take theirs straight from the item/field.
    description: []const u8 = "",
    score: f64,
    tie: usize,
};

const Branch = struct {
    title: []const u8,
    /// Lowest (best) score among this branch's leaves — branches sort best-first too, so typing a
    /// plugin's name floats that plugin to the top.
    score: f64 = 0,
    tie: usize = 0,
    leaves: std.ArrayListUnmanaged(Leaf) = .empty,
    children: std.ArrayListUnmanaged(Branch) = .empty,
    /// Set for plugin branches; drives which `drawField` source the leaves index into.
    schema: ?*const settings.SettingsSchema = null,
    /// Set for the shell's group branches.
    group: ?*const shell_settings.Group = null,
    /// Set for a failed-plugin branch, whose single "leaf" is an error message.
    failed: ?fizzy.Editor.FailedPlugin = null,
    /// True only for the shell's own root branch — the one that gets the fox.
    is_shell: bool = false,
    /// Stable identity for expand/collapse state — see `open_branches`.
    key: u64 = 0,
};

/// Score one candidate against the query, matching on the tree path (`fizzy/appearance/theme`)
/// as well as the bare label and any hidden keywords.
///
/// The path form is why this uses `plain = false`: zf then treats the last `/` segment as a
/// filename and weights it above the ancestors, so typing `theme` ranks the Theme row above a
/// plugin whose *branch* happens to contain the letters.
fn scoreLeaf(query: *const fuzzy.Query, path: []const u8, label: []const u8, key: []const u8, keywords: []const u8) ?f64 {
    if (query.isEmpty()) return 0;
    const by_path = fuzzy.score(path, query, .{ .plain = false });
    const by_label = fuzzy.score(label, query, .{ .plain = true });
    // The zon key is drawn on the row, so a key hit is as legitimate as a label hit — typing
    // `insert_spaces_on_tab` (or just `spaces`) has to find the row either way.
    const by_key = if (key.len > 0) fuzzy.score(key, query, .{ .plain = true }) else null;
    const by_keywords = if (keywords.len > 0) fuzzy.score(keywords, query, .{ .plain = true }) else null;

    var best: ?f64 = by_path;
    if (by_label) |s| if (best == null or s < best.?) {
        best = s;
    };
    if (by_key) |s| if (best == null or s < best.?) {
        best = s;
    };
    // A keyword-only hit ("dark" → Theme) is a weaker signal than a visible-text hit, so it is
    // penalised rather than allowed to outrank a row the user can actually read the match on.
    if (by_keywords) |s| if (best == null or s + 1.0 < best.?) {
        best = s + 1.0;
    };
    return best;
}

fn lowerBranch(_: void, a: Branch, b: Branch) bool {
    if (a.score != b.score) return a.score < b.score;
    return a.tie < b.tie;
}

fn lowerLeaf(_: void, a: Leaf, b: Leaf) bool {
    if (a.score != b.score) return a.score < b.score;
    return a.tie < b.tie;
}

/// Build the surviving tree for `query`. Everything is arena-allocated: this is rebuilt from
/// scratch every frame, which is cheap (tens of leaves) and keeps zero state to invalidate.
fn collect(arena: std.mem.Allocator, query: *const fuzzy.Query) std.ArrayListUnmanaged(Branch) {
    var roots: std.ArrayListUnmanaged(Branch) = .empty;
    const editor = fizzy.editor;

    // --- the shell's own settings, one child branch per category
    var shell: Branch = .{
        .title = shell_branch_title,
        .score = std.math.floatMax(f64),
        .tie = 0,
        .is_shell = true,
        .key = branchKey(shell_branch_title),
    };
    for (&shell_settings.groups, 0..) |*group, gi| {
        var child: Branch = .{
            .title = group.title,
            .score = std.math.floatMax(f64),
            .tie = gi,
            .group = group,
            .key = branchKey(std.fmt.allocPrint(arena, "{s}/{s}", .{ shell_branch_title, group.title }) catch group.title),
        };
        for (group.items, 0..) |item, ii| {
            // An item that owns a searchable list scores itself: its rows, not its label, are
            // what the query is really matching against (`settings.Search`).
            const s = if (item.search) |sr| sr.score(query) orelse continue else blk: {
                const path = std.fmt.allocPrint(arena, "{s}/{s}/{s}", .{ shell_branch_title, group.title, item.label }) catch item.label;
                break :blk scoreLeaf(query, path, item.label, item.key, item.keywords) orelse continue;
            };
            child.leaves.append(arena, .{
                .index = ii,
                .label = item.label,
                .key = item.key,
                .description = item.description,
                .score = s,
                .tie = ii,
            }) catch continue;
            if (s < child.score) child.score = s;
        }
        if (child.leaves.items.len == 0) continue;
        std.sort.block(Leaf, child.leaves.items, {}, lowerLeaf);
        if (child.score < shell.score) shell.score = child.score;
        shell.children.append(arena, child) catch {};
    }
    if (shell.children.items.len > 0) {
        std.sort.block(Branch, shell.children.items, {}, lowerBranch);
        roots.append(arena, shell) catch {};
    }

    // --- one branch per plugin that registered a schema
    for (editor.host.settings_schemas.items, 0..) |*schema, si| {
        // Branch title is the plugin's display name (store / sidebar), not `schema.title` —
        // that field is a leftover section label (e.g. "Text Editor") and reads as a different
        // product from the plugin itself ("Text").
        const title = if (schema.owner.display_name.len > 0) schema.owner.display_name else schema.title;
        var branch: Branch = .{
            .title = title,
            .score = std.math.floatMax(f64),
            .tie = si + 1,
            .schema = schema,
            .key = branchKey(schema.owner.id),
        };
        // The plugin id is matched too, so `pixi` finds a plugin whose display name is something
        // else entirely — ids are what users see in the store and in settings.zon.
        const branch_hit = fuzzy.scoreBest(&.{ title, schema.owner.id }, query, .{ .plain = true });

        for (schema.fields, 0..) |field, fi| {
            const path = std.fmt.allocPrint(arena, "{s}/{s}", .{ title, field.label }) catch field.label;
            const leaf_hit = scoreLeaf(query, path, field.label, field.key, schema.owner.id);
            // A hit on the plugin itself keeps all of its settings visible — you searched for the
            // plugin, so you want its panel, not a filtered subset of it.
            const s = leaf_hit orelse (branch_hit orelse continue);
            branch.leaves.append(arena, .{
                .index = fi,
                .label = field.label,
                .key = field.key,
                .description = field.description,
                .score = s,
                .tie = fi,
            }) catch continue;
            if (s < branch.score) branch.score = s;
        }
        if (branch.leaves.items.len == 0) continue;
        std.sort.block(Leaf, branch.leaves.items, {}, lowerLeaf);
        roots.append(arena, branch) catch {};
    }

    // --- plugins that failed to load: one branch each, carrying the failure reason
    for (editor.failed_user_plugins.items, 0..) |f, fi| {
        const title = PluginStore.displayName(f.id);
        const s = fuzzy.scoreBest(&.{ title, f.id, f.reason }, query, .{ .plain = true }) orelse continue;
        var branch: Branch = .{
            .title = title,
            .score = s,
            .tie = editor.host.settings_schemas.items.len + fi + 1,
            .failed = f,
            // Distinct from a loaded plugin's key: the same id can legitimately appear in both
            // lists, and the two rows expand independently.
            .key = branchKey(std.fmt.allocPrint(arena, "failed/{s}", .{f.id}) catch f.id),
        };
        branch.leaves.append(arena, .{ .index = 0, .label = f.reason, .score = s, .tie = 0 }) catch {};
        roots.append(arena, branch) catch {};
    }

    // Only reorder when there's a query — with an empty one every score is 0 and the declaration
    // order (shell first, then plugins in registration order) is the intended reading order.
    if (!query.isEmpty()) std.sort.block(Branch, roots.items, {}, lowerBranch);
    return roots;
}

// ---- drawing ------------------------------------------------------------------------------

pub fn draw() !void {
    // Cap the pane at the explorer's viewport width.
    //
    // Two things depend on this. The explorer scrolls horizontally (long file paths need it), so
    // it sizes itself to the widest child min size — and `TextLayoutWidget` documents that with
    // `break_lines = true` its min *width* is still the width the text would need **unwrapped**.
    // Left uncapped, every description therefore both widened the pane and, having been handed
    // that width, never wrapped. Clamping the pane's own reported min size (`max_size_content`
    // is what `minSizeSetAndRefresh` clamps against) stops descriptions from driving the width,
    // which in turn gives them a bounded width to wrap inside.
    const viewport_w = fizzy.editor.explorer.scroll_info.viewport.w;
    const right_gap: f32 = 20; // clear of the pane's right edge (scrollbar / clip)

    var vbox = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .margin = .{ .w = right_gap },
        // Zero on the very first frame, before the scroll area has measured itself — no cap that
        // frame, then it settles.
        .max_size_content = if (viewport_w > right_gap) .width(viewport_w - right_gap) else null,
    });
    defer vbox.deinit();

    const query_text = drawSearchRow();
    var query = fuzzy.Query.init(query_text);
    const searching = !query.isEmpty();

    const arena = dvui.currentWindow().arena();
    const roots = collect(arena, &query);

    if (roots.items.len == 0) {
        dvui.labelNoFmt(@src(), "No matching settings", .{}, .{
            .margin = .{ .x = 4, .y = 12, .w = 4, .h = 4 },
            .color_text = dvui.themeGet().color(.control, .text),
        });
        return;
    }

    // Two trees, one per mode. A search force-expands branches, and `TreeWidget` stores expansion
    // per widget id — sharing one id space would bleed "expanded because searching" into the
    // browsing tree's animation state. Separate `id_extra` keeps them cleanly apart.
    var tree = wdvui.TreeWidget.tree(@src(), .{}, .{
        .id_extra = @intFromBool(searching),
        .expand = .horizontal,
        .background = false,
    });
    defer tree.deinit();

    for (roots.items, 0..) |*root, ri| {
        try drawBranch(tree, root, &query, searching, ri, .root);
    }
}

/// Which of the file tree's two row styles a branch borrows.
///
/// The settings tree deliberately reuses the explorer's visual language rather than inventing its
/// own: a top-level branch (Fizzy, or a plugin) is the analogue of the file tree's *project root*
/// row — identity icon, heading font, wide expander indent — and a category branch is the
/// analogue of a *folder* row. Every constant below is matched to `workbench/src/files.zig`; when
/// one moves there, move it here too.
const RowStyle = enum { root, category };

/// Search row — deliberately the same shape as the file tree's filter (`workbench/src/files.zig`)
/// so the two read as the same control.
fn drawSearchRow() []const u8 {
    var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    defer hbox.deinit();

    dvui.icon(
        @src(),
        "SettingsSearchIcon",
        icons.tvg.lucide.search,
        .{ .stroke_color = dvui.themeGet().color(.window, .text) },
        .{ .gravity_y = 0.5, .padding = dvui.Rect.all(0) },
    );
    const entry = dvui.textEntry(@src(), .{ .placeholder = "Search settings..." }, .{
        .expand = .horizontal,
        .background = false,
    });
    defer entry.deinit();
    return entry.getText();
}

fn drawBranch(
    tree: *wdvui.TreeWidget,
    branch: *const Branch,
    query: *const fuzzy.Query,
    searching: bool,
    id_extra: usize,
    style: RowStyle,
) !void {
    const theme = dvui.themeGet();

    // While searching every branch is forced open and `open_branches` is left untouched, so
    // clearing the query drops straight back to whatever the user had expanded.
    const want_open = searching or isOpen(branch.key);

    // Row fill states copied from the file tree's rows so hovering a settings category feels
    // identical to hovering a folder.
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

    drawRow(b, branch, query, style);

    const expanded = switch (style) {
        .root => b.expander(@src(), .{ .indent = 24 }, .{
            .color_fill = theme.color(.control, .fill),
            .corners = .all(8),
            .expand = .horizontal,
            .margin = .{ .x = 10, .w = 5 },
            .background = false,
        }),
        .category => b.expander(@src(), .{ .indent = 14 }, .{
            .expand = .horizontal,
            .corners = .all(8),
        }),
    };

    if (expanded) {
        var box = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .background = false });
        defer box.deinit();

        for (branch.children.items, 0..) |*child, ci| {
            try drawBranch(tree, child, query, searching, ci, .category);
        }
        try drawLeaves(branch, query);
    }

    if (!searching) setOpen(branch.key, b.expanded);
}

/// One setting row: the setting name (match-highlighted while searching), then the control body.
/// Labels live here so shell and plugin rows share the same chrome; drawers only draw widgets.
fn drawLeaves(branch: *const Branch, query: *const fuzzy.Query) !void {
    if (branch.failed) |f| {
        drawFailure(f);
        return;
    }

    for (branch.leaves.items) |leaf| {
        var row = dvui.box(@src(), .{ .dir = .vertical }, .{
            .id_extra = leaf.index,
            .expand = .horizontal,
            .background = false,
            // A setting's name, key, description and control read as one group, so the gap
            // *between* settings has to be clearly larger than any gap inside one. Split evenly
            // top/bottom rather than loaded onto the bottom: dvui margins don't collapse, so two
            // adjacent rows still sum to the same separation, but the first row no longer sits
            // flush under its category header and the last no longer trails a lone wide gap.
            .margin = .{ .y = 6, .h = 6 },
        });
        defer row.deinit();

        // A `settings.Search` item draws its own rows (each with its own name), so the leaf's own
        // name/key header above them would just be a second, redundant heading — but its
        // description still belongs at the top, explaining the table that follows.
        const search_item: ?shell_settings.Search =
            if (branch.group) |group| group.items[leaf.index].search else null;

        if (search_item == null) SettingRow.header(leaf.label, leaf.key, query);

        if (search_item) |sr| {
            SettingRow.description(leaf.description);
            sr.draw(query);
        } else if (branch.group) |group| {
            const item = group.items[leaf.index];
            if (item.inline_control) {
                var inline_box = SettingRow.beginInlineControl();
                defer inline_box.deinit();
                if (item.draw) |drawFn| drawFn();
                SettingRow.descriptionInline(item.description);
            } else {
                SettingRow.description(item.description);
                if (item.draw) |drawFn| drawFn();
            }
        } else if (branch.schema) |schema| {
            // Same hashing the old pane used: a plugin id that shows up in more than one section
            // must not collide on a widget id.
            const id_extra = hashId(schema.owner.id) +% leaf.index +% 1;
            const field = schema.fields[leaf.index];
            // A checkbox is the one control that shares its line with the description — see
            // `SettingRow`.
            if (field.kind == .bool) {
                var inline_box = SettingRow.beginInlineControl();
                defer inline_box.deinit();
                try PluginSettingsPane.drawField(schema, field, leaf.index, id_extra);
                SettingRow.descriptionInline(field.description);
            } else {
                SettingRow.description(field.description);
                try PluginSettingsPane.drawField(schema, field, leaf.index, id_extra);
            }
        }
    }
}

fn hashId(s: []const u8) usize {
    return @truncate(std.hash.Wyhash.hash(0, s));
}

fn drawFailure(f: fizzy.Editor.FailedPlugin) void {
    var buf: [256]u8 = undefined;
    const text = if (f.detail) |d|
        std.fmt.bufPrint(&buf, "Failed to load: {s} ({s})", .{ f.reason, d }) catch f.reason
    else
        std.fmt.bufPrint(&buf, "Failed to load: {s}", .{f.reason}) catch f.reason;

    // Wrapped, and with the same insets as a real setting row: an ABI-mismatch reason is a long
    // sentence, and a single unwrapped line of it would widen the whole pane (see `draw`).
    var tl = dvui.textLayout(@src(), .{ .break_lines = true }, .{
        .expand = .horizontal,
        .background = false,
        .margin = dvui.Rect.all(0),
        .padding = .{ .x = 3, .w = 3, .y = 1, .h = 3 },
        .font = dvui.Font.theme(.body),
    });
    tl.addText(text, .{ .color_text = dvui.themeGet().color(.err, .text) });
    tl.deinit();
}

/// A branch's own row: the same caret + identity icon + label the file tree draws, with the
/// characters the query matched tinted so it's obvious *why* a row survived the filter.
fn drawRow(b: *wdvui.TreeWidget.Branch, branch: *const Branch, query: *const fuzzy.Query, style: RowStyle) void {
    // Same tint the file tree uses for every caret (project root *and* folder) — `control.fill`.
    // `fill_hover` reads as a washed-out caret on top-level settings branches.
    const icon_color = dvui.themeGet().color(.control, .fill);

    {
        var slot = wdvui.treeRowGlyph(@src(), .{});
        defer slot.deinit();
        _ = dvui.icon(
            @src(),
            "BranchCaret",
            if (b.expanded) icons.tvg.entypo.@"down-open" else icons.tvg.entypo.@"right-open",
            .{ .fill_color = icon_color, .stroke_color = icon_color },
            wdvui.treeRowIconOptions(.{}),
        );
    }

    {
        // Same trailing gap as the file tree's folder/file icon slot (`files.zig`).
        var slot = wdvui.treeRowGlyph(@src(), .{ .margin = .{ .w = 2 } });
        defer slot.deinit();
        drawIdentityIcon(branch, style, icon_color);
    }

    // Label chrome matches the file tree's folder rows (`editableLabel`): 3px padding, no
    // margin, expanding. Roots keep the heading font (project-name weight); categories use body.
    var tl = dvui.textLayout(@src(), .{ .break_lines = false }, .{
        .gravity_y = 0.5,
        .background = false,
        .expand = .horizontal,
        .margin = dvui.Rect.all(0),
        .padding = dvui.Rect.all(3),
        .font = if (style == .root) dvui.Font.theme(.heading) else dvui.Font.theme(.body),
    });
    addHighlighted(tl, branch.title, query);
    tl.deinit();
}

/// The glyph between the caret and the title: the app logo for Fizzy's own branch, the plugin's
/// registered icon for a plugin, and the file tree's folder glyph for a settings category.
/// Always drawn inside a `treeRowGlyph` slot, so nothing here manages its own size.
fn drawIdentityIcon(branch: *const Branch, style: RowStyle, color: dvui.Color) void {
    if (style == .category) {
        // Each shell category names its own glyph (`Group.icon`) — a palette for Appearance, a
        // bug for Debugging — so the row says what it configures. A folder would only say
        // "there are more rows under here", which the caret already does.
        const glyph = if (branch.group) |g| g.icon else icons.tvg.entypo.folder;
        _ = dvui.icon(
            @src(),
            "CategoryIcon",
            glyph,
            .{ .fill_color = color, .stroke_color = color },
            wdvui.treeRowIconOptions(.{}),
        );
        return;
    }

    if (branch.is_shell) {
        // `icon.png` is the pixel-art F (not `fox.png`). Use `.imageFile` so dvui caches the
        // texture — `fromImageFileBytes` re-decodes and leaks a 1024² buffer every frame.
        const logo: dvui.ImageSource = .{ .imageFile = .{
            .bytes = assets.files.@"icon.png",
            .name = "icon.png",
            .interpolation = .nearest,
        } };
        _ = dvui.image(@src(), .{ .source = logo, .shrink = .ratio }, wdvui.treeRowIconOptions(.{}));
        return;
    }

    // Plugin branch. `drawPluginIcon` is the same hook the plugin store's cards use, so a plugin
    // that ships an icon is recognisable in both places.
    const plugin_id = if (branch.schema) |s| s.owner.id else if (branch.failed) |f| f.id else "";
    if (plugin_id.len > 0 and fizzy.editor.host.drawPluginIcon(plugin_id)) return;

    // No icon of its own: fall back to the plugin's initial in the theme's *text* color, the same
    // stand-in `Host`'s plugin button uses. A generic package glyph tinted with a row *fill*
    // color — which is what this used to draw — is nearly invisible against the row it sits on.
    const initial = [1]u8{if (branch.title.len > 0) std.ascii.toUpper(branch.title[0]) else '?'};
    dvui.labelNoFmt(@src(), &initial, .{}, .{
        .gravity_x = 0.5,
        .gravity_y = 0.5,
        .padding = dvui.Rect.all(0),
        .margin = dvui.Rect.all(0),
        .font = dvui.Font.theme(.heading),
        .color_text = dvui.themeGet().color(.window, .text),
    });
}

/// Emit `text` into `tl`, tinting the bytes `query` matched. Falls back to one plain run when
/// there's no query (or nothing matched), which is the common case.
fn addHighlighted(tl: *dvui.TextLayoutWidget, text: []const u8, query: *const fuzzy.Query) void {
    const plain = dvui.themeGet().color(.control, .text);
    if (query.isEmpty()) {
        tl.addText(text, .{ .color_text = plain });
        return;
    }

    var buf: [fuzzy.highlight_buf_len]usize = undefined;
    const hits = fuzzy.highlight(text, query, &buf, .{ .plain = true });
    if (hits.len == 0) {
        tl.addText(text, .{ .color_text = plain });
        return;
    }

    const matched = dvui.themeGet().color(.highlight, .fill);
    var i: usize = 0;
    var h: usize = 0;
    while (i < text.len) {
        if (h < hits.len and hits[h] == i) {
            // Consume the whole contiguous run of matched bytes in one addText.
            const start = i;
            while (h < hits.len and hits[h] == i) : (h += 1) i += 1;
            tl.addText(text[start..i], .{ .color_text = matched });
        } else {
            const start = i;
            const next = if (h < hits.len) hits[h] else text.len;
            i = next;
            tl.addText(text[start..i], .{ .color_text = plain });
        }
    }
}
