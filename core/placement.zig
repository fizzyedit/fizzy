//! Where a new view goes, decided from the shape of the room and nothing else: a space taller
//! than wide stacks two views, a wider one sets them side by side, and one too small for either
//! takes the view as a tab. No OS, device or pointer is asked, so a phone held upright, a narrow
//! desktop window and a portrait monitor all land the same way. std-only, so the table in the
//! tests below is the specification (`build/app.zig`). In `core` so a plugin that arranges its own
//! panes (the workbench) asks the same answer as an app that places them in layout.
const std = @import("std");

/// How two views share a space.
pub const Axis = enum {
    /// Side by side: the split runs along the width.
    side_by_side,
    /// One above the other.
    stacked,
};

/// The width-to-height ratio inside which a space counts as square, and keeps the axis it had.
/// A window dragged through square, or a phone tilting past it, would otherwise flip on every
/// pixel.
pub const dead_band = 1.15;

/// The room each half of a split must keep for a document to be worth reading in, in points.
pub const min_half = Size{ .w = 360, .h = 440 };

/// The gap a split's sash takes.
pub const handle: f32 = 8;

pub const Size = struct { w: f32, h: f32 };

/// The axis a split of a `w` by `h` space runs now. `prev` is the axis it ran before, if any:
/// inside the dead band it is kept, and with none a square space sits side by side.
pub fn orient(prev: ?Axis, w: f32, h: f32) Axis {
    if (w > h * dead_band) return .side_by_side;
    if (h > w * dead_band) return .stacked;
    return prev orelse .side_by_side;
}

/// The size of one half of `space` split along `axis`.
pub fn half(space: Size, axis: Axis) Size {
    return switch (axis) {
        .side_by_side => .{ .w = (space.w - handle) / 2, .h = space.h },
        .stacked => .{ .w = space.w, .h = (space.h - handle) / 2 },
    };
}

/// Whether a view can be read in a place of `s`.
pub fn fits(s: Size) bool {
    return s.w >= min_half.w and s.h >= min_half.h;
}

pub const Result = union(enum) {
    /// The view goes into the place at this index of `places`.
    into: usize,
    /// Split the anchor along this axis; the new place is the trailing half.
    split: Axis,
    /// Neither a place nor a split has room: the view joins the anchor's place as a tab.
    tab,
};

/// Where a view opened beside `anchor` (the place the person is in) goes. `places` are the
/// other places already showing, in the order to prefer. The person's arrangement comes first:
/// a place that fits takes the view, and only without one does the anchor split, along the axis
/// its shape asks, or the other when only that one fits.
pub fn place(anchor: Size, places: []const Size) Result {
    for (places, 0..) |p, i| if (fits(p)) return .{ .into = i };
    const want = orient(null, anchor.w, anchor.h);
    if (fits(half(anchor, want))) return .{ .split = want };
    const other: Axis = if (want == .stacked) .side_by_side else .stacked;
    if (fits(half(anchor, other))) return .{ .split = other };
    return .tab;
}

/// The axis a split off `anchor` runs when it must split even though `place` said `.tab`: the
/// shape's own, so a caller with no tabs to give (a pane is a place of its own) still follows
/// the room.
pub fn splitAxis(anchor: Size) Axis {
    return orient(null, anchor.w, anchor.h);
}

const Case = struct {
    name: []const u8,
    anchor: Size,
    places: []const Size = &.{},
    want: Result,
};

test "place: the table" {
    const cases = [_]Case{
        .{ .name = "phone portrait", .anchor = .{ .w = 390, .h = 844 }, .want = .tab },
        .{ .name = "phone landscape", .anchor = .{ .w = 844, .h = 390 }, .want = .tab },
        .{ .name = "tablet portrait", .anchor = .{ .w = 820, .h = 1180 }, .want = .{ .split = .stacked } },
        .{ .name = "tablet landscape", .anchor = .{ .w = 1180, .h = 820 }, .want = .{ .split = .side_by_side } },
        .{ .name = "narrow desktop window", .anchor = .{ .w = 700, .h = 800 }, .want = .tab },
        .{ .name = "tall desktop window", .anchor = .{ .w = 900, .h = 1100 }, .want = .{ .split = .stacked } },
        .{ .name = "wide desktop window", .anchor = .{ .w = 1440, .h = 900 }, .want = .{ .split = .side_by_side } },
        .{ .name = "square fits side by side", .anchor = .{ .w = 1000, .h = 1000 }, .want = .{ .split = .side_by_side } },
        .{
            // Stacked halves are 700x386, too short; side by side they are 346 wide, too thin.
            .name = "neither axis fits",
            .anchor = .{ .w = 700, .h = 780 },
            .want = .tab,
        },
        .{
            // Tall by ratio, but its stacked halves are 421 high; side by side they fit.
            .name = "the other axis, when only it fits",
            .anchor = .{ .w = 730, .h = 850 },
            .want = .{ .split = .side_by_side },
        },
        .{
            .name = "an existing place that fits wins over a split",
            .anchor = .{ .w = 1440, .h = 900 },
            .places = &.{.{ .w = 600, .h = 900 }},
            .want = .{ .into = 0 },
        },
        .{
            .name = "a place too small to read in is skipped",
            .anchor = .{ .w = 1440, .h = 900 },
            .places = &.{ .{ .w = 200, .h = 900 }, .{ .w = 500, .h = 900 } },
            .want = .{ .into = 1 },
        },
        .{
            .name = "phone with a second group: into it",
            .anchor = .{ .w = 390, .h = 844 },
            .places = &.{.{ .w = 390, .h = 844 }},
            .want = .{ .into = 0 },
        },
    };
    for (cases) |c| {
        errdefer std.debug.print("case: {s}\n", .{c.name});
        try std.testing.expectEqual(c.want, place(c.anchor, c.places));
    }
}

test "orient: the shape of the room" {
    try std.testing.expectEqual(Axis.stacked, orient(null, 390, 844));
    try std.testing.expectEqual(Axis.side_by_side, orient(null, 844, 390));
    try std.testing.expectEqual(Axis.side_by_side, orient(null, 1000, 1000));
}

test "orient: a rotation turns the split, and the dead band holds it" {
    // Two views stacked on a phone held upright.
    var axis = orient(null, 390, 844);
    try std.testing.expectEqual(Axis.stacked, axis);
    // Turned to landscape: side by side, with no layout written, only a new answer.
    axis = orient(axis, 844, 390);
    try std.testing.expectEqual(Axis.side_by_side, axis);
    // Inside the band the axis stays whichever it was.
    try std.testing.expectEqual(Axis.side_by_side, orient(.side_by_side, 1000, 1100));
    try std.testing.expectEqual(Axis.stacked, orient(.stacked, 1100, 1000));
    try std.testing.expectEqual(Axis.stacked, orient(.stacked, 1000, 1000));
    // Past the band it turns.
    try std.testing.expectEqual(Axis.stacked, orient(.side_by_side, 1000, 1200));
    try std.testing.expectEqual(Axis.side_by_side, orient(.stacked, 1200, 1000));
}
