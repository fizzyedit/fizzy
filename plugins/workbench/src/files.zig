const std = @import("std");
const core = @import("core");
const builtin = @import("builtin");
const dvui = @import("dvui");
const fuzzy = @import("core").fuzzy;
const FileTable = @import("core").FileTable;
const palette = @import("core").palette;
const runtime = @import("runtime.zig");
const icons = @import("icons");
const Workspace = @import("Workspace.zig");

pub var tree_removed_path: ?[]const u8 = null;
pub var selected_id: ?usize = null;
pub var edit_id: ?usize = null;

/// Multi-selection for the file tree. Maps `id_extra` (hash of absolute path) to the heap-owned
/// absolute path string. The primary `selected_id` is always a key here when set. Paths are
/// allocated from `runtime.allocator()` so they outlive the dvui arena used during draw.
pub var selected_paths: std.AutoArrayHashMapUnmanaged(usize, []u8) = .empty;
pub var selection_anchor: ?usize = null;

/// One row in depth-first tree order, for resolving a shift-range. Built on demand — see
/// `flushPendingFileShiftRange` — because the tree only builds widgets for rows near the
/// viewport and a shift anchor is usually scrolled well off screen.
const FileVisRow = struct { id: usize, path: []const u8 };

/// Shift-range uses row order built incrementally during draw; applying mid-traverse misses the anchor
/// when it appears later in DFS than the clicked row. Flush after the tree pass completes.
var pending_file_shift_range: ?struct {
    anchor_id: usize,
    clicked_id: usize,
    clicked_path: []const u8,
} = null;

/// The path a New Document flow just created and wants revealed, or null.
///
/// Reads through to `Workbench.pending_new_file_path` rather than being a `var` here, because
/// this module is compiled twice — into fizzy and into the workbench dylib — and a global would
/// give each copy its own. Whichever copy draws the tree must see what fizzy wrote; the
/// `Workbench` instance is shared across both, so it is the one place that holds. See that
/// field's doc comment for the full story.
fn newFilePath() ?[]const u8 {
    return runtime.workbench().pending_new_file_path;
}

fn clearNewFilePath() void {
    runtime.workbench().clearPendingNewFilePath();
}

const open_message = if (builtin.os.tag == .macos) "Reveal in Finder" else "Reveal in File Browser";

pub const Extension = enum {
    unsupported,
    hidden,
    fizzy,
    atlas,
    png,
    jpg,
    pdf,
    psd,
    aseprite,
    pyxel,
    json,
    zig,
    txt,
    zip,
    _7z,
    tar,
    gif,
};

pub fn draw() !void {
    // `tab_drag` matches workspace tab strips so file rows can drop on the canvas like tabs (DVUI reorder_tree cross-widget pattern).
    var tree = core.widgets.TreeWidget.tree(@src(), .{ .enable_reordering = true, .drag_name = "tab_drag" }, .{ .background = false, .expand = .both });
    defer tree.deinit();

    // Same as tools pane header: first frame after open (or after Files wasn't drawn last frame)
    // lacks published min sizes; clip until layout settles.
    const files_tree_settling = dvui.firstFrame(tree.data().id);
    const prev_clip: ?dvui.Rect.Physical = if (files_tree_settling)
        dvui.clip(.{ .x = 0, .y = 0, .w = 0, .h = 0 })
    else
        null;
    defer if (prev_clip) |p| dvui.clipSet(p);

    // Multi-drag uses this id list; descendants are omitted when a selected parent folder is dragged too.
    // Safe as long as `selected_paths` isn't mutated between now and `tree.deinit`.
    tree.selected_branch_ids = selectionBranchIdsForMultiDrag(dvui.currentWindow().arena()) catch selected_paths.keys();

    // One root: the open folder, whatever backs it — a directory on the disk, a zip the user
    // opened, a cloud drive they signed into. Opening any of them replaces the root, and Close
    // closes it; the table answers them all the same way.
    const folder: ?[]const u8 = runtime.host().folder();
    const path = folder orelse {
        runtime.workbench().file_tree_data_id = null;
        if (comptime builtin.target.cpu.arch == .wasm32) try drawWebEmpty() else drawNativeEmpty();
        return;
    };

    const filter_text = try drawFilter(tree);
    const kind: RootKind = if (core.paths.isMountPath(path)) .{ .mount = {} } else .{ .disk = {} };
    try drawRoot(path, kind, tree, filter_text, 0);
}

fn drawNativeEmpty() void {
    dvui.labelNoFmt(
        @src(),
        "Open a project folder to begin.",
        .{},
        .{ .color_text = .{ .color = dvui.themeGet().color(.control, .text) } },
    );

    if (dvui.button(@src(), "Open Folder", .{ .draw_focus = false }, .{ .expand = .horizontal, .style = .highlight })) {
        // Route through the backend abstraction (native = OS dialog, web = file input
        // element), not `dvui.dialogNativeFolderSelect`, which has no wasm implementation
        // and silently no-ops — same fix as the homepage button and File menu item.
        runtime.host().showOpenFolderDialog(Workspace.setProjectFolderCallback, null);
    }
}

fn drawWebEmpty() !void {
    const viewport_w = runtime.host().explorerViewportWidth();
    const wrap_w: f32 = if (viewport_w > 0) viewport_w else 200;

    {
        var wrap_box = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            .max_size_content = .{ .w = wrap_w, .h = std.math.floatMax(f32) },
            .background = false,
        });
        defer wrap_box.deinit();

        const tl = dvui.textLayout(@src(), .{}, .{
            .expand = .horizontal,
            .background = false,
        });
        tl.addText(
            "Open files from your device to begin. A .zip opens as a folder.",
            .{ .color_text = .{ .color = dvui.themeGet().color(.control, .text) } },
        );
        tl.deinit();
    }

    if (dvui.button(@src(), "Open Files", .{ .draw_focus = false }, .{
        .expand = .horizontal,
        .style = .highlight,
        .min_size_content = .{ .w = 110, .h = 0 },
    })) {
        runtime.host().showOpenFileDialog(
            struct {
                fn cb(_: ?[][:0]const u8) void {}
            }.cb,
            &.{},
            "",
            null,
        );
    }
}

/// The filter box above the roots. Returns the live filter text (arena-backed for the frame).
fn drawFilter(tree: *core.widgets.TreeWidget) ![]const u8 {
    const files = table() orelse return "";
    // Nothing is mid-walk at this point, so this is the one safe moment to free listings that
    // last frame's draw invalidated while it was still reading them.
    files.releaseRetired();

    runtime.workbench().file_tree_data_id = dvui.parentGet().extendId(@src(), 0);
    _ = tree;

    // Right margin keeps the entry clear of the overlay scrollbar that draws over the pane's right edge.
    var filter_hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .w = 10 } });
    core.icon.icon(
        @src(),
        "FilterIcon",
        icons.tvg.lucide.search,
        .{ .stroke_color = .{ .color = dvui.themeGet().color(.window, .text) } },
        .{ .gravity_y = 0.5, .padding = dvui.Rect.all(0) },
    );
    const filter_text_edit = dvui.textEntry(@src(), .{ .placeholder = "Filter..." }, .{
        .expand = .horizontal,
        .background = false,
    });
    const filter_text = filter_text_edit.getText();
    filter_text_edit.deinit();
    filter_hbox.deinit();

    // Closing the filter ends the session the path index was built for: the next one re-walks, so
    // files created or removed while the box was closed can't linger in the results.
    if (filter_text.len == 0) files.invalidateIndex();
    return filter_text;
}

/// What backs the root, which decides its row's menu: a disk folder can be revealed in the
/// file browser; a mount cannot. Both close.
const RootKind = union(enum) { disk, mount };

