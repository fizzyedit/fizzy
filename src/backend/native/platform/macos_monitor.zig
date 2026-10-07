//! The macOS window through Spaces, zooms and live resizes. AppKit animates a window into and out
//! of a fullscreen Space, and through a zoom, without SDL hearing of the sizes on the way — so
//! dvui laid out at the old size until the animation ended. The monitor (`macos/window_monitor.m`)
//! follows those animations by their notifications, pushes AppKit's live sizes into SDL as they
//! change, and pumps frames from a timer while they run, so the app redraws through them; it also
//! undoes AppKit's nudge of a full-size-content window under the menu bar, and turns vsync off for
//! a live resize so the window keeps up with the pointer. On an SDL with fizzy's live-resize
//! patches (`docs/MACOS_LIVE_RESIZE.md`), `install` also has SDL draw each step of a live resize
//! in the screen update that shows it.
//!
//! An app installs it once its window is styled (`install`) and lets its frames through once it
//! is ready to draw them (`launchComplete`). It relies on two of SDL's own functions that are not
//! in its public headers (`SDL_SendWindowEvent`, `SDL_OnWindowLiveResizeUpdate`) — linked from the
//! static SDL — and is to be checked against SDL when SDL is updated.
const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const Backend = @import("backend");
const c = Backend.c;
const window_layout = @import("window_layout.zig");

const log = std.log.scoped(.macos_monitor);

extern fn fizzy_macos_window_titlebar_inset(cocoa_window: ?*anyopaque) f64;
extern fn fizzy_macos_window_is_zoomed(cocoa_window: ?*anyopaque) c_int;
extern fn fizzy_macos_window_in_fullscreen_space(cocoa_window: ?*anyopaque) c_int;
extern fn fizzy_macos_window_saved_titlebar_inset(cocoa_window: ?*anyopaque) f64;
extern fn fizzy_macos_window_prefer_fullscreen_space(cocoa_window: ?*anyopaque) void;
extern fn fizzy_macos_window_chrome_hidden(cocoa_window: ?*anyopaque) c_int;
extern fn fizzy_macos_window_titlebar_strip_collapsed(cocoa_window: ?*anyopaque) c_int;
extern fn fizzy_macos_window_resize_pump_active() c_int;
extern fn fizzy_macos_window_unzoom_animating(cocoa_window: ?*anyopaque) c_int;
extern fn fizzy_macos_window_space_transition_active(cocoa_window: ?*anyopaque) c_int;
extern fn fizzy_macos_window_space_entering(cocoa_window: ?*anyopaque) c_int;
extern fn fizzy_macos_window_space_has_target(cocoa_window: ?*anyopaque) c_int;
extern fn fizzy_macos_window_transition_sync_active(cocoa_window: ?*anyopaque) c_int;
extern fn fizzy_macos_window_top_left(cocoa_window: ?*anyopaque, out_x: *c_int, out_y: *c_int) void;
extern fn fizzy_macos_window_uninstall_monitor(cocoa_window: ?*anyopaque) void;
extern fn fizzy_macos_window_pixel_size(cocoa_window: ?*anyopaque, out_w: *c_int, out_h: *c_int) void;
extern fn fizzy_macos_window_point_size(cocoa_window: ?*anyopaque, out_w: *c_int, out_h: *c_int) void;
// Frame-based geometry persistence for fizzy's custom (frame == content) window.
extern fn fizzy_macos_window_current_windowed_frame(cocoa_window: ?*anyopaque, out4: [*]f64) void;
extern fn fizzy_macos_window_set_frame(cocoa_window: ?*anyopaque, x: f64, y: f64, w: f64, h: f64) void;
extern fn fizzy_macos_copy_screen_frames(out: [*]f64, max: c_int) c_int;
extern fn fizzy_macos_window_sync_content_views(cocoa_window: ?*anyopaque) void;
extern fn fizzy_macos_window_install_resize_observer(cocoa_window: ?*anyopaque) void;
extern fn fizzy_macos_window_sdl_draws_live_resize(cocoa_window: ?*anyopaque) c_int;

// SDL internals (linked but not in public headers) — the same hooks SDL uses
// for macOS live resize while the window frame is animating.
extern fn SDL_SendWindowEvent(window: *c.SDL_Window, windowevent: c_uint, data1: c_int, data2: c_int) bool;
extern fn SDL_OnWindowLiveResizeUpdate(window: *c.SDL_Window) void;

