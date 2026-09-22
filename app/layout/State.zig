//! The application's layout *state*: what each region shows, the regions this frame declared,
//! and every region's remembered extent.
//!
//! `Layout.State`, because `Layout` is the thing a shape declares regions *with* and this is
//! what persists behind it between frames. The field on the app is `layout`.
//!
//! Grouped rather than spread across the application state because the boundary matters: this
//! is framework, and the chrome beside it (explorer, sidebar, panes) is fizzy's own. Seventy-five
//! flat fields made that invisible.
const std = @import("std");
const dvui = @import("dvui");
const core = @import("core");
const sdk = @import("fizzy_sdk");
const Region = @import("Region.zig");
const Picker = @import("Picker.zig");
const Seed = @import("Seed.zig");
pub const SplitTree = @import("SplitTree.zig");

const State = @This();

/// A rendered picture of a surface as it last drew, for the picker's cards. Taken by `Layout`
/// on request (`snapshots_wanted`), one per surface per request, never on an ordinary frame.
pub const Snapshot = struct {
    texture: dvui.Texture,
    /// The size it was drawn at, in points — the aspect the card should keep.
    natural: dvui.Size,
};

/// A view being carried from one place to another — see `ViewDrag.zig`.
pub const ViewDrag = @import("ViewDrag.zig");

/// What the picker needs from a plugin store without importing one. The store's module graph
/// reaches `app.zig`, which owns this file, so a direct import is a cycle.
pub const StoreOffer = struct {
    id: []const u8,
    title: []const u8,
};

pub const StoreCatalog = struct {
    uninstalled: *const fn (arena: std.mem.Allocator) []const StoreOffer,
    install: *const fn (id: []const u8) void,
    installing: *const fn (id: []const u8) bool,
};

/// Shell (new-layout) selection state: keyword-group hash -> selected surface id.
/// Surface ids are registry-owned string literals, so this stores no allocations of its own.
/// Keyed by group rather than by region so two regions written with the same keywords share a
/// selection with no wiring between them (see `layout/Layout.zig`).
selection: std.AutoHashMapUnmanaged(u64, []const u8) = .empty,
/// What a region shows, by the name its shape declared — the user's answer to "what goes
/// *here*", which overrides keyword matching wholesale for that region. An entry with no
/// surfaces is a region the user deliberately emptied; a region with no entry shows whatever
/// its keywords attract, which is every region's starting state.
///
/// Region-centric rather than surface-centric on purpose. A plugin's keywords are its guess at
/// the *kind* of place a surface belongs, and the person who can see the layout is the one who
/// knows where it actually goes. Keying by region also says two things a per-surface override
/// never could: the same surface in two regions, and a region left empty on purpose.
///
/// Keys and every id are gpa-owned; surface ids are duplicated rather than borrowed so an
/// assignment to a plugin that is not currently loaded survives until it is.
assignments: std.StringHashMapUnmanaged([]const []const u8) = .empty,
/// User override of how many surfaces a place can show. Absent means the
/// shape's `shows` (Sidebar/Panel are `.many`; a leftover leaf is `.one`).
shows: std.StringHashMapUnmanaged(Region.Shows) = .empty,
/// Surface id → its snapshot. Keys are gpa-owned copies: a surface can unregister (plugin
/// unloaded) while the picker is open.
snapshots: std.StringHashMapUnmanaged(Snapshot) = .empty,
/// While true, `Layout.draw` captures any surface it draws that has no snapshot yet, and
/// `Layout.captureUnplaced` draws the rest offscreen once. Set by `openPicker`.
snapshots_wanted: bool = false,
/// The one surface picker, if open. On the state rather than in whichever pane opened it so the
/// settings table and a region's corner button open the same thing, and the app draws it in
/// one place above everything else (`Picker.draw`).
picker: Picker = .{},
/// Filled in by the application when it has a plugin store. Null means the picker only lists
/// loaded surfaces — tests, and an app that never switched the store on.
store_catalog: ?StoreCatalog = null,
/// Region waiting for a store install to finish so its new surfaces can be assigned. Empty
/// while nothing is pending. gpa-owned.
pending_store_region: []const u8 = "",
pending_store_plugin: []const u8 = "",

