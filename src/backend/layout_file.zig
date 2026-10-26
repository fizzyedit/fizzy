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
    /// That split is fizzy's own, not the person's (`Branch.adaptive`): it follows its space's
    /// shape and turns with it. Absent is the person's, as every split of an older file is.
    adaptive: ?bool = null,
    /// What a fizzy before tabs-when-many wrote: whether the place showed one view or several.
    /// Read only to migrate (`loadRegions`), never written: a place now shows tabs exactly when
    /// it holds more than one view.
    shows: ?SavedShows = null,
    /// The order the user dragged this place's views into. Sorts only — which views the place
    /// holds is `surfaces` (or its keywords); views not named here follow in their usual order.
    order: ?[]const []const u8 = null,
    /// A float's place (`app/layout/Floats.zig`): where its window is and what it floated out of.
    /// Absent for every place a shape declares. A fizzy too old to know it reads past it, and the
    /// view goes back where its keywords put it — the place it names is never declared there.
    floating: ?Floating = null,

    pub const Floating = struct {
        /// The window, in points from the main window's top left.
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        /// Bottom to top among the floats.
        z: u16 = 0,
        /// The place it floated out of, where closing it sends its views.
        home: []const u8 = "",
    };
};

pub const SavedShows = enum { one, many };

pub const SavedFrame = struct {
    x: f64 = 0,
    y: f64 = 0,
    w: f64 = 0,
    h: f64 = 0,
    /// Left maximized (Windows, where `x`…`h` are the restored rect it maximizes from).
    maximized: bool = false,
    regions: []const SavedRegion = &.{},
    /// Live seed-tree arrangement (`DockLayout.snapshot`). Absent in files written before
    /// the seed form, and while a shape still declares regions by call order.
    tree: ?core.widgets.DockLayout.Snapshot = null,
    /// The arrangement of every shape after the first, by its key (`Layout.State.shape`). The
    /// first shape's stays in `regions` and `tree` above, so a file written before shapes had
    /// keys reads as it always did, and one written now reads in a fizzy that has none.
    shapes: []const SavedShape = &.{},
};

/// What one shape keeps in `layout.zon`: its places and its seed tree.
pub const SavedShape = struct {
    key: []const u8,
    regions: []const SavedRegion = &.{},
    tree: ?core.widgets.DockLayout.Snapshot = null,
};

fn shapeOf(f: SavedFrame, key: []const u8) ?SavedShape {
    if (key.len == 0) return .{ .key = "", .regions = f.regions, .tree = f.tree };
    for (f.shapes) |s| if (std.mem.eql(u8, s.key, key)) return s;
    return null;
}

/// Put `s` in `f` under its key, in `arena` memory for a shape of its own.
fn setShape(arena: std.mem.Allocator, f: *SavedFrame, s: SavedShape) !void {
    if (s.key.len == 0) {
        f.regions = s.regions;
        f.tree = s.tree;
        return;
    }
    const grown = try arena.alloc(SavedShape, f.shapes.len + 1);
    var n: usize = 0;
    for (f.shapes) |other| {
        if (std.mem.eql(u8, other.key, s.key)) continue;
        grown[n] = other;
        n += 1;
    }
    grown[n] = s;
    f.shapes = grown[0 .. n + 1];
}
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
        return std.mem.printSentinel(buf, "{s}{s}", .{ dir, name }, 0) catch null;
    }
    return std.mem.printSentinel(buf, "{s}{s}{s}", .{ dir, sep, name }, 0) catch null;
}

