//! `layout.zon`: the window frame plus one entry per region a shape named — how wide the user
//! left it, what they chose to show in it — and the live seed-tree snapshot. Read and written
//! whole through `core.fs`, so the desktop keeps it in the config directory and the web keeps
//! it in `localStorage` under the same path; both backends re-export what is here.
//!
//! Two independent writers touch this same file — the macOS-only geometry save (at shutdown)
//! and the cross-platform region save (debounced) — so every writer read-modify-writes
//! (`loadWindowFile`, then override only its own fields) rather than overwriting the whole file.
const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const core = @import("core");

const is_wasm = builtin.target.cpu.arch == .wasm32;

/// `readFileAlloc` with the size cap, through the seam.
fn readCapped(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    const data = try core.fs.read(gpa, dvui.io, path);
    if (data.len > max_layout_file) {
        gpa.free(data);
        return error.FileTooBig;
    }
    return data;
}

/// One region as `layout.zon` remembers it, by the name its shape declared: how wide or tall
/// the user left it, and what they chose to show in it. Either half may be absent — a region
/// dragged but never assigned, or assigned but never dragged.
///
/// Replaced the hardcoded `explorer_ratio` / `panel_ratio` pair, which named the two regions fizzy
/// happens to have — so an app with a "Stack" and a "Strip" could persist nothing, and fizzy's own
/// furniture was baked into a framework's on-disk format.
pub const SavedRegion = struct {
    name: []const u8,
    /// Points along the region's own axis: width under a horizontal parent, height under a
    /// vertical one. One number, because a region only ever divides its parent one way.
    extent: ?f32 = null,
    /// Surface ids the user assigned, in their order. `null` is "never chose" — the region's
    /// keywords decide — and an empty list is a region emptied on purpose.
    surfaces: ?[]const []const u8 = null,
    /// Runtime split: this leaf was dragged out of `parent` from `from` (left/right/top/bottom).
    parent: ?[]const u8 = null,
    from: ?[]const u8 = null,
    /// User override of Single vs Multiple. Null means the shape's default.
    shows: ?SavedShows = null,
};

pub const SavedShows = enum { one, many };

pub const SavedFrame = struct {
    x: f64 = 0,
    y: f64 = 0,
    w: f64 = 0,
    h: f64 = 0,
    regions: []const SavedRegion = &.{},
    /// Live seed-tree arrangement (`DockLayout.snapshot`). Absent in files written before
    /// the seed form, and while a shape still declares regions by call order.
    tree: ?core.widgets.DockLayout.Snapshot = null,
};
const layout_file = "layout.zon";
/// Geometry plus a line or two per region; far more than this is a corrupt file, not a layout.
const max_layout_file: usize = 64 * 1024;
/// What `layout.zon` used to be called, read once as a fallback so an existing install keeps its
/// window position. It only ever held geometry plus two hardcoded region ratios; the name stopped
/// fitting when regions became something a shape names for itself.
const legacy_window_file = "window.zon";

fn windowFilePath(buf: []u8, dir: []const u8, name: []const u8) ?[:0]const u8 {
    const sep = std.fs.path.sep_str;
    if (std.mem.endsWith(u8, dir, sep)) {
        return std.fmt.bufPrintZ(buf, "{s}{s}", .{ dir, name }) catch null;
    }
    return std.fmt.bufPrintZ(buf, "{s}{s}{s}", .{ dir, sep, name }) catch null;
}

/// Reads every field of `window.zon`, falling back to `SavedFrame`'s own defaults for whatever
/// is missing or unparseable (never null — simplifies every caller, which only cares about the
/// subset of fields it owns).
/// Reads `window.zon` into `gpa`-owned memory. Free with `std.zon.parse.free(gpa, frame)` — the
/// region list holds allocated names now, so the old return-by-value-and-forget will not do.
pub fn loadWindowFile(gpa: std.mem.Allocator, dir: []const u8) SavedFrame {
    var path_buf: [1024]u8 = undefined;
    const path = windowFilePath(&path_buf, dir, layout_file) orelse return .{};
    const data = readCapped(gpa, path) catch blk: {
        // Fall back to the old name once, so an existing install keeps its window position.
        var legacy_buf: [1024]u8 = undefined;
        const legacy = windowFilePath(&legacy_buf, dir, legacy_window_file) orelse return .{};
        break :blk readCapped(gpa, legacy) catch return .{};
    };
    defer gpa.free(data);
    const data_z = gpa.dupeZ(u8, data) catch return .{};
    defer gpa.free(data_z);
    // `fromSliceAlloc`, not `fromSlice`: the region list holds allocated names, and `fromSlice`
    // asserts at comptime that the result contains no pointers.
    return std.zon.parse.fromSliceAlloc(
        SavedFrame,
        gpa,
        data_z,
        null,
        .{ .ignore_unknown_fields = true },
    ) catch .{};
}