/// Regions the last completed shape declared — what `Editor.regionFor` answers from.
///
/// Deliberately the *previous* frame's set rather than the one being built: a command can run
/// between frames (a native menu item is dispatched before the shape has drawn anything), and a
/// command that drives a region — Toggle Explorer, Toggle Panel — must find one. Reading a
/// half-built list gave it nothing, and the toggle silently did half its job: the menu title
/// flipped, because that reads a bool, and the sidebar never moved.
///
/// Answering from last frame is correct rather than merely convenient: a region's id comes from
/// its shape's `@src()`, so it is the same id this frame will declare. The one case it cannot
/// help is a command dispatched before the *first* shape has ever run — there is genuinely no
/// region yet — which is why this is a swap rather than a claim that ordering no longer matters.
regions: std.ArrayListUnmanaged(Region) = .empty,
/// The set the shape currently running is declaring. Swapped into `regions` when it finishes.
regions_building: std.ArrayListUnmanaged(Region) = .empty,
/// Every region's remembered extent in **points** — width under a horizontal parent, height
/// under a vertical one — by the name its shape declared, loaded from
/// `layout.zon` at startup and written back debounced.
///
/// Replaces `explorer_ratio` / `panel_ratio`, which named the two regions fizzy happens to have —
/// so an app with a "Stack" and a "Strip" could persist nothing, and fizzy's own furniture was
/// baked into a framework's on-disk format. Those two survive only for the legacy shell.
extents: std.StringHashMapUnmanaged(f32) = .empty,
/// Runtime subdivisions of a shape-declared place. A name not in here is still a leaf.
splits: SplitTree.Forest = .{},
/// Live seed-tree layout, when the shape called `Layout.tree`. Null for shapes that still
/// declare regions by call order.
dock: ?core.widgets.DockLayout = null,
/// Loaded from `layout.zon` at startup; `ensureDock` takes it on the first `Layout.tree`.
pending_dock: ?core.widgets.DockLayout = null,
/// Reset Layout cleared the tree: the next save writes `tree = null` rather than keeping
/// whatever is on disk.
tree_cleared: bool = false,
/// New leaf that should ease open this frame. Interned; empty when none.
slide_open: []const u8 = "",
/// Where that ease starts, 0..1 of the leaf's target. Zero is a first
/// appearance (picker split). A view-drag that already previewed the
/// split seeds this from the preview so the real pane does not start
/// over from nothing — that restart is the snap after a smooth preview.
slide_open_from: f32 = 0,
/// A place's view being dragged to another place. Empty `name` when idle.
view_drag: ViewDrag = .{},
/// Explorer/panel split ratios — "window shape" state persisted in `window.zon`, not
/// `settings.zon` (dragging a splitter fires every frame; keeping it out of the settings file
/// means normal window use never dirties a git-tracked settings.zon). Loaded once at startup
/// (see `init`); defaults match the pre-move `Settings` field defaults.
/// Debounced-save bookkeeping for the ratios above, separate from `settings_dirty`/
/// `settings_save_deadline_ns` — sidebar/panel dragging must not force a settings.zon write
/// attempt on every drag frame.
dirty: bool = false,
save_deadline_ns: i128 = 0,
/// Id of the center provider drawn last frame, so a swap can look the outgoing one up again by
/// id (never cache the pointer: a plugin can unload between frames). Borrowed from the host's
/// registry entry, which outlives a frame.
center_prev_id: ?[]const u8 = null,
/// Host-owned cross-fade between center providers. See `drawActiveCenter`.
center_transition: core.anim.Transition = .{},
/// Per-place swap overlay, keyed by the region's selection key (or keyword
/// group). Heap-owned so a nested `drawSelected` can grow the map without
/// dangling the outer frame's pointer. GPU textures, so every entry must be
/// `discard`ed on teardown.
swaps: std.AutoHashMapUnmanaged(u64, *core.anim.Transition) = .empty,
/// Keyword sets qualified by the region enclosing theirs, interned. See `qualify`.
qualified: std.ArrayListUnmanaged(Qualified) = .empty,
/// Region names interned. The shape's own names are literals; a plugin's are formatted per
/// frame ("Pane 3") into memory that is gone by the time the registry is read.
names: std.StringHashMapUnmanaged(void) = .empty,

// ---- the app's side of a region ---------------------------------------------------------------
//
// Regions are declared by a shape and driven from outside it — a rail button, a command, a
// keybind. These four are that seam, and they live on the state rather than on the application
// because nothing here is fizzy's: a name, an extent, and the set the last shape declared.