/// One root of the explorer: a project folder or a mount, expanded, with its own row menu.
/// `index` keeps several roots' widget ids apart.
fn drawRoot(path: []const u8, kind: RootKind, tree: *core.widgets.TreeWidget, filter_text: []const u8, index: usize) !void {
    const unique_id = runtime.workbench().file_tree_data_id orelse return;

    const folder = switch (kind) {
        // A mount's name is what follows `scheme://` — the archive, the account.
        .mount => path[(std.mem.indexOf(u8, path, "://") orelse 0) + 3 ..],
        // Resolve before taking the basename. Launching as `fizzy .` (or any relative path)
        // makes `basename` return the literal "." and the project row's title becomes a single
        // unreadable period instead of the folder's name.
        .disk => blk: {
            const base = std.fs.path.basename(path);
            if (base.len > 0 and !std.mem.eql(u8, base, ".") and !std.mem.eql(u8, base, "..")) break :blk base;
            const resolved = std.fs.path.resolve(dvui.currentWindow().arena(), &.{path}) catch break :blk base;
            const resolved_base = std.fs.path.basename(resolved);
            break :blk if (resolved_base.len > 0) resolved_base else base;
        },
    };

    const branch = tree.branch(@src(), .{
        .expanded = true,
        .animation_duration = 450_000,
        .animation_easing = dvui.easing.outBack,
    }, .{
        .id_extra = index,
        .expand = .both,
        .color_fill = .transparent,
        .margin = dvui.Rect.all(0),
        .padding = dvui.Rect.all(1),
    });
    defer branch.deinit();

    { // Project root row: close / reveal / new items (same actions as folder rows, plus Close)
        var context = dvui.context(@src(), .{ .rect = branch.button.data().borderRectScale().r }, .{});
        defer context.deinit();

        if (context.activePoint()) |point| {
            try showRootProjectContextMenu(point, path, kind, tree);
        }
    }

    if (branch.button.clicked()) {
        selected_id = null;
        selectionFreeAll();
        selection_anchor = null;
    }

    const color = dvui.themeGet().color(.control, .fill_hover);
    // Folder rows tint their caret from the per-row palette colour (optionally overridden
    // by `fileRowFillColor`); the project row has no per-row tint, so it takes the theme base.
    const caret_color = dvui.themeGet().color(.control, .fill);

    {
        var caret_slot = core.widgets.treeRowGlyph(@src(), .{});
        defer caret_slot.deinit();
        _ = core.icon.icon(
            @src(),
            "FolderIcon",
            if (branch.expanded) icons.tvg.entypo.@"down-open" else icons.tvg.entypo.@"right-open",
            // Same tint the folder rows below use, so the project row's caret doesn't read as a
            // different kind of control from every other caret in the tree.
            .{ .fill_color = .{ .color = caret_color }, .stroke_color = .{ .color = caret_color } },
            core.widgets.treeRowIconOptions(.{}),
        );
    }

    var fmt_string = std.fmt.allocPrint(dvui.currentWindow().lifo(), comptime "{s}", .{folder}) catch unreachable;
    defer dvui.currentWindow().lifo().free(fmt_string);

    for (fmt_string, 0..) |c, i| {
        fmt_string[i] = std.ascii.toUpper(c);
    }

    dvui.labelNoFmt(@src(), fmt_string, .{}, .{
        .color_fill = .{ .color = color },
        .font = dvui.Font.theme(.heading),
        .gravity_y = 0.5,
    });

    if (branch.expander(@src(), .{ .indent = 24 }, .{
        .color_fill = .{ .color = dvui.themeGet().color(.control, .fill) },
        .corners = .all(8),
        .expand = .both,
        .margin = .{ .x = 10, .w = 5 },
        .background = false,
    })) {
        var box = dvui.box(@src(), .{
            .dir = .vertical,
        }, .{
            .expand = .both,
            .background = false,
            .gravity_y = 0,
        });
        defer box.deinit();

        try recurseFiles(path, tree, unique_id, filter_text);

        // Fill remaining explorer height so empty projects (or short trees) still receive clicks;
        // context is registered after file rows so row menus keep priority.
        var filler = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .both,
            .background = false,
        });
        defer filler.deinit();

        {
            var blank_ctx = dvui.context(@src(), .{ .rect = filler.data().borderRectScale().r }, .{});
            defer blank_ctx.deinit();

            if (blank_ctx.activePoint()) |point| {
                try showRootProjectContextMenu(point, path, kind, tree);
            }
        }
    }
}

/// Context menu for the project root directory: close project, reveal on disk, new file / folder.
fn showRootProjectContextMenu(point: dvui.Point.Natural, project_path: []const u8, kind: RootKind, tree: *core.widgets.TreeWidget) !void {
    var fw2 = dvui.floatingMenu(@src(), .{ .from = dvui.Rect.Natural.fromPoint(point) }, .{ .box_shadow = .{
        .color = .black,
        .offset = .{ .x = 0, .y = 0 },
        .shrink = 0,
        .fade = 10,
        .alpha = 0.15,
    } });
    defer fw2.deinit();

    const root_branch_id = dvui.Id.update(tree.data().id, project_path);

    if ((dvui.menuItemLabel(@src(), "Close", .{}, .{
        .expand = .horizontal,
    })) != null) {
        runtime.host().closeProjectFolder();

        fw2.close();
    }

    _ = dvui.separator(@src(), .{ .expand = .horizontal });

    if (kind == .disk) {
        if ((dvui.menuItemLabel(@src(), open_message, .{}, .{ .expand = .horizontal })) != null) {
            runtime.host().openInFileBrowser(project_path) catch {
                dvui.log.err("Failed to open file browser", .{});
            };

            fw2.close();
        }
    }

    if ((dvui.menuItemLabel(@src(), "New File...", .{}, .{ .expand = .horizontal })) != null) {
        defer fw2.close();

        runtime.host().requestNewDocument(project_path, root_branch_id.asUsize());
    }

    if ((dvui.menuItemLabel(@src(), "New Folder...", .{}, .{ .expand = .horizontal })) != null) {
        createFolderInteractive(project_path);

        fw2.close();
    }
}

fn pointerReleaseInRectWithoutSelectionModifier(r: dvui.Rect.Physical) bool {
    for (dvui.events()) |*e| {
        switch (e.evt) {
            .mouse => |me| {
                if (me.action == .release and me.button.pointer() and r.contains(me.p)) {
                    return !me.mod.shift() and !me.mod.control() and !me.mod.command();
                }
            },
            else => {},
        }
    }
    return false;
}

// ---- the shared file set --------------------------------------------------------------------
//
// Listing directories, caching those listings, and ranking every path in the project used to
// live here, as module-level `var`s. They now live in `core.FileTable`, one instance owned by
// the app and reached through the Host — because the tab strip needs the same answers this tree
// does, and neither should pay to find them out twice. See that file for why the caches exist
// at all; the tree just reads them.
//
// It also fixed a real defect. This module is compiled into fizzy *and* into the workbench
// dylib, so every one of those `var`s was two objects, kept roughly in step by a
// `disk_generation` counter each copy polled to decide when to throw its own work away.

/// The shared file set, or null in a headless host. Every file-drawing path below starts here
/// and returns early without it, which is the same degradation a missing service gets.
fn table() ?*FileTable {
    return runtime.host().files;
}

// ---- file-run virtualization ----------------------------------------------------------------
//
// Every row in the tree is a real widget stack — a branch, a caret slot, an icon slot, a label,
// a context menu — so a directory's row count is a *per-frame* cost even for rows scrolled far
// out of sight. A quarter-million-file directory is therefore unusable no matter how fast the
// listing is read, which is why the cache above is only half the fix.
//
// Only the file run is virtualized. File rows are uniform height, so a leading and trailing
// spacer can stand in for the rows outside the viewport and keep both the scrollbar and the
// scroll offset exactly where they'd otherwise be. Directory rows are not: an expanded folder is
// as tall as its whole subtree. They always draw, which is fine because directories are the
// small half of every real tree.

/// Below this many files in one directory, virtualizing costs more than it saves.
const virtual_min_rows: usize = 64;

