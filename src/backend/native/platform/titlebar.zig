//! The title bar an app draws itself, where it does (Windows and Linux): what it tells the
//! window each frame about where its drag strip, its interactive widgets and its caption buttons
//! are, and the one hit test both platforms answer the OS with — `win32_titlebar`'s
//! `WM_NCHITTEST` and `linux_titlebar`'s SDL hit test. std-only, so the hit test is tested on any
//! host (`fizzy-titlebar-tests`); elsewhere nothing asks it.
//!
//! Hit-test priority within the window:
//!   1. resize edges and corners — only when the caller gives a frame (not while maximized)
//!   2. caption buttons (min/max/close) — right-anchored, recomputed live against the current width
//!   3. interactive rects → the app's (menu items, in-titlebar buttons) — left-anchored
//!   4. the top drag strip (y < strip height) → caption — the full current width
//!   5. anything else → the app's
//! Cached rects can go stale during a resize: Windows delivers WM_NCHITTEST continuously while its
//! modal sizing loop blocks the app's frame. Taking the strip's width from the window's current
//! width and right-anchoring the caption buttons keeps the hit test right even when the last
//! drawn frame is from before the resize.
//!
//! Rects are in physical pixels from the window's top-left — a widget's rectScale(), which the
//! backend hands over as a `Rect` (on Windows the client origin is the window origin:
//! WM_NCCALCSIZE returns 0).
//!
//! Build the hints each frame with this push-based API:
//!   resetTitleBarHints();                                    // once at frame start
//!   setTitleBarStrip(strip_height_pixels, client_pixel_w);   // top drag strip + width caption buttons anchor to
//!   pushTitleBarInteractiveRect(menu_item_rect);             // from anywhere during draw
//!   setTitleBarCaptionButtonRect(.close, rect);
const std = @import("std");
const builtin = @import("builtin");

/// Whether the app draws its own title bar on this platform.
pub const active = builtin.os.tag == .windows or builtin.os.tag == .linux;
/// Whether the OS asks these hints where a press goes: where the app draws its own title bar,
/// and on macOS, where AppKit moves the window from any press in its transparent titlebar's
/// region unless the view there says otherwise (`interactiveAt`).
pub const hit_tested = active or builtin.os.tag == .macos;

/// A caption button the app draws (Windows 11-style: the app draws them, the backend hit-tests them).
pub const TitleBarButton = enum { minimize, maximize, close };

pub const Edge = enum { top_left, top, top_right, right, bottom_right, bottom, bottom_left, left };

/// What a point in the window is, for the OS.
pub const Hit = union(enum) {
    /// The app's: it gets the event.
    client,
    /// The drag strip: the OS moves the window.
    caption,
    button: TitleBarButton,
    resize: Edge,
};

/// A rect in physical pixels from the window's top-left (`Rect`'s fields).
pub const Rect = struct { x: f32, y: f32, w: f32, h: f32 };

const max_interactive_rects = 32;

const CaptionRect = struct {
    rect: Rect,
    // Client pixel width captured at push time, used to right-anchor on resize.
    captured_client_width: i32,
};

var state: struct {
    // Height (px) of the top drag strip. The strip always spans the full current width, read at
    // hit-test time, not cached.
    top_strip_height_pixels: f32 = 0,
    // Width (px) the app saw when it pushed this frame's caption button rects. Caption buttons
    // live at the right edge; on hit-test they shift by the width delta.
    frame_client_pixel_width: i32 = 0,
    interactive_rects: [max_interactive_rects]Rect = undefined,
    interactive_count: usize = 0,
    minimize_rect: ?CaptionRect = null,
    maximize_rect: ?CaptionRect = null,
    close_rect: ?CaptionRect = null,
    // The caption button under the pointer, where the OS reports it (Windows: WM_NCMOUSEMOVE).
    hovered: ?TitleBarButton = null,
} = .{};

/// Clears all per-frame title bar hints. Call at the start of each frame before any widgets push their rects.
pub fn resetTitleBarHints() void {
    state.top_strip_height_pixels = 0;
    state.frame_client_pixel_width = 0;
    state.interactive_count = 0;
    state.minimize_rect = null;
    state.maximize_rect = null;
    state.close_rect = null;
}

/// Sets the top drag strip's height (px) and records the current client pixel width so right-anchored
/// caption buttons stay correct if the window resizes before the next frame.
pub fn setTitleBarStrip(strip_height_pixels: f32, client_pixel_width: i32) void {
    state.top_strip_height_pixels = strip_height_pixels;
    state.frame_client_pixel_width = client_pixel_width;
}

/// Registers a rect the app should receive clicks for. Use for any interactive widget drawn inside
/// the title bar so it overrides the surrounding drag region. Silently drops past limit.
pub fn pushTitleBarInteractiveRect(rect: Rect) void {
    if (state.interactive_count >= max_interactive_rects) return;
    state.interactive_rects[state.interactive_count] = rect;
    state.interactive_count += 1;
}

/// Registers the rect of one of the app-drawn caption buttons. On Windows the hit test answers
/// the matching HT code, so Win11 snap layouts appear over the maximize button and the OS clicks
/// it; on Linux the app takes the click (`window.performTitleBarButton`). The rect is stored with
/// the width recorded by `setTitleBarStrip`; the hit test shifts it by
/// `(current_client_width - captured_client_width)` so right-anchored buttons follow resizes.
pub fn setTitleBarCaptionButtonRect(button: TitleBarButton, rect: Rect) void {
    const captured: CaptionRect = .{
        .rect = rect,
        .captured_client_width = state.frame_client_pixel_width,
    };
    switch (button) {
        .minimize => state.minimize_rect = captured,
        .maximize => state.maximize_rect = captured,
        .close => state.close_rect = captured,
    }
}

