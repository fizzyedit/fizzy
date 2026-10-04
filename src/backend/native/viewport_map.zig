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

/// `r` on whole pixels: what a float's rect, a pixel-snapped picture, is meant to be. A size that
/// is an odd number of pixels is a half point, and float noise either side of it (678.9999,
/// 679.0001) rounded to points one way, then the other: the window's edge flickered by a point as
/// it moved. On whole pixels first, a half point always rounds the same way.
fn wholePixels(r: Rect) Rect {
    return .{ .x = @round(r.x), .y = @round(r.y), .w = @round(r.w), .h = @round(r.h) };
}

/// Where to put a window showing `frame` (band `b`): on whole points, the nearest to it.
pub fn place(b: Point, anchor: Point, density: f32, frame: Rect) Placement {
    const screen = wholePoints(screenFromFrame(b, anchor, density, wholePixels(frame)));
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

/// Where a part of the main window's frame — `frame`, physical pixels, which may lie past its edge,
/// the frame running on across the desktop — is on the desktop, the main window at `main` with
/// `density` pixels per point: a window split out of the main one under a drag, still in the main
/// window's frame while the drag goes on.
pub fn screenFromMain(main: Point, density: f32, frame: Rect) Rect {
    return .{
        .x = main.x + frame.x / density,
        .y = main.y + frame.y / density,
        .w = frame.w / density,
        .h = frame.h / density,
    };
}

/// Where to put a window showing `frame` of the main window's frame (`screenFromMain`): on whole
/// points, and the part of the frame it then shows.
pub fn placeMain(main: Point, density: f32, frame: Rect) Placement {
    const screen = wholePoints(screenFromMain(main, density, wholePixels(frame)));
    return .{ .screen = screen, .frame = mainFromScreen(main, density, screen) };
}

/// The farthest a window is ever put from the desktop's origin, points, each way. Past about
/// 46340, SDL's search for the display a window is on squares the distance as an `int` and
/// overflows (`GetDisplayForRect`): a panic in Debug, garbage after. A window that far from any
/// display is lost to the user anyway.
pub const screen_limit: f32 = 16384;

/// `s` (desktop points) on whole points, within `screen_limit` — and a rect gone NaN, which a float
/// cast to an integer cannot be, at the origin.
pub fn wholePoints(s: Rect) ScreenRect {
    const Sane = struct {
        fn of(v: f32, lo: f32) f32 {
            if (std.math.isNan(v)) return lo;
            return std.math.clamp(@round(v), lo, screen_limit);
        }
    };
    return .{
        .x = @intFromFloat(Sane.of(s.x, -screen_limit)),
        .y = @intFromFloat(Sane.of(s.y, -screen_limit)),
        .w = @intFromFloat(Sane.of(s.w, 1)),
        .h = @intFromFloat(Sane.of(s.h, 1)),
    };
}

/// The part of the frame, physical pixels, a window the OS moved or resized to `screen` (desktop
/// points) shows in the band starting at `b`: where its float goes, so it follows its window.
pub fn frameOfScreen(b: Point, anchor: Point, density: f32, screen: ScreenRect) Rect {
    const at = frameFromScreen(b, anchor, density, .{ .x = @floatFromInt(screen.x), .y = @floatFromInt(screen.y) });
    return .{
        .x = at.x,
        .y = at.y,
        .w = @as(f32, @floatFromInt(screen.w)) * density,
        .h = @as(f32, @floatFromInt(screen.h)) * density,
    };
}

// ---- A press on a viewport's window, for the OS ------------------------------------------------
//
// The OS moves and resizes a float's window itself, as it does any window — so it snaps, tiles,
// maximizes — from what the float says each frame of where its header and edges are. Window
// coordinates throughout: SDL's, from the window's top left.

pub const Hints = struct {
    /// The float's header: a press there is the OS's to move the window by.
    drag: Rect = .{},
    /// Inside `drag`, the app's all the same: the header's close button.
    keep: Rect = .{},
    /// The float's glass, whose edges resize the window — `edge` in from each side, and anything
    /// of the window outside it — where the OS resizes it. Zero `edge`: it does not (the platform
    /// has no resize regions, or the window is maximized).
    glass: Rect = .{},
    edge: f32 = 0,
    /// Where the OS resizes nothing from a hit test (macOS): how far in from the glass's sides,
    /// and along them from its corners, a press is the app's however it lies over the header —
    /// the float's own resize zones (`FloatingWindowWidget`), so a press on the header's corner
    /// resizes the float, as it does in the main window, rather than moving its window.
    app_side: f32 = 0,
    app_corner: f32 = 0,
};

pub const Hit = enum { app, drag, top_left, top, top_right, right, bottom_right, bottom, bottom_left, left };

/// What a press at `p` is: the OS's to resize the window from an edge or corner, the OS's to move
/// it by, or the app's.
pub fn hitTest(h: Hints, p: Point) Hit {
    if (h.edge > 0) {
        const g = h.glass;
        const near_l = p.x < g.x + h.edge;
        const near_r = p.x >= g.x + g.w - h.edge;
        const near_t = p.y < g.y + h.edge;
        const near_b = p.y >= g.y + g.h - h.edge;
        if (near_l or near_r or near_t or near_b) {
            // A corner reaches further along each side than an edge is deep, as a window's does.
            const reach = h.edge * 3;
            const top = p.y < g.y + reach;
            const bottom = p.y >= g.y + g.h - reach;
            const left = p.x < g.x + reach;
            const right = p.x >= g.x + g.w - reach;
            if (top and left) return .top_left;
            if (top and right) return .top_right;
            if (bottom and left) return .bottom_left;
            if (bottom and right) return .bottom_right;
            if (near_t) return .top;
            if (near_b) return .bottom;
            if (near_l) return .left;
            return .right;
        }
    }
    if (h.app_side > 0 or h.app_corner > 0) {
        const g = h.glass;
        const in_x = p.x >= g.x and p.x < g.x + g.w;
        const in_y = p.y >= g.y and p.y < g.y + g.h;
        const side = (in_y and (p.x < g.x + h.app_side or p.x >= g.x + g.w - h.app_side)) or
            (in_x and (p.y < g.y + h.app_side or p.y >= g.y + g.h - h.app_side));
        const near_x = p.x < g.x + h.app_corner or p.x >= g.x + g.w - h.app_corner;
        const near_y = p.y < g.y + h.app_corner or p.y >= g.y + g.h - h.app_corner;
        if (side or (in_x and in_y and near_x and near_y)) return .app;
    }
    if (contains(h.drag, p) and !contains(h.keep, p)) return .drag;
    return .app;
}

fn contains(r: Rect, p: Point) bool {
    return p.x >= r.x and p.y >= r.y and p.x < r.x + r.w and p.y < r.y + r.h;
}

const testing = std.testing;

test "a window is never put where SDL's display search overflows" {
    const far = place(.{ .x = 100000, .y = 0 }, .{ .x = 300, .y = 200 }, 2, .{ .x = -1e9, .y = 3e9, .w = 1e9, .h = 10 });
    try std.testing.expectEqual(@as(i32, -16384), far.screen.x);
    try std.testing.expectEqual(@as(i32, 16384), far.screen.y);
    try std.testing.expectEqual(@as(i32, 16384), far.screen.w);
    const nan = placeMain(.{ .x = 300, .y = 200 }, 2, .{ .x = std.math.nan(f32), .y = 0, .w = std.math.nan(f32), .h = 40 });
    try std.testing.expectEqual(@as(i32, -16384), nan.screen.x);
    try std.testing.expectEqual(@as(i32, 1), nan.screen.w);
    try std.testing.expectEqual(@as(i32, 20), nan.screen.h);
}

test "a window the OS moved shows the part of the band under it, and placing it there leaves it be" {
    const b = band(0);
    const anchor: Point = .{ .x = 100, .y = 50 };
    const moved: ScreenRect = .{ .x = 700, .y = 420, .w = 380, .h = 460 };
    const frame = frameOfScreen(b, anchor, 2, moved);
    try testing.expectEqual(@as(f32, b.x + 1200), frame.x);
    try testing.expectEqual(@as(f32, 740), frame.y);
    try testing.expectEqual(@as(f32, 760), frame.w);
    // Its float drawn there next frame puts its window exactly where the OS left it.
    try testing.expectEqual(moved, place(b, anchor, 2, frame).screen);
}

test "a float an odd number of pixels wide keeps one window size, whatever the noise in its rect" {
    const main: Point = .{ .x = 300, .y = 200 };
    // 679 physical pixels is 339.5 points; the float's rect comes out a hair either side of it.
    const a = placeMain(main, 2, .{ .x = 100.0001, .y = 50, .w = 678.9999, .h = 400 });
    const b2 = placeMain(main, 2, .{ .x = 99.9999, .y = 50, .w = 679.0001, .h = 400 });
    try testing.expectEqual(a.screen.w, b2.screen.w);
    try testing.expectEqual(a.screen.x, b2.screen.x);
    const band0 = band(0);
    const c = place(band0, main, 2, .{ .x = band0.x + 100.0001, .y = 50, .w = 678.9999, .h = 400 });
    const d = place(band0, main, 2, .{ .x = band0.x + 99.9999, .y = 50, .w = 679.0001, .h = 400 });
    try testing.expectEqual(c.screen.w, d.screen.w);
}

test "a press on a float's window: its edges and corners resize, its header moves, its close button and the rest are the app's" {
    const h: Hints = .{
        .drag = .{ .x = 0, .y = 0, .w = 300, .h = 32 },
        .keep = .{ .x = 268, .y = 0, .w = 32, .h = 32 },
        .glass = .{ .x = 0, .y = 0, .w = 300, .h = 200 },
        .edge = 4,
    };
    try testing.expectEqual(Hit.drag, hitTest(h, .{ .x = 150, .y = 16 }));
    try testing.expectEqual(Hit.app, hitTest(h, .{ .x = 280, .y = 16 }));
    try testing.expectEqual(Hit.app, hitTest(h, .{ .x = 150, .y = 100 }));
    try testing.expectEqual(Hit.top, hitTest(h, .{ .x = 150, .y = 1 }));
    try testing.expectEqual(Hit.left, hitTest(h, .{ .x = 1, .y = 100 }));
    try testing.expectEqual(Hit.bottom_right, hitTest(h, .{ .x = 299, .y = 199 }));
    // A corner reaches along the side further than the edge is deep.
    try testing.expectEqual(Hit.top_left, hitTest(h, .{ .x = 1, .y = 10 }));
    // No resize edges: the header's top moves the window.
    var no_edges = h;
    no_edges.edge = 0;
    try testing.expectEqual(Hit.drag, hitTest(no_edges, .{ .x = 150, .y = 1 }));
}

test "where the OS resizes nothing, the float's own corners and edges stay the app's over the header" {
    const h: Hints = .{
        .drag = .{ .x = 0, .y = 0, .w = 300, .h = 32 },
        .glass = .{ .x = 0, .y = 0, .w = 300, .h = 200 },
        .app_side = 4,
        .app_corner = 15,
    };
    // The header's corners and top edge: the float resizes.
    try testing.expectEqual(Hit.app, hitTest(h, .{ .x = 5, .y = 5 }));
    try testing.expectEqual(Hit.app, hitTest(h, .{ .x = 295, .y = 10 }));
    try testing.expectEqual(Hit.app, hitTest(h, .{ .x = 150, .y = 2 }));
    // Its middle moves the window.
    try testing.expectEqual(Hit.drag, hitTest(h, .{ .x = 150, .y = 16 }));
    try testing.expectEqual(Hit.drag, hitTest(h, .{ .x = 20, .y = 16 }));
}

test "a press in the clear margin round the glass resizes from the nearest edge" {
    const h: Hints = .{ .glass = .{ .x = 10, .y = 10, .w = 300, .h = 200 }, .edge = 4 };
    try testing.expectEqual(Hit.left, hitTest(h, .{ .x = 3, .y = 100 }));
    try testing.expectEqual(Hit.bottom, hitTest(h, .{ .x = 150, .y = 215 }));
}

test "the main window's frame runs on across the desktop: past its edge is where a split window goes" {
    const main: Point = .{ .x = 100, .y = 50 };
    const r = screenFromMain(main, 2, .{ .x = 1000, .y = -40, .w = 300, .h = 200 });
    try testing.expectEqual(@as(f32, 600), r.x);
    try testing.expectEqual(@as(f32, 30), r.y);
    try testing.expectEqual(@as(f32, 150), r.w);
    // Placed on whole points, and back: the same part of the frame.
    const p = placeMain(main, 2, .{ .x = 1000, .y = -40, .w = 300, .h = 200 });
    try testing.expectEqual(@as(i32, 600), p.screen.x);
    try testing.expectEqual(@as(f32, 1000), p.frame.x);
    try testing.expectEqual(@as(f32, -40), p.frame.y);
}

test "a window split out of the main one is the same place on the desktop in its band" {
    // Split under a drag in the main window's frame, then settled into band 0: the frame of the
    // band, read back to the desktop, is where the window was.
    const main: Point = .{ .x = 300, .y = 120 };
    const at = screenFromMain(main, 2, .{ .x = 2500, .y = 200, .w = 400, .h = 300 });
    const b = band(0);
    const in_band = frameFromScreen(b, main, 2, .{ .x = at.x, .y = at.y });
    const back = screenFromFrame(b, main, 2, .{ .x = in_band.x, .y = in_band.y, .w = 400, .h = 300 });
    try testing.expectApproxEqAbs(at.x, back.x, 0.001);
    try testing.expectApproxEqAbs(at.y, back.y, 0.001);
}

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
