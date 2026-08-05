const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const wdvui = @import("core").dvui;
const fuzzy = @import("core").fuzzy;
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

/// Set from New File dialog when creating on disk; tree uses this to expand parents, focus rename, and set the dialog close-rect override.
pub var new_file_path: ?[]const u8 = null;

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
    if (comptime builtin.target.cpu.arch == .wasm32) {
        try drawWeb();
        return;
    }

    // `tab_drag` matches workspace tab strips so file rows can drop on the canvas like tabs (DVUI reorder_tree cross-widget pattern).
    var tree = wdvui.TreeWidget.tree(@src(), .{ .enable_reordering = true, .drag_name = "tab_drag" }, .{ .background = false, .expand = .both });
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

    if (runtime.host().folder()) |path| {
        try drawFiles(path, tree);
    } else {
        runtime.workbench().file_tree_data_id = null;
        dvui.labelNoFmt(
            @src(),
            "Open a project folder to begin.",
            .{},
            .{ .color_text = dvui.themeGet().color(.control, .text) },
        );

        if (dvui.button(@src(), "Open Folder", .{ .draw_focus = false }, .{ .expand = .horizontal, .style = .highlight })) {
            // Route through the backend abstraction (native = OS dialog, web = file input
            // element), not `dvui.dialogNativeFolderSelect`, which has no wasm implementation
            // and silently no-ops — same fix as the homepage button and File menu item.
            runtime.host().showOpenFolderDialog(Workspace.setProjectFolderCallback, null);
        }
    }
}