/// The caption button the OS reports the pointer over (Windows), for the app's hover art. Where
/// the app gets the pointer itself (Linux) it is null, and the app hovers its buttons as widgets.
pub fn getHoveredTitleBarButton() ?TitleBarButton {
    if (!active) return null;
    return state.hovered;
}

/// Records the hovered caption button; true when it changed (the window wants a repaint).
pub fn setHovered(button: ?TitleBarButton) bool {
    if (state.hovered == button) return false;
    state.hovered = button;
    return true;
}

/// The resize frame's thickness in pixels; zero for no resize edges (maximized, full screen).
pub const Frame = struct { w: i32 = 0, h: i32 = 0 };

/// What the point (`x`, `y`) — physical pixels from the window's top-left — is, in a window
/// `width` × `height` pixels.
pub fn hitTest(x: i32, y: i32, width: i32, height: i32, frame: Frame) Hit {
    // 1) Resize edges/corners.
    if (frame.w > 0 and frame.h > 0) {
        const top = y < frame.h;
        const bottom = y >= height - frame.h;
        if (x < frame.w) return .{ .resize = if (top) .top_left else if (bottom) .bottom_left else .left };
        if (x >= width - frame.w) return .{ .resize = if (top) .top_right else if (bottom) .bottom_right else .right };
        if (bottom) return .{ .resize = .bottom };
        if (top) return .{ .resize = .top };
    }

    // 2) Caption buttons, right-anchored against `width`.
    if (captionRectContains(state.close_rect, width, x, y)) return .{ .button = .close };
    if (captionRectContains(state.maximize_rect, width, x, y)) return .{ .button = .maximize };
    if (captionRectContains(state.minimize_rect, width, x, y)) return .{ .button = .minimize };

    // 3) Interactive widgets in the title bar, checked before the strip so a widget over it still
    //    gets the click. Left-anchored, so the cached rect holds through a resize.
    for (state.interactive_rects[0..state.interactive_count]) |r| {
        if (rectContains(r, x, y)) return .client;
    }

    // 4) The top drag strip, across the whole current width: a resize between frames leaves no
    //    dead zone at the right.
    if (state.top_strip_height_pixels > 0 and @as(f32, @floatFromInt(y)) < state.top_strip_height_pixels) return .caption;

    // 5) The app's.
    return .client;
}

/// Whether the point is the app's to click by its own say — one of its interactive rects or a
/// caption button — wherever it is in the window. macOS asks this alone: AppKit knows its own
/// titlebar's region and only asks whether the app claims the press.
pub fn interactiveAt(x: i32, y: i32) bool {
    for (state.interactive_rects[0..state.interactive_count]) |r| {
        if (rectContains(r, x, y)) return true;
    }
    for ([_]?CaptionRect{ state.minimize_rect, state.maximize_rect, state.close_rect }) |cap| {
        if (cap) |cr| if (rectContains(cr.rect, x, y)) return true;
    }
    return false;
}

fn rectContains(rect: Rect, x: i32, y: i32) bool {
    const fx = @as(f32, @floatFromInt(x));
    const fy = @as(f32, @floatFromInt(y));
    return fx >= rect.x and fy >= rect.y and fx < rect.x + rect.w and fy < rect.y + rect.h;
}

fn captionRectContains(maybe: ?CaptionRect, current_client_width: i32, x: i32, y: i32) bool {
    const cap = maybe orelse return false;
    // Shift the cached rect by however much the window has grown (or shrunk) since it was pushed,
    // so the button stays anchored to the right edge.
    var r = cap.rect;
    r.x += @as(f32, @floatFromInt(current_client_width - cap.captured_client_width));
    return rectContains(r, x, y);
}

test "hitTest: edges first, then buttons, widgets, strip" {
    resetTitleBarHints();
    defer resetTitleBarHints();
    setTitleBarStrip(40, 1000);
    setTitleBarCaptionButtonRect(.close, .{ .x = 954, .y = 0, .w = 46, .h = 30 });
    pushTitleBarInteractiveRect(.{ .x = 50, .y = 5, .w = 40, .h = 25 });
    const frame: Frame = .{ .w = 6, .h = 6 };
    try std.testing.expectEqual(Hit{ .resize = .top_left }, hitTest(2, 2, 1000, 800, frame));
    try std.testing.expectEqual(Hit{ .resize = .bottom }, hitTest(500, 797, 1000, 800, frame));
    try std.testing.expectEqual(Hit{ .button = .close }, hitTest(970, 10, 1000, 800, frame));
    // The window grew 200 px since the frame: the close button followed the right edge.
    try std.testing.expectEqual(Hit{ .button = .close }, hitTest(1170, 10, 1200, 800, frame));
    try std.testing.expectEqual(Hit.client, hitTest(60, 10, 1000, 800, frame));
    try std.testing.expectEqual(Hit.caption, hitTest(500, 20, 1000, 800, frame));
    try std.testing.expectEqual(Hit.client, hitTest(500, 60, 1000, 800, frame));
    // Maximized: no resize edges, the strip reaches the top.
    try std.testing.expectEqual(Hit.caption, hitTest(500, 2, 1000, 800, .{}));
}

test "interactiveAt: the app's rects, anywhere in the window" {
    resetTitleBarHints();
    defer resetTitleBarHints();
    setTitleBarStrip(40, 1000);
    // A dialog dragged up over the strip, reaching below it.
    pushTitleBarInteractiveRect(.{ .x = 300, .y = 10, .w = 400, .h = 300 });
    try std.testing.expect(interactiveAt(310, 20));
    try std.testing.expect(interactiveAt(310, 200));
    try std.testing.expect(!interactiveAt(100, 20));
    try std.testing.expectEqual(Hit.client, hitTest(310, 20, 1000, 800, .{}));
}