/// The region accepting `keywords`, or null when this app's shape declared none — a normal
/// state, not an error.
///
/// `intersects`, not `accepts`: a caller here holds a *vocabulary* and wants the region that
/// speaks it — Toggle Explorer asks for `ide.sidebar` and must find the sidebar whether the
/// shape declared it qualified or not. Whether a *surface* belongs in a region is the asymmetric
/// question, and that one goes through `accepts`.
pub fn regionFor(self: *State, keywords: []const []const u8) ?Region {
    for (self.regions.items) |entry| {
        if (sdk.keywords.intersects(entry.keywords, keywords)) return entry;
    }
    return null;
}

/// A region's keywords qualified by the region enclosing it: `{"document"}` declared inside the
/// main area becomes `{"main.document"}`. Interned, and stable for as long as the state lives.
///
/// Interned rather than arena-allocated because the registry is read a frame *later* than it is
/// written — `regionFor` answers a command dispatched between frames from the last completed
/// shape, and an arena string would be freed by then. There are as many of these as a shape has
/// nested regions, which is a handful, so the pool is a list and a linear scan.
///
/// On allocation failure the region keeps its unqualified keywords: it then accepts the general
/// kind instead of its own sub-place, which is a shape slightly flatter than the one written
/// rather than a region that accepts nothing.
pub fn qualify(
    self: *State,
    gpa: std.mem.Allocator,
    prefix: []const u8,
    base: []const []const u8,
) []const []const u8 {
    if (prefix.len == 0 or base.len == 0) return base;

    for (self.qualified.items) |q| {
        if (!std.mem.eql(u8, q.prefix, prefix)) continue;
        if (q.words.len != base.len) continue;
        var same = true;
        for (q.base, base) |a, b| same = same and std.mem.eql(u8, a, b);
        if (same) return q.words;
    }

    const entry = buildQualified(gpa, prefix, base) catch |err| {
        dvui.log.err("qualifying {d} keywords under \"{s}\": {any}", .{ base.len, prefix, err });
        return base;
    };
    self.qualified.append(gpa, entry) catch {
        freeQualified(gpa, entry);
        return base;
    };
    return entry.words;
}

/// One interned qualified keyword set. `base` is the shape's own set, kept so the next frame's
/// identical request finds this entry instead of allocating another.
const Qualified = struct {
    prefix: []const u8,
    base: []const []const u8,
    words: []const []const u8,
};

fn buildQualified(gpa: std.mem.Allocator, prefix: []const u8, base: []const []const u8) !Qualified {
    var entry: Qualified = .{ .prefix = "", .base = &.{}, .words = &.{} };
    errdefer freeQualified(gpa, entry);

    entry.prefix = try gpa.dupe(u8, prefix);
    const base_copy = try gpa.alloc([]const u8, base.len);
    entry.base = base_copy;
    for (base_copy) |*w| w.* = "";
    for (base_copy, base) |*dst, src| dst.* = try gpa.dupe(u8, src);

    const words = try gpa.alloc([]const u8, base.len);
    entry.words = words;
    for (words) |*w| w.* = "";
    for (words, base) |*dst, src| {
        // A word that already names a place under this one is left alone: a shape may write the
        // qualified form itself, and qualifying it twice would invent `main.main.document`.
        dst.* = if (std.mem.startsWith(u8, src, prefix) and src.len > prefix.len and src[prefix.len] == '.')
            try gpa.dupe(u8, src)
        else
            try std.fmt.allocPrint(gpa, "{s}.{s}", .{ prefix, src });
    }
    return entry;
}

fn freeQualified(gpa: std.mem.Allocator, entry: Qualified) void {
    if (entry.prefix.len > 0) gpa.free(entry.prefix);
    for (entry.base) |w| if (w.len > 0) gpa.free(w);
    if (entry.base.len > 0) gpa.free(entry.base);
    for (entry.words) |w| if (w.len > 0) gpa.free(w);
    if (entry.words.len > 0) gpa.free(entry.words);
}

pub fn deinitQualified(self: *State, gpa: std.mem.Allocator) void {
    for (self.qualified.items) |q| freeQualified(gpa, q);
    self.qualified.deinit(gpa);
    var it = self.names.keyIterator();
    while (it.next()) |k| gpa.free(k.*);
    self.names.deinit(gpa);
}

