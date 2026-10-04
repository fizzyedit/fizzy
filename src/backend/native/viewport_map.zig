//! Where a viewport's OS window is on the desktop and where its part of the frame lies — the one
//! mapping between the two (`docs/POPOUT_WINDOWS_PLAN.md`). std-only, its own `b.addTest` root in
//! `build/app.zig`; `SDLBackend` applies it.
//!
//! There is one `dvui.Window` and one frame. The main window shows the part of it at its origin.
//! A viewport — a float popped out into an OS window of its own — shows a part of it far past the
//! main window's edge, its band, which no pointer over the main window can reach: dvui routes a
//! pointer to whatever is drawn under it in the frame, and nothing over the main window is ever
//! under a point in a band. Within its band the frame follows the desktop:
//!
//!     frame = band + (screen − anchor) · density
//!
//! where `anchor` is where the main window's top left was on the desktop when the viewport opened
//! and `density` its pixels per point then. Both stay as they were for the viewport's life, so
//! the main window moving does not move the windows that left it (the plan's decision 2). A float
//! moved or resized in its band — by dvui's own drag, as in the main window — moves its window
//! with it, and a pointer over the window is put back where the window shows it.

const std = @import("std");

pub const Point = struct {
    x: f32 = 0,
    y: f32 = 0,
};

pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,
};

/// A window's place on the desktop, whole points, as SDL takes it.
pub const ScreenRect = struct {
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,
};

/// Physical pixels from the frame's origin to the first band, and from each band to the next:
/// more than any desktop spans either way of the main window, so bands meet neither the main
/// window nor each other — two viewports' windows may overlap on the desktop, their floats never
/// do in the frame.
pub const band_stride: f32 = 100_000;

/// Where band `slot` (the `slot`th viewport) starts in the frame, physical pixels.
pub fn band(slot: usize) Point {
    return .{ .x = band_stride * @as(f32, @floatFromInt(slot + 1)), .y = 0 };
}

/// The point of the frame, physical pixels, that `screen` (desktop points) is over in the band
/// starting at `b`, for a viewport anchored at `anchor` with `density` pixels per point.
pub fn frameFromScreen(b: Point, anchor: Point, density: f32, screen: Point) Point {
    return .{
        .x = b.x + (screen.x - anchor.x) * density,
        .y = b.y + (screen.y - anchor.y) * density,
    };
}

/// A rect of the frame, physical pixels, in the band starting at `b`, on the desktop: where a
/// window showing exactly that part of the frame goes.
pub fn screenFromFrame(b: Point, anchor: Point, density: f32, frame: Rect) Rect {
    return .{
        .x = anchor.x + (frame.x - b.x) / density,
        .y = anchor.y + (frame.y - b.y) / density,
        .w = frame.w / density,
        .h = frame.h / density,
    };
}

pub const Placement = struct {
    /// Where the window goes, whole points.
    screen: ScreenRect,
    /// The part of the frame it then shows, physical pixels: the rect asked for, moved and sized
    /// by less than a point to sit on whole points, so what the window shows is what is drawn
    /// there and a pointer over it lands where it is drawn.
    frame: Rect,
};

/// Where to put a window showing `frame` (band `b`): on whole points, the nearest to it.
pub fn place(b: Point, anchor: Point, density: f32, frame: Rect) Placement {
    const s = screenFromFrame(b, anchor, density, frame);
    const screen: ScreenRect = .{
        .x = @intFromFloat(@round(s.x)),
        .y = @intFromFloat(@round(s.y)),
        .w = @intFromFloat(@max(1, @round(s.w))),
        .h = @intFromFloat(@max(1, @round(s.h))),
    };
    const at = frameFromScreen(b, anchor, density, .{ .x = @floatFromInt(screen.x), .y = @floatFromInt(screen.y) });
    return .{
        .screen = screen,
        .frame = .{
            .x = at.x,
            .y = at.y,
            .w = @as(f32, @floatFromInt(screen.w)) * density,
            .h = @as(f32, @floatFromInt(screen.h)) * density,
        },
    };
}

/// Where a window at `screen` (desktop points) lies in the main window's part of the frame,
/// physical pixels from its top left — the main window now at `main` on the desktop, with
/// `density` pixels per point. For a float coming back from its window into the main one: it
/// comes back where its window is.
pub fn mainFromScreen(main: Point, density: f32, screen: ScreenRect) Rect {
    return .{
        .x = (@as(f32, @floatFromInt(screen.x)) - main.x) * density,
        .y = (@as(f32, @floatFromInt(screen.y)) - main.y) * density,
        .w = @as(f32, @floatFromInt(screen.w)) * density,
        .h = @as(f32, @floatFromInt(screen.h)) * density,
    };
}