/// The main window, whose frames the pump renders (`install`).
var macos_monitor_window: ?*c.SDL_Window = null;
/// Gates the pump's frame rendering until AppInit has finished, so the NSTimer
/// can't drive a dvui frame before the app is fully initialized.
var macos_pump_ready = false;

/// A window the monitor follows: the main window (`install`), and each float's own window
/// (`watch`) — one machinery for both, so a float's window goes through a Space, a zoom and a live
/// resize as the main window does.
const Watched = struct {
    window: *c.SDL_Window,
    cocoa: *anyopaque,
    /// Its place is the app's to follow through an animation: a float's window, which its float
    /// follows (`SDLBackend.viewportFollowWindow` reads where SDL says it is).
    follow_position: bool,
    /// Last sizes, and place, pushed into SDL during an AppKit animation.
    last_point: [2]c_int = .{ 0, 0 },
    last_pixel: [2]c_int = .{ 0, 0 },
    last_origin: ?[2]c_int = null,
};
/// The main window and up to the backend's eight viewports, with room to spare.
var watched: [16]?Watched = @splat(null);

fn watchedOf(cocoa: ?*anyopaque) ?*Watched {
    const want = cocoa orelse return null;
    for (&watched) |*slot| {
        if (slot.*) |*w| if (w.cocoa == want) return w;
    }
    return null;
}
/// SDL_OnWindowLiveResizeUpdate can call back into appIterate — never invoke it
/// while already inside a frame or live-resize update.
var macos_in_live_resize: bool = false;

fn cocoaWindowOf(window: *c.SDL_Window) ?*anyopaque {
    return c.SDL_GetPointerProperty(
        c.SDL_GetWindowProperties(window),
        c.SDL_PROP_WINDOW_COCOA_WINDOW_POINTER,
        null,
    );
}

fn macosTransitionSyncActive(w: *const Watched) bool {
    return fizzy_macos_window_transition_sync_active(w.cocoa) != 0;
}

fn macosSpaceSyncAllowed(w: *const Watched) bool {
    return macosTransitionSyncActive(w) or fizzy_macos_window_space_has_target(w.cocoa) != 0;
}

/// Push AppKit's live sizes into SDL — SDL doesn't emit resize events during
/// Space animations, and dvui's SDL backend pairs its reported sizes to the
/// drawable, so this is what keeps layout sizes fresh mid-morph. A float's window, its place too:
/// AppKit moves it into the Space and back out with no word to SDL either.
fn macosSyncRendererSize(w: *Watched, force: bool) void {
    var pw: c_int = 0;
    var ph: c_int = 0;
    var aw: c_int = 0;
    var ah: c_int = 0;
    fizzy_macos_window_point_size(w.cocoa, &pw, &ph);
    fizzy_macos_window_pixel_size(w.cocoa, &aw, &ah);
    if (aw < 1 or ah < 1) return;

    if (w.follow_position) {
        var x: c_int = 0;
        var y: c_int = 0;
        fizzy_macos_window_top_left(w.cocoa, &x, &y);
        const was = w.last_origin;
        if (force or was == null or was.?[0] != x or was.?[1] != y) {
            w.last_origin = .{ x, y };
            _ = SDL_SendWindowEvent(w.window, c.SDL_EVENT_WINDOW_MOVED, x, y);
        }
    }
    if (force or pw > 0 and ph > 0 and (pw != w.last_point[0] or ph != w.last_point[1])) {
        w.last_point = .{ pw, ph };
        _ = SDL_SendWindowEvent(w.window, c.SDL_EVENT_WINDOW_RESIZED, pw, ph);
    }
    if (force or aw != w.last_pixel[0] or ah != w.last_pixel[1]) {
        w.last_pixel = .{ aw, ah };
        _ = SDL_SendWindowEvent(w.window, c.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED, aw, ah);
    }
}

/// Push AppKit sizes into SDL. Does not call SDL_OnWindowLiveResizeUpdate — safe
/// from notification callbacks and from inside appIterate.
fn macosSyncSizes(w: *Watched) void {
    if (!macosSpaceSyncAllowed(w)) return;
    fizzy_macos_window_sync_content_views(w.cocoa);
    macosSyncRendererSize(w, false);
}