/// A copy of `name` that outlives the frame — the registry, the assignment table and the picker
/// all hold a region's name across frames. Same string in, same slice out.
pub fn internName(self: *State, gpa: std.mem.Allocator, name: []const u8) []const u8 {
    if (self.names.getKey(name)) |k| return k;
    const owned = gpa.dupe(u8, name) catch return name;
    self.names.put(gpa, owned, {}) catch {
        gpa.free(owned);
        return name;
    };
    return owned;
}

/// Build or take the live dock tree. First `Layout.tree` (or the one after Reset Layout)
/// converts `seed`; a tree loaded from `layout.zon` wins when present.
pub fn ensureDock(self: *State, gpa: std.mem.Allocator, seed: *const Seed.Tree) !void {
    if (self.dock != null) return;
    if (self.pending_dock) |d| {
        self.dock = d;
        self.pending_dock = null;
        return;
    }
    self.dock = try seed.toDockLayout(gpa);
}

pub fn deinitDock(self: *State) void {
    if (self.dock) |*d| {
        d.deinit();
        self.dock = null;
    }
    if (self.pending_dock) |*d| {
        d.deinit();
        self.pending_dock = null;
    }
}

pub fn clearDock(self: *State) void {
    self.deinitDock();
    self.tree_cleared = true;
}

/// On the tree, a leaf that has a sibling to collapse into — minted or declared, since a
/// declared place's pin moves to whatever is left. Off the tree, never (the old split forest
/// has its own rule, `isMinted`).
pub fn canRemove(self: *const State, name: []const u8) bool {
    const d = if (self.dock) |*d| d else return false;
    const idx = d.findPanel(name) orelse return false;
    return d.findParent(idx) != null;
}

/// The heir of a closed pinned place takes its name: whatever this state keyed by the heir's
/// old name — its assignment, Single/Multiple, extent — is now the place's, and the closed
/// place's own entries go with it.
pub fn renamePlace(self: *State, gpa: std.mem.Allocator, from: []const u8, to: []const u8) void {
    self.unassign(gpa, to);
    if (self.assignments.fetchRemove(from)) |kv| {
        gpa.free(kv.key);
        self.assign(gpa, to, kv.value) catch {};
        for (kv.value) |id| gpa.free(id);
        gpa.free(kv.value);
    }
    if (self.shows.fetchRemove(from)) |kv| {
        gpa.free(kv.key);
        self.setShows(gpa, to, kv.value);
    } else {
        if (self.shows.fetchRemove(to)) |kv| gpa.free(kv.key);
    }
    _ = self.clearExtent(gpa, to);
    if (self.extents.fetchRemove(from)) |kv| {
        gpa.free(kv.key);
        _ = self.setExtent(gpa, to, kv.value);
    }
    self.markDirty();
}

/// A leaf the user minted (picker Split), not a seed-declared / pinned place.
pub fn isMinted(self: *const State, name: []const u8) bool {
    if (self.dock) |*d| {
        const idx = d.findPanel(name) orelse return false;
        return switch (d.nodes.items[idx]) {
            .leaf => |l| !l.pinned,
            else => false,
        };
    }
    return self.splits.canForget(name);
}

/// Called by `Region.init` as a shape declares one. Lands in the list being built, which
/// `publishRegions` swaps into view when the shape finishes.
pub fn registerRegion(self: *State, gpa: std.mem.Allocator, entry: Region) void {
    var r = entry;
    if (r.name.len > 0) r.shows = self.showsOf(r.name, r.shows);
    self.regions_building.append(gpa, r) catch {};
}

/// The shape has finished declaring: make this frame's regions the ones `regionFor` answers with.
pub fn publishRegions(self: *State) void {
    std.mem.swap(@TypeOf(self.regions), &self.regions, &self.regions_building);
    self.regions_building.clearRetainingCapacity();
}

/// The surfaces the user assigned to region `name`, in the order they chose; null when they never
/// touched it and keyword matching decides.
pub fn assignment(self: *State, name: []const u8) ?[]const []const u8 {
    return self.assignments.get(name);
}

