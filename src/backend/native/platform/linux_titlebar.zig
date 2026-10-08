//! Linux chrome: the window without the desktop's decorations, the app drawing its own title bar
//! across the top of its content as it does on Windows, and SDL's hit test answering the
//! compositor from `titlebar`'s hints — the drag strip moves the window, its edges resize it.
//! SDL asks on every pointer motion and acts on the press: xdg-shell's interactive move and
//! resize on Wayland (through libdecor where SDL uses it), `_NET_WM_MOVERESIZE` on X11. The
//! caption buttons are the app's to click (`window.performTitleBarButton`): the hit test leaves
//! them to it. Everything here is a no-op off Linux.
//!
//! The app opts in before its window is made (`useClientDecorations`): no libdecor, a
//! borderless window, and a margin round the frame where the app draws the drop shadow a desktop
//! would have — fizzyedit/SDL's frame insets, which tell a Wayland compositor the frame is the
//! window (it places, snaps and tiles that) and let the rest of the shadow pass clicks through.
//!
//! Not yet: a double click on the strip does not maximize. The press that starts a move never
//! reaches the app (SDL hands it to the compositor and stops), so it would have to be SDL's.
const builtin = @import("builtin");
const dvui = @import("dvui");
const backend = @import("backend");
const c = backend.c;
const titlebar = @import("titlebar.zig");
const wayland_blur = @import("wayland_blur.zig");

/// The margins round the frame for its shadow, in window coordinates (points).
pub const Insets = struct { left: f32 = 0, top: f32 = 0, right: f32 = 0, bottom: f32 = 0 };

var requested_insets: Insets = .{};

/// Before the window is made (before `initWindow`): the app draws its window's decorations — the
/// title bar and, in `insets` round the frame, its drop shadow. SDL loads no libdecor (on a
/// desktop without server-side decorations, GNOME, the window then has none of its own) and
/// makes the window borderless with those frame insets. Where SDL keeps no margin (X11)
/// `frameInsets` reads zero and nothing draws there.
pub fn useClientDecorations(insets: Insets) void {
    if (builtin.os.tag != .linux) return;
    // Only fizzy's own backend makes the window through a creation hook, against an SDL with
    // frame insets; dvui's keeps the desktop's decorations.
    if (comptime @hasDecl(backend, "window_create_hook") and @hasDecl(c, "SDL_PROP_WINDOW_CREATE_WAYLAND_FRAME_INSET_LEFT_NUMBER")) {
        requested_insets = insets;
        _ = c.SDL_SetHint(c.SDL_HINT_VIDEO_WAYLAND_ALLOW_LIBDECOR, "0");
        backend.window_create_hook = addCreateProps;
    }
}

fn addCreateProps(props: c.SDL_PropertiesID) void {
    _ = c.SDL_SetBooleanProperty(props, c.SDL_PROP_WINDOW_CREATE_BORDERLESS_BOOLEAN, true);
    _ = c.SDL_SetNumberProperty(props, c.SDL_PROP_WINDOW_CREATE_WAYLAND_FRAME_INSET_LEFT_NUMBER, @intFromFloat(@round(requested_insets.left)));
    _ = c.SDL_SetNumberProperty(props, c.SDL_PROP_WINDOW_CREATE_WAYLAND_FRAME_INSET_TOP_NUMBER, @intFromFloat(@round(requested_insets.top)));
    _ = c.SDL_SetNumberProperty(props, c.SDL_PROP_WINDOW_CREATE_WAYLAND_FRAME_INSET_RIGHT_NUMBER, @intFromFloat(@round(requested_insets.right)));
    _ = c.SDL_SetNumberProperty(props, c.SDL_PROP_WINDOW_CREATE_WAYLAND_FRAME_INSET_BOTTOM_NUMBER, @intFromFloat(@round(requested_insets.bottom)));
}

/// The frame's margins in effect now, in window coordinates: those asked for while the window
/// floats on Wayland; zero maximized, tiled or full screen, or where SDL keeps none.
pub fn frameInsets(window: *c.SDL_Window) Insets {
    if (comptime builtin.os.tag == .linux and @hasDecl(c, "SDL_PROP_WINDOW_WAYLAND_FRAME_INSET_LEFT_NUMBER")) {
        const props = c.SDL_GetWindowProperties(window);
        return .{
            .left = @floatFromInt(c.SDL_GetNumberProperty(props, c.SDL_PROP_WINDOW_WAYLAND_FRAME_INSET_LEFT_NUMBER, 0)),
            .top = @floatFromInt(c.SDL_GetNumberProperty(props, c.SDL_PROP_WINDOW_WAYLAND_FRAME_INSET_TOP_NUMBER, 0)),
            .right = @floatFromInt(c.SDL_GetNumberProperty(props, c.SDL_PROP_WINDOW_WAYLAND_FRAME_INSET_RIGHT_NUMBER, 0)),
            .bottom = @floatFromInt(c.SDL_GetNumberProperty(props, c.SDL_PROP_WINDOW_WAYLAND_FRAME_INSET_BOTTOM_NUMBER, 0)),
        };
    }
    return .{};
}

/// The desktop's blur behind the window's frame (`wayland_blur`), inside the margin its shadow is
/// drawn in (`frameInsets`), its corners rounded by `radius` points — or none, null. Whether the
/// compositor blurs behind windows at all: Wayland with `ext-background-effect-v1` (GNOME 51,
/// Plasma 6.7, niri) or KDE's older `org_kde_kwin_blur`. Not X11, nor a compositor without either.
/// Cheap to call every frame; it is sent to the compositor only when it changes, and taken with
/// the frame presented next.
pub fn blurBehind(window: *c.SDL_Window, radius: ?f32) bool {
    if (comptime builtin.os.tag != .linux) return false;
    const props = c.SDL_GetWindowProperties(window);
    const display = c.SDL_GetPointerProperty(props, c.SDL_PROP_WINDOW_WAYLAND_DISPLAY_POINTER, null) orelse return false;
    const surface = c.SDL_GetPointerProperty(props, c.SDL_PROP_WINDOW_WAYLAND_SURFACE_POINTER, null) orelse return false;
    const want: ?wayland_blur.Want = if (radius) |r| want: {
        // The surface is the window SDL reports (points), the frame and its shadow's margin.
        var w: c_int = 0;
        var h: c_int = 0;
        _ = c.SDL_GetWindowSize(window, &w, &h);
        const in = frameInsets(window);
        const left: i32 = @intFromFloat(@round(in.left));
        const top: i32 = @intFromFloat(@round(in.top));
        break :want .{
            .frame = .{
                .x = left,
                .y = top,
                .w = w - left - @as(i32, @intFromFloat(@round(in.right))),
                .h = h - top - @as(i32, @intFromFloat(@round(in.bottom))),
            },
            .radius = r,
        };
    } else null;
    return wayland_blur.behind(display, surface, want);
}

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
    // The frame sits inside its shadow's margin; its edges resize from either side of the line.
    const in = frameInsets(w);
    const px = struct {
        fn px(v: f32, d: f32) i32 {
            return @intFromFloat(@round(v * d));
        }
    }.px;
    return switch (titlebar.hitTest(x, y, width, height, .{
        .w = f,
        .h = f,
        .insets = .{ .left = px(in.left, density), .top = px(in.top, density), .right = px(in.right, density), .bottom = px(in.bottom, density) },
    })) {
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