/// Rows drawn beyond each edge of the viewport. Overscan is not just polish here: dvui drops a
/// widget's min size the moment it goes undrawn (`min_sizes` is put-only tracked), so a row
/// scrolled back into view reports zero height on its first frame again. Drawing it a few rows
/// early means it has settled by the time it is actually on screen.
const virtual_overscan: f32 = 16;

/// Rows drawn on the very first frame purely to measure the row pitch, before which there is no
/// way to know where the viewport falls in the run. One frame, then it self-corrects.
const virtual_probe_rows: usize = 32;

/// Natural-unit height budget for one file run.
///
/// dvui clamps *every* widget's reported min size to `dvui.max_float_safe` (2e6) so layout
/// arithmetic stays inside f32's exact-integer range. At ~21.5 natural px per row that caps a
/// run at roughly 93k rows — a 283k-file directory would silently lose two thirds of its scroll
/// range, stopping partway down the list with no indication anything was cut.
///
/// Past that many rows the run therefore stops being drawn at one pixel per pixel: rows keep
/// their true height, but the *mapping* from scroll offset to row index is compressed to fit the
/// budget (see `virt_pitch`). The scrollbar then covers the whole directory, at the cost of one
/// pixel of travel meaning more than one row. Sized under the limit to leave room for the
/// directory rows and chrome sharing the same box.
const virtual_run_budget: f32 = 1_800_000;

/// Measured spacing between consecutive file rows, in physical pixels.
///
/// Module-level rather than per-directory dvui data on purpose: every file row in the tree is
/// built identically, so one measurement serves all of them, and it survives the file tree not
/// being drawn for a frame (switching sidebar tabs). Stored per widget, it would be reaped
/// along with the widget, and the run would fall back to the probe path — which briefly reports
/// a tiny content height and yanks the scroll position back to the top.
var row_pitch_px: f32 = 0;

/// `query`, when non-null, is the active filter — the bytes of `label` it matched are tinted so
/// a row explains *why* it survived the filter (the same treatment the settings tree gives its
/// rows). Null while no filter is active, which is the common case.
pub fn editableLabel(id_extra: usize, label: []const u8, color: dvui.Color, kind: std.Io.File.Kind, full_path: []const u8, query: ?*const fuzzy.Query) !void {
    const padding = dvui.Rect.all(3);
    const font = dvui.Font.theme(.body);

    const selected: bool = isFileSelected(id_extra);
    const editing: bool = if (edit_id) |id| id_extra == id else false;

    if (editing) {
        var te = dvui.textEntry(@src(), .{}, .{
            .expand = .horizontal,
            .background = false,
            .padding = dvui.Rect.all(0),
            .margin = dvui.Rect.all(0),
            .color_text = .{ .color = dvui.themeGet().color(.window, .text) },
            .gravity_y = 0.5,
            .id_extra = id_extra,
            .font = font,
        });
        defer te.deinit();

        // Text edit should handle any click events, so if we find one unhandled after the text edit
        // we can assume the mouse was clicked anywhere else and that the edit needs to be confirmed.
        for (dvui.events()) |*event| {
            switch (event.evt) {
                .mouse => |mouse| {
                    if (mouse.action == .press and selected and editing and !event.handled) {
                        selected_id = null;
                        edit_id = null;
                    }
                },
                else => {},
            }
        }

        if (dvui.firstFrame(te.data().id)) {
            te.textSet(label, true);

            if (std.mem.indexOf(u8, label, ".")) |idx| {
                if (idx == 0) {
                    te.textLayout.selection.moveCursor(1, false);
                    te.textLayout.selection.moveCursor(label.len - 1, true);
                } else {
                    te.textLayout.selection.moveCursor(0, false);
                    te.textLayout.selection.moveCursor(idx, true);
                }
            }

            dvui.focusWidget(te.data().id, null, null);
        }

        if (te.enter_pressed or !selected) {
            const parent_folder = std.fs.path.dirname(full_path);
            var new_path: []const u8 = undefined;

            defer edit_id = null;

            const valid_path = if (table()) |files| files.exists(full_path) else false;

            if (parent_folder) |folder| {
                new_path = try core.paths.join(dvui.currentWindow().arena(), folder, te.getText());
            } else {
                new_path = try std.fs.path.join(dvui.currentWindow().arena(), &.{te.getText()});
            }

            if (!std.mem.eql(u8, label, te.getText()) and te.getText().len > 0 and valid_path) {
                if (runtime.files()) |fs| try fs.rename(full_path, new_path, kind);
            }
        }
    } else if (kind == .file) {
        // File row: label expands and pushes plugin-registered decorations
        // (e.g. the unsaved dot) to the right edge of the row.
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .background = false,
            .padding = dvui.Rect.all(0),
            .margin = dvui.Rect.all(0),
            .id_extra = id_extra,
        });
        defer row.deinit();
        filterLabel(id_extra, label, color, font, padding, query);
        runtime.workbench().drawBranchDecorations(full_path, id_extra);
    } else {
        filterLabel(id_extra, label, color, font, padding, query);
    }
}

/// A row's text: a plain label normally, and a run-split label tinting the filter's matched bytes
/// while a filter is active. Chrome (font, padding, expansion) is identical either way so rows
/// don't shift when the filter box gains or loses text.
fn filterLabel(
    id_extra: usize,
    label: []const u8,
    color: dvui.Color,
    font: dvui.Font,
    padding: dvui.Rect,
    query: ?*const fuzzy.Query,
) void {
    const opts: dvui.Options = .{
        .color_text = .{ .color = color },
        .padding = padding,
        .margin = dvui.Rect.all(0),
        .id_extra = id_extra,
        .font = font,
        .expand = .horizontal,
        .gravity_y = 0.5,
    };

    const q = query orelse {
        dvui.label(@src(), "{s}", .{label}, opts);
        return;
    };

    var buf: [fuzzy.highlight_buf_len]usize = undefined;
    // `.plain = false` matches how `FileTable.search` scored these rows: the label is a
    // project-relative path, so zf weights its basename here too.
    const hits = fuzzy.highlight(label, q, &buf, .{ .plain = false });
    if (hits.len == 0) {
        dvui.label(@src(), "{s}", .{label}, opts);
        return;
    }

    var tl = dvui.textLayout(@src(), .{ .break_lines = false }, opts.override(.{ .background = false }));
    defer tl.deinit();

    const matched = dvui.themeGet().color(.highlight, .fill);
    var i: usize = 0;
    var h: usize = 0;
    while (i < label.len) {
        if (h < hits.len and hits[h] == i) {
            // Consume the whole contiguous run of matched bytes in one addText.
            const start = i;
            while (h < hits.len and hits[h] == i) : (h += 1) i += 1;
            tl.addText(label[start..i], .{ .color_text = .{ .color = matched } });
        } else {
            const start = i;
            i = if (h < hits.len) hits[h] else label.len;
            tl.addText(label[start..i], .{ .color_text = .{ .color = color } });
        }
    }
}

