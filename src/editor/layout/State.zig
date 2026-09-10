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
const Region = @import("Region.zig");

/// Shell (new-layout) selection state: keyword-group hash -> selected surface id.
/// Surface ids are registry-owned string literals, so this stores no allocations of its own.
/// Keyed by group rather than by region so two regions written with the same keywords share a
/// selection with no wiring between them (see `layout/Layout.zig`).
selection: std.AutoHashMapUnmanaged(u64, []const u8) = .empty,
/// Per-surface keyword overrides from `settings.zon` (`.plugins.<id>.surfaces.<sid>.keywords`).
/// The user's answer wins over the plugin's declared defaults, which is what makes a wrong
/// default cost two clicks rather than a plugin release. Keys and values are gpa-owned.
keyword_overrides: std.StringHashMapUnmanaged([]const []const u8) = .empty,
/// Regions declared by this frame's shape. Cleared and rebuilt every frame.
regions: std.ArrayListUnmanaged(Region) = .empty,
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
