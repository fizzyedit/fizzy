//! Linux chrome: the window without the desktop's decorations, the app drawing its own title bar
//! across the top of its content as it does on Windows, and SDL's hit test answering the
//! compositor from `titlebar`'s hints — the drag strip moves the window, its edges resize it.
//! SDL asks on every pointer motion and acts on the press: xdg-shell's interactive move and
//! resize on Wayland (through libdecor where SDL uses it), `_NET_WM_MOVERESIZE` on X11. The
//! caption buttons are the app's to click (`window.performTitleBarButton`): the hit test leaves
//! them to it. Everything here is a no-op off Linux.
//!
//! Not yet: a double click on the strip does not maximize. The press that starts a move never
//! reaches the app (SDL hands it to the compositor and stops), so it would have to be SDL's.
const builtin = @import("builtin");
const dvui = @import("dvui");
const c = @import("backend").c;
const titlebar = @import("titlebar.zig");

/// The window whose chrome is in place.
var styled_window: ?*c.SDL_Window = null;

/// How far in from the window's edge, in points, a press resizes instead of reaching the app.
const resize_frame_points: f32 = 6;

/// Apply the chrome to `win` (see `window.setStyle`): idempotent, cheap to call every frame.
pub fn applyChrome(win: *dvui.Window) void {
    if (builtin.os.tag != .linux) return;
    const window = win.backend.impl.window;
    if (styled_window == window) return;
    styled_window = window;
    // At runtime rather than at creation: an app on this backend that draws no title bar keeps
    // the desktop's. With libdecor this hides its frame; with server-side decorations it asks
    // for none.
    _ = c.SDL_SetWindowBordered(window, false);
    _ = c.SDL_SetWindowHitTest(window, hitTest, null);
}

/// `area` is in window coordinates; `titlebar`'s hints are in pixels.
fn hitTest(window: ?*c.SDL_Window, area: [*c]const c.SDL_Point, _: ?*anyopaque) callconv(.c) c.SDL_HitTestResult {
    const w = window orelse return c.SDL_HITTEST_NORMAL;
    const density = c.SDL_GetWindowPixelDensity(w);
    var width: c_int = 0;
    var height: c_int = 0;
    _ = c.SDL_GetWindowSizeInPixels(w, &width, &height);
    // No resize edges while maximized or full screen: the window fills what it can.
    const sized = c.SDL_GetWindowFlags(w) & (c.SDL_WINDOW_MAXIMIZED | c.SDL_WINDOW_FULLSCREEN) == 0;
    const f: i32 = if (sized) @intFromFloat(@round(resize_frame_points * density)) else 0;
    const x: i32 = @intFromFloat(@as(f32, @floatFromInt(area.*.x)) * density);
    const y: i32 = @intFromFloat(@as(f32, @floatFromInt(area.*.y)) * density);
    return switch (titlebar.hitTest(x, y, width, height, .{ .w = f, .h = f })) {
        .client, .button => c.SDL_HITTEST_NORMAL,
        .caption => c.SDL_HITTEST_DRAGGABLE,
        .resize => |e| switch (e) {
            .top_left => c.SDL_HITTEST_RESIZE_TOPLEFT,
            .top => c.SDL_HITTEST_RESIZE_TOP,
            .top_right => c.SDL_HITTEST_RESIZE_TOPRIGHT,
            .right => c.SDL_HITTEST_RESIZE_RIGHT,
            .bottom_right => c.SDL_HITTEST_RESIZE_BOTTOMRIGHT,
            .bottom => c.SDL_HITTEST_RESIZE_BOTTOM,
            .bottom_left => c.SDL_HITTEST_RESIZE_BOTTOMLEFT,
            .left => c.SDL_HITTEST_RESIZE_LEFT,
        },
    };
}