pub fn recurseFiles(root_directory: []const u8, outer_tree: *core.widgets.TreeWidget, unique_id: dvui.Id, outer_filter_text: []const u8) !void {
    var color_i: usize = 0;
    var id_extra: usize = 0;

    errdefer pending_file_shift_range = null;

    const recursor = struct {
        /// Draw a set of rows: either the contents of `directory` (the normal tree walk, `rows`
        /// null), or a caller-supplied flat list of already-ranked rows (`rows` non-null, used
        /// while a filter is active — see `FileTable.search`).
        ///
        /// The filtered case used to run through the walk too, re-reading *every* directory in
        /// the project from disk on *every frame* and testing each basename with a substring
        /// match. That is what made typing in the filter box scale with project size.
        fn search(directory: []const u8, tree: *core.widgets.TreeWidget, inner_unique_id: dvui.Id, inner_id_extra: *usize, color_id: *usize, filter_text: []const u8, parent_branch: ?*core.widgets.TreeWidget.Branch, rows: ?[]const FileTable.Entry) anyerror!void {
            // Borrows `filter_text`, which outlives this call — see `fuzzy.Query`.
            const query = fuzzy.Query.init(filter_text);
            const active_query: ?*const fuzzy.Query = if (query.isEmpty()) null else &query;

            // Two sources of rows: a caller-supplied ranked list while a filter is active (flat,
            // all files, already capped and screened), or this directory's cached listing. One
            // `FileTable.Entry` type serves both, which is what lets the run below draw either
            // without a second code path. Neither is copied — a listing can be hundreds of
            // thousands of entries and only the handful actually drawn is touched.
            const listing: ?*const FileTable.Listing = if (rows == null)
                ((table() orelse return).listDir(directory) orelse return)
            else
                null;
            const total: usize = if (rows) |r| r.len else listing.?.entries.len;
            const file_run_start: usize = if (listing) |l| l.dir_count else 0;

            const entryAt = struct {
                fn get(r: ?[]const FileTable.Entry, l: ?*const FileTable.Listing, i: usize) FileTable.Entry {
                    return if (r) |ranked| ranked[i] else l.?.entries[i];
                }
            }.get;

            // Directory rows: variable height, always drawn (see the virtualization notes above).
            for (0..file_run_start) |i| {
                _ = try drawRow(entryAt(rows, listing, i), directory, tree, inner_unique_id, inner_id_extra, color_id, filter_text, active_query, parent_branch);
            }

            const file_count = total - file_run_start;
            if (file_count == 0) return;

            // Anchors the top of the file run in screen space. Placed after the directory rows
            // precisely so their (variable, possibly animating) height doesn't have to be
            // predicted — whatever it came out to, the run starts here.
            const anchor = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 0, .h = 0 } });
            const anchor_rs = anchor.rectScale();
            const pitch: f32 = row_pitch_px;

            const scale = if (anchor_rs.s > 0) anchor_rs.s else 1;
            const count_f: f32 = @floatFromInt(file_count);

            // Geometry pitch: the real row pitch normally, squeezed to fit `virtual_run_budget`
            // once the run is too tall for dvui to express. Rows are still *drawn* at `pitch`;
            // only the spacers and the offset-to-row mapping use this.
            const virt_pitch = @min(pitch, virtual_run_budget * scale / count_f);

            var lo: usize = 0;
            var hi: usize = file_count;
            const clip = dvui.clipGet();
            if (file_count > virtual_min_rows) {
                if (pitch > 0.5 and virt_pitch > 0.01 and clip.h > 0) {
                    // Clamped as floats before the conversion: `@intFromFloat` is undefined for a
                    // value outside the integer's range, and nothing here bounds the arithmetic.
                    const limit: f32 = count_f;
                    // Where the viewport starts is a question about the compressed mapping...
                    const top = (clip.y - anchor_rs.r.y) / virt_pitch - virtual_overscan;
                    lo = @intFromFloat(std.math.clamp(@floor(top), 0, limit));

                    // ...but how many rows it takes to *fill* the viewport is a question about
                    // real row height, which compression must not change.
                    const span: usize = @intFromFloat(std.math.clamp(
                        @ceil(clip.h / pitch + 2 * virtual_overscan),
                        1,
                        limit,
                    ));

                    // Once the block can no longer start that far down without overflowing the
                    // end of the run, the lead spacer below pins it to the end — so it has to
                    // show the rows that actually *live* at the end, not the ones the mapping
                    // nominally points at.
                    //
                    // The test is in pixels, not row counts. Under compression the viewport
                    // spans far more virtual rows than the block draws (~135 vs ~67 here), so
                    // at max scroll `lo + span` still sits ~68 rows short of the last row and a
                    // row-count test never fires — which is exactly how the final entries ended
                    // up drawn but positioned past the scrollable area, and unreachable.
                    const span_px = @as(f32, @floatFromInt(span)) * pitch;
                    const max_lead_px = @max(0, count_f * virt_pitch - span_px);
                    if (@as(f32, @floatFromInt(lo)) * virt_pitch > max_lead_px) {
                        lo = file_count -| span;
                    }
                    hi = @min(file_count, lo + span);
                } else {
                    // No pitch yet (first frame for this run) — draw a bounded probe to measure it.
                    hi = @min(file_count, virtual_probe_rows);
                }
            }

            // Both spacers are drawn unconditionally, even at zero height: a widget that comes
            // and goes as you scroll churns ids for no benefit.
            //
            // The lead is also held back so the drawn block cannot run past the end of the run.
            // Under compression the block is taller than the virtual space it maps to, so near
            // the bottom `lo * virt_pitch` would push it past `run_px`, the trailing spacer
            // would bottom out at zero, and the run would grow — moving the scroll end, which
            // moves `lo`. Pinning the last screenful to the end keeps the height invariant.
            // Uncompressed this is never binding: `hi <= file_count` already guarantees it.
            const run_px = count_f * virt_pitch;
            const block_px = @as(f32, @floatFromInt(hi - lo)) * pitch;
            const lead_px = @max(0, @min(@as(f32, @floatFromInt(lo)) * virt_pitch, run_px - block_px));
            _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 0, .h = lead_px / scale } });

            // Pitch is the *largest* gap between consecutive drawn rows, not their average.
            //
            // A row that just scrolled into view has no min size yet and lays out zero-height
            // for one frame, so an average is biased low by however many rows are settling —
            // and a pitch that shrinks shrinks the content height, which is exactly the
            // feedback the trailing spacer above exists to prevent. The largest gap is the
            // pitch of a settled pair, and there is essentially always one in the window.
            var widest_gap: f32 = 0;
            var prev_y: f32 = 0;
            var drawn: usize = 0;
            for (file_run_start + lo..file_run_start + hi) |i| {
                const y = try drawRow(entryAt(rows, listing, i), directory, tree, inner_unique_id, inner_id_extra, color_id, filter_text, active_query, parent_branch);
                if (drawn > 0) widest_gap = @max(widest_gap, y - prev_y);
                prev_y = y;
                drawn += 1;
            }
            if (widest_gap > 0.5) row_pitch_px = widest_gap;

            // The trailing spacer is sized from what the rows *actually* occupied this frame,
            // not from `(file_count - hi) * pitch`, so the run is always exactly
            // `file_count * pitch` tall no matter what happened above.
            //
            // That invariant is the whole fix for a scroll area that fought the user: dvui drops
            // a widget's min size as soon as it goes undrawn, so every row scrolled back into
            // view is zero-height for one frame. With a fixed trailing spacer that made the
            // content height collapse by a screenful whenever the visible window moved, which
            // re-clamped the scroll offset, which moved the window again. Absorbing the
            // difference here keeps the total constant and breaks the loop.
            const marker = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 0, .h = 0 } });
            const consumed_px = marker.rectScale().r.y - anchor_rs.r.y;
            _ = dvui.spacer(@src(), .{ .min_size_content = .{
                .w = 0,
                .h = @max(0, run_px - consumed_px) / scale,
            } });
        }

        /// Draw one file or folder row, returning its top edge in physical screen coordinates
        /// (which is what `search` measures the run's row pitch from).
        fn drawRow(
            entry: FileTable.Entry,
            directory: []const u8,
            tree: *core.widgets.TreeWidget,
            inner_unique_id: dvui.Id,
            inner_id_extra: *usize,
            color_id: *usize,
            filter_text: []const u8,
            active_query: ?*const fuzzy.Query,
            parent_branch: ?*core.widgets.TreeWidget.Branch,
            // `anyerror` breaks the inferred-error-set cycle with `search`, which this calls back
            // into for an expanded folder.
        ) anyerror!f32 {
            var row_y: f32 = 0;
            {
                const entry_dir = entry.dir orelse directory;
                const abs_path = try core.paths.join(dvui.currentWindow().arena(), entry_dir, entry.name);

                inner_id_extra.* = dvui.Id.update(tree.data().id, abs_path).asUsize();

                // Fixed Fizzy palette (theme-independent) so row accents stay stable across
                // theme switches and line up with rainbow bracket colours in the editor.
                var color = palette.at(color_id.*);
                if (runtime.host().fileRowFillColor(color_id.*)) |tint| {
                    color = tint;
                }

                // (row icon padding now comes from the shared `treeRowGlyph` slot)

                const selected: bool = isFileSelected(inner_id_extra.*);
                const editing: bool = if (edit_id) |id| inner_id_extra.* == id else false;

                const branch_id = tree.data().id.update(abs_path);

                var expanded = false;
                const expanded_indent: f32 = 14.0;

                if (runtime.host().explorerBranchIsOpen(branch_id)) {
                    expanded = true;
                }

                if (newFilePath()) |path| {
                    if (std.fs.path.dirname(path)) |d| {
                        if (std.mem.containsAtLeast(u8, d, 1, abs_path)) {
                            expanded = true;
                        }
                    }
                }

                const branch = tree.branch(@src(), .{
                    .expanded = expanded,
                    .animation_duration = 450_000,
                    .animation_easing = dvui.easing.outBack,
                    .process_events = !editing,
                    .can_accept_children = entry.kind == .directory,
                    .branch_id = inner_id_extra.*,
                }, .{
                    .id_extra = inner_id_extra.*,
                    .expand = .horizontal,
                    //.color_fill_hover = .fill,
                    .color_fill_hover = .{ .color = dvui.themeGet().color(.control, .fill).opacity(0.5) },
                    .color_fill_press = .{ .color = dvui.themeGet().color(.control, .fill_press) },
                    .color_fill = .{ .color = if (selected and tree.drag_point == null)
                        dvui.themeGet().color(.control, .fill).opacity(0.5)
                    else
                        core.widgets.hoverRestFill(dvui.themeGet().color(.control, .fill)) },
                    .padding = dvui.Rect.all(1),
                });
                defer branch.deinit();

                row_y = branch.data().borderRectScale().r.y;

                if (newFilePath()) |path| {
                    if (std.mem.eql(u8, path, abs_path)) {
                        if (!dvui.firstFrame(branch.data().id)) {
                            if ((parent_branch != null and !parent_branch.?.expanding()) or branch.button.data().rect.h > 10.0) {
                                edit_id = inner_id_extra.*;
                                selected_id = inner_id_extra.*;
                                // The dialog that created this file is still shrinking towards its
                                // own centre; now that the row it produced has a rect, re-aim the
                                // close at it so the user's eye is carried from the dialog to the
                                // name they are about to type over.
                                core.dialogs.setDialogCloseRectOverride(branch.data().borderRectScale().r);
                                clearNewFilePath();
                            }
                        }
                    }
                }

                const current_point = dvui.currentWindow().mouse_pt;
                const rect = branch.data().borderRectScale().r;
                const max_distance = if (!expanded) rect.h * 3.0 else rect.w / 8.0;

                var dx: f32 = std.math.floatMax(f32);

                if (current_point.x < rect.x + if (expanded) (expanded_indent * dvui.currentWindow().natural_scale) else 0.0) {
                    dx = std.math.floatMax(f32);
                } else if (current_point.x > rect.bottomRight().x) {
                    dx = @abs(current_point.x - rect.bottomRight().x);
                } else {
                    dx = 0.0;
                }

                var dy: f32 = std.math.floatMax(f32);

                if (current_point.y < rect.y) {
                    dy = @abs(current_point.y - rect.y);
                } else if (current_point.y > rect.bottomRight().y) {
                    dy = @abs(current_point.y - rect.bottomRight().y);
                } else {
                    dy = 0.0;
                }

                const distance = @sqrt(dx * dx + dy * dy);

                const t = 1.0 - (distance / max_distance);

                color = dvui.themeGet().color(.window, .fill).lerp(color, t);

                if (branch.floating()) {
                    if (dvui.dataGetSlice(null, inner_unique_id, "removed_path", []u8) == null)
                        dvui.dataSetSlice(null, inner_unique_id, "removed_path", abs_path);

                    if (entry.kind == .file and tree.id_branch == inner_id_extra.*) {
                        if (runtime.workbench().tab_drag_from_tree_path) |old| {
                            if (!std.mem.eql(u8, old, abs_path)) {
                                runtime.allocator().free(old);
                                runtime.workbench().tab_drag_from_tree_path = runtime.allocator().dupe(u8, abs_path) catch null;
                            }
                        } else {
                            runtime.workbench().tab_drag_from_tree_path = runtime.allocator().dupe(u8, abs_path) catch null;
                        }
                    }
                }

                if (branch.insertBefore()) {
                    const target_dir = if (entry.kind == .directory) abs_path else entry_dir;
                    try applyFileMove(inner_unique_id, tree, target_dir);
                }

                if (branch.dropInto() and entry.kind == .directory) {
                    try applyFileMove(inner_unique_id, tree, abs_path);
                    // Expand the folder so the dropped item is visible
                    runtime.host().setExplorerBranchOpen(branch_id, true);
                }

                { // Add right click context menu for item options
                    var context = dvui.context(@src(), .{ .rect = branch.button.data().borderRectScale().r }, .{ .id_extra = inner_id_extra.* });
                    defer context.deinit();

                    if (context.activePoint()) |point| {
                        var fw2 = dvui.floatingMenu(@src(), .{ .from = dvui.Rect.Natural.fromPoint(point) }, .{ .box_shadow = .{
                            .color = .black,
                            .offset = .{ .x = 0, .y = 0 },
                            .shrink = 0,
                            .fade = 10,
                            .alpha = 0.15,
                        } });
                        defer fw2.deinit();

                        // Right-clicking a row that isn't already part of the selection takes over
                        // as a single-row selection; right-clicking a selected row preserves the
                        // multi-selection so context-menu actions apply to the group.
                        if (!isFileSelected(inner_id_extra.*)) {
                            applyFileClick(inner_id_extra.*, abs_path, .replace);
                        } else {
                            selected_id = inner_id_extra.*;
                        }

                        if (entry.kind == .file) {
                            if ((dvui.menuItemLabel(@src(), "Open", .{}, .{
                                .expand = .horizontal,
                            })) != null) {
                                const arena = dvui.currentWindow().arena();
                                const to_open = selectionTopMostOpenableFilesForOpenActions(arena) catch |err| blk: {
                                    dvui.log.err("Failed to collect files to open: {any}", .{err});
                                    break :blk &[_][]const u8{};
                                };
                                for (to_open) |p| {
                                    _ = runtime.host().openFilePath(p, runtime.workbench().currentGroupingID()) catch |e| {
                                        dvui.log.err("Failed to open file: {any} ({s})", .{ e, p });
                                    };
                                }

                                fw2.close();
                            }

                            if ((dvui.menuItemLabel(@src(), "Open to the side", .{}, .{
                                .expand = .horizontal,
                            })) != null) {
                                const arena = dvui.currentWindow().arena();
                                const to_open = selectionTopMostOpenableFilesForOpenActions(arena) catch |err| blk: {
                                    dvui.log.err("Failed to collect files to open: {any}", .{err});
                                    break :blk &[_][]const u8{};
                                };
                                var side_grouping: u64 = undefined;
                                var have_grouping = false;
                                for (to_open) |p| {
                                    if (!have_grouping) {
                                        side_grouping = if (runtime.host().openDocCount() == 0)
                                            runtime.workbench().currentGroupingID()
                                        else
                                            runtime.workbench().newGroupingID();
                                        have_grouping = true;
                                    }
                                    _ = runtime.host().openFilePath(p, side_grouping) catch {
                                        dvui.log.err("Failed to open file: {s}", .{p});
                                    };
                                }

                                fw2.close();
                            }

                            _ = dvui.separator(@src(), .{ .expand = .horizontal });
                        }

                        if ((dvui.menuItemLabel(@src(), open_message, .{}, .{ .expand = .horizontal })) != null) {
                            runtime.host().openInFileBrowser(if (entry.kind == .file) std.fs.path.dirname(abs_path) orelse abs_path else abs_path) catch {
                                dvui.log.err("Failed to open file browser", .{});
                            };

                            fw2.close();
                        }

                        if ((dvui.menuItemLabel(@src(), "New File...", .{}, .{ .expand = .horizontal })) != null) {
                            defer fw2.close();

                            const parent_dir: []const u8 = if (entry.kind == .directory) abs_path else entry_dir;
                            runtime.host().requestNewDocument(parent_dir, branch_id.asUsize());
                        }

                        if ((dvui.menuItemLabel(@src(), "New Folder...", .{}, .{ .expand = .horizontal })) != null) {
                            switch (entry.kind) {
                                .directory => createFolderInteractive(abs_path),
                                .file => createFolderInteractive(entry_dir),
                                else => {},
                            }

                            fw2.close();
                        }

                        if ((dvui.menuItemLabel(@src(), "Rename", .{}, .{
                            .expand = .horizontal,
                        })) != null) {
                            edit_id = inner_id_extra.*;
                            fw2.close();
                        }

                        {
                            if ((dvui.menuItemLabel(@src(), "Delete", .{}, .{
                                .expand = .horizontal,
                            })) != null) {
                                defer fw2.close();

                                const arena = dvui.currentWindow().arena();
                                const top = selectionPathsSorted(arena) catch |err| blk: {
                                    dvui.log.err("Failed to collect selection paths: {any}", .{err});
                                    break :blk &[_][]const u8{};
                                };
                                if (runtime.files()) |fs| {
                                    for (top) |del_path| fs.delete(del_path);
                                }
                            }
                        }
                    }
                }

                switch (entry.kind) {
                    .file => {
                        const ext = extension(entry.name);
                        //if (ext == .hidden) continue;
                        const icon_color = color;

                        // Files have no expander, so they open with an empty caret-sized slot —
                        // that's what lines their icons up with the folder icons above them.
                        {
                            var caret_slot = core.widgets.treeRowGlyph(@src(), .{});
                            caret_slot.deinit();
                        }

                        // The plugin that owns this file type draws its own icon (see
                        // `Host.registerFileIcon`); the workbench only falls back to generic
                        // filesystem icons when no plugin claims it. A plugin's icon is arbitrary
                        // art at an arbitrary aspect ratio, so it is boxed to the shared row-glyph
                        // size like every other glyph rather than being trusted to behave.
                        {
                            var icon_slot = core.widgets.treeRowGlyph(@src(), .{ .margin = .{ .w = 2 } });
                            defer icon_slot.deinit();

                            if (!runtime.host().drawFileIcon(std.fs.path.extension(entry.name), abs_path, icon_color)) {
                                const icon = switch (ext) {
                                    .pdf => icons.tvg.entypo.@"doc-text",
                                    .tar, ._7z, .zip => icons.tvg.entypo.archive,
                                    else => icons.tvg.entypo.archive,
                                };
                                core.icon.icon(
                                    @src(),
                                    "FileIcon",
                                    icon,
                                    .{ .stroke_color = .{ .color = icon_color }, .fill_color = .{ .color = icon_color } },
                                    core.widgets.treeRowIconOptions(.{}),
                                );
                            }
                        }

                        const doc = runtime.host().docFromPath(abs_path);
                        const file_label = if (filter_text.len > 0) std.fs.path.relativePosix(dvui.currentWindow().arena(), ".", runtime.host().folder().?, abs_path) catch entry.name else entry.name;

                        editableLabel(
                            inner_id_extra.*,
                            file_label,
                            if (doc != null) dvui.themeGet().color(.window, .text) else dvui.themeGet().color(.control, .text),
                            entry.kind,
                            abs_path,
                            active_query,
                        ) catch {
                            dvui.log.err("Failed to draw editable label", .{});
                        };

                        if (doc) |d| {
                            if (d.owner.showsSaveStatusIndicator(d)) {
                                core.dialogs.bubbleSpinner(@src(), .{
                                    .id_extra = inner_id_extra.* +% 4001,
                                    .expand = .none,
                                    .min_size_content = .{ .w = 14, .h = 14 },
                                    .gravity_x = 1.0,
                                    .gravity_y = 0.5,
                                    .color_text = .{ .color = dvui.themeGet().color(.window, .text) },
                                }, .{
                                    .complete_elapsed_ns = d.owner.timeSinceSaveCompleteNs(d),
                                });
                            }
                        }

                        if (branch.button.clicked()) {
                            const mode = detectClickMode(branch.button.data().borderRectScale().r);
                            applyFileClick(inner_id_extra.*, abs_path, mode);
                            if (mode == .replace and openablePath(abs_path)) {
                                _ = runtime.host().openFilePath(abs_path, runtime.workbench().currentGroupingID()) catch |err| {
                                    dvui.log.err("{any}: {s}", .{ err, abs_path });
                                };
                            }
                        }
                    },
                    .directory => {
                        const folder_name = std.fs.path.basename(abs_path);
                        const icon_color = color;

                        if (dvui.parentGet().data().rectScale().r.h > 10) {
                            {
                                var caret_slot = core.widgets.treeRowGlyph(@src(), .{});
                                defer caret_slot.deinit();
                                _ = core.icon.icon(
                                    @src(),
                                    "DropIcon",
                                    if (branch.expanded) icons.tvg.entypo.@"down-open" else icons.tvg.entypo.@"right-open",
                                    .{
                                        .fill_color = .{ .color = icon_color },
                                        .stroke_color = .{ .color = icon_color },
                                    },
                                    core.widgets.treeRowIconOptions(.{}),
                                );
                            }

                            {
                                var icon_slot = core.widgets.treeRowGlyph(@src(), .{ .margin = .{ .w = 2 } });
                                defer icon_slot.deinit();
                                _ = core.icon.icon(
                                    @src(),
                                    "FolderIcon",
                                    icons.tvg.entypo.folder,
                                    .{
                                        .fill_color = .{ .color = icon_color },
                                        .stroke_color = .{ .color = icon_color },
                                    },
                                    core.widgets.treeRowIconOptions(.{}),
                                );
                            }
                        }

                        editableLabel(
                            inner_id_extra.*,
                            folder_name,
                            dvui.themeGet().color(.control, .text),
                            entry.kind,
                            abs_path,
                            // Folder rows only appear in the unfiltered walk, and their label is a
                            // bare basename rather than the path the filter scored.
                            null,
                        ) catch {
                            dvui.log.err("Failed to draw editable label", .{});
                        };

                        if (branch.button.clicked()) {
                            const mode = detectClickMode(branch.button.data().borderRectScale().r);
                            applyFileClick(inner_id_extra.*, abs_path, mode);
                        }

                        if (branch.expander(@src(), .{ .indent = expanded_indent }, .{
                            //.color_border = .{ .color = color.opacity(t) },
                            .expand = .horizontal,
                            .corners = .all(8),
                            // .box_shadow = .{
                            //     .color = .black,
                            //     .offset = .{ .x = -10 * t, .y = 0 },
                            //     .shrink = 10 * t,
                            //     .fade = 10 * t,
                            //     .alpha = 0.15 * t,
                            // },
                        })) {
                            runtime.host().setExplorerBranchOpen(branch_id, true);
                            try search(
                                abs_path,
                                tree,
                                inner_unique_id,
                                inner_id_extra,
                                color_id,
                                filter_text,
                                branch,
                                null,
                            );
                        } else {
                            if (runtime.host().explorerBranchIsOpen(branch_id)) {
                                runtime.host().setExplorerBranchOpen(branch_id, false);
                            }
                        }
                        // Keep open_branches in sync so hover-expand and drop-into expand persist next frame
                        if (branch.expanded) {
                            runtime.host().setExplorerBranchOpen(branch_id, true);
                        }
                        color_id.* = color_id.* + 1;
                    },
                    else => {},
                }
            }
            return row_y;
        }
    };

    if (outer_filter_text.len > 0) {
        const files = table() orelse return;
        const ranked = files.search(root_directory, outer_filter_text, dvui.currentWindow().arena());
        try recursor.search(root_directory, outer_tree, unique_id, &id_extra, &color_i, outer_filter_text, null, ranked);
        flushPendingFileShiftRange(root_directory, outer_tree, ranked);
    } else {
        try recursor.search(root_directory, outer_tree, unique_id, &id_extra, &color_i, outer_filter_text, null, null);
        flushPendingFileShiftRange(root_directory, outer_tree, null);
    }
}