pub fn writeWindowFile(dir: []const u8, f: SavedFrame) void {
    var path_buf: [1024]u8 = undefined;
    const path = windowFilePath(&path_buf, dir, layout_file) orelse return;
    var aw = std.Io.Writer.Allocating.init(std.heap.page_allocator);
    defer aw.deinit();
    std.zon.stringify.serializeMaxDepth(f, .{}, &aw.writer, 64) catch return;
    if (comptime !is_wasm) std.Io.Dir.createDirAbsolute(dvui.io, dir, .default_dir) catch {};
    core.fs.write(dvui.io, path, aw.written()) catch {
        std.log.err("failed to write layout.zon", .{});
    };
}

/// Read-modify-write: preserves whatever frame geometry is already on disk, overrides only the
/// explorer/panel split ratios. Cross-platform (called from `Editor`'s debounced autosave on
/// every OS, not just macOS).
/// Read-modify-write: keeps whatever frame geometry is on disk, replaces the region list.
pub fn saveRegions(dir: []const u8, regions: []const SavedRegion) void {
    const gpa = std.heap.page_allocator;
    var f = loadWindowFile(gpa, dir);
    defer std.zon.parse.free(gpa, f);
    const keep = f.regions;
    f.regions = regions;
    writeWindowFile(dir, f);
    f.regions = keep;
}

/// Read-modify-write: keeps frame geometry and the region list, replaces the seed-tree snapshot.
/// Pass `null` to clear it (Reset Layout). Shapes that never call `Layout.tree` should not call
/// this, so an existing tree on disk is left alone.
pub fn saveTree(dir: []const u8, tree: ?core.widgets.DockLayout.Snapshot) void {
    const gpa = std.heap.page_allocator;
    var f = loadWindowFile(gpa, dir);
    defer std.zon.parse.free(gpa, f);
    const keep = f.tree;
    f.tree = tree;
    writeWindowFile(dir, f);
    f.tree = keep;
}

/// The saved seed-tree, rebuilt as a live `DockLayout`, or null when the file has none.
/// Caller owns the result (`DockLayout.deinit`).
pub fn loadTree(gpa: std.mem.Allocator, dir: []const u8) ?core.widgets.DockLayout {
    const f = loadWindowFile(gpa, dir);
    defer std.zon.parse.free(gpa, f);
    const snap = f.tree orelse return null;
    var dock = core.widgets.DockLayout.fromSnapshot(gpa, snap) catch return null;
    dock.animated = true;
    return dock;
}

/// Every region `layout.zon` remembers, in `gpa`-owned memory. Call once at startup; free with
/// `freeRegions`.
pub fn loadRegions(gpa: std.mem.Allocator, dir: []const u8) []SavedRegion {
    const f = loadWindowFile(gpa, dir);
    defer std.zon.parse.free(gpa, f);
    const out = gpa.alloc(SavedRegion, f.regions.len) catch return &.{};
    var n: usize = 0;
    for (f.regions) |r| {
        const name = gpa.dupe(u8, r.name) catch continue;
        var surfaces: ?[]const []const u8 = null;
        if (r.surfaces) |ids| {
            const owned = gpa.alloc([]const u8, ids.len) catch {
                gpa.free(name);
                continue;
            };
            var m: usize = 0;
            while (m < ids.len) : (m += 1) {
                owned[m] = gpa.dupe(u8, ids[m]) catch break;
            }
            if (m < ids.len) { // partial: drop the whole region rather than keep half a list
                for (owned[0..m]) |id| gpa.free(id);
                gpa.free(owned);
                gpa.free(name);
                continue;
            }
            surfaces = owned;
        }
        const parent = if (r.parent) |p| gpa.dupe(u8, p) catch null else null;
        const from = if (r.from) |s| gpa.dupe(u8, s) catch null else null;
        out[n] = .{ .name = name, .extent = r.extent, .surfaces = surfaces, .parent = parent, .from = from, .shows = r.shows };
        n += 1;
    }
    return out[0..n];
}

pub fn freeRegions(gpa: std.mem.Allocator, regions: []SavedRegion) void {
    for (regions) |r| {
        gpa.free(r.name);
        if (r.surfaces) |ids| {
            for (ids) |id| gpa.free(id);
            gpa.free(ids);
        }
        if (r.parent) |p| gpa.free(p);
        if (r.from) |s| gpa.free(s);
    }
    gpa.free(regions);
}