fn macosLiveResizeUpdate(window: *c.SDL_Window) void {
    if (macos_in_live_resize) return;
    // From inside a frame — AppKit calls back at once from what a frame asks of it, as
    // `toggleFullScreen:` asked from a command did — a frame run here would nest in that one, and
    // dvui's state does not survive it: every later frame began on the nested one's, and the app
    // slept through the rest of the transition. Wake the loop instead; the next frame follows.
    if (comptime @hasDecl(Backend, "appFrameOpen")) {
        if (Backend.appFrameOpen()) {
            var ue = std.mem.zeroes(c.SDL_Event);
            ue.type = c.SDL_EVENT_USER;
            _ = c.SDL_PushEvent(&ue);
            return;
        }
    }
    macos_in_live_resize = true;
    defer macos_in_live_resize = false;
    if (comptime @hasDecl(Backend, "callbackFrames")) Backend.callbackFrames(true);
    defer if (comptime @hasDecl(Backend, "callbackFrames")) Backend.callbackFrames(false);
    SDL_OnWindowLiveResizeUpdate(window);
}

/// Wake the SDL event loop from an AppKit notification about `cocoa`'s window. Sync its sizes
/// first so the next appIterate begin() sees transition-correct dimensions.
export fn fizzy_macos_window_resize_cb(cocoa: ?*anyopaque) void {
    if (comptime builtin.os.tag == .macos) {
        if (macos_pump_ready) {
            if (watchedOf(cocoa)) |w| macosSyncSizes(w);
        }
    }
    var ue = std.mem.zeroes(c.SDL_Event);
    ue.type = c.SDL_EVENT_USER;
    _ = c.SDL_PushEvent(&ue);
}

/// Called from the monitor's 60Hz NSTimer for each window animating: its live sizes into SDL.
export fn fizzy_macos_window_pump_sync(cocoa: ?*anyopaque) void {
    if (comptime builtin.os.tag == .macos) {
        if (!macos_pump_ready) return;
        if (watchedOf(cocoa)) |w| macosSyncSizes(w);
    }
}

/// Called from the monitor's 60Hz NSTimer once a tick while any window animates — same approach
/// SDL itself uses for live resize: one frame of the app, which draws every window. The timer runs
/// it between frames; a transition's stage, run from inside one, only wakes the loop
/// (`macosLiveResizeUpdate`).
export fn fizzy_macos_window_pump_render() void {
    if (comptime builtin.os.tag == .macos) {
        if (!macos_pump_ready) return;
        const window = macos_monitor_window orelse return;
        macosLiveResizeUpdate(window);
    }
}

/// Sync AppKit → SDL before `Window.begin` during Space / zoom animations only, for every window
/// animating. Registered on the SDL backend from `restoreWindowState`.
fn macosAppPreBeginSync(back: *Backend.SDLBackend) void {
    if (comptime builtin.os.tag != .macos) return;
    if (!macos_pump_ready) return;
    _ = back;
    // Sync AppKit's live sizes into SDL during Space/zoom animations so dvui lays
    // out at transition-correct dimensions. Geometry persistence is owned by fizzy
    // (window.zon) and disabled in dvui, so there is nothing to toggle here.
    for (&watched) |*slot| {
        const w = if (slot.*) |*w| w else continue;
        if (!macosTransitionSyncActive(w)) continue;
        fizzy_macos_window_sync_content_views(w.cocoa);
        macosSyncRendererSize(w, true);
    }
}

/// Saved vsync setting while a manual live resize has it switched off.
var macos_live_resize_saved_vsync: ?c_int = null;

