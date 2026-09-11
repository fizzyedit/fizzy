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

const State = @This();

/// A rendered picture of a surface as it last drew, for the picker's cards. Taken by `Layout`
/// on request (`snapshots_wanted`), one per surface per request, never on an ordinary frame.
pub const Snapshot = struct {
    texture: dvui.Texture,
    /// The size it was drawn at, in points — the aspect the card should keep.
    natural: dvui.Size,
};

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
/// Explorer/panel split ratios — "window shape" state persisted in `window.zon`, not
/// `settings.zon` (dragging a splitter fires every frame; keeping it out of the settings file
/// means normal window use never dirties a git-tracked settings.zon). Loaded once at startup
/// (see `init`); defaults match the pre-move `Settings` field defaults.
/// Debounced-save bookkeeping for the ratios above, separate from `settings_dirty`/
/// `settings_save_deadline_ns` — sidebar/panel dragging must not force a settings.zon write
/// attempt on every drag frame.
dirty: bool = false,
save_deadline_ns: i128 = 0,
/// Collapsed-layout (phone / narrow web viewport) center focus: while true the bottom panel
/// stays swung shut so the center region owns the whole viewport. Set by `revealCenter`, which
/// callers use when a tap has just put something worth reading in the center (e.g. picking a
/// plugin in the store). Deliberately *not* a `panel_ratio` write: the user's panel height
/// survives, so dragging the handle back up — or widening the window out of the collapsed
/// layout — restores the panel where they left it.
panel_hidden_for_center: bool = false,
/// Id of the center provider drawn last frame, so a swap can look the outgoing one up again by
/// id (never cache the pointer: a plugin can unload between frames). Borrowed from the host's
/// registry entry, which outlives a frame.
center_prev_id: ?[]const u8 = null,
/// Host-owned cross-fade between center providers. See `drawActiveCenter`.
center_transition: core.anim.Transition = .{},
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

/// Called by `Region.init` as a shape declares one. Lands in the list being built, which
/// `publishRegions` swaps into view when the shape finishes.
pub fn registerRegion(self: *State, gpa: std.mem.Allocator, entry: Region) void {
    self.regions_building.append(gpa, entry) catch {};
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
/// `unassign`, which hands the region back to its keywords.
pub fn assign(self: *State, gpa: std.mem.Allocator, name: []const u8, surfaces: []const []const u8) !void {
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
    var it = self.extents.keyIterator();
    while (it.next()) |k| gpa.free(k.*);
    self.extents.deinit(gpa);
}

pub fn deinitAssignments(self: *State, gpa: std.mem.Allocator) void {
    var it = self.assignments.iterator();
    while (it.next()) |e| {
        gpa.free(e.key_ptr.*);
        for (e.value_ptr.*) |id| gpa.free(id);
        gpa.free(e.value_ptr.*);
    }
    self.assignments.deinit(gpa);
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
