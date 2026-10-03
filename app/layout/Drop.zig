//! What releasing a dragged view does, as a value.
//!
//! One rule: **the edge you release on is where the dragged view ends up.**
//! The middle of another place is a trade — or, when the two places are the
//! halves of one split, a join: they are one place again, holding both. The
//! middle of the place the view came out of floats it, into a window of its
//! own over the layout (`Floats`). Both the drop zones and the commit read this
//! file, so what lights under the pointer is what you get when you let go.
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
//! the origin, and remounting a surface into a fresh slot tears down every
//! widget under it — scroll positions, sash sizes, focus. So the origin keeps
//! it and the leaf opens empty on the far side — which is also the only way the
//! view can stay under the pointer, where the user dropped it.
const std = @import("std");
const dvui = @import("dvui");
const SplitTree = @import("SplitTree.zig");
const DropZones = @import("core").widgets.DropZones;

pub const Side = SplitTree.Side;

/// Where the pointer is, in a place's own terms. The raw reading of a
/// position; `plan` turns it into what will happen.
pub const Kind = union(enum) {
    swap,
    split: Side,
    /// The trash: out of the layout.
    remove,
};

/// A resolved release: the same value the drop zones read, and the assignment
/// that lands. Null from `plan` means the release does nothing.
pub const Plan = union(enum) {
    /// Trade views with the place under the pointer.
    swap,
    /// Close the split the two places are the halves of: one place, holding the views of both.
    join,
    split: Split,
    /// Out of the layout: a document closes, any other view leaves its place.
    remove,
    /// Out of its place into a floating window of its own, over the layout (`Floats`).
    float,

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

/// Read a pointer position against a place: the drop's own reading (`DropZones`), so what the
/// drop shows under the pointer is what a release does. Its middle is a swap, each side of
/// its ring a split on that side, the trash (offered with `remove`) a removal, and off the drop
/// nothing — null.
pub fn kindAt(bounds: dvui.Rect.Physical, mouse: dvui.Point.Physical, scale: f32, remove: bool) ?Kind {
    return kindAtDisc(bounds, mouse, 0, scale, remove);
}

/// `kindAt` for a carried drop of radius `r` (physical) centred on `c`: the bubble it overlaps
/// (`DropZones.atDisc`). `r` 0 is a point.
pub fn kindAtDisc(bounds: dvui.Rect.Physical, c: dvui.Point.Physical, r: f32, scale: f32, remove: bool) ?Kind {
    if (bounds.w <= 0 or bounds.h <= 0) return null;
    const zone = DropZones.atDisc(DropZones.wheel(bounds, scale, remove), c, r) orelse return null;
    return switch (zone) {
        .center => .swap,
        .remove => .remove,
        .edge => |side| .{ .split = switch (side) {
            .left => .left,
            .right => .right,
            .top => .top,
            .bottom => .bottom,
        } },
    };
}

/// What `kind` means when the place under the pointer is (`self_drop`) or is
/// not the place the view was lifted from, whether the two are the halves of
/// one split (`halves`, `SplitTree.Forest.joinable`), and whether the view may
/// float (`can_float`, `float_rules.canFloat`). The middle of your own place is
/// not a trade with yourself: it floats the view, or — where it cannot float —
/// does nothing, null.
pub fn plan(kind: Kind, self_drop: bool, halves: bool, can_float: bool) ?Plan {
    return switch (kind) {
        .swap => if (self_drop) (if (can_float) .float else null) else if (halves) .join else .swap,
        .remove => .remove,
        .split => |landing| .{ .split = .{
            .landing = landing,
            .mint = if (self_drop) SplitTree.opposite(landing) else landing,
            .fills_mint = !self_drop,
        } },
    };
}

test "the drop's middle is a swap, each side a split, the trash a removal, off it nothing" {
    // An 800×600 place: the bubbles sit round (400, 300) — the sides 108 out, the trash 88 out
    // on the diagonal.
    const r: dvui.Rect.Physical = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    try std.testing.expectEqual(@as(?Kind, .swap), kindAt(r, .{ .x = 400, .y = 300 }, 1, false));
    try std.testing.expectEqual(@as(?Kind, .{ .split = .left }), kindAt(r, .{ .x = 292, .y = 300 }, 1, false));
    try std.testing.expectEqual(@as(?Kind, .{ .split = .right }), kindAt(r, .{ .x = 508, .y = 310 }, 1, false));
    try std.testing.expectEqual(@as(?Kind, .{ .split = .top }), kindAt(r, .{ .x = 410, .y = 192 }, 1, false));
    try std.testing.expectEqual(@as(?Kind, .{ .split = .bottom }), kindAt(r, .{ .x = 400, .y = 408 }, 1, false));
    // The trash, only when it is offered.
    try std.testing.expectEqual(@as(?Kind, .remove), kindAt(r, .{ .x = 488, .y = 388 }, 1, true));
    try std.testing.expectEqual(@as(?Kind, null), kindAt(r, .{ .x = 488, .y = 388 }, 1, false));
    // The place's own edges are off the drop: no drop.
    try std.testing.expectEqual(@as(?Kind, null), kindAt(r, .{ .x = 20, .y = 300 }, 1, false));
    try std.testing.expectEqual(@as(?Kind, null), kindAt(r, .{ .x = 400, .y = 10 }, 1, false));
}

test "a small place fits the whole drop" {
    // 60 tall: the cluster (148 points out) shrinks to 27 physical pixels out.
    const r: dvui.Rect.Physical = .{ .x = 0, .y = 0, .w = 90, .h = 60 };
    try std.testing.expectEqual(@as(?Kind, .swap), kindAt(r, .{ .x = 45, .y = 30 }, 1, false));
    try std.testing.expectEqual(@as(?Kind, .{ .split = .left }), kindAt(r, .{ .x = 45 - 19.7, .y = 30 }, 1, false));
}

test "the dropped edge is where the view lands, on any place" {
    // Another place: the leaf opens under the pointer and takes the view.
    const away = plan(.{ .split = .right }, false, false, false).?.split;
    try std.testing.expectEqual(Side.right, away.landing);
    try std.testing.expectEqual(Side.right, away.mint);
    try std.testing.expect(away.fills_mint);

    // Your own place: the origin is already the view, so it stays under the
    // pointer and the empty leaf opens on the far side.
    const own = plan(.{ .split = .right }, true, false, true).?.split;
    try std.testing.expectEqual(Side.right, own.landing);
    try std.testing.expectEqual(Side.left, own.mint);
    try std.testing.expect(!own.fills_mint);
}

test "every edge lands where it was dropped" {
    for (std.meta.tags(Side)) |side| {
        for ([_]bool{ true, false }) |self_drop| {
            const s = plan(.{ .split = side }, self_drop, false, true).?.split;
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

test "the middle of your own place floats the view, or does nothing where it cannot float" {
    try std.testing.expectEqual(Plan.float, plan(.swap, true, false, true).?);
    try std.testing.expect(plan(.swap, true, false, false) == null);
    // Anywhere else the middle trades, whatever floating would allow.
    try std.testing.expectEqual(Plan.swap, plan(.swap, false, false, true).?);
    try std.testing.expectEqual(Plan.swap, plan(.swap, false, false, false).?);
}

test "the middle of the other half of a split joins, and its edges still split" {
    try std.testing.expectEqual(Plan.join, plan(.swap, false, true, true).?);
    const s = plan(.{ .split = .left }, false, true, true).?.split;
    try std.testing.expect(s.fills_mint);
}