/// Frames during a manual live resize are paced by SDL's 60Hz timer inside AppKit's
/// resize-tracking loop; a vsync-blocking present there only delays the tracker's next
/// mouse event, so quick drags fall behind the pointer. Off for the drag, restored after —
/// unless SDL draws the resize itself (`sdl_draws_live_resize` in `macos/window_monitor.m`),
/// whose presents wait for no vsync.
export fn fizzy_macos_window_live_resize_vsync(cocoa: ?*anyopaque, active: c_int) void {
    if (comptime builtin.os.tag != .macos) return;
    const window = macos_monitor_window orelse return;
    // The main window's: a float's window is drawn with the main one's frame, paced by it.
    if (cocoa == null or cocoaWindowOf(window) != cocoa) return;
    // Fizzy's own backend sets its swapchain's present mode; dvui's SDL_Renderer one its renderer's.
    if (comptime @hasDecl(Backend, "setWindowVSync")) {
        if (active != 0) {
            if (macos_live_resize_saved_vsync != null) return;
            const vsync = Backend.windowVSync(window) orelse return;
            macos_live_resize_saved_vsync = @intFromBool(vsync);
            _ = Backend.setWindowVSync(window, false);
        } else if (macos_live_resize_saved_vsync) |vsync| {
            macos_live_resize_saved_vsync = null;
            _ = Backend.setWindowVSync(window, vsync != 0);
        }
        return;
    }
    const renderer = c.SDL_GetRenderer(window) orelse return;
    if (active != 0) {
        if (macos_live_resize_saved_vsync != null) return;
        var vsync: c_int = 0;
        if (!c.SDL_GetRenderVSync(renderer, &vsync)) return;
        macos_live_resize_saved_vsync = vsync;
        _ = c.SDL_SetRenderVSync(renderer, 0);
    } else if (macos_live_resize_saved_vsync) |vsync| {
        macos_live_resize_saved_vsync = null;
        _ = c.SDL_SetRenderVSync(renderer, vsync);
    }
}

export fn fizzy_macos_window_reset_sync_cache(cocoa: ?*anyopaque) void {
    const w = watchedOf(cocoa) orelse return;
    w.last_point = .{ 0, 0 };
    w.last_pixel = .{ 0, 0 };
    w.last_origin = null;
}

/// Reconcile SDL's cached sizes and Metal drawable with `cocoa`'s live AppKit bounds.
/// Called at didEnter/didExit so steady state never keeps transition sizes.
export fn fizzy_macos_window_commit_steady_state(cocoa: ?*anyopaque) void {
    if (comptime builtin.os.tag != .macos) return;
    if (!macos_pump_ready) return;
    const w = watchedOf(cocoa) orelse return;
    fizzy_macos_window_reset_sync_cache(cocoa);
    fizzy_macos_window_sync_content_views(w.cocoa);
    macosSyncRendererSize(w, true);
    if (macos_monitor_window) |main| macosLiveResizeUpdate(main);
}

export fn fizzy_macos_window_request_clear_frames(cocoa: ?*anyopaque, frames: c_int) void {
    // dvui's SDL backend clears the window on every begin
    // (clear_window_on_begin), so no extra clearing is needed.
    _ = cocoa;
    _ = frames;
}

/// C-ABI for `macos/window_monitor.m`'s `-constrainFrameRect:toScreen:` override.
/// Returns 1 when AppKit's `constrained` result is just the menu-bar nudge of a
/// top-anchored full-size-content window (which the monitor then undoes). Rects
/// are AppKit screen coords (NSRect order); `visible_top` is NSMaxY(visibleFrame).
/// Single source of truth shared with the unit tests in window_layout.zig.
export fn fizzy_macos_constrain_is_menu_bar_nudge(
    rx: f64,
    ry: f64,
    rw: f64,
    rh: f64,
    cx: f64,
    cy: f64,
    cw: f64,
    ch: f64,
    visible_top: f64,
) c_int {
    const is_nudge = window_layout.constrainResultIsMenuBarNudge(
        .{ .x = rx, .y = ry, .w = rw, .h = rh },
        .{ .x = cx, .y = cy, .w = cw, .h = ch },
        visible_top,
        40.0,
        0.5,
    );
    return if (is_nudge) 1 else 0;
}

/// C-ABI for the post-exit origin re-assert: returns 1 when the current origin is
/// AppKit's small exit nudge of the captured pre-fullscreen origin (so it should
/// be re-asserted), 0 when already correct or moved too far to be the nudge.
export fn fizzy_macos_origin_nudged(cap_x: f64, cap_y: f64, cur_x: f64, cur_y: f64) c_int {
    return if (window_layout.originNudged(cap_x, cap_y, cur_x, cur_y, 64.0)) 1 else 0;
}

