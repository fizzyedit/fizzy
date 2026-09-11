//! The application's layout *state*: which surface each region shows, the regions this frame
//! declared, and every region's remembered extent.
//!
//! `Layout.State`, because `Layout` is the thing a shape declares regions *with* and this is
//! what persists behind it between frames. The field on the app is `layout`.
//!
//! Grouped rather than spread across the application state because the boundary matters: this
//! is framework, and the chrome beside it (explorer, sidebar, panes) is fizzy's own. Seventy-five
//! flat fields made that invisible.
const std = @import("std");
const core = @import("core");
const sdk = @import("fizzy_sdk");
const Region = @import("Region.zig");

const State = @This();

/// Shell (new-layout) selection state: keyword-group hash -> selected surface id.
/// Surface ids are registry-owned string literals, so this stores no allocations of its own.
/// Keyed by group rather than by region so two regions written with the same keywords share a
/// selection with no wiring between them (see `layout/Layout.zig`).
selection: std.AutoHashMapUnmanaged(u64, []const u8) = .empty,
/// Per-surface keyword overrides from `settings.zon` (`.plugins.<id>.surfaces.<sid>.keywords`).
/// The user's answer wins over the plugin's declared defaults, which is what makes a wrong
/// default cost two clicks rather than a plugin release. Keys and values are gpa-owned.
keyword_overrides: std.StringHashMapUnmanaged([]const []const u8) = .empty,
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

// ---- the app's side of a region ---------------------------------------------------------------
//
// Regions are declared by a shape and driven from outside it — a rail button, a command, a
// keybind. These four are that seam, and they live on the state rather than on the application
// because nothing here is fizzy's: a name, an extent, and the set the last shape declared.

/// The region accepting `keywords`, or null when this app's shape declared none — a normal
/// state, not an error.
pub fn regionFor(self: *State, keywords: []const []const u8) ?Region {
    for (self.regions.items) |entry| {
        if (sdk.keywords.intersects(entry.keywords, keywords)) return entry;
    }
    return null;
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

/// The extent a region should start at: what the user last left it, or the shape's default.
pub fn extent(self: *State, name: []const u8, default: f32) f32 {
    return self.extents.get(name) orelse default;
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