/// Set what region `name` shows. An empty list is a real choice — "nothing here" — distinct from
/// `unassign`, which hands the region back to its keywords. A surface lives in one
/// place: putting it here takes it out of every other assignment.
pub fn assign(self: *State, gpa: std.mem.Allocator, name: []const u8, surfaces: []const []const u8) !void {
    try self.setAssignment(gpa, name, surfaces);
    for (surfaces) |id| self.evictIdFromOthers(gpa, name, id);
}

fn setAssignment(self: *State, gpa: std.mem.Allocator, name: []const u8, surfaces: []const []const u8) !void {
    const owned = try gpa.alloc([]const u8, surfaces.len);
    errdefer gpa.free(owned);
    var n: usize = 0;
    errdefer for (owned[0..n]) |id| gpa.free(id);
    for (surfaces) |id| {
        owned[n] = try gpa.dupe(u8, id);
        n += 1;
    }
    const gop = try self.assignments.getOrPut(gpa, name);
    if (gop.found_existing) {
        for (gop.value_ptr.*) |id| gpa.free(id);
        gpa.free(gop.value_ptr.*);
    } else {
        gop.key_ptr.* = gpa.dupe(u8, name) catch |err| {
            _ = self.assignments.remove(name);
            return err;
        };
    }
    gop.value_ptr.* = owned;
}

fn evictIdFromOthers(self: *State, gpa: std.mem.Allocator, keep: []const u8, id: []const u8) void {
    var names: [32][]const u8 = undefined;
    var n: usize = 0;
    var it = self.assignments.iterator();
    while (it.next()) |e| {
        if (std.mem.eql(u8, e.key_ptr.*, keep)) continue;
        for (e.value_ptr.*) |x| {
            if (!std.mem.eql(u8, x, id)) continue;
            if (n < names.len) {
                names[n] = e.key_ptr.*;
                n += 1;
            }
            break;
        }
    }
    for (names[0..n]) |region| {
        const ids = self.assignment(region) orelse continue;
        var kept: [32][]const u8 = undefined;
        var k: usize = 0;
        for (ids) |x| {
            if (std.mem.eql(u8, x, id)) continue;
            if (k < kept.len) {
                kept[k] = x;
                k += 1;
            }
        }
        self.setAssignment(gpa, region, kept[0..k]) catch {};
    }
}

/// How this place shows surfaces: the user's choice, else the shape's default.
pub fn showsOf(self: *const State, name: []const u8, fallback: Region.Shows) Region.Shows {
    return self.shows.get(name) orelse fallback;
}

/// Remember Single vs Multiple for `name`. Same name interned as assignments.
pub fn setShows(self: *State, gpa: std.mem.Allocator, name: []const u8, value: Region.Shows) void {
    const gop = self.shows.getOrPut(gpa, name) catch return;
    if (gop.found_existing) {
        gop.value_ptr.* = value;
        return;
    }
    gop.key_ptr.* = gpa.dupe(u8, name) catch {
        _ = self.shows.remove(name);
        return;
    };
    gop.value_ptr.* = value;
}

/// Forget the user's choice for region `name`; its keywords decide again.
pub fn unassign(self: *State, gpa: std.mem.Allocator, name: []const u8) void {
    const kv = self.assignments.fetchRemove(name) orelse return;
    gpa.free(kv.key);
    for (kv.value) |id| gpa.free(id);
    gpa.free(kv.value);
}

/// The debounce between a layout change and its write to disk. Long enough that dragging a
/// split does not write every frame; short enough that a crash right after a change loses
/// nothing a user would notice.
pub const save_debounce_ns: i128 = 500 * std.time.ns_per_ms;

/// Something worth persisting changed: an extent, an assignment. The application's frame flushes
/// once the deadline passes (fizzy: `saveWindowRatiosRaw`).
pub fn markDirty(self: *State) void {
    self.dirty = true;
    self.save_deadline_ns = core.perf.nanoTimestamp() + save_debounce_ns;
}

// ---- snapshots and the picker ----------------------------------------------------------------

pub fn snapshot(self: *State, id: []const u8) ?Snapshot {
    return self.snapshots.get(id);
}

/// Record a capture. Replaces (and frees) an older one for the same surface.
pub fn takeSnapshot(self: *State, gpa: std.mem.Allocator, id: []const u8, snap: Snapshot) void {
    const gop = self.snapshots.getOrPut(gpa, id) catch {
        dvui.textureDestroyLater(snap.texture);
        return;
    };
    if (gop.found_existing) {
        dvui.textureDestroyLater(gop.value_ptr.texture);
    } else {
        gop.key_ptr.* = gpa.dupe(u8, id) catch {
            _ = self.snapshots.remove(id);
            dvui.textureDestroyLater(snap.texture);
            return;
        };
    }
    gop.value_ptr.* = snap;
}

