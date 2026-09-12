//! What releasing a dragged view does, as a value.
//!
//! One rule: **the edge you release on is where the dragged view ends up.**
//! The middle of another place is a trade. Everything else here follows from
//! that sentence, and both the preview and the commit read this file — so what
//! slides open under the pointer is what you get when you let go.
//!
//! A split mints one empty leaf and keeps the origin. Which of the two the
//! dragged view occupies is the only thing that differs between dropping on
//! another place and dropping on your own:
//!
//! | release        | origin ends up | minted leaf opens | leaf holds   |
//! |----------------|----------------|-------------------|--------------|
//! | other's edge   | untouched      | that edge         | dragged view |
//! | own edge       | that edge      | opposite edge     | empty        |
//!
//! A self-split cannot move the view onto the leaf: the view is *already* in
//! the origin, and remounting a surface into a fresh slot tears down its
//! state (fizzy's Workspace loses its document panes). So the origin keeps it
//! and the leaf opens empty on the far side — which is also the only way the
//! view can stay under the pointer, where the user dropped it.
const std = @import("std");
const dvui = @import("dvui");
const SplitTree = @import("SplitTree.zig");

pub const Side = SplitTree.Side;

/// Where the pointer is, in a place's own terms. The raw reading of a
/// position; `plan` turns it into what will happen.
pub const Kind = union(enum) {
    swap,
    split: Side,
};

/// A resolved release: the same value drives the preview animation and the
/// assignment that lands. Null from `plan` means the release does nothing.
pub const Plan = union(enum) {
    /// Trade views with the place under the pointer.
    swap,
    split: Split,

    pub const Split = struct {
        /// The edge the pointer chose — where the dragged view ends up.
        landing: Side,
        /// Where the empty leaf opens. Opposite `landing` when the origin
        /// keeps the view, so the view stays on the edge it was dropped on.
        mint: Side,
        /// The dragged view moves onto the minted leaf and leaves its source.
        /// False on a self-split, where the origin already holds it.
        fills_mint: bool,
    };
};

/// How near an edge counts as a split, in points, and as a fraction of the
/// shorter side. The fraction is what keeps a small place usable: a fixed band
/// on a 100pt pane would leave no middle to aim at, and swapping would become
/// unreachable exactly where precision is hardest.
pub const edge_band: f32 = 36;
pub const edge_band_fraction: f32 = 0.28;

/// Read a pointer position against a place. Near an edge is a split on that
/// edge; anywhere else is a swap.
pub fn kindAt(bounds: dvui.Rect.Physical, mouse: dvui.Point.Physical, scale: f32) Kind {
    if (bounds.w <= 0 or bounds.h <= 0) return .swap;
    const band = @min(edge_band * scale, @min(bounds.w, bounds.h) * edge_band_fraction);
    const dl = mouse.x - bounds.x;
    const dr = bounds.x + bounds.w - mouse.x;
    const dt = mouse.y - bounds.y;
    const db = bounds.y + bounds.h - mouse.y;
    const nearest = @min(@min(dl, dr), @min(dt, db));
    if (nearest > band) return .swap;
    if (nearest == dl) return .{ .split = .left };
    if (nearest == dr) return .{ .split = .right };
    if (nearest == dt) return .{ .split = .top };
    return .{ .split = .bottom };
}

/// What `kind` means when the place under the pointer is (`self_drop`) or is
/// not the place the view was lifted from. Null when nothing should happen:
/// the middle of your own place is not a trade with yourself.
pub fn plan(kind: Kind, self_drop: bool) ?Plan {
    return switch (kind) {
        .swap => if (self_drop) null else .swap,
        .split => |landing| .{ .split = .{
            .landing = landing,
            .mint = if (self_drop) SplitTree.opposite(landing) else landing,
            .fills_mint = !self_drop,
        } },
    };
}

test "the middle is a swap and each edge is its own split" {
    const r: dvui.Rect.Physical = .{ .x = 0, .y = 0, .w = 200, .h = 100 };
    try std.testing.expectEqual(Kind.swap, kindAt(r, .{ .x = 100, .y = 50 }, 1));
    try std.testing.expectEqual(Kind{ .split = .left }, kindAt(r, .{ .x = 10, .y = 50 }, 1));
    try std.testing.expectEqual(Kind{ .split = .right }, kindAt(r, .{ .x = 190, .y = 50 }, 1));
    try std.testing.expectEqual(Kind{ .split = .top }, kindAt(r, .{ .x = 100, .y = 8 }, 1));
    try std.testing.expectEqual(Kind{ .split = .bottom }, kindAt(r, .{ .x = 100, .y = 94 }, 1));
}

test "a small place keeps a middle to aim at" {
    const r: dvui.Rect.Physical = .{ .x = 0, .y = 0, .w = 90, .h = 60 };
    try std.testing.expectEqual(Kind.swap, kindAt(r, .{ .x = 45, .y = 30 }, 1));
}

test "the dropped edge is where the view lands, on any place" {
    // Another place: the leaf opens under the pointer and takes the view.
    const away = plan(.{ .split = .right }, false).?.split;
    try std.testing.expectEqual(Side.right, away.landing);
    try std.testing.expectEqual(Side.right, away.mint);
    try std.testing.expect(away.fills_mint);

    // Your own place: the origin is already the view, so it stays under the
    // pointer and the empty leaf opens on the far side.
    const own = plan(.{ .split = .right }, true).?.split;
    try std.testing.expectEqual(Side.right, own.landing);
    try std.testing.expectEqual(Side.left, own.mint);
    try std.testing.expect(!own.fills_mint);
}

test "every edge lands where it was dropped" {
    for (std.meta.tags(Side)) |side| {
        for ([_]bool{ true, false }) |self_drop| {
            const s = plan(.{ .split = side }, self_drop).?.split;
            try std.testing.expectEqual(side, s.landing);
            // The view is on `landing` either way: it fills the minted leaf,
            // or the origin keeps it and the leaf went to the other side.
            if (s.fills_mint) {
                try std.testing.expectEqual(side, s.mint);
            } else {
                try std.testing.expectEqual(SplitTree.opposite(side), s.mint);
            }
        }
    }
}

test "the middle of your own place does nothing" {
    try std.testing.expect(plan(.swap, true) == null);
    try std.testing.expectEqual(Plan.swap, plan(.swap, false).?);
}