/// Reads every field of `window.zon`, falling back to `SavedFrame`'s own defaults for whatever
/// is missing or unparseable (never null — simplifies every caller, which only cares about the
/// subset of fields it owns).
/// Reads `window.zon` into `arena` (the region list holds allocated names); `gpa` is scratch.
pub fn loadWindowFile(gpa: std.mem.Allocator, arena: std.mem.Allocator, dir: []const u8) SavedFrame {
    var path_buf: [1024]u8 = undefined;
    const path = windowFilePath(&path_buf, dir, layout_file) orelse return .{};
    const data = readCapped(gpa, path) catch blk: {
        // Fall back to the old name once, so an existing install keeps its window position.
        var legacy_buf: [1024]u8 = undefined;
        const legacy = windowFilePath(&legacy_buf, dir, legacy_window_file) orelse return .{};
        break :blk readCapped(gpa, legacy) catch return .{};
    };
    defer gpa.free(data);
    const data_z = gpa.dupeSentinel(u8, data, 0) catch return .{};
    defer gpa.free(data_z);
    var diag: std.zon.parse.Diagnostics = undefined;
    return std.zon.parse.fromSlice(SavedFrame, .{
        .gpa = gpa,
        .arena = arena,
        .source = data_z,
        .diagnostics = &diag,
        .ignore_unknown_fields = true,
    }) catch .{};
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

/// Read-modify-write: keeps frame geometry and every other shape's arrangement, replaces the
/// region list of `shape` (`Layout.State.shape`). Cross-platform (called from `Editor`'s debounced
/// autosave on every OS, not just macOS).
pub fn saveRegions(dir: []const u8, shape: []const u8, regions: []const SavedRegion) void {
    const gpa = std.heap.page_allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var f = loadWindowFile(gpa, arena.allocator(), dir);
    var mine = shapeOf(f, shape) orelse SavedShape{ .key = shape };
    mine.regions = regions;
    setShape(arena.allocator(), &f, mine) catch return;
    writeWindowFile(dir, f);
}

/// Read-modify-write: keeps frame geometry and the region lists, replaces the seed-tree snapshot
/// of `shape`. Pass `null` to clear it (Reset Layout). Shapes that never call `Layout.tree` should
/// not call this, so an existing tree on disk is left alone.
pub fn saveTree(dir: []const u8, shape: []const u8, tree: ?core.widgets.DockLayout.Snapshot) void {
    const gpa = std.heap.page_allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var f = loadWindowFile(gpa, arena.allocator(), dir);
    var mine = shapeOf(f, shape) orelse SavedShape{ .key = shape };
    mine.tree = tree;
    setShape(arena.allocator(), &f, mine) catch return;
    writeWindowFile(dir, f);
}

/// The saved seed-tree of `shape`, rebuilt as a live `DockLayout`, or null when the file has none.
/// Caller owns the result (`DockLayout.deinit`).
pub fn loadTree(gpa: std.mem.Allocator, dir: []const u8, shape: []const u8) ?core.widgets.DockLayout {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const f = loadWindowFile(gpa, arena.allocator(), dir);
    const snap = (shapeOf(f, shape) orelse return null).tree orelse return null;
    var dock = core.widgets.DockLayout.fromSnapshot(gpa, snap) catch return null;
    dock.animated = true;
    return dock;
}

/// Every region `layout.zon` remembers for `shape`, in `gpa`-owned memory. Call at startup and
/// when the shape changes; free with `freeRegions`.
pub fn loadRegions(gpa: std.mem.Allocator, dir: []const u8, shape: []const u8) []SavedRegion {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const f = loadWindowFile(gpa, arena.allocator(), dir);
    const saved = (shapeOf(f, shape) orelse return &.{}).regions;
    const out = gpa.alloc(SavedRegion, saved.len) catch return &.{};
    var n: usize = 0;
    for (saved) |r| {
        const name = gpa.dupe(u8, r.name) catch continue;
        var surfaces: ?[]const []const u8 = null;
        if (r.surfaces) |all| {
            // A place that showed one view (`shows`, from an older fizzy) shows what it showed:
            // holding several now means tabs, so it keeps only the first.
            const ids = if (r.shows == .one and all.len > 1) all[0..1] else all;
            // Partial: drop the whole region rather than keep half a list.
            surfaces = dupeIds(gpa, ids) orelse {
                gpa.free(name);
                continue;
            };
        }
        // An order that fails to copy is only a lost preference; the region keeps the rest.
        const order: ?[]const []const u8 = if (r.order) |ids| dupeIds(gpa, ids) else null;
        const parent = if (r.parent) |p| gpa.dupe(u8, p) catch null else null;
        const from = if (r.from) |s| gpa.dupe(u8, s) catch null else null;
        // A float whose home fails to copy floats still; closed, its view goes to its keywords.
        var floating = r.floating;
        if (floating) |*fl| fl.home = gpa.dupe(u8, fl.home) catch "";
        out[n] = .{
            .name = name,
            .extent = r.extent,
            .surfaces = surfaces,
            .parent = parent,
            .from = from,
            .order = order,
            .floating = floating,
        };
        n += 1;
    }
    return out[0..n];
}

/// `ids`, every string copied into `gpa`; null when any copy fails (nothing is leaked).
fn dupeIds(gpa: std.mem.Allocator, ids: []const []const u8) ?[]const []const u8 {
    const owned = gpa.alloc([]const u8, ids.len) catch return null;
    var m: usize = 0;
    while (m < ids.len) : (m += 1) {
        owned[m] = gpa.dupe(u8, ids[m]) catch break;
    }
    if (m < ids.len) {
        for (owned[0..m]) |id| gpa.free(id);
        gpa.free(owned);
        return null;
    }
    return owned;
}

pub fn freeRegions(gpa: std.mem.Allocator, regions: []SavedRegion) void {
    for (regions) |r| {
        gpa.free(r.name);
        if (r.surfaces) |ids| {
            for (ids) |id| gpa.free(id);
            gpa.free(ids);
        }
        if (r.order) |ids| {
            for (ids) |id| gpa.free(id);
            gpa.free(ids);
        }
        if (r.parent) |p| gpa.free(p);
        if (r.from) |s| gpa.free(s);
        if (r.floating) |fl| if (fl.home.len > 0) gpa.free(fl.home);
    }
    gpa.free(regions);
}