const testing = std.testing;

test "a window on the desktop lies in the main window's frame from the main window's top left, at its density" {
    const r = mainFromScreen(.{ .x = 100, .y = 50 }, 2, .{ .x = 160, .y = 80, .w = 300, .h = 200 });
    try testing.expectEqual(@as(f32, 120), r.x);
    try testing.expectEqual(@as(f32, 60), r.y);
    try testing.expectEqual(@as(f32, 600), r.w);
    try testing.expectEqual(@as(f32, 400), r.h);
    // Left of and above the main window: negative, for the caller to bring back onto it.
    const off = mainFromScreen(.{ .x = 100, .y = 50 }, 1, .{ .x = 20, .y = 10, .w = 10, .h = 10 });
    try testing.expectEqual(@as(f32, -80), off.x);
    try testing.expectEqual(@as(f32, -40), off.y);
}

test "the anchor — the main window's top left when the viewport opened — is where its band starts" {
    const b = band(0);
    const p = frameFromScreen(b, .{ .x = 300, .y = 120 }, 2, .{ .x = 300, .y = 120 });
    try testing.expectEqual(b.x, p.x);
    try testing.expectEqual(b.y, p.y);
}

test "a point on the desktop goes to the frame and back" {
    const b = band(1);
    const anchor: Point = .{ .x = -800, .y = 40 };
    const screen: Point = .{ .x = 1234.5, .y = -77.25 };
    const p = frameFromScreen(b, anchor, 2, screen);
    const back = screenFromFrame(b, anchor, 2, .{ .x = p.x, .y = p.y, .w = 10, .h = 10 });
    try testing.expectApproxEqAbs(screen.x, back.x, 0.001);
    try testing.expectApproxEqAbs(screen.y, back.y, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 5), back.w, 0.001);
}

test "a pointer over a moved window lands where its frame is drawn" {
    // The window follows its float a frame late: wherever it is, the frame point under the
    // pointer depends on the desktop alone.
    const b = band(0);
    const anchor: Point = .{ .x = 100, .y = 100 };
    const frame: Rect = .{ .x = b.x + 600, .y = b.y + 400, .w = 800, .h = 600 };
    const placed = place(b, anchor, 2, frame);
    // The pointer 10 points into the window's top left.
    const pointer: Point = .{ .x = @as(f32, @floatFromInt(placed.screen.x)) + 10, .y = @as(f32, @floatFromInt(placed.screen.y)) + 10 };
    const p = frameFromScreen(b, anchor, 2, pointer);
    try testing.expectApproxEqAbs(placed.frame.x + 20, p.x, 0.001);
    try testing.expectApproxEqAbs(placed.frame.y + 20, p.y, 0.001);
}

test "a placement sits on whole points and shows the frame it is on" {
    const b = band(0);
    const anchor: Point = .{ .x = 50, .y = 25 };
    const placed = place(b, anchor, 2, .{ .x = b.x + 101, .y = b.y + 33, .w = 401, .h = 299 });
    try testing.expectEqual(@as(i32, 101), placed.screen.x); // 50 + 101/2 = 100.5, rounded up
    try testing.expectEqual(@as(i32, 42), placed.screen.y); // 25 + 16.5
    try testing.expectEqual(@as(i32, 201), placed.screen.w); // 200.5
    try testing.expectEqual(@as(i32, 150), placed.screen.h); // 149.5
    try testing.expectApproxEqAbs(b.x + 102, placed.frame.x, 0.001);
    try testing.expectApproxEqAbs(b.y + 34, placed.frame.y, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 402), placed.frame.w, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 300), placed.frame.h, 0.001);
}

test "bands meet neither the main window nor each other" {
    // Ten 8K displays' worth of pixels across, the main window in the middle of them.
    const reach: f32 = 10 * 7680;
    const anchor: Point = .{ .x = 0, .y = 0 };
    for (0..4) |slot| {
        const b = band(slot);
        const left = frameFromScreen(b, anchor, 1, .{ .x = -reach / 2, .y = 0 });
        const right = frameFromScreen(b, anchor, 1, .{ .x = reach / 2, .y = 0 });
        // Past the main window (well under 20000 pixels wide) and short of the next band.
        try testing.expect(left.x > 20_000);
        try testing.expect(right.x < band(slot + 1).x - reach / 2);
    }
}
