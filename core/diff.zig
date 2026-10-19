//! Diffing, std-only like `app/state_delta.zig`, so plugins, the web and a plain Linux test root
//! all use it. No dvui, no global state: a diff runs only when something asks.
//! `plans/DIFF_PLAN.md` has the design.

/// RGBA8 pixels to the rects that differ: row fast path, tile compare, exact refinement.
pub const Image = @import("diff/Image.zig");
/// A keepable per-tile hash of an image, 8 bytes per tile, to diff a past state against.
pub const TileGrid = @import("diff/TileGrid.zig");
/// A line diff of two texts: histogram with a Myers fallback, over a reusable scratch.
pub const Text = @import("diff/Text.zig");
/// A text diff's hunks as a standard unified diff, with a size cap.
pub const unified = @import("diff/unified.zig");

test {
    _ = Image;
    _ = TileGrid;
    _ = Text;
    _ = unified;
    _ = @import("diff/tests.zig");
}