fn drawWeb() !void {
    var tree = wdvui.TreeWidget.tree(@src(), .{}, .{ .background = false, .expand = .both });
    defer tree.deinit();

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
            "Open files from your device to begin.",
            .{ .color_text = dvui.themeGet().color(.control, .text) },
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

pub fn drawFiles(path: []const u8, tree: *wdvui.TreeWidget) !void {
    // Nothing is mid-walk at this point, so this is the one safe moment to free listings that
    // last frame's draw invalidated while it was still reading them.
    releaseRetiredListings();

    const unique_id = dvui.parentGet().extendId(@src(), 0);
    runtime.workbench().file_tree_data_id = unique_id;

    // Right margin keeps the entry clear of the overlay scrollbar that draws over the pane's right edge.
    var filter_hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .w = 10 } });
    dvui.icon(
        @src(),
        "FilterIcon",
        icons.tvg.lucide.search,
        .{ .stroke_color = dvui.themeGet().color(.window, .text) },
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
    if (filter_text.len == 0) invalidateFilterIndex();

    // Resolve before taking the basename. Launching as `fizzy .` (or any relative path) makes
    // `basename` return the literal "." and the project row's title becomes a single unreadable
    // period instead of the folder's name.
    const folder = blk: {
        const base = std.fs.path.basename(path);
        if (base.len > 0 and !std.mem.eql(u8, base, ".") and !std.mem.eql(u8, base, "..")) break :blk base;
        const resolved = std.fs.path.resolve(dvui.currentWindow().arena(), &.{path}) catch break :blk base;
        const resolved_base = std.fs.path.basename(resolved);
        break :blk if (resolved_base.len > 0) resolved_base else base;
    };

    const branch = tree.branch(@src(), .{
        .expanded = true,
        .animation_duration = 450_000,
        .animation_easing = dvui.easing.outBack,
    }, .{
        .id_extra = 0,
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
            try showRootProjectContextMenu(point, path, tree);
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
        var caret_slot = wdvui.treeRowGlyph(@src(), .{});
        defer caret_slot.deinit();
        _ = dvui.icon(
            @src(),
            "FolderIcon",
            if (branch.expanded) icons.tvg.entypo.@"down-open" else icons.tvg.entypo.@"right-open",
            // Same tint the folder rows below use, so the project row's caret doesn't read as a
            // different kind of control from every other caret in the tree.
            .{ .fill_color = caret_color, .stroke_color = caret_color },
            wdvui.treeRowIconOptions(.{}),
        );
    }

    var fmt_string = std.fmt.allocPrint(dvui.currentWindow().lifo(), comptime "{s}", .{folder}) catch unreachable;
    defer dvui.currentWindow().lifo().free(fmt_string);

    for (fmt_string, 0..) |c, i| {
        fmt_string[i] = std.ascii.toUpper(c);
    }

    dvui.labelNoFmt(@src(), fmt_string, .{}, .{
        .color_fill = color,
        .font = dvui.Font.theme(.heading),
        .gravity_y = 0.5,
    });

    if (branch.expander(@src(), .{ .indent = 24 }, .{
        .color_fill = dvui.themeGet().color(.control, .fill),
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
                try showRootProjectContextMenu(point, path, tree);
            }
        }
    }
}

/// Context menu for the project root directory: close project, reveal on disk, new file / folder.
fn showRootProjectContextMenu(point: dvui.Point.Natural, project_path: []const u8, tree: *wdvui.TreeWidget) !void {
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

    if ((dvui.menuItemLabel(@src(), open_message, .{}, .{ .expand = .horizontal })) != null) {
        runtime.host().openInFileBrowser(project_path) catch {
            dvui.log.err("Failed to open file browser", .{});
        };

        fw2.close();
    }

    if ((dvui.menuItemLabel(@src(), "New File...", .{}, .{ .expand = .horizontal })) != null) {
        defer fw2.close();

        runtime.host().requestNewDocument(project_path, root_branch_id.asUsize());
    }

    if ((dvui.menuItemLabel(@src(), "New Folder...", .{}, .{ .expand = .horizontal })) != null) {
        const new_folder_path = try std.fs.path.join(dvui.currentWindow().arena(), &.{ project_path, "New Folder" });
        std.Io.Dir.createDirAbsolute(dvui.io, new_folder_path, .default_dir) catch dvui.log.err("Failed to create folder: {s}", .{new_folder_path});

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

// ---- filtered-mode path index --------------------------------------------------------------
//
// While the filter box is empty the tree is drawn straight from the filesystem, one directory per
// expanded folder — cheap, and always current. A filter changes that completely: every file in
// the project is a candidate, so the old code re-walked the *entire* project on every frame just
// to test basenames. Instead the project is walked **once per filter session** into this index,
// and each keystroke only re-ranks strings already in memory.

/// Absolute paths of every non-ignored file in the project, owned by `runtime.allocator()`.
var filter_index: std.ArrayListUnmanaged([]u8) = .empty;
/// Project root the index was built for; empty when there is no index. Owned.
var filter_index_root: []u8 = &.{};
/// Set when the filter box goes empty, so the next filter session rebuilds from disk rather than
/// ranking a snapshot that may be minutes old. Also set by the mutation helpers below.
var filter_index_stale: bool = true;

/// Refuse to index a pathological tree rather than stall a frame. A project past this many files
/// still filters — just over the first `filter_index_max_files` discovered.
const filter_index_max_files: usize = 200_000;
const filter_index_max_depth: usize = 32;

/// Hard cap on drawn filtered rows. Every row is a real tree widget — an id, an icon, a
/// run-split highlighted label — so the list length is a per-frame cost, not just a scroll
/// length. Uncapped, a one-letter query over a large project matched nearly the whole index
/// and drew tens of thousands of rows per frame, which froze the app. Past a few hundred hits
/// the ranking is noise anyway; the answer is to type another character.
const filter_max_rows: usize = 300;

/// Last ranking, reused while neither the query nor the index has changed. Without this the
/// whole index is re-scored on every frame the explorer draws, not just on each keystroke.
var filter_cache_query: []u8 = &.{};
var filter_cache_rows: std.ArrayListUnmanaged(SimpleEntry) = .empty;
var filter_cache_valid: bool = false;

/// Drop the cached path index. Called when the filter closes and whenever this module creates,
/// deletes, renames, or moves something — those are the only mutations that happen while the
/// explorer is open, and re-walking on the next keystroke is cheap enough to not need finer
/// invalidation.
pub fn invalidateFilterIndex() void {
    filter_index_stale = true;
    filter_cache_valid = false;
}

/// Both caches, for the disk-mutating helpers below. Deliberately *not* folded into
/// `invalidateFilterIndex`: that one also fires every frame the filter box is empty, which would
/// drop the listing cache continuously and undo the whole point of having it.
fn invalidateAfterDiskChange() void {
    invalidateFilterIndex();
    invalidateDirCache();
}

fn freeFilterIndex() void {
    const gpa = runtime.allocator();
    for (filter_index.items) |p| gpa.free(p);
    filter_index.clearRetainingCapacity();
    // Cached rows borrow the index strings.
    filter_cache_valid = false;
    filter_cache_rows.clearRetainingCapacity();
}

pub fn deinitFilterIndex() void {
    const gpa = runtime.allocator();
    freeFilterIndex();
    filter_index.deinit(gpa);
    if (filter_index_root.len > 0) gpa.free(filter_index_root);
    filter_index_root = &.{};
    filter_index_stale = true;
    filter_cache_rows.deinit(gpa);
    if (filter_cache_query.len > 0) gpa.free(filter_cache_query);
    filter_cache_query = &.{};
}

/// Rebuild the index for `root` if it's missing, stale, or was built for a different project.
fn ensureFilterIndex(root: []const u8) void {
    if (!filter_index_stale and std.mem.eql(u8, filter_index_root, root)) return;

    const gpa = runtime.allocator();
    freeFilterIndex();
    if (!std.mem.eql(u8, filter_index_root, root)) {
        if (filter_index_root.len > 0) gpa.free(filter_index_root);
        filter_index_root = gpa.dupe(u8, root) catch &.{};
    }
    indexDir(root, 0);
    filter_index_stale = false;
}

/// Depth-first walk honouring the same ignore rules the tree itself uses, so a filter never
/// surfaces something the unfiltered tree deliberately hides (`.git`, `node_modules`, …). Written
/// by hand rather than with `Dir.walk` precisely because it has to *prune* ignored directories —
/// a walker that descends into `node_modules` first and filters after is the slow thing we're
/// removing.
fn indexDir(directory: []const u8, depth: usize) void {
    if (depth > filter_index_max_depth) return;
    if (filter_index.items.len >= filter_index_max_files) return;

    const io = dvui.io;
    const gpa = runtime.allocator();
    var dir = std.Io.Dir.cwd().openDir(io, directory, .{ .access_sub_paths = true, .iterate = true }) catch return;
    defer dir.close(io);

    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (filter_index.items.len >= filter_index_max_files) return;

        const abs_path = std.fs.path.join(gpa, &.{ directory, entry.name }) catch continue;
        var keep = false;
        defer if (!keep) gpa.free(abs_path);

        if (runtime.host().folder()) |proj_root| {
            if (runtime.host().isPathIgnored(proj_root, abs_path, entry.name, entry.kind)) continue;
        }

        switch (entry.kind) {
            .file => {
                filter_index.append(gpa, abs_path) catch continue;
                keep = true;
            },
            .directory => indexDir(abs_path, depth + 1),
            else => {},
        }
    }
}

/// Rank the indexed paths against `filter_text` and return the rows to draw, best match first.
///
/// Matching runs against the **project-relative path**, not just the basename, with zf's filepath
/// mode: `src/files.zig` beats `s/r/c/f/i/l/e/s.zig` for the query `srcfiles`, and a query with a
/// `/` in it is treated as a path constraint. The old substring test on the basename alone could
/// not express either.
fn rankedFilterRows(root_directory: []const u8, filter_text: []const u8) []const SimpleEntry {
    ensureFilterIndex(root_directory);

    var query = fuzzy.Query.init(filter_text);
    if (query.isEmpty()) return &.{};

    // Ranking depends only on the query and the index, and both change far less often than
    // frames do — the explorer redraws on hover, scroll, animation, every peer widget.
    if (filter_cache_valid and std.mem.eql(u8, filter_cache_query, filter_text)) {
        return filter_cache_rows.items;
    }

    const gpa = runtime.allocator();
    const arena = dvui.currentWindow().arena();
    const Hit = fuzzy.Ranked(usize);
    var hits: std.ArrayListUnmanaged(Hit) = .empty;

    for (filter_index.items, 0..) |abs_path, i| {
        const rel = std.fs.path.relativePosix(arena, ".", root_directory, abs_path) catch continue;
        const score = fuzzy.score(rel, &query, .{ .plain = false }) orelse continue;
        // Shorter paths win ties — the same tie-break zf's own frontend uses.
        hits.append(arena, .{ .item = i, .score = score, .tie = rel.len }) catch break;
    }
    fuzzy.sort(usize, hits.items);

    // Rows borrow the index strings, so the cache lives exactly as long as the index does —
    // `freeFilterIndex` drops it.
    filter_cache_rows.clearRetainingCapacity();
    for (hits.items) |hit| {
        if (filter_cache_rows.items.len >= filter_max_rows) break;
        const abs_path = filter_index.items[hit.item];
        filter_cache_rows.append(gpa, .{
            .name = std.fs.path.basename(abs_path),
            .kind = .file,
            .dir = std.fs.path.dirname(abs_path) orelse root_directory,
        }) catch break;
    }

    if (filter_cache_query.len > 0) gpa.free(filter_cache_query);
    filter_cache_query = gpa.dupe(u8, filter_text) catch &.{};
    // A failed dupe just means the next frame re-ranks; never claim a cache we can't key.
    filter_cache_valid = filter_cache_query.len == filter_text.len;

    return filter_cache_rows.items;
}

// ---- directory listing cache ---------------------------------------------------------------
//
// The unfiltered tree used to re-read every expanded directory straight from disk on *every
// frame*: `openDir` + `iterate`, an arena dupe per name, a full sort, and an `isPathIgnored`
// call per entry. On a normal project that is invisible. On a vault with a few hundred thousand
// markdown files in one directory it is megabytes of arena churn and a sort of the whole listing
// per frame, which is half of why such a folder drops the app to single-digit FPS. (The other
// half is drawing a widget per row — see the virtualized file run in `search`.)
//
// So a listing is read once and kept. Freshness comes from `folderPathsChanged`, the watcher
// fizzy already runs on the open root; when there is no watcher backend for the platform,
// entries fall back to a short TTL so outside edits still show up.

const CachedEntry = struct {
    name: []u8,
    /// Always `.file` or `.directory`. Anything else on disk (a symlink, a fifo) is resolved to
    /// whichever it behaves as, so a sorted listing is always a directory run followed by a file
    /// run — the split `search` needs to virtualize the file half. It also fixes a small
    /// pre-existing bug: an entry of any other kind used to fall through the draw loop's `switch`
    /// and leave a blank, unlabelled row in the tree.
    kind: std.Io.File.Kind,
};

const CachedListing = struct {
    /// Sorted by `cachedLessThan` and already screened against fizzy's ignore rules.
    entries: []CachedEntry,
    /// Count of leading `.directory` entries; `entries[dir_count..]` is the uniform-height run.
    dir_count: usize,
    read_at_ms: i64,
};

/// Keyed by absolute directory path (owned). Values are boxed because a listing is borrowed
/// across a whole `search` call and the map rehashes as nested directories are read, which would
/// otherwise move the value out from under the loop iterating it.
var dir_cache: std.StringArrayHashMapUnmanaged(*CachedListing) = .empty;

/// Listings unlinked from the cache but possibly still being read by the draw in progress.
///
/// Invalidation can fire *during* a draw — a context menu that deletes or renames a file runs
/// inside the row it belongs to, several `search` frames deep, each of which is iterating a
/// listing. Freeing eagerly there is a use-after-free in the enclosing loops, so an unlinked
/// listing is parked here and released at the top of the next frame instead.
var dir_cache_retired: std.ArrayListUnmanaged(*CachedListing) = .empty;

/// Directories held at once. A tree with more than this expanded isn't a UI anyone is reading;
/// dropping the whole cache beats maintaining an LRU for a case nobody reaches.
const dir_cache_max_dirs: usize = 1024;

/// Re-read interval used *only* when fizzy has no live folder watcher, so the tree still
/// notices outside edits on a platform with no watcher backend.
const dir_cache_unwatched_ttl_ms: i64 = 1000;

/// Monotonic milliseconds. The boot clock rather than a wall clock: a TTL must not be
/// perturbed by the system clock stepping.
fn nowMs() i64 {
    return @intCast(@divTrunc(std.Io.Clock.boot.now(dvui.io).nanoseconds, std.time.ns_per_ms));
}

fn cachedLessThan(_: void, lhs: CachedEntry, rhs: CachedEntry) bool {
    if (lhs.kind == .directory and rhs.kind != .directory) return true;
    if (lhs.kind != .directory and rhs.kind == .directory) return false;
    return std.mem.order(u8, lhs.name, rhs.name) == .lt;
}

fn freeListing(listing: *CachedListing) void {
    const gpa = runtime.allocator();
    for (listing.entries) |e| gpa.free(e.name);
    gpa.free(listing.entries);
    gpa.destroy(listing);
}

/// Unlink one listing, parking it for release on the next frame (see `dir_cache_retired`).
fn retireCachedListingAt(index: usize) void {
    const gpa = runtime.allocator();
    const listing = dir_cache.values()[index];
    gpa.free(dir_cache.keys()[index]);
    dir_cache.swapRemoveAt(index);
    dir_cache_retired.append(gpa, listing) catch freeListing(listing);
}

/// Release listings unlinked during earlier frames. Called once at the top of the tree draw,
/// which is the only point at which nothing can still be reading one.
fn releaseRetiredListings() void {
    for (dir_cache_retired.items) |listing| freeListing(listing);
    dir_cache_retired.clearRetainingCapacity();
}

/// Drop every cached listing. The tree re-reads whatever it draws on the next frame.
pub fn invalidateDirCache() void {
    while (dir_cache.count() > 0) retireCachedListingAt(dir_cache.count() - 1);
}

/// Drop the listing for one directory. `folderPathsChanged` calls this with the parent of each
/// changed path — a file appearing in `a/b/c.md` only invalidates `a/b`.
pub fn invalidateDirCacheFor(directory: []const u8) void {
    if (dir_cache.getIndex(directory)) |idx| retireCachedListingAt(idx);
}

/// Cached, sorted, ignore-screened listing for `directory`, reading it from disk on a miss.
/// Null when the directory can't be opened.
fn listDir(directory: []const u8) ?*const CachedListing {
    const gpa = runtime.allocator();
    const now = nowMs();

    if (dir_cache.getIndex(directory)) |idx| {
        const listing = dir_cache.values()[idx];
        if (runtime.host().folderWatchActive() or now - listing.read_at_ms < dir_cache_unwatched_ttl_ms) {
            return listing;
        }
        retireCachedListingAt(idx);
    }

    if (dir_cache.count() >= dir_cache_max_dirs) invalidateDirCache();

    const io = dvui.io;
    var dir = std.Io.Dir.cwd().openDir(io, directory, .{ .access_sub_paths = true, .iterate = true }) catch return null;
    defer dir.close(io);

    var entries: std.ArrayListUnmanaged(CachedEntry) = .empty;
    const proj_root = runtime.host().folder();
    // The ignore check wants an absolute path but doesn't keep it, so it's built into a stack
    // buffer: joining through an allocator here would mean one allocation per entry on a listing
    // that can be hundreds of thousands long.
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;

    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        const abs_path: ?[]const u8 = std.fmt.bufPrint(
            &path_buf,
            "{s}" ++ std.fs.path.sep_str ++ "{s}",
            .{ directory, entry.name },
        ) catch null;

        if (proj_root) |root| {
            const abs = abs_path orelse continue;
            if (runtime.host().isPathIgnored(root, abs, entry.name, entry.kind)) continue;
        }

        const kind: std.Io.File.Kind = switch (entry.kind) {
            .directory => .directory,
            .file => .file,
            else => if (abs_path) |abs|
                (if (pathIsDirAbsolute(abs)) .directory else .file)
            else
                .file,
        };

        const name = gpa.dupe(u8, entry.name) catch continue;
        entries.append(gpa, .{ .name = name, .kind = kind }) catch {
            gpa.free(name);
            continue;
        };
    }

    const owned = entries.toOwnedSlice(gpa) catch {
        for (entries.items) |e| gpa.free(e.name);
        entries.deinit(gpa);
        return null;
    };
    std.mem.sort(CachedEntry, owned, {}, cachedLessThan);

    var dir_count: usize = 0;
    while (dir_count < owned.len and owned[dir_count].kind == .directory) dir_count += 1;

    const listing = gpa.create(CachedListing) catch {
        for (owned) |e| gpa.free(e.name);
        gpa.free(owned);
        return null;
    };
    listing.* = .{ .entries = owned, .dir_count = dir_count, .read_at_ms = now };

    const key = gpa.dupe(u8, directory) catch {
        freeListing(listing);
        return null;
    };
    dir_cache.put(gpa, key, listing) catch {
        gpa.free(key);
        freeListing(listing);
        return null;
    };
    return listing;
}

/// Free everything this module holds across frames. Called from `Workbench.deinit`.
pub fn deinitCaches() void {
    deinitFilterIndex();
    invalidateDirCache();
    releaseRetiredListings();
    dir_cache.deinit(runtime.allocator());
    dir_cache_retired.deinit(runtime.allocator());
    selectionFreeAll();
    selected_paths.deinit(runtime.allocator());
}

/// One row to draw. `dir` is normally null — the row's parent directory is whichever directory
/// the walk is currently in. Filtered rows come from all over the project at once (a flat ranked
/// list, not a walk), so those carry their own parent explicitly.
const SimpleEntry = struct {
    name: []const u8,
    kind: std.Io.File.Kind,
    dir: ?[]const u8 = null,
};

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
            .color_text = dvui.themeGet().color(.window, .text),
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

            const valid_path = blk: {
                std.Io.Dir.accessAbsolute(dvui.io, full_path, .{}) catch {
                    break :blk false;
                };

                break :blk true;
            };

            if (parent_folder) |folder| {
                new_path = try std.fs.path.join(dvui.currentWindow().arena(), &.{ folder, te.getText() });
            } else {
                new_path = try std.fs.path.join(dvui.currentWindow().arena(), &.{te.getText()});
            }

            if (!std.mem.eql(u8, label, te.getText()) and te.getText().len > 0 and valid_path) {
                try renamePath(full_path, new_path, kind);
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
        .color_text = color,
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
    // `.plain = false` matches how `rankedFilterRows` scored these rows: the label is a
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
            tl.addText(label[start..i], .{ .color_text = matched });
        } else {
            const start = i;
            i = if (h < hits.len) hits[h] else label.len;
            tl.addText(label[start..i], .{ .color_text = color });
        }
    }
}