pub fn isFileSelected(id: usize) bool {
    if (selected_id) |p| if (p == id) return true;
    return selected_paths.contains(id);
}

/// Free everything this module holds across frames. Called from `Workbench.deinit`. Only the
/// selection is left: the listing and path caches this used to tear down belong to the app now
/// (see `table`), which is also why nothing here is per-copy any more.
pub fn deinitCaches() void {
    selectionFreeAll();
    selected_paths.deinit(runtime.allocator());
}

fn selectionFreeAll() void {
    var it = selected_paths.iterator();
    while (it.next()) |e| runtime.allocator().free(e.value_ptr.*);
    selected_paths.clearRetainingCapacity();
}

fn selectionPut(id: usize, path: []const u8) void {
    if (selected_paths.getPtr(id)) |existing| {
        if (std.mem.eql(u8, existing.*, path)) return;
        runtime.allocator().free(existing.*);
        existing.* = runtime.allocator().dupe(u8, path) catch return;
        return;
    }
    const copy = runtime.allocator().dupe(u8, path) catch return;
    selected_paths.put(runtime.allocator(), id, copy) catch {
        runtime.allocator().free(copy);
    };
}

fn selectionRemove(id: usize) bool {
    if (selected_paths.fetchSwapRemove(id)) |kv| {
        runtime.allocator().free(kv.value);
        return true;
    }
    return false;
}

