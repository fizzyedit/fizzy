//! A declared region: an area that accepts keywords and draws the surfaces matching them.
//!
//! Note this is **not** docking in the draggable-panel sense — a region's place is fixed by the
//! shape that declares it. Real docking (dvui has dockable panels now) would be a layer *above*
//! this that lets the user move regions at runtime, and is the natural basis for a
//! Premiere-style shape. Named seam, not built.
//!
//! `region` draws the region's own contents — its chrome, if it declared any, and the active
//! matching surface — and leaves the caller positioned in the *remaining* space, so whatever the
//! layout writes next lands there. That is what removes the `showFirst`/`showSecond` pairs from
//! shapes.
const std = @import("std");
const dvui = @import("dvui");
const Layout = @import("Layout.zig");

const Region = @This();

/// Clip set while the region is open, restored on `deinit`.
prev_clip: ?dvui.Rect.Physical = null,
/// The box this region is. A region **is** a `dvui.box`: same layout mechanics, same
/// options, same lifetime rules — so an app author who has written any dvui already knows
/// how this behaves, and a split is a separator between two of them.
box: ?*dvui.BoxWidget = null,
layout: ?*Layout = null,

pub fn deinit(self: *Region) void {
    if (self.prev_clip) |c| dvui.clipSet(c);
    if (self.box) |b| {
        if (self.layout) |l| {
            std.debug.assert(l.depth > 0);
            l.depth -= 1;
        }
        b.deinit();
    }
}

/// How a region draws its own contents.
///
/// Null means "draw the selected matching surface" — the "this region IS x" form. A function
/// means the region has chrome of its own: a tab strip above its content, a titled scroll pane,
/// a splittable panel. It is handed the region's keywords and returns when the region is full.
///
/// This replaced a five-value `Chooser` enum, two of whose values (`explorer_chrome`,
/// `panel_chrome`) named *fizzy's own* furniture from inside the generic layer. That is the
/// case CLAUDE.md calls a bug in `Layout` rather than a special case: a shape is supposed to be
/// ordinary code over this API, and an app copying `ide.zig` could not have written those two
/// values itself. As a function pointer they are just `chrome.explorerPane` and
/// `chrome.bottomPane` — app code, passed in, replaceable by the app's own loop over
/// `matching` / `selected` / `draw`, which is the governing test for everything here.
///
/// It also retired the two values nothing used (`.tabs`, `.icons`); `chrome.tabbed` is the
/// first of those as a plain function, and the icon rail was never this shape to begin with —
/// it sits *beside* the region it chooses for, so `ide.zig` calls it directly and reads the
/// action it returns.
pub const Content = *const fn (f: *Layout, keywords: []const []const u8) anyerror!dvui.App.Result;

/// What a region *is*, as opposed to how it is laid out — which is `dvui.Options`, unchanged.
pub const Init = struct {
    /// Human-facing name, shown wherever a user places a surface by hand.
    name: []const u8 = "",
    /// What kinds of surface this region accepts. Empty means it hosts nothing itself and is
    /// purely a container for other regions.
    keywords: []const []const u8 = &.{},
    /// The axis this region lays its children along, exactly as `dvui.box`'s `dir`.
    dir: dvui.enums.Direction = .vertical,
    /// Chrome drawn instead of the plain selected surface. See `Content`.
    content: ?Content = null,
    /// Make this region's extent along its parent's axis draggable by the `split` after it. The
    /// starting extent comes from `min_size_content` in the `dvui.Options`; the user's drag
    /// replaces it and persists.
    resize: bool = false,
    /// Collapse while nothing matches, rather than holding empty space open.
    hide_when_empty: bool = false,
    /// Start shut when the window has no room to show this region beside everything else.
    ///
    /// Closing itself needs no flag: a region slides continuously from its full size to nothing,
    /// because a pinned box is exactly the size it is pinned to and a region clips what it holds.
    /// There is no threshold and nothing snaps — a sash that jumps the last stretch is a sash
    /// that fights you.
    collapsible: bool = false,
};