pub fn recurseFiles(root_directory: []const u8, outer_tree: *wdvui.TreeWidget, unique_id: dvui.Id, outer_filter_text: []const u8) !void {
    var color_i: usize = 0;
    var id_extra: usize = 0;

    errdefer pending_file_shift_range = null;

    const recursor = struct {
        /// Draw a set of rows: either the contents of `directory` (the normal tree walk, `rows`
        /// null), or a caller-supplied flat list of already-ranked rows (`rows` non-null, used
        /// while a filter is active — see `rankedFilterRows`).
        ///
        /// The filtered case used to run through the walk too, re-reading *every* directory in
        /// the project from disk on *every frame* and testing each basename with a substring
        /// match. That is what made typing in the filter box scale with project size.
        fn search(directory: []const u8, tree: *wdvui.TreeWidget, inner_unique_id: dvui.Id, inner_id_extra: *usize, color_id: *usize, filter_text: []const u8, parent_branch: ?*wdvui.TreeWidget.Branch, rows: ?[]const SimpleEntry) anyerror!void {
            // Borrows `filter_text`, which outlives this call — see `fuzzy.Query`.
            const query = fuzzy.Query.init(filter_text);
            const active_query: ?*const fuzzy.Query = if (query.isEmpty()) null else &query;

            // Two sources of rows: a caller-supplied ranked list while a filter is active (flat,
            // all files, already capped and screened), or this directory's cached listing.
            // Neither is copied — a listing can be hundreds of thousands of entries and only the
            // handful actually drawn below is touched.
            const listing: ?*const CachedListing = if (rows == null) (listDir(directory) orelse return) else null;
            const total: usize = if (rows) |r| r.len else listing.?.entries.len;
            const file_run_start: usize = if (listing) |l| l.dir_count else 0;

            const entryAt = struct {
                fn get(r: ?[]const SimpleEntry, l: ?*const CachedListing, i: usize) SimpleEntry {
                    if (r) |ranked| return ranked[i];
                    const e = l.?.entries[i];
                    return .{ .name = e.name, .kind = e.kind };
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
            entry: SimpleEntry,
            directory: []const u8,
            tree: *wdvui.TreeWidget,
            inner_unique_id: dvui.Id,
            inner_id_extra: *usize,
            color_id: *usize,
            filter_text: []const u8,
            active_query: ?*const fuzzy.Query,
            parent_branch: ?*wdvui.TreeWidget.Branch,
            // `anyerror` breaks the inferred-error-set cycle with `search`, which this calls back
            // into for an expanded folder.
        ) anyerror!f32 {
            var row_y: f32 = 0;
            {
                const entry_dir = entry.dir orelse directory;
                const abs_path = try std.fs.path.join(
                    dvui.currentWindow().arena(),
                    &.{ entry_dir, entry.name },
                );

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

                if (new_file_path) |path| {
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
                    .color_fill_hover = dvui.themeGet().color(.control, .fill).opacity(0.5),
                    .color_fill_press = dvui.themeGet().color(.control, .fill_press),
                    .color_fill = if (selected and tree.drag_point == null)
                        dvui.themeGet().color(.control, .fill).opacity(0.5)
                    else
                        wdvui.hoverRestFill(dvui.themeGet().color(.control, .fill)),
                    .padding = dvui.Rect.all(1),
                });
                defer branch.deinit();

                row_y = branch.data().borderRectScale().r.y;

                if (new_file_path) |path| {
                    if (std.mem.eql(u8, path, abs_path)) {
                        if (!dvui.firstFrame(branch.data().id)) {
                            if ((parent_branch != null and !parent_branch.?.expanding()) or branch.button.data().rect.h > 10.0) {
                                edit_id = inner_id_extra.*;
                                selected_id = inner_id_extra.*;
                                new_file_path = null;
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
                                .directory => {
                                    const new_folder_path = try std.fs.path.join(dvui.currentWindow().arena(), &.{ abs_path, "New Folder" });
                                    std.Io.Dir.createDirAbsolute(dvui.io, new_folder_path, .default_dir) catch dvui.log.err("Failed to create folder: {s}", .{new_folder_path});
                                },
                                .file => {
                                    const new_folder_path = try std.fs.path.join(dvui.currentWindow().arena(), &.{ entry_dir, "New Folder" });
                                    std.Io.Dir.createDirAbsolute(dvui.io, new_folder_path, .default_dir) catch dvui.log.err("Failed to create folder: {s}", .{new_folder_path});
                                },
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
                                for (top) |del_path| deletePath(del_path);
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
                            var caret_slot = wdvui.treeRowGlyph(@src(), .{});
                            caret_slot.deinit();
                        }

                        // The plugin that owns this file type draws its own icon (see
                        // `Host.registerFileIcon`); the workbench only falls back to generic
                        // filesystem icons when no plugin claims it. A plugin's icon is arbitrary
                        // art at an arbitrary aspect ratio, so it is boxed to the shared row-glyph
                        // size like every other glyph rather than being trusted to behave.
                        {
                            var icon_slot = wdvui.treeRowGlyph(@src(), .{ .margin = .{ .w = 2 } });
                            defer icon_slot.deinit();

                            if (!runtime.host().drawFileIcon(std.fs.path.extension(entry.name), abs_path, icon_color)) {
                                const icon = switch (ext) {
                                    .pdf => icons.tvg.entypo.@"doc-text",
                                    .tar, ._7z, .zip => icons.tvg.entypo.archive,
                                    else => icons.tvg.entypo.archive,
                                };
                                dvui.icon(
                                    @src(),
                                    "FileIcon",
                                    icon,
                                    .{ .stroke_color = icon_color, .fill_color = icon_color },
                                    wdvui.treeRowIconOptions(.{}),
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
                                wdvui.bubbleSpinner(@src(), .{
                                    .id_extra = inner_id_extra.* +% 4001,
                                    .expand = .none,
                                    .min_size_content = .{ .w = 14, .h = 14 },
                                    .gravity_x = 1.0,
                                    .gravity_y = 0.5,
                                    .color_text = dvui.themeGet().color(.window, .text),
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
                                var caret_slot = wdvui.treeRowGlyph(@src(), .{});
                                defer caret_slot.deinit();
                                _ = dvui.icon(
                                    @src(),
                                    "DropIcon",
                                    if (branch.expanded) icons.tvg.entypo.@"down-open" else icons.tvg.entypo.@"right-open",
                                    .{
                                        .fill_color = icon_color,
                                        .stroke_color = icon_color,
                                    },
                                    wdvui.treeRowIconOptions(.{}),
                                );
                            }

                            {
                                var icon_slot = wdvui.treeRowGlyph(@src(), .{ .margin = .{ .w = 2 } });
                                defer icon_slot.deinit();
                                _ = dvui.icon(
                                    @src(),
                                    "FolderIcon",
                                    icons.tvg.entypo.folder,
                                    .{
                                        .fill_color = icon_color,
                                        .stroke_color = icon_color,
                                    },
                                    wdvui.treeRowIconOptions(.{}),
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
                            //.color_border = color.opacity(t),
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
        const ranked = rankedFilterRows(root_directory, outer_filter_text);
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
fn applyFileClick(id: usize, path: []const u8, mode: wdvui.TreeSelection.ClickMode) void {
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
    const listing = listDir(directory) orelse return;
    for (listing.entries) |e| {
        const abs = std.fs.path.join(arena, &.{ directory, e.name }) catch continue;
        const branch_id = tree_id.update(abs);
        out.append(arena, .{ .id = branch_id.asUsize(), .path = abs }) catch return;
        if (e.kind == .directory and runtime.host().explorerBranchIsOpen(branch_id)) {
            appendRowOrder(arena, tree_id, abs, out);
        }
    }
}

fn flushPendingFileShiftRange(
    root_directory: []const u8,
    tree: *wdvui.TreeWidget,
    ranked: ?[]const SimpleEntry,
) void {
    const p = pending_file_shift_range orelse return;
    pending_file_shift_range = null;

    const arena = dvui.currentWindow().arena();
    var rows: std.ArrayListUnmanaged(FileVisRow) = .empty;

    if (ranked) |list| {
        // A filter is active: row order is the ranked list, not the tree.
        for (list) |e| {
            const abs = std.fs.path.join(arena, &.{ e.dir orelse root_directory, e.name }) catch continue;
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
fn detectClickMode(rect: dvui.Rect.Physical) wdvui.TreeSelection.ClickMode {
    var mode: wdvui.TreeSelection.ClickMode = .replace;
    for (dvui.events()) |*e| {
        if (e.evt != .mouse) continue;
        const me = e.evt.mouse;
        if (me.action != .release or !me.button.pointer()) continue;
        if (!rect.contains(me.p)) continue;
        mode = wdvui.TreeSelection.clickModeFromMod(me.mod);
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
    const io = dvui.io;
    var d = std.Io.Dir.openDirAbsolute(io, abs, .{}) catch return false;
    d.close(io);
    return true;
}

/// True when some registered plugin claims this file extension (not directories).
fn openablePath(abs_path: []const u8) bool {
    if (pathIsDirAbsolute(abs_path)) return false;
    return runtime.host().pluginForExtension(std.fs.path.extension(abs_path)) != null;
}

fn appendOpenableFilesInTree(arena: std.mem.Allocator, root_abs: []const u8, out: *std.ArrayListUnmanaged([]const u8)) !void {
    const io = dvui.io;
    var dir = std.Io.Dir.openDirAbsolute(io, root_abs, .{ .iterate = true }) catch |err| {
        dvui.log.err("Failed to open directory for open: {s} ({any})", .{ root_abs, err });
        return;
    };
    defer dir.close(io);
    var walker = try dir.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const full = try std.fs.path.join(arena, &.{ root_abs, entry.path });
        if (!openablePath(full)) continue;
        try out.append(arena, try arena.dupe(u8, full));
    }
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
fn applyFileMove(unique_id: dvui.Id, tree: *wdvui.TreeWidget, target_dir: []const u8) !void {
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
            _ = try moveOnePath(p, target_dir, arena);
        }

        // Rebuild the selection map from the new paths on disk.
        selectionFreeAll();
        selected_id = null;
        for (paths.items) |old_path| {
            const base = std.fs.path.basename(old_path);
            const new_path = std.fs.path.join(arena, &.{ target_dir, base }) catch continue;
            std.Io.Dir.accessAbsolute(dvui.io, new_path, .{}) catch continue;
            const new_id = dvui.Id.update(tree.data().id, new_path).asUsize();
            selectionPut(new_id, new_path);
            selected_id = new_id;
        }
        selection_anchor = selected_id;
    } else if (primary_path_opt) |removed_path| {
        _ = try moveOnePath(removed_path, target_dir, arena);
    }

    dvui.dataRemove(null, unique_id, "removed_path");
}

pub fn moveOnePath(source_path: []const u8, target_dir: []const u8, arena: std.mem.Allocator) !bool {
    const base = std.fs.path.basename(source_path);
    const new_path = try std.fs.path.join(arena, &.{ target_dir, base });
    if (std.mem.eql(u8, source_path, new_path)) return false;

    std.Io.Dir.renameAbsolute(source_path, new_path, dvui.io) catch {
        dvui.log.err("Failed to move {s} to {s}", .{ source_path, new_path });
        return false;
    };
    invalidateAfterDiskChange();

    if (runtime.host().docFromPath(source_path)) |doc| {
        doc.owner.setDocumentPath(doc, new_path) catch {
            dvui.log.err("Failed to duplicate path: {s}", .{new_path});
            return error.FailedToDuplicatePath;
        };
    }
    return true;
}

// ---- workbench-api file-tree operations -------------------------------------
// The functions below are the disk-mutating primitives behind both the explorer's
// inline actions (rename/delete above) and the `workbench-api` Host service. They
// keep any matching open document's `path` field in sync so tabs don't dangle.

/// Rename `full_path` to `new_path`. A directory rename rewrites the `path` of
/// every open document beneath it; a file rename rewrites that document. Logs and
/// continues on a filesystem failure (matches the explorer's inline behavior).
pub fn renamePath(full_path: []const u8, new_path: []const u8, kind: std.Io.File.Kind) !void {
    invalidateAfterDiskChange();
    switch (kind) {
        .directory => {
            std.Io.Dir.renameAbsolute(full_path, new_path, dvui.io) catch dvui.log.err("Failed to rename folder: {s} to {s}", .{ std.fs.path.basename(full_path), std.fs.path.basename(new_path) });

            var di: usize = 0;
            while (di < runtime.host().openDocCount()) : (di += 1) {
                const doc = runtime.host().docByIndex(di) orelse continue;
                const path = doc.owner.documentPath(doc);
                if (std.mem.containsAtLeast(u8, path, 1, full_path)) {
                    const file_name = dvui.currentWindow().arena().dupe(u8, std.fs.path.basename(path)) catch "Failed to duplicate path";
                    const new_full = try std.fs.path.join(runtime.allocator(), &.{ new_path, file_name });
                    doc.owner.setDocumentPath(doc, new_full) catch {
                        dvui.log.err("Failed to update open document path", .{});
                    };
                }
            }
        },
        .file => {
            std.Io.Dir.renameAbsolute(full_path, new_path, dvui.io) catch dvui.log.err("Failed to rename file: {s} to {s}", .{ std.fs.path.basename(full_path), std.fs.path.basename(new_path) });

            if (runtime.host().docFromPath(full_path)) |doc| {
                doc.owner.setDocumentPath(doc, new_path) catch {
                    dvui.log.err("Failed to duplicate path: {s}", .{new_path});
                    return error.FailedToDuplicatePath;
                };
            }
        },
        else => {},
    }
}

/// Delete `path` from disk (a directory must be empty — mirrors the explorer's
/// inline Delete). Logs and continues on failure.
pub fn deletePath(path: []const u8) void {
    invalidateAfterDiskChange();
    if (pathIsDirAbsolute(path)) {
        std.Io.Dir.deleteDirAbsolute(dvui.io, path) catch dvui.log.err("Failed to delete folder: {s}", .{path});
    } else {
        std.Io.Dir.deleteFileAbsolute(dvui.io, path) catch dvui.log.err("Failed to delete file: {s}", .{path});
    }
}

/// Create an empty file at absolute `path`.
pub fn createFilePath(path: []const u8) !void {
    invalidateAfterDiskChange();
    var handle = try std.Io.Dir.createFileAbsolute(dvui.io, path, .{});
    handle.close(dvui.io);
}

/// Create a directory at absolute `path` (parents must already exist).
pub fn createDirPath(path: []const u8) !void {
    invalidateAfterDiskChange();
    try std.Io.Dir.createDirAbsolute(dvui.io, path, .default_dir);
}

/// Remove stale selections whose underlying file no longer exists (e.g. moved by a multi-drag).
pub fn pruneMissingSelections() void {
    var i: usize = 0;
    while (i < selected_paths.count()) {
        const entry = selected_paths.entries.get(i);
        std.Io.Dir.accessAbsolute(dvui.io, entry.value, .{}) catch {
            const removed = selected_paths.fetchSwapRemove(entry.key) orelse {
                i += 1;
                continue;
            };
            if (selected_id == removed.key) selected_id = null;
            runtime.allocator().free(removed.value);
            continue;
        };
        i += 1;
    }
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