/// Apply a modifier-aware click to the file-tree selection. Indexed by id_extra (path hash).
fn applyFileClick(id: usize, path: []const u8, mode: core.widgets.TreeSelection.ClickMode) void {
    switch (mode) {
        .replace => {
            selectionFreeAll();
            selectionPut(id, path);
            selected_id = id;
            selection_anchor = id;
        },
        .toggle => {
            if (selectionRemove(id)) {
                if (selected_id == id) {
                    var it = selected_paths.iterator();
                    selected_id = if (it.next()) |entry| entry.key_ptr.* else null;
                }
            } else {
                selectionPut(id, path);
                selected_id = id;
            }
            selection_anchor = id;
        },
        .extend => {
            const pivot = selection_anchor orelse selected_id orelse id;
            pending_file_shift_range = .{
                .anchor_id = pivot,
                .clicked_id = id,
                .clicked_path = path,
            };
        },
    }
}

/// Depth-first order of every row the tree would show, matching draw order (a directory's
/// children immediately follow it, directories before files within each listing).
///
/// This walks the cached listings rather than recording rows as they draw, because the tree
/// only builds widgets for rows near the viewport — a shift anchor is usually scrolled far off
/// screen, and recording only drawn rows would silently reduce every long-range shift-click to a
/// single-row selection. Costs one pass on the frame a shift-click lands and nothing otherwise.
fn appendRowOrder(
    arena: std.mem.Allocator,
    tree_id: dvui.Id,
    directory: []const u8,
    out: *std.ArrayListUnmanaged(FileVisRow),
) void {
    const listing = (table() orelse return).listDir(directory) orelse return;
    for (listing.entries) |e| {
        const abs = core.paths.join(arena, directory, e.name) catch continue;
        const branch_id = tree_id.update(abs);
        out.append(arena, .{ .id = branch_id.asUsize(), .path = abs }) catch return;
        if (e.kind == .directory and runtime.host().explorerBranchIsOpen(branch_id)) {
            appendRowOrder(arena, tree_id, abs, out);
        }
    }
}

