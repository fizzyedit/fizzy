//! Where a new view goes, decided from the shape of the room and nothing else: a space taller
//! than wide stacks two views, a wider one sets them side by side, and one too small for two
//! takes the view as a card. No OS, device or pointer is asked, so a phone held upright, a narrow
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

/// The room each half of a split must keep for a document to be worth reading in, in points. Sized
/// so that no phone splits by itself, held either way up (the largest, 956 x 440, gives 478-wide
/// halves), and a tablet or a desktop window does.
pub const split_half = Size{ .w = 480, .h = 360 };

pub const Size = struct { w: f32, h: f32 };

/// The axis a split of a `w` by `h` space runs now. `prev` is the axis it ran before, if any:
/// inside the dead band it is kept, and with none a square space sits side by side.
pub fn orient(prev: ?Axis, w: f32, h: f32) Axis {
    if (w > h * dead_band) return .side_by_side;
    if (h > w * dead_band) return .stacked;
    return prev orelse .side_by_side;
}

pub const Result = union(enum) {
    /// The view goes into the place at this index of `places`.
    into: usize,
    /// Split the anchor along this axis; the new place is the trailing half.
    split: Axis,
    /// Neither a place nor a split has room: the view joins the anchor's place as a card.
    tab,
};

/// Where a view opened beside `anchor` (the place the person is in) goes. `places` are the other
/// places drawn now that take the view, in the order to prefer: the caller leaves out any that
/// are hidden or do not accept it. The person's arrangement comes first: the first of them takes
/// the view, whatever its size, because the person made it. Without one the anchor splits along
/// the axis its shape asks, if both halves keep `split_half`; otherwise the view is a card in
/// the anchor's place.
pub fn place(anchor: Size, places: []const Size) Result {
    if (places.len > 0) return .{ .into = 0 };
    const axis = orient(null, anchor.w, anchor.h);
    const half: Size = switch (axis) {
        .side_by_side => .{ .w = anchor.w / 2, .h = anchor.h },
        .stacked => .{ .w = anchor.w, .h = anchor.h / 2 },
    };
    if (half.w >= split_half.w and half.h >= split_half.h) return .{ .split = axis };
    return .tab;
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
        .{ .name = "large phone, 932 x 430 on its side", .anchor = .{ .w = 932, .h = 430 }, .want = .tab },
        .{ .name = "largest phone, 956 x 440 on its side", .anchor = .{ .w = 956, .h = 440 }, .want = .tab },
        .{ .name = "tablet portrait", .anchor = .{ .w = 820, .h = 1180 }, .want = .{ .split = .stacked } },
        .{ .name = "tablet landscape", .anchor = .{ .w = 1180, .h = 820 }, .want = .{ .split = .side_by_side } },
        .{ .name = "narrow desktop window is a phone's", .anchor = .{ .w = 700, .h = 800 }, .want = .tab },
        .{ .name = "tall desktop window", .anchor = .{ .w = 900, .h = 1100 }, .want = .{ .split = .stacked } },
        .{ .name = "wide desktop window", .anchor = .{ .w = 1440, .h = 900 }, .want = .{ .split = .side_by_side } },
        .{ .name = "square fits side by side", .anchor = .{ .w = 1000, .h = 1000 }, .want = .{ .split = .side_by_side } },
        .{
            // Tall by ratio, so it asks for stacked halves of 730 x 425: they fit. It does not
            // fall back to the other axis when they do not (the next row).
            .name = "tall, and the stacked halves fit",
            .anchor = .{ .w = 730, .h = 850 },
            .want = .{ .split = .stacked },
        },
        .{
            // Stacked halves are 580 x 350, too short; side by side would be 290 wide, too thin.
            // Neither is tried when the shape picks the other.
            .name = "the shape's axis does not fit: a card, not the other axis",
            .anchor = .{ .w = 580, .h = 700 },
            .want = .tab,
        },
        .{
            .name = "a place the person made takes the view, whatever its size",
            .anchor = .{ .w = 1440, .h = 900 },
            .places = &.{.{ .w = 200, .h = 900 }},
            .want = .{ .into = 0 },
        },
        .{
            .name = "the first of the places wins",
            .anchor = .{ .w = 1440, .h = 900 },
            .places = &.{ .{ .w = 500, .h = 900 }, .{ .w = 600, .h = 900 } },
            .want = .{ .into = 0 },
        },
        .{
            // Two groups stacked on a phone, each about 390 x 418: the other is filled.
            .name = "phone with two groups: into the other",
            .anchor = .{ .w = 390, .h = 418 },
            .places = &.{.{ .w = 390, .h = 418 }},
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