/// Take a snapshot out of the set, keeping its texture alive: the caller owns it from here.
/// How a card lifted out of the picker keeps its picture after the picker closes and
/// `discardSnapshots` destroys the rest.
pub fn stealSnapshot(self: *State, gpa: std.mem.Allocator, id: []const u8) ?Snapshot {
    const kv = self.snapshots.fetchRemove(id) orelse return null;
    gpa.free(kv.key);
    return kv.value;
}

/// Drop every snapshot. Textures go at the end of the frame, so a card drawn earlier this frame
/// is unaffected. Must run between `Window.begin` and `Window.end`.
pub fn discardSnapshots(self: *State, gpa: std.mem.Allocator) void {
    var it = self.snapshots.iterator();
    while (it.next()) |e| {
        gpa.free(e.key_ptr.*);
        dvui.textureDestroyLater(e.value_ptr.texture);
    }
    self.snapshots.clearRetainingCapacity();
    self.snapshots_wanted = false;
}

/// Open the picker for region `name`, anchored at `anchor` (or centred when null), and start
/// collecting fresh snapshots. Whatever a previous open captured is stale by now.
pub fn openPicker(self: *State, gpa: std.mem.Allocator, name: []const u8, anchor: ?dvui.Point.Natural) void {
    self.discardSnapshots(gpa);
    self.snapshots_wanted = true;
    self.picker.open(gpa, name, anchor);
}

/// Remember that region `name` should receive plugin `plugin_id`'s surfaces once it loads.
pub fn requestStoreInstall(self: *State, gpa: std.mem.Allocator, name: []const u8, plugin_id: []const u8) void {
    self.clearPendingStore(gpa);
    self.pending_store_region = gpa.dupe(u8, name) catch return;
    self.pending_store_plugin = gpa.dupe(u8, plugin_id) catch {
        gpa.free(self.pending_store_region);
        self.pending_store_region = "";
        return;
    };
}

pub fn clearPendingStore(self: *State, gpa: std.mem.Allocator) void {
    if (self.pending_store_region.len > 0) gpa.free(self.pending_store_region);
    if (self.pending_store_plugin.len > 0) gpa.free(self.pending_store_plugin);
    self.pending_store_region = "";
    self.pending_store_plugin = "";
}

pub fn deinitExtents(self: *State, gpa: std.mem.Allocator) void {
    self.deinitSwaps(gpa);
    var it = self.extents.keyIterator();
    while (it.next()) |k| gpa.free(k.*);
    self.extents.deinit(gpa);
    self.splits.deinit(gpa);
    self.deinitDock();
}

/// Drop every per-place overlay texture. Safe to call twice — the map is
/// emptied. Tests that only tear down extents or assignments both reach here.
pub fn deinitSwaps(self: *State, gpa: std.mem.Allocator) void {
    var it = self.swaps.valueIterator();
    while (it.next()) |t| {
        t.*.discard();
        gpa.destroy(t.*);
    }
    self.swaps.deinit(gpa);
    self.swaps = .{};
}

pub fn discardSwaps(self: *State) void {
    var it = self.swaps.valueIterator();
    while (it.next()) |t| t.*.discard();
}

/// The overlay for this place, created on first use. Null only if the map
/// cannot grow — the caller then draws without a transition.
pub fn swapFor(self: *State, gpa: std.mem.Allocator, key: u64) ?*core.anim.Transition {
    if (self.swaps.get(key)) |t| return t;
    const t = gpa.create(core.anim.Transition) catch return null;
    t.* = .{};
    self.swaps.put(gpa, key, t) catch {
        gpa.destroy(t);
        return null;
    };
    return t;
}