fn flushPendingFileShiftRange(
    root_directory: []const u8,
    tree: *core.widgets.TreeWidget,
    ranked: ?[]const FileTable.Entry,
) void {
    const p = pending_file_shift_range orelse return;
    pending_file_shift_range = null;

    const arena = dvui.currentWindow().arena();
    var rows: std.ArrayListUnmanaged(FileVisRow) = .empty;

    if (ranked) |list| {
        // A filter is active: row order is the ranked list, not the tree.
        for (list) |e| {
            const abs = core.paths.join(arena, e.dir orelse root_directory, e.name) catch continue;
            rows.append(arena, .{ .id = tree.data().id.update(abs).asUsize(), .path = abs }) catch break;
        }
    } else {
        appendRowOrder(arena, tree.data().id, root_directory, &rows);
    }

    applyFileShiftRange(rows.items, p.clicked_id, p.clicked_path, p.anchor_id);
}

fn applyFileShiftRange(rows: []const FileVisRow, clicked_id: usize, clicked_path: []const u8, anchor_id: usize) void {
    var a_idx: ?usize = null;
    var c_idx: ?usize = null;
    for (rows, 0..) |row, i| {
        if (row.id == anchor_id) a_idx = i;
        if (row.id == clicked_id) c_idx = i;
    }
    if (a_idx == null or c_idx == null) {
        selectionPut(clicked_id, clicked_path);
        selected_id = clicked_id;
        selection_anchor = anchor_id;
        return;
    }
    const lo = @min(a_idx.?, c_idx.?);
    const hi = @max(a_idx.?, c_idx.?);
    selectionFreeAll();
    for (rows[lo .. hi + 1]) |row| {
        selectionPut(row.id, row.path);
    }
    selected_id = clicked_id;
    if (selection_anchor == null) selection_anchor = anchor_id;
}

/// Derive the click mode from the most recent pointer release event that falls within `rect`.
/// Used after `branch.button.clicked()` so we can honor ctrl/cmd/shift without intercepting the
/// button's own event handling.
fn detectClickMode(rect: dvui.Rect.Physical) core.widgets.TreeSelection.ClickMode {
    var mode: core.widgets.TreeSelection.ClickMode = .replace;
    for (dvui.events()) |*e| {
        if (e.evt != .mouse) continue;
        const me = e.evt.mouse;
        if (me.action != .release or !me.button.pointer()) continue;
        if (!rect.contains(me.p)) continue;
        mode = core.widgets.TreeSelection.clickModeFromMod(me.mod);
    }
    return mode;
}

/// True when `child` lies strictly inside `ancestor` as a filesystem path (e.g. `/a/b` under `/a`).
fn isStrictPathDescendant(child: []const u8, ancestor: []const u8) bool {
    if (child.len <= ancestor.len) return false;
    if (!std.mem.startsWith(u8, child, ancestor)) return false;
    return std.fs.path.isSep(child[ancestor.len]);
}

/// Another selected entry is a folder that already contains this path — skip it for multi-drag / move.
fn selectionPathExcludedByAncestor(path: []const u8) bool {
    var it = selected_paths.iterator();
    while (it.next()) |e| {
        const other = e.value_ptr.*;
        if (std.mem.eql(u8, path, other)) continue;
        if (isStrictPathDescendant(path, other)) return true;
    }
    return false;
}

/// Selected paths with no selected ancestor folder, sorted lexically (same set as multi-drag).
fn selectionPathsSorted(arena: std.mem.Allocator) ![]const []const u8 {
    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = selected_paths.iterator();
    while (it.next()) |e| {
        const src = e.value_ptr.*;
        if (selectionPathExcludedByAncestor(src)) continue;
        const copy = try arena.dupe(u8, src);
        try paths.append(arena, copy);
    }
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    return paths.toOwnedSlice(arena);
}

fn pathIsDirAbsolute(abs: []const u8) bool {
    const files = table() orelse return false;
    return files.isDir(abs);
}