/// Follow `win` through Spaces, zooms and live resizes: from here on AppKit's live sizes reach SDL
/// before each frame (`Backend.SDLBackend.begin_hook`) and through every animation. Call once the
/// window's chrome is in place, before it is shown.
pub fn install(win: *dvui.Window) void {
    if (comptime builtin.os.tag != .macos) return;
    const back = win.backend.impl;
    const cocoa = cocoaWindowOf(back.window) orelse return;
    macos_monitor_window = back.window;
    back.begin_hook = macosAppPreBeginSync;
    addWatched(.{ .window = back.window, .cocoa = cocoa, .follow_position = false });
    fizzy_macos_window_install_resize_observer(cocoa);
    // Draw each step of a live resize from inside it, presented with the Core Animation
    // transaction that resizes the window, so the new size and the frame drawn for it reach the
    // screen together (fizzyedit/SDL's live-resize patches, `docs/MACOS_LIVE_RESIZE.md`). By name,
    // not SDL's #define, so this builds against an SDL without them, which ignores it.
    _ = c.SDL_SetHint("SDL_VIDEO_MAC_SYNC_LIVE_RESIZE", "1");
    // Which one this build has is otherwise invisible until a drag looks wrong.
    if (fizzy_macos_window_sdl_draws_live_resize(cocoa) != 0) {
        log.info("live resize: SDL draws each step in its transaction (fizzy's SDL patches)", .{});
    } else {
        log.info("live resize: timer-driven (this SDL has no live-resize patches, or SDL_VIDEO_MAC_SYNC_LIVE_RESIZE=0)", .{});
    }
}

fn addWatched(w: Watched) void {
    if (watchedOf(w.cocoa) != null) return;
    for (&watched) |*slot| {
        if (slot.* == null) {
            slot.* = w;
            return;
        }
    }
}

/// Follow a float's own window through Spaces, zooms and live resizes as the main window is
/// followed (`install`): it goes full screen in a Space of its own, and its float follows it there
/// and back. Call once its chrome is in place; `unwatch` before it closes.
pub fn watch(window: *c.SDL_Window) void {
    if (comptime builtin.os.tag != .macos) return;
    const cocoa = cocoaWindowOf(window) orelse return;
    addWatched(.{ .window = window, .cocoa = cocoa, .follow_position = true });
    fizzy_macos_window_install_resize_observer(cocoa);
    fizzy_macos_window_prefer_fullscreen_space(cocoa);
}

/// Stop following a float's window (`watch`), as it closes.
pub fn unwatch(window: *c.SDL_Window) void {
    if (comptime builtin.os.tag != .macos) return;
    const cocoa = cocoaWindowOf(window) orelse return;
    fizzy_macos_window_uninstall_monitor(cocoa);
    for (&watched) |*slot| {
        if (slot.*) |w| if (w.cocoa == cocoa) {
            slot.* = null;
        };
    }
}

/// Whether AppKit owns a watched window's frame: in a fullscreen Space, or on its way into or out
/// of one, or un-zooming. Nothing may move it then.
pub fn osOwnsFrame(window: *c.SDL_Window) bool {
    if (comptime builtin.os.tag != .macos) return false;
    const cocoa = cocoaWindowOf(window) orelse return false;
    return fizzy_macos_window_in_fullscreen_space(cocoa) != 0 or fizzy_macos_window_transition_sync_active(cocoa) != 0;
}

/// Called at the end of AppInit: allows the monitor's pump timer to start
/// driving dvui frames during window animations.
pub fn launchComplete() void {
    macos_pump_ready = true;
}

/// What the app needs to keep its content clear of the traffic lights (`window_layout.chooseTitlebarStrip`):
/// the window's titlebar inset now and as it was last windowed, and whether its chrome is hidden
/// or coming back.
pub const TitlebarState = struct {
    collapsed: bool = false,
    restoring_chrome: bool = false,
    live_inset: f32 = 0,
    saved_inset: f32 = 0,
};

pub fn titlebarState(win: *dvui.Window) TitlebarState {
    if (comptime builtin.os.tag != .macos) return .{};
    const raw_ptr = cocoaWindowOf(win.backend.impl.window);
    const inset = if (raw_ptr != null) fizzy_macos_window_titlebar_inset(raw_ptr) else 0;
    const saved = fizzy_macos_window_saved_titlebar_inset(raw_ptr);
    return .{
        .collapsed = raw_ptr != null and fizzy_macos_window_titlebar_strip_collapsed(raw_ptr) != 0,
        .restoring_chrome = raw_ptr != null and (fizzy_macos_window_unzoom_animating(raw_ptr) != 0 or
            (fizzy_macos_window_space_transition_active(raw_ptr) != 0 and
                fizzy_macos_window_space_entering(raw_ptr) == 0)),
        .live_inset = if (inset > 0) @floatCast(inset) else 0,
        .saved_inset = if (saved > 0) @floatCast(saved) else 0,
    };
}