/// Forget every remembered extent, assignment and runtime split. The next frame
/// draws the shape's defaults. Widget `_size` is cleared so a leftover drag
/// does not write itself back.
pub fn resetLayout(self: *State, gpa: std.mem.Allocator) void {
    for (self.regions.items) |r| forgetWidgetSize(r.id);
    for (self.regions_building.items) |r| forgetWidgetSize(r.id);

    var eit = self.extents.keyIterator();
    while (eit.next()) |k| gpa.free(k.*);
    self.extents.clearRetainingCapacity();

    var ait = self.assignments.iterator();
    while (ait.next()) |e| {
        gpa.free(e.key_ptr.*);
        for (e.value_ptr.*) |id| gpa.free(id);
        gpa.free(e.value_ptr.*);
    }
    self.assignments.clearRetainingCapacity();
    forgetShows(self, gpa);

    self.splits.deinit(gpa);
    self.splits = .{};
    self.clearDock();
    self.slide_open = "";
    self.slide_open_from = 0;
    self.view_drag.discard();
    self.discardSwaps();
    self.center_transition.discard();
    self.center_prev_id = null;
}

fn forgetWidgetSize(id: dvui.Id) void {
    if (id == .zero) return;
    dvui.dataRemove(null, id, "_size");
    dvui.dataRemove(null, id, "_shown");
    dvui.dataRemove(null, id, "_ease");
    dvui.dataRemove(null, id, "_open");
    dvui.dataRemove(null, id, "_drag");
    dvui.dataRemove(null, id, "_drag_anchor");
    dvui.dataRemove(null, id, "_chooser");
    dvui.dataRemove(null, id, "_chooser_shown");
    dvui.dataRemove(null, id, "_chooser_press");
}

pub fn setPlaceMetrics(self: *State, name: []const u8, size: dvui.Size, bounds: dvui.Rect.Physical) void {
    var i = self.regions_building.items.len;
    while (i > 0) {
        i -= 1;
        if (!std.mem.eql(u8, self.regions_building.items[i].name, name)) continue;
        self.regions_building.items[i].size = size;
        self.regions_building.items[i].bounds = bounds;
        return;
    }
}

pub fn placeSize(self: *const State, name: []const u8) ?dvui.Size {
    for (self.regions.items) |r| {
        if (std.mem.eql(u8, r.name, name)) return r.size;
    }
    return null;
}

pub fn requestSlideOpen(self: *State, name: []const u8) void {
    self.slide_open = name;
}

pub fn takeSlideOpen(self: *State, name: []const u8) ?f32 {
    if (self.slide_open.len == 0 or !std.mem.eql(u8, self.slide_open, name)) return null;
    self.slide_open = "";
    const from = std.math.clamp(self.slide_open_from, 0, 1);
    self.slide_open_from = 0;
    return from;
}

pub fn deinitAssignments(self: *State, gpa: std.mem.Allocator) void {
    self.deinitSwaps(gpa);
    var it = self.assignments.iterator();
    while (it.next()) |e| {
        gpa.free(e.key_ptr.*);
        for (e.value_ptr.*) |id| gpa.free(id);
        gpa.free(e.value_ptr.*);
    }
    self.assignments.deinit(gpa);
    deinitShows(self, gpa);
}

fn forgetShows(self: *State, gpa: std.mem.Allocator) void {
    var it = self.shows.keyIterator();
    while (it.next()) |k| gpa.free(k.*);
    self.shows.clearRetainingCapacity();
}

fn deinitShows(self: *State, gpa: std.mem.Allocator) void {
    forgetShows(self, gpa);
    self.shows.deinit(gpa);
}

/// The extent a region should start at: what the user last left it, or the shape's default.
pub fn extent(self: *State, name: []const u8, default: f32) f32 {
    return self.extents.get(name) orelse default;
}

/// Forget a region's persisted extent. Returns true when there was one.
pub fn clearExtent(self: *State, gpa: std.mem.Allocator, name: []const u8) bool {
    const kv = self.extents.fetchRemove(name) orelse return false;
    gpa.free(kv.key);
    return true;
}

/// Remember a region's extent. Returns true when the value actually changed, so the application
/// can decide what "remember" means — fizzy debounces a write to `layout.zon`; another app might
/// do nothing at all.
pub fn setExtent(self: *State, gpa: std.mem.Allocator, name: []const u8, value: f32) bool {
    const gop = self.extents.getOrPut(gpa, name) catch return false;
    if (gop.found_existing and gop.value_ptr.* == value) return false;
    if (!gop.found_existing) gop.key_ptr.* = gpa.dupe(u8, name) catch {
        _ = self.extents.remove(name);
        return false;
    };
    gop.value_ptr.* = value;
    return true;
}