/// True when some registered plugin claims this file extension (not directories).
fn openablePath(abs_path: []const u8) bool {
    if (pathIsDirAbsolute(abs_path)) return false;
    return runtime.host().pluginForExtension(std.fs.path.extension(abs_path)) != null;
}

/// Every openable file beneath `root_abs`, through the table's listings so a mount walks the
/// same way the disk does. A directory a slow mount has not answered yet contributes nothing
/// this time — the same files the tree could not have shown either.
fn appendOpenableFilesInTree(arena: std.mem.Allocator, root_abs: []const u8, out: *std.ArrayListUnmanaged([]const u8)) !void {
    const files = table() orelse return;
    const listing = files.listDir(root_abs) orelse return;
    for (listing.entries) |entry| {
        const full = try joinChild(arena, root_abs, entry.name);
        switch (entry.kind) {
            .directory => try appendOpenableFilesInTree(arena, full, out),
            else => if (openablePath(full)) try out.append(arena, full),
        }
    }
}

fn joinChild(arena: std.mem.Allocator, dir: []const u8, name: []const u8) ![]u8 {
    return core.paths.join(arena, dir, name);
}

/// Top-most selection (no selected ancestor), then every openable canvas file: each selected file,
/// plus all openable descendants of selected directories. Sorted lexically. Not used for delete.
fn selectionTopMostOpenableFilesForOpenActions(arena: std.mem.Allocator) ![]const []const u8 {
    const top = try selectionPathsSorted(arena);
    var files: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer files.deinit(arena);
    for (top) |p| {
        if (pathIsDirAbsolute(p)) {
            try appendOpenableFilesInTree(arena, p, &files);
        } else if (openablePath(p)) {
            try files.append(arena, try arena.dupe(u8, p));
        }
    }
    std.mem.sort([]const u8, files.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    return files.toOwnedSlice(arena);
}

/// Branch ids for `TreeWidget.selected_branch_ids`: same as selection, minus descendants when a parent folder is also selected.
fn selectionBranchIdsForMultiDrag(arena: std.mem.Allocator) ![]const usize {
    const IdPath = struct {
        id: usize,
        path: []const u8,
    };
    var tmp: std.ArrayListUnmanaged(IdPath) = .empty;
    defer tmp.deinit(arena);

    var it = selected_paths.iterator();
    while (it.next()) |e| {
        const path = e.value_ptr.*;
        if (selectionPathExcludedByAncestor(path)) continue;
        try tmp.append(arena, .{ .id = e.key_ptr.*, .path = path });
    }
    std.mem.sort(IdPath, tmp.items, {}, struct {
        fn lt(_: void, a: IdPath, b: IdPath) bool {
            return std.mem.order(u8, a.path, b.path) == .lt;
        }
    }.lt);

    const out = try arena.alloc(usize, tmp.items.len);
    for (tmp.items, 0..) |p, i| out[i] = p.id;
    return out;
}

/// Move the drag source (and, for a multi-drag, every other selected path) into `target_dir`.
/// Renames files/folders on disk and rewrites open-file paths in-place. Clears the drag's
/// stashed `removed_path` when complete.
fn applyFileMove(unique_id: dvui.Id, tree: *core.widgets.TreeWidget, target_dir: []const u8) !void {
    const arena = dvui.currentWindow().arena();

    // The primary (floating) row's path is stashed here by the branch that reports `floating()`.
    const primary_path_opt: ?[]const u8 = dvui.dataGetSlice(null, unique_id, "removed_path", []u8);
    const is_multi = tree.drag_branch_ids != null;

    if (is_multi) {
        // Snapshot paths first: moving invalidates `selected_paths` entries and their strings.
        // Omit paths that are already under another selected folder (the folder move covers them).
        var paths: std.ArrayList([]u8) = .empty;
        defer paths.deinit(arena);
        var it = selected_paths.iterator();
        while (it.next()) |e| {
            const path = e.value_ptr.*;
            if (selectionPathExcludedByAncestor(path)) continue;
            const copy = arena.dupe(u8, path) catch continue;
            paths.append(arena, copy) catch continue;
        }

        // Stable order keeps sibling-relative order roughly predictable for the user.
        std.mem.sort([]u8, paths.items, {}, struct {
            fn lt(_: void, a: []u8, b: []u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lt);

        for (paths.items) |p| {
            if (runtime.files()) |fs| _ = try fs.move(p, target_dir);
        }

        // Rebuild the selection map from the new paths on disk.
        selectionFreeAll();
        selected_id = null;
        for (paths.items) |old_path| {
            const base = std.fs.path.basename(old_path);
            const new_path = joinChild(arena, target_dir, base) catch continue;
            if (table()) |files| {
                if (!files.exists(new_path)) continue;
            }
            const new_id = dvui.Id.update(tree.data().id, new_path).asUsize();
            selectionPut(new_id, new_path);
            selected_id = new_id;
        }
        selection_anchor = selected_id;
    } else if (primary_path_opt) |removed_path| {
        if (runtime.files()) |fs| _ = try fs.move(removed_path, target_dir);
    }

    dvui.dataRemove(null, unique_id, "removed_path");
}

/// "New Folder..." from either context menu (the project row and a folder row run the same
/// code): create the folder, then hand the tree its path so the row that appears next frame
/// opens its inline rename editor with the name selected — the same handoff a New Document
/// dialog makes through `EditorAPI.setExplorerNewFilePath`. Both now land on the shared
/// `Workbench` instance, so it no longer matters which copy of this module makes the call.
/// A folder that could not be created focuses nothing.
pub fn createFolderInteractive(parent: []const u8) void {
    const arena = dvui.currentWindow().arena();
    // "New Folder", then "New Folder 2", "New Folder 3"… — creating a second one must not fail
    // just because the first is still called what it was created as.
    var name_buf: [32]u8 = undefined;
    var n: usize = 1;
    const path = while (n <= 1000) : (n += 1) {
        const name = if (n == 1)
            "New Folder"
        else
            std.fmt.bufPrint(&name_buf, "New Folder {d}", .{n}) catch return;
        const candidate = joinChild(arena, parent, name) catch return;
        const taken = if (table()) |files| files.exists(candidate) else false;
        if (!taken) break candidate;
    } else return;

    const fs = runtime.files() orelse return;
    fs.createDir(path) catch {
        dvui.log.err("Failed to create folder: {s}", .{path});
        return;
    };
    runtime.workbench().setPendingNewFilePath(path) catch |err| {
        dvui.log.err("Failed to queue new folder reveal: {any}", .{err});
    };
}

pub fn extension(file: []const u8) Extension {
    const ext = std.fs.path.extension(file);
    if (std.mem.eql(u8, ext, "")) return .hidden;
    if (std.mem.eql(u8, ext, ".fiz")) return .fizzy;
    if (std.mem.eql(u8, ext, ".pixi")) return .fizzy;
    if (std.mem.eql(u8, ext, ".atlas")) return .atlas;
    if (std.mem.eql(u8, ext, ".png")) return .png;
    if (std.mem.eql(u8, ext, ".gif")) return .gif;
    if (std.mem.eql(u8, ext, ".jpg") or std.mem.eql(u8, ext, ".jpeg")) return .jpg;
    if (std.mem.eql(u8, ext, ".pdf")) return .pdf;
    if (std.mem.eql(u8, ext, ".psd")) return .psd;
    if (std.mem.eql(u8, ext, ".aseprite")) return .aseprite;
    if (std.mem.eql(u8, ext, ".pyxel")) return .pyxel;
    if (std.mem.eql(u8, ext, ".json")) return .json;
    if (std.mem.eql(u8, ext, ".zig")) return .zig;
    if (std.mem.eql(u8, ext, ".zip")) return .zip;
    if (std.mem.eql(u8, ext, ".7z")) return ._7z;
    if (std.mem.eql(u8, ext, ".tar")) return .tar;
    if (std.mem.eql(u8, ext, ".txt")) return .txt;
    return .unsupported;
}
