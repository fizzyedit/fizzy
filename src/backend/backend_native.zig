// These are functions specific to the backend, which is currently SDL3
const fizzy = @import("../fizzy.zig");
const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const sdl3 = @import("backend").c;
const objc = @import("objc");
const win32 = @import("win32");
const singleton = @import("singleton.zig");
const window_layout = @import("window_layout.zig");

// AppKit geometry types for NSView frame/bounds (same layout as Foundation).
const NSPoint = extern struct { x: f64, y: f64 };
const NSSize = extern struct { width: f64, height: f64 };
const NSRect = extern struct { origin: NSPoint, size: NSSize };

const DWMWA_SYSTEM_BACKDROP_TYPE: c_ulong = 20;
const DWMWA_SYSTEM_BACKDROP_TYPE_DEFAULT: c_ulong = 0;
const DWMWA_SYSTEM_BACKDROP_TYPE_ACRYLIC: c_ulong = 1;
const DWMWA_SYSTEM_BACKDROP_TYPE_NONE: c_ulong = 2;
const DWMWA_SYSTEM_BACKDROP_TYPE_TRANSPARENT: c_ulong = 3;
const DWMWA_SYSTEM_BACKDROP_TYPE_BLUR_BEHIND: c_ulong = 4;
const DWMWA_SYSTEM_BACKDROP_TYPE_ACRYLIC_LIGHT: c_ulong = 5;
const DWMWA_SYSTEM_BACKDROP_TYPE_ACRYLIC_DARK: c_ulong = 6;

// Windows 11 (Build 22621+): System backdrop and extended frame for title bar drawing.
const DWMWA_SYSTEMBACKDROP_TYPE: u32 = 38; // Windows 11 SDK
const DWMSBT_MAINWINDOW: u32 = 2; // Mica
const DWMSBT_TRANSIENTWINDOW: u32 = 3; // Acrylic (frosted glass) — more visible blur than Mica

// Undocumented user32 API for acrylic blur (used by Start menu, taskbar). Loaded at runtime.
const WCA_ACCENT_POLICY: u32 = 19;
const ACCENT_ENABLE_ACRYLICBLURBEHIND: u32 = 4;
const WINCOMPATTR_DATA = struct {
    attrib: u32,
    pv_data: *const anyopaque,
    cb_data: usize,
};
const ACCENT_POLICY = struct {
    accent_state: u32,
    accent_flags: u32,
    gradient_color: u32, // ABGR
    animation_id: u32,
};

// NSWindowStyleMaskFullSizeContentView = 1 << 15 — content view extends under titlebar so vibrancy can cover it.
const NSWindowStyleMaskFullSizeContentView: c_ulong = 1 << 15;
const ns_visual_effect_material: c_long = 15;

// macOS window/Space monitor (objc/FizzyWindowMonitor.m). Tracks fullscreen
// Space transitions, keeps chrome/layout state, and pumps frames during
// AppKit window animations. Only referenced from macOS-gated code paths.
extern fn fizzy_macos_window_titlebar_inset(cocoa_window: ?*anyopaque) f64;
extern fn fizzy_macos_window_is_zoomed(cocoa_window: ?*anyopaque) c_int;
extern fn fizzy_macos_window_in_fullscreen_space(cocoa_window: ?*anyopaque) c_int;
extern fn fizzy_macos_window_saved_titlebar_inset() f64;
extern fn fizzy_macos_window_prefer_fullscreen_space(cocoa_window: ?*anyopaque) void;
extern fn fizzy_macos_window_chrome_hidden(cocoa_window: ?*anyopaque) c_int;
extern fn fizzy_macos_window_titlebar_strip_collapsed(cocoa_window: ?*anyopaque) c_int;
extern fn fizzy_macos_window_resize_pump_active() c_int;
extern fn fizzy_macos_window_unzoom_animating(cocoa_window: ?*anyopaque) c_int;
extern fn fizzy_macos_window_space_transition_active() c_int;
extern fn fizzy_macos_window_space_entering() c_int;
extern fn fizzy_macos_window_space_has_target() c_int;
extern fn fizzy_macos_window_pixel_size(cocoa_window: ?*anyopaque, out_w: *c_int, out_h: *c_int) void;
extern fn fizzy_macos_window_point_size(cocoa_window: ?*anyopaque, out_w: *c_int, out_h: *c_int) void;
// Frame-based geometry persistence for fizzy's custom (frame == content) window.
extern fn fizzy_macos_window_current_windowed_frame(cocoa_window: ?*anyopaque, out4: [*]f64) void;
extern fn fizzy_macos_window_set_frame(cocoa_window: ?*anyopaque, x: f64, y: f64, w: f64, h: f64) void;
extern fn fizzy_macos_copy_screen_frames(out: [*]f64, max: c_int) c_int;
extern fn fizzy_macos_window_sync_content_views(cocoa_window: ?*anyopaque) void;
extern fn fizzy_macos_window_install_resize_observer(cocoa_window: ?*anyopaque) void;

// SDL internals (linked but not in public headers) — the same hooks SDL uses
// for macOS live resize while the window frame is animating.
extern fn SDL_SendWindowEvent(window: *sdl3.SDL_Window, windowevent: c_uint, data1: c_int, data2: c_int) bool;
extern fn SDL_OnWindowLiveResizeUpdate(window: *sdl3.SDL_Window) void;

/// SDL window the monitor pump drives; set once in `restoreWindowState`.
var macos_monitor_window: ?*sdl3.SDL_Window = null;
/// Gates the pump's frame rendering until AppInit has finished, so the NSTimer
/// can't drive a dvui frame before the app is fully initialized.
var macos_pump_ready = false;
/// Last sizes pushed into SDL during an AppKit resize animation.
var macos_last_sync_point: [2]c_int = .{ 0, 0 };
var macos_last_sync_pixel: [2]c_int = .{ 0, 0 };
/// SDL_OnWindowLiveResizeUpdate can call back into appIterate — never invoke it
/// while already inside a frame or live-resize update.
var macos_in_live_resize: bool = false;

fn cocoaWindowOf(window: *sdl3.SDL_Window) ?*anyopaque {
    return sdl3.SDL_GetPointerProperty(
        sdl3.SDL_GetWindowProperties(window),
        sdl3.SDL_PROP_WINDOW_COCOA_WINDOW_POINTER,
        null,
    );
}

fn macosTransitionSyncActive() bool {
    return fizzy_macos_window_space_transition_active() != 0 or
        fizzy_macos_window_unzoom_animating(null) != 0;
}

fn macosSpaceSyncAllowed() bool {
    return macosTransitionSyncActive() or fizzy_macos_window_space_has_target() != 0;
}

fn macosSyncContentViews(window: *sdl3.SDL_Window) void {
    if (cocoaWindowOf(window)) |cocoa| fizzy_macos_window_sync_content_views(cocoa);
}

/// Push AppKit's live sizes into SDL — SDL doesn't emit resize events during
/// Space animations, and dvui's SDL backend pairs its reported sizes to the
/// drawable, so this is what keeps layout sizes fresh mid-morph.
fn macosSyncRendererSize(window: *sdl3.SDL_Window, force: bool) void {
    const cocoa = cocoaWindowOf(window) orelse return;
    var pw: c_int = 0;
    var ph: c_int = 0;
    var aw: c_int = 0;
    var ah: c_int = 0;
    fizzy_macos_window_point_size(cocoa, &pw, &ph);
    fizzy_macos_window_pixel_size(cocoa, &aw, &ah);
    if (aw < 1 or ah < 1) return;

    if (force or pw > 0 and ph > 0 and (pw != macos_last_sync_point[0] or ph != macos_last_sync_point[1])) {
        macos_last_sync_point = .{ pw, ph };
        _ = SDL_SendWindowEvent(window, sdl3.SDL_EVENT_WINDOW_RESIZED, pw, ph);
    }
    if (force or aw != macos_last_sync_pixel[0] or ah != macos_last_sync_pixel[1]) {
        macos_last_sync_pixel = .{ aw, ah };
        _ = SDL_SendWindowEvent(window, sdl3.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED, aw, ah);
    }
}

/// Push AppKit sizes into SDL. Does not call SDL_OnWindowLiveResizeUpdate — safe
/// from notification callbacks and from inside appIterate.
fn macosSyncSizes(window: *sdl3.SDL_Window) void {
    if (!macosSpaceSyncAllowed()) return;
    macosSyncContentViews(window);
    macosSyncRendererSize(window, false);
}

fn macosLiveResizeUpdate(window: *sdl3.SDL_Window) void {
    if (macos_in_live_resize) return;
    macos_in_live_resize = true;
    defer macos_in_live_resize = false;
    SDL_OnWindowLiveResizeUpdate(window);
}

/// Wake the SDL event loop from an AppKit notification. Sync sizes first so
/// the next appIterate begin() sees transition-correct dimensions.
export fn fizzy_macos_window_resize_cb() void {
    if (comptime builtin.os.tag == .macos) {
        if (macos_pump_ready) {
            if (macos_monitor_window) |window| macosSyncSizes(window);
        }
    }
    var ue = std.mem.zeroes(sdl3.SDL_Event);
    ue.type = sdl3.SDL_EVENT_USER;
    _ = sdl3.SDL_PushEvent(&ue);
}

/// Called from the monitor's 60Hz NSTimer during window animations — same
/// approach SDL itself uses for live resize. Runs outside appIterate, so
/// SDL_OnWindowLiveResizeUpdate is safe here.
export fn fizzy_macos_window_pump_frame() void {
    if (comptime builtin.os.tag == .macos) {
        if (!macos_pump_ready) return;
        const window = macos_monitor_window orelse return;
        macosSyncSizes(window);
        macosLiveResizeUpdate(window);
    }
}

/// Sync AppKit → SDL before `Window.begin` during Space / zoom animations only.
/// Registered on the SDL backend from `restoreWindowState`.
fn macosAppPreBeginSync(back: *@import("backend").SDLBackend) void {
    if (comptime builtin.os.tag != .macos) return;
    if (!macos_pump_ready) return;
    // Sync AppKit's live sizes into SDL during Space/zoom animations so dvui lays
    // out at transition-correct dimensions. Geometry persistence is owned by fizzy
    // (window_frame.zon) and disabled in dvui, so there is nothing to toggle here.
    if (!macosTransitionSyncActive()) return;
    macosSyncContentViews(back.window);
    macosSyncRendererSize(back.window, true);
}

export fn fizzy_macos_window_reset_sync_cache() void {
    macos_last_sync_point = .{ 0, 0 };
    macos_last_sync_pixel = .{ 0, 0 };
}

/// Reconcile SDL's cached sizes and Metal drawable with live AppKit bounds.
/// Called at didEnter/didExit so steady state never keeps transition sizes.
export fn fizzy_macos_window_commit_steady_state() void {
    if (comptime builtin.os.tag != .macos) return;
    if (!macos_pump_ready) return;
    const window = macos_monitor_window orelse return;
    macos_last_sync_point = .{ 0, 0 };
    macos_last_sync_pixel = .{ 0, 0 };
    macosSyncContentViews(window);
    macosSyncRendererSize(window, true);
    macosLiveResizeUpdate(window);
}

export fn fizzy_macos_window_request_clear_frames(frames: c_int) void {
    // dvui's SDL backend clears the window on every begin
    // (clear_window_on_begin), so no extra clearing is needed.
    _ = frames;
}

// Frame-based geometry persistence. fizzy's window is a frame == content window
// (full-size content view), which dvui's content-based `WindowGeometry` can't
// represent — so fizzy persists the actual NSWindow.frame (AppKit bottom-left
// points) itself. dvui's own persistence is disabled (persist_window_geometry =
// false in App.startOptions). Stored next to where dvui would write, in the
// configured pref_path.
const SavedFrame = struct { x: f64, y: f64, w: f64, h: f64 };
const window_frame_file = "window_frame.zon";

fn frameFilePath(buf: []u8, dir: [:0]const u8) ?[:0]const u8 {
    const sep = std.fs.path.sep_str;
    if (std.mem.endsWith(u8, dir, sep)) {
        return std.fmt.bufPrintZ(buf, "{s}{s}", .{ dir, window_frame_file }) catch null;
    }
    return std.fmt.bufPrintZ(buf, "{s}{s}{s}", .{ dir, sep, window_frame_file }) catch null;
}

fn loadSavedFrame(dir: [:0]const u8) ?SavedFrame {
    var path_buf: [1024]u8 = undefined;
    const path = frameFilePath(&path_buf, dir) orelse return null;
    const data = std.Io.Dir.cwd().readFileAlloc(dvui.io, path, std.heap.page_allocator, .limited(1024)) catch return null;
    defer std.heap.page_allocator.free(data);
    var nul_buf: [1025]u8 = undefined;
    if (data.len >= nul_buf.len) return null;
    @memcpy(nul_buf[0..data.len], data);
    nul_buf[data.len] = 0;
    const f = std.zon.parse.fromSlice(
        SavedFrame,
        std.heap.page_allocator,
        nul_buf[0..data.len :0],
        null,
        .{ .ignore_unknown_fields = true },
    ) catch return null;
    if (f.w < 1 or f.h < 1) return null;
    return f;
}

fn writeSavedFrame(dir: [:0]const u8, f: SavedFrame) void {
    var path_buf: [1024]u8 = undefined;
    const path = frameFilePath(&path_buf, dir) orelse return;
    var aw = std.Io.Writer.Allocating.init(std.heap.page_allocator);
    defer aw.deinit();
    std.zon.stringify.serialize(f, .{}, &aw.writer) catch return;
    std.Io.Dir.createDirAbsolute(dvui.io, dir, .default_dir) catch {};
    std.Io.Dir.cwd().writeFile(dvui.io, .{ .sub_path = path, .data = aw.written() }) catch {
        std.log.err("failed to write window_frame.zon", .{});
    };
}

/// True if the saved frame's title strip lands on a connected display (guards
/// against restoring onto a monitor that was unplugged). macOS only.
fn frameValidOnScreens(frame: window_layout.Rect) bool {
    var raw: [8 * 4]f64 = undefined;
    const n = fizzy_macos_copy_screen_frames(&raw, 8);
    if (n <= 0) return false;
    var screens: [8]window_layout.Rect = undefined;
    var i: usize = 0;
    const count: usize = @intCast(n);
    while (i < count) : (i += 1) {
        screens[i] = .{ .x = raw[i * 4 + 0], .y = raw[i * 4 + 1], .w = raw[i * 4 + 2], .h = raw[i * 4 + 3] };
    }
    return window_layout.frameTitleReachable(frame, screens[0..count]);
}

/// C-ABI for `FizzyWindowMonitor.m`'s `-constrainFrameRect:toScreen:` override.
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

/// Applies the macOS window chrome, restores the saved window frame, installs the
/// Space monitor, and registers the per-frame AppKit→SDL sync hook. Called from
/// `AppInit` (dvui's `initFn`) while the window is still hidden, so the
/// full-size-content-view style mask is in place — and the frame is restored on
/// top of it — before the window is shown. No-op on non-macOS (Windows chrome is
/// applied separately in AppInit).
pub fn restoreWindowState(win: *dvui.Window) void {
    if (comptime builtin.os.tag == .macos) {
        const back = win.backend.impl;
        const window = back.window;
        const cocoa = cocoaWindowOf(window) orelse return;

        // Establish frame == content first; then assert our saved frame on top of
        // it, so the style mask's frame-resizing side effect can't corrupt it.
        setWindowStyle(win);

        if (back.init_opts_save) |opts| {
            if (opts.pref_path) |dir| {
                if (loadSavedFrame(dir)) |f| {
                    const r: window_layout.Rect = .{ .x = f.x, .y = f.y, .w = f.w, .h = f.h };
                    if (frameValidOnScreens(r)) {
                        fizzy_macos_window_set_frame(cocoa, f.x, f.y, f.w, f.h);
                    }
                }
            }
        }

        // dvui no longer manages geometry (persist_window_geometry = false); fizzy
        // owns it via window_frame.zon.
        macos_monitor_window = window;
        // `begin_hook` is now a per-backend field (dvui moved it off the module).
        back.begin_hook = macosAppPreBeginSync;
        fizzy_macos_window_install_resize_observer(cocoa);
    }
}

/// Persist the current windowed NSWindow.frame. Call at shutdown (AppDeinit) so
/// the next launch restores the exact frame. No-op on non-macOS.
pub fn saveWindowGeometry(win: *dvui.Window) void {
    if (comptime builtin.os.tag != .macos) return;
    const back = win.backend.impl;
    const dir = (back.init_opts_save orelse return).pref_path orelse return;
    const cocoa = cocoaWindowOf(back.window) orelse return;
    var out4: [4]f64 = .{0} ** 4;
    fizzy_macos_window_current_windowed_frame(cocoa, &out4);
    if (out4[2] < 1 or out4[3] < 1) return;
    writeSavedFrame(dir, .{ .x = out4[0], .y = out4[1], .w = out4[2], .h = out4[3] });
}

/// Reveal the window after chrome + geometry are settled (it is created hidden).
/// Safe to call on any platform; no-op where there is no SDL window.
pub fn showWindow(win: *dvui.Window) void {
    if (comptime builtin.os.tag != .macos and builtin.os.tag != .windows and builtin.os.tag != .linux) return;
    _ = sdl3.SDL_ShowWindow(win.backend.impl.window);
}

/// Called at the end of AppInit: allows the monitor's pump timer to start
/// driving dvui frames during window animations.
pub fn macosLaunchComplete() void {
    macos_pump_ready = true;
}

// NSEventModifierFlag for menu key equivalents (right-justified grey hotkey in menu)
const NSEventModifierFlagCommand: c_ulong = 1 << 20;
const NSEventModifierFlagShift: c_ulong = 1 << 17;
const NSEventModifierFlagOption: c_ulong = 1 << 18;
const NSEventModifierFlagControl: c_ulong = 1 << 19;

/// Re-export of SDL3's filter struct under a fizzy-owned name. Editor call sites
/// type their filter literals with this so the same code compiles on web (where
/// `backend_web.zig` defines its own `DialogFileFilter` with the same layout).
pub const DialogFileFilter = sdl3.SDL_DialogFileFilter;

// macOS native menu bar (top bar): action ids match FizzyMenuTarget.m
pub const NativeMenuAction = enum(c_int) {
    open_folder = 0,
    open_files = 1,
    save = 2,
    copy = 3,
    paste = 4,
    undo = 5,
    redo = 6,
    transform = 7,
    toggle_explorer = 8,
    show_dvui_demo = 9,
    save_as = 10,
    new_file = 11,
    grid_layout = 12,
    about = 13,
    check_for_updates = 14,
    report_bug = 15,
    save_all = 16,
};

// Queue a single pending native action id.
// This may be written from an AppKit callback thread, so use an atomic.
var pending_native_menu_action_id: std.atomic.Value(c_int) = .init(-1);

/// Called from FizzyMenuTarget.m when user picks a native menu item. Runs on main thread.
export fn FizzyNativeMenuAction(id: c_int) void {
    pending_native_menu_action_id.store(id, .release);
}

// Only referenced on macOS (from setupMacOSMenuBar).
const fizzy_get_selector = if (builtin.os.tag == .macos) struct {
    extern fn FizzyGetSelector(name: [*c]const u8) ?*anyopaque;
    fn get(name: [*c]const u8) ?*anyopaque {
        return FizzyGetSelector(name);
    }
}.get else struct {
    fn get(_: [*c]const u8) ?*anyopaque {
        return null;
    }
}.get;

// macOS trackpad pinch-to-zoom. NSEventTypeMagnify bypasses SDL3 entirely (SDL2's gesture
// API was removed and never replaced), so an Obj-C local event monitor (see
// `objc/FizzyTrackpadGesture.m`) calls back here for each magnification delta. We accumulate
// a single multiplicative ratio that the canvas widget drains and applies per frame.
//
// Storage is the bit pattern of an f64 (initial = 1.0) in an atomic u64. NSEvent local
// monitors run on the AppKit event-pump thread (main, for SDL), and we drain on the same
// main thread inside the frame, so the RMW below is single-threaded in practice — the
// atomic is a guardrail against a future change moving the producer side.
var pending_pinch_ratio_bits: std.atomic.Value(u64) = .init(@bitCast(@as(f64, 1.0)));

/// Called from `objc/FizzyTrackpadGesture.m` for every magnify event. `delta` is the relative
/// magnification reported by AppKit for that single event (small per-event values that
/// compound multiplicatively across the gesture).
export fn FizzyTrackpadMagnification(delta: f64) void {
    if (delta == 0.0) return;
    const current: f64 = @bitCast(pending_pinch_ratio_bits.load(.acquire));
    const next = current * (1.0 + delta);
    pending_pinch_ratio_bits.store(@bitCast(next), .release);
}

// Conditional declaration so non-macOS native targets (which don't compile the .m source) don't
// pull in an unresolved external symbol at link time.
const fizzy_install_trackpad_gesture_monitor = if (builtin.os.tag == .macos) struct {
    extern fn FizzyInstallTrackpadGestureMonitor() void;
    fn install() void {
        FizzyInstallTrackpadGestureMonitor();
    }
}.install else struct {
    fn install() void {}
}.install;

/// Install a process-wide AppKit local monitor for trackpad pinch events. Safe to call multiple
/// times — the monitor is one-shot. No-op on non-macOS targets.
pub fn installTrackpadGestureMonitor() void {
    fizzy_install_trackpad_gesture_monitor();
}

/// True while the macOS window chrome (traffic lights / titlebar area) is hidden, i.e. while
/// the layout's end state is a fullscreen Space: entering or steady fullscreen. Flips false
/// already at willExitFullScreen so the titlebar strip is back in the layout before the
/// buttons fade in. Driven by AppKit notifications via objc/FizzyWindowMonitor.m, NOT SDL's
/// fullscreen flag (which is wrong for zoomed windows and only updates after animations).
/// On non-macOS targets this is just `isMaximized`.
pub fn isFullscreenChromeHidden(win: *dvui.Window) bool {
    if (builtin.os.tag != .macos) return isMaximized(win);
    const raw_ptr = sdl3.SDL_GetPointerProperty(
        sdl3.SDL_GetWindowProperties(win.backend.impl.window),
        sdl3.SDL_PROP_WINDOW_COCOA_WINDOW_POINTER,
        null,
    );
    return fizzy_macos_window_chrome_hidden(raw_ptr) != 0;
}

/// Drain the accumulated trackpad pinch zoom ratio (>1.0 = zoom in, <1.0 = zoom out). Multiply
/// canvas scale by this and adjust the focal point to match. Returns 1.0 if no pinch input has
/// arrived since the last call.
pub fn takeTrackpadPinchRatio() f32 {
    const one_bits: u64 = @bitCast(@as(f64, 1.0));
    const prev_bits = pending_pinch_ratio_bits.swap(one_bits, .acq_rel);
    return @floatCast(@as(f64, @bitCast(prev_bits)));
}

/// Wraps the window's content view in an NSVisualEffectView so the window gets
/// vibrancy (blur of the desktop behind it). Safe to call multiple times;
/// only wraps once per window. Caller should set full-size content view style
/// mask and titlebarAppearsTransparent before calling so the effect covers the titlebar.
/// Uses FizzyVisualEffectView (custom subclass) when available so right-click is forwarded to the content view.
fn wrapContentViewWithVibrancy(window: objc.Object) void {
    const content_view = window.msgSend(objc.Object, "contentView", .{});
    if (content_view.value == 0) return;

    const NSVisualEffectViewClass = objc.getClass("NSVisualEffectView") orelse return;
    const fill_mask: c_ulong = 18; // NSViewWidthSizable | NSViewHeightSizable

    const is_effect_view = content_view.msgSend(bool, "isKindOfClass:", .{NSVisualEffectViewClass.value});
    if (is_effect_view) {
        content_view.msgSend(void, "setMaterial:", .{ns_visual_effect_material});
        content_view.msgSend(void, "setMenu:", .{@as(usize, 0)});
        // Keep the content subview's nextResponder pointing at the window delegate so rightMouseDown reaches SDL.
        const subviews = content_view.msgSend(objc.Object, "subviews", .{});
        const count: usize = subviews.msgSend(usize, "count", .{});
        if (count > 0) {
            const sub = subviews.msgSend(objc.Object, "objectAtIndex:", .{@as(c_ulong, 0)});
            const delegate = window.msgSend(objc.Object, "delegate", .{});
            if (delegate.value != 0) sub.msgSend(void, "setNextResponder:", .{delegate.value});
        }
        return;
    }

    // Prefer custom subclass that forwards rightMouseDown to the content view (see vibrancy_rightclick_fix.m).
    const EffectViewClass = objc.getClass("FizzyVisualEffectView") orelse NSVisualEffectViewClass;
    const effect_view = EffectViewClass.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "init", .{});
    if (effect_view.value == 0) return;

    effect_view.msgSend(void, "setBlendingMode:", .{@as(c_long, 0)}); // NSVisualEffectBlendingModeBehindWindow
    effect_view.msgSend(void, "setState:", .{@as(c_long, 1)}); // NSVisualEffectStateActive
    effect_view.msgSend(void, "setMaterial:", .{ns_visual_effect_material});
    effect_view.msgSend(void, "setMenu:", .{@as(usize, 0)}); // no context menu so right-click can reach subview

    window.msgSend(void, "setContentView:", .{effect_view.value});
    effect_view.msgSend(void, "addSubview:", .{content_view.value});
    content_view.msgSend(void, "setMenu:", .{@as(usize, 0)}); // no context menu so rightMouseDown is delivered
    // SDL sets the content view's nextResponder to the window delegate (listener) so rightMouseDown reaches the handler.
    // Adding the view as our subview made its nextResponder us; restore it so right-click events reach the app.
    const delegate = window.msgSend(objc.Object, "delegate", .{});
    if (delegate.value != 0) {
        content_view.msgSend(void, "setNextResponder:", .{delegate.value});
    }

    const bounds = effect_view.msgSend(NSRect, "bounds", .{});
    content_view.msgSend(void, "setFrame:", .{bounds});
    content_view.msgSend(void, "setAutoresizingMask:", .{fill_mask});
}

// Window button for custom-drawn caption (Windows 11-style: app draws the buttons, backend hit-tests them).
pub const TitleBarButton = enum { minimize, maximize, close };

// Title bar hint state describes which on-screen rectangles in the app's custom title bar should be
// treated as caption buttons (snap-layouts + syscommand), interactive DVUI widgets (HTCLIENT — DVUI gets
// the event), or part of the top drag strip (HTCAPTION). Hit-test priority within the title bar:
//   1. caption buttons (min/max/close) — right-anchored, recomputed live against current client width
//   2. interactive_rects → HTCLIENT (DVUI menu items, in-titlebar buttons, etc.) — left-anchored
//   3. top drag strip (client_y < top_strip_height_pixels) → HTCAPTION — full current client width
//   4. anything else → HTCLIENT
// Cached rects can go stale during a resize because Windows delivers WM_NCHITTEST continuously and the
// modal sizing loop blocks our SDL/DVUI frame from rendering. Deriving the drag strip's width from
// `GetClientRect` and right-anchoring the caption buttons makes the hit-test correct even when the
// last drawn frame is from before the resize.
//
// Rects are in physical pixel coordinates relative to the window client origin — i.e. dvui.Rect.Physical
// from a widget's rectScale(). Because we return 0 from WM_NCCALCSIZE, client origin == window origin.
//
// Build the hints each frame with this push-based API:
//   resetTitleBarHints();                                    // once at frame start
//   setTitleBarStrip(strip_height_pixels, client_pixel_w);   // top drag strip + width caption buttons anchor to
//   pushTitleBarInteractiveRect(menu_item_rect);             // from anywhere during draw
//   setTitleBarCaptionButtonRect(.close, rect);
const max_interactive_rects = 32;

const CaptionRect = struct {
    rect: dvui.Rect.Physical,
    // Client pixel width captured at push time, used to right-anchor on resize.
    captured_client_width: i32,
};

var titlebar_state: struct {
    // Height (px) of the top drag strip. The strip always spans the full current client width;
    // its width is read live from GetClientRect at hit-test time, not cached.
    top_strip_height_pixels: f32 = 0,
    // Client width (px) the editor saw when it pushed this frame's caption button rects.
    // Caption buttons live at the right edge; on hit-test we shift them by the width delta.
    frame_client_pixel_width: i32 = 0,
    interactive_rects: [max_interactive_rects]dvui.Rect.Physical = undefined,
    interactive_count: usize = 0,
    minimize_rect: ?CaptionRect = null,
    maximize_rect: ?CaptionRect = null,
    close_rect: ?CaptionRect = null,
    hovered: ?TitleBarButton = null,
    hover_tracking: bool = false,
} = .{};

/// Clears all per-frame title bar hints. Call at the start of each frame before any widgets push their rects.
pub fn resetTitleBarHints() void {
    if (builtin.os.tag != .windows) return;
    titlebar_state.top_strip_height_pixels = 0;
    titlebar_state.frame_client_pixel_width = 0;
    titlebar_state.interactive_count = 0;
    titlebar_state.minimize_rect = null;
    titlebar_state.maximize_rect = null;
    titlebar_state.close_rect = null;
}

/// Sets the top drag strip's height (px) and records the current client pixel width so right-anchored
/// caption buttons stay correct if the window resizes before the next frame.
pub fn setTitleBarStrip(strip_height_pixels: f32, client_pixel_width: i32) void {
    if (builtin.os.tag != .windows) return;
    titlebar_state.top_strip_height_pixels = strip_height_pixels;
    titlebar_state.frame_client_pixel_width = client_pixel_width;
}

/// Registers a rect that DVUI should receive clicks for (HTCLIENT). Use for any interactive widget
/// drawn inside the title bar so it overrides the surrounding drag region. Silently drops past limit.
pub fn pushTitleBarInteractiveRect(rect: dvui.Rect.Physical) void {
    if (builtin.os.tag != .windows) return;
    if (titlebar_state.interactive_count >= max_interactive_rects) return;
    titlebar_state.interactive_rects[titlebar_state.interactive_count] = rect;
    titlebar_state.interactive_count += 1;
}

/// Registers the rect of one of our app-drawn caption buttons. The backend's WM_NCHITTEST returns the
/// matching HT code so Win11 snap-layouts appear over the maximize button and clicks invoke the action.
/// The rect is stored alongside the client width recorded by `setTitleBarStrip`; the hit-test shifts it
/// by `(current_client_width - captured_client_width)` so right-anchored buttons follow window resizes.
pub fn setTitleBarCaptionButtonRect(button: TitleBarButton, rect: dvui.Rect.Physical) void {
    if (builtin.os.tag != .windows) return;
    const captured: CaptionRect = .{
        .rect = rect,
        .captured_client_width = titlebar_state.frame_client_pixel_width,
    };
    switch (button) {
        .minimize => titlebar_state.minimize_rect = captured,
        .maximize => titlebar_state.maximize_rect = captured,
        .close => titlebar_state.close_rect = captured,
    }
}

/// Returns which caption button (if any) the cursor is currently hovered over, based on WM_NCMOUSEMOVE
/// tracking in the subclass proc. Use this to animate hover art on your custom-drawn buttons. Windows only.
pub fn getHoveredTitleBarButton() ?TitleBarButton {
    if (builtin.os.tag != .windows) return null;
    return titlebar_state.hovered;
}

// Performs the window button action (minimize, maximize/restore, close). The subclass calls this directly
// on WM_NCLBUTTONDOWN for our registered button rects. Public so callers without a mouse path (e.g. a
// right-click system menu or keyboard shortcut) can still trigger it. Windows only.
pub fn performWindowButton(win: *dvui.Window, button: TitleBarButton) void {
    if (builtin.os.tag != .windows) return;
    const hwnd = getWin32Hwnd(win) orelse return;
    performWindowButtonHwnd(@ptrCast(hwnd), button);
}

fn performWindowButtonHwnd(hwnd_h: win32.foundation.HWND, button: TitleBarButton) void {
    // We strip WS_SYSMENU from the window style to hide the OS-drawn caption buttons,
    // so WM_SYSCOMMAND(SC_MINIMIZE/MAXIMIZE/CLOSE) is no longer reliable. Drive the actions
    // directly via ShowWindow / WM_CLOSE instead.
    const WM_CLOSE: u32 = 0x0010;
    switch (button) {
        .minimize => _ = win32.ui.windows_and_messaging.ShowWindow(hwnd_h, win32.ui.windows_and_messaging.SW_MINIMIZE),
        .maximize => {
            const cmd = if (win32.ui.windows_and_messaging.IsZoomed(hwnd_h) != 0)
                win32.ui.windows_and_messaging.SW_RESTORE
            else
                win32.ui.windows_and_messaging.SW_MAXIMIZE;
            _ = win32.ui.windows_and_messaging.ShowWindow(hwnd_h, cmd);
        },
        .close => _ = win32.ui.windows_and_messaging.PostMessageW(hwnd_h, WM_CLOSE, 0, 0),
    }
}

fn rectContainsI32(rect: dvui.Rect.Physical, x: i32, y: i32) bool {
    const fx = @as(f32, @floatFromInt(x));
    const fy = @as(f32, @floatFromInt(y));
    return fx >= rect.x and fy >= rect.y and fx < rect.x + rect.w and fy < rect.y + rect.h;
}

fn captionRectContains(maybe: ?CaptionRect, current_client_width: i32, x: i32, y: i32) bool {
    const cap = maybe orelse return false;
    // Shift the cached rect right by however much the client area has grown (or left if shrunk),
    // so the button stays anchored to the right edge regardless of resize.
    const delta_f = @as(f32, @floatFromInt(current_client_width - cap.captured_client_width));
    const fx = @as(f32, @floatFromInt(x));
    const fy = @as(f32, @floatFromInt(y));
    const r_x = cap.rect.x + delta_f;
    return fx >= r_x and fy >= cap.rect.y and fx < r_x + cap.rect.w and fy < cap.rect.y + cap.rect.h;
}

fn hitTestCaptionButton(client_x: i32, client_y: i32, current_client_width: i32) ?TitleBarButton {
    if (captionRectContains(titlebar_state.close_rect, current_client_width, client_x, client_y)) return .close;
    if (captionRectContains(titlebar_state.maximize_rect, current_client_width, client_x, client_y)) return .maximize;
    if (captionRectContains(titlebar_state.minimize_rect, current_client_width, client_x, client_y)) return .minimize;
    return null;
}

fn getWin32Hwnd(win: *dvui.Window) ?*anyopaque {
    const raw = sdl3.SDL_GetPointerProperty(
        sdl3.SDL_GetWindowProperties(win.backend.impl.window),
        sdl3.SDL_PROP_WINDOW_WIN32_HWND_POINTER,
        null,
    );
    return if (raw != null) @ptrCast(raw) else null;
}

// Full-window Mica margins for DwmExtendFrameIntoClientArea (-1 = "sheet of glass").
const win32_mica_margins = win32.ui.controls.MARGINS{
    .cxLeftWidth = -1,
    .cxRightWidth = -1,
    .cyTopHeight = -1,
    .cyBottomHeight = -1,
};

const win32_mica_subclass_id: usize = 0x50584931; // "PXI1"

/// Applies the undocumented SetWindowCompositionAttribute accent policy for acrylic blur (frosted glass).
/// Safe to call; no-ops if user32 or the API is unavailable.
fn applyWin32AcrylicAccent(hwnd: win32.foundation.HWND) void {
    const user32 = win32.system.library_loader.LoadLibraryA("user32.dll") orelse return;
    defer _ = win32.system.library_loader.FreeLibrary(user32);
    const proc = win32.system.library_loader.GetProcAddress(user32, "SetWindowCompositionAttribute") orelse return;
    const SetWindowCompositionAttribute: *const fn (win32.foundation.HWND, *const WINCOMPATTR_DATA) callconv(.winapi) i32 = @ptrCast(proc);
    var policy = ACCENT_POLICY{
        .accent_state = ACCENT_ENABLE_ACRYLICBLURBEHIND,
        .accent_flags = 0,
        .gradient_color = 0xE6_00_00_00, // ABGR: dark tint so blur is visible
        .animation_id = 0,
    };
    var data = WINCOMPATTR_DATA{
        .attrib = WCA_ACCENT_POLICY,
        .pv_data = @ptrCast(&policy),
        .cb_data = @sizeOf(ACCENT_POLICY),
    };
    _ = SetWindowCompositionAttribute(hwnd, &data);
}

// Extend client area into title bar: return 0 from WM_NCCALCSIZE when wParam TRUE (MSDN).
const WM_NCCALCSIZE: u32 = 0x0083;
const WM_NCHITTEST: u32 = 0x0084;
const HTCAPTION: i32 = 2;
const HTLEFT: i32 = 10;
const HTRIGHT: i32 = 11;
const HTTOP: i32 = 12;
const HTTOPLEFT: i32 = 13;
const HTTOPRIGHT: i32 = 14;
const HTBOTTOM: i32 = 15;
const HTBOTTOMLEFT: i32 = 16;
const HTBOTTOMRIGHT: i32 = 17;
const HTMINBUTTON: i32 = 8;
const HTMAXBUTTON: i32 = 9;
const HTCLOSE: i32 = 20;
const SM_CXSIZEFRAME: u32 = 32;
const SM_CYSIZEFRAME: u32 = 33;
const WM_NCLBUTTONDOWN: u32 = 0x00A1;
const WM_NCMOUSEMOVE: u32 = 0x00A0;
const WM_NCMOUSELEAVE: u32 = 0x02A2;

fn requestRepaint(hWnd: ?win32.foundation.HWND) void {
    _ = win32.graphics.gdi.InvalidateRect(hWnd, null, 0);
}

fn setHoveredButton(hWnd: ?win32.foundation.HWND, new_hover: ?TitleBarButton) void {
    if (titlebar_state.hovered != new_hover) {
        titlebar_state.hovered = new_hover;
        requestRepaint(hWnd);
    }
}

/// Ask Windows to deliver WM_NCMOUSELEAVE once the cursor exits the non-client area. Must be re-armed
/// on each WM_NCMOUSEMOVE after a leave, since TrackMouseEvent is one-shot.
fn armNcMouseLeaveTracking(hWnd: ?win32.foundation.HWND) void {
    if (titlebar_state.hover_tracking) return;
    var tme = win32.ui.input.keyboard_and_mouse.TRACKMOUSEEVENT{
        .cbSize = @sizeOf(win32.ui.input.keyboard_and_mouse.TRACKMOUSEEVENT),
        .dwFlags = .{ .LEAVE = 1, .NONCLIENT = 1 },
        .hwndTrack = hWnd,
        .dwHoverTime = 0,
    };
    if (win32.ui.input.keyboard_and_mouse.TrackMouseEvent(&tme) != 0) {
        titlebar_state.hover_tracking = true;
    }
}

fn win32MicaSubclassProc(
    hWnd: ?win32.foundation.HWND,
    uMsg: u32,
    wParam: win32.foundation.WPARAM,
    lParam: win32.foundation.LPARAM,
    uIdSubclass: usize,
    dwRefData: usize,
) callconv(.winapi) win32.foundation.LRESULT {
    _ = uIdSubclass;
    _ = dwRefData;
    // DWM requires the frame extension to be applied in WM_ACTIVATE (and when composition changes)
    // for the backdrop to show correctly instead of staying opaque.
    // Re-apply backdrop type on activate/deactivate so the window stays acrylic when unfocused
    // instead of dimming to opaque (default DWM behavior for inactive windows).
    if (uMsg == win32.ui.windows_and_messaging.WM_ACTIVATE or
        uMsg == win32.ui.windows_and_messaging.WM_DWMCOMPOSITIONCHANGED)
    {
        const backdrop_type: u32 = DWMSBT_TRANSIENTWINDOW;
        _ = win32.graphics.dwm.DwmSetWindowAttribute(
            hWnd,
            @as(win32.graphics.dwm.DWMWINDOWATTRIBUTE, @enumFromInt(DWMWA_SYSTEMBACKDROP_TYPE)),
            &backdrop_type,
            @sizeOf(u32),
        );
        _ = win32.graphics.dwm.DwmExtendFrameIntoClientArea(hWnd, &win32_mica_margins);
    }
    // Extend client area into the title bar so the app can draw there; we keep OS min/max/close via hit-test.
    // When maximized, constrain the client rect to the monitor work area so the window doesn't extend past
    // the screen edge (the 7–8 px overflow that happens when returning 0 with borderless-style handling).
    if (uMsg == WM_NCCALCSIZE and wParam != 0) {
        const params = @as(*win32.ui.windows_and_messaging.NCCALCSIZE_PARAMS, @ptrFromInt(@as(usize, @intCast(lParam))));
        if (win32.ui.windows_and_messaging.IsZoomed(hWnd) != 0) {
            const hmon = win32.graphics.gdi.MonitorFromWindow(hWnd, win32.graphics.gdi.MONITOR_DEFAULTTONEAREST);
            var mi: win32.graphics.gdi.MONITORINFO = undefined;
            mi.cbSize = @sizeOf(win32.graphics.gdi.MONITORINFO);
            if (win32.graphics.gdi.GetMonitorInfoW(hmon, &mi) != 0) {
                params.rgrc[0] = mi.rcWork;
            }
        }
        return 0; // Client area = rgrc[0] (full window when not maximized; work area when maximized).
    }
    if (uMsg == WM_NCHITTEST) {
        const def = win32.ui.shell.DefSubclassProc(hWnd, uMsg, wParam, lParam);
        // lParam = (y << 16) | x in screen coordinates (signed 16-bit each).
        const lp = @as(isize, lParam);
        const screen_x = @as(i32, @as(i16, @truncate(lp)));
        const screen_y = @as(i32, @as(i16, @truncate(lp >> 16)));
        var rect: win32.foundation.RECT = undefined;
        if (win32.ui.windows_and_messaging.GetWindowRect(hWnd, &rect) == 0) return def;
        if (screen_x < rect.left or screen_x >= rect.right or screen_y < rect.top or screen_y >= rect.bottom) return def;

        // Client origin == window origin because WM_NCCALCSIZE returned 0.
        const client_x = screen_x - rect.left;
        const client_y = screen_y - rect.top;
        const width = rect.right - rect.left;
        const height = rect.bottom - rect.top;

        // 1) Resize edges/corners (skip when maximized — no resize then).
        if (win32.ui.windows_and_messaging.IsZoomed(hWnd) == 0) {
            const frame_w = @max(win32.ui.windows_and_messaging.GetSystemMetrics(@as(win32.ui.windows_and_messaging.SYSTEM_METRICS_INDEX, @enumFromInt(SM_CXSIZEFRAME))), 4);
            const frame_h = @max(win32.ui.windows_and_messaging.GetSystemMetrics(@as(win32.ui.windows_and_messaging.SYSTEM_METRICS_INDEX, @enumFromInt(SM_CYSIZEFRAME))), 4);
            if (client_x < frame_w) {
                if (client_y < frame_h) return @as(win32.foundation.LRESULT, @intCast(HTTOPLEFT));
                if (client_y >= height - frame_h) return @as(win32.foundation.LRESULT, @intCast(HTBOTTOMLEFT));
                return @as(win32.foundation.LRESULT, @intCast(HTLEFT));
            }
            if (client_x >= width - frame_w) {
                if (client_y < frame_h) return @as(win32.foundation.LRESULT, @intCast(HTTOPRIGHT));
                if (client_y >= height - frame_h) return @as(win32.foundation.LRESULT, @intCast(HTBOTTOMRIGHT));
                return @as(win32.foundation.LRESULT, @intCast(HTRIGHT));
            }
            if (client_y >= height - frame_h) return @as(win32.foundation.LRESULT, @intCast(HTBOTTOM));
            if (client_y < frame_h) return @as(win32.foundation.LRESULT, @intCast(HTTOP));
        }

        // 2) App-registered caption buttons. Returning these HT codes is also what makes the Win11
        //    snap-layouts flyout appear on the maximize button. Right-anchored against `width` so a
        //    resize between frames still hits the correct button.
        if (hitTestCaptionButton(client_x, client_y, width)) |btn| return switch (btn) {
            .close => @as(win32.foundation.LRESULT, @intCast(HTCLOSE)),
            .maximize => @as(win32.foundation.LRESULT, @intCast(HTMAXBUTTON)),
            .minimize => @as(win32.foundation.LRESULT, @intCast(HTMINBUTTON)),
        };

        // 3) App-registered interactive widget rects (DVUI menus / buttons inside the title bar).
        //    Checked before the drag strip so a widget overlapping it still gets the click. These are
        //    left-anchored, so the cached rect is correct even if the window resized.
        for (titlebar_state.interactive_rects[0..titlebar_state.interactive_count]) |r| {
            if (rectContainsI32(r, client_x, client_y)) return @as(win32.foundation.LRESULT, @intCast(1)); // HTCLIENT
        }

        // 4) Top drag strip — spans the entire current client width, so resizing the window between
        //    frames never leaves dead zones at the right.
        if (titlebar_state.top_strip_height_pixels > 0 and
            @as(f32, @floatFromInt(client_y)) < titlebar_state.top_strip_height_pixels)
        {
            return @as(win32.foundation.LRESULT, @intCast(HTCAPTION));
        }

        // 5) Otherwise let DVUI handle it.
        return @as(win32.foundation.LRESULT, @intCast(1)); // HTCLIENT
    }

    // Hover tracking for custom-drawn caption buttons. Windows sends WM_NCMOUSEMOVE with wParam = HT code
    // when the cursor is over HTMINBUTTON/HTMAXBUTTON/HTCLOSE because we returned those from WM_NCHITTEST.
    if (uMsg == WM_NCMOUSEMOVE) {
        armNcMouseLeaveTracking(hWnd);
        const hover: ?TitleBarButton = switch (@as(i32, @intCast(wParam))) {
            HTCLOSE => .close,
            HTMAXBUTTON => .maximize,
            HTMINBUTTON => .minimize,
            else => null,
        };
        setHoveredButton(hWnd, hover);
    }
    if (uMsg == WM_NCMOUSELEAVE) {
        titlebar_state.hover_tracking = false;
        setHoveredButton(hWnd, null);
    }

    // Click on a custom caption button: perform the action ourselves (don't let DefWindowProc try to
    // drive its own non-existent button UI). Consume the message so no spurious system menu appears.
    if (uMsg == WM_NCLBUTTONDOWN) {
        const action: ?TitleBarButton = switch (@as(i32, @intCast(wParam))) {
            HTCLOSE => .close,
            HTMAXBUTTON => .maximize,
            HTMINBUTTON => .minimize,
            else => null,
        };
        if (action) |btn| {
            if (hWnd) |h| performWindowButtonHwnd(h, btn);
            return 0;
        }
    }

    return win32.ui.shell.DefSubclassProc(hWnd, uMsg, wParam, lParam);
}

fn windowFillsUsableBounds(window: *sdl3.SDL_Window) bool {
    const display = sdl3.SDL_GetDisplayForWindow(window);
    if (display == 0) return false;
    var usable: sdl3.SDL_Rect = undefined;
    if (!sdl3.SDL_GetDisplayUsableBounds(display, &usable)) return false;
    var w: c_int = 0;
    var h: c_int = 0;
    if (!sdl3.SDL_GetWindowSize(window, &w, &h)) return false;
    const wf: f32 = @floatFromInt(w);
    const hf: f32 = @floatFromInt(h);
    const uw: f32 = @floatFromInt(usable.w);
    const uh: f32 = @floatFromInt(usable.h);
    return wf >= uw * 0.95 and hf >= uh * 0.95;
}

/// Height of the top strip that keeps editor content clear of the traffic lights.
/// Collapsed during fullscreen Space; expanded early when exiting so
/// traffic lights don't overlap left-anchored panes mid-transition.
/// Zoom/maximize without a Space keeps the full strip.
pub fn titlebarStripHeight(win: *dvui.Window) f32 {
    if (builtin.os.tag != .macos) return fizzy.editor.settings.titlebar_height;
    const raw_ptr = sdl3.SDL_GetPointerProperty(
        sdl3.SDL_GetWindowProperties(win.backend.impl.window),
        sdl3.SDL_PROP_WINDOW_COCOA_WINDOW_POINTER,
        null,
    );
    const collapsed = raw_ptr != null and fizzy_macos_window_titlebar_strip_collapsed(raw_ptr) != 0;
    const inset = if (raw_ptr != null) fizzy_macos_window_titlebar_inset(raw_ptr) else 0;
    const saved = fizzy_macos_window_saved_titlebar_inset();
    const restoring_chrome = raw_ptr != null and (fizzy_macos_window_unzoom_animating(null) != 0 or
        (fizzy_macos_window_space_transition_active() != 0 and
            fizzy_macos_window_space_entering() == 0));
    return window_layout.chooseTitlebarStrip(.{
        .collapsed = collapsed,
        .restoring_chrome = restoring_chrome,
        .live_inset = if (inset > 0) @floatCast(inset) else 0,
        .saved_inset = if (saved > 0) @floatCast(saved) else 0,
        .titlebar_height = fizzy.editor.settings.titlebar_height,
        .titlebar_top_buffer = fizzy.editor.settings.titlebar_top_buffer,
    });
}

pub fn isMaximized(win: *dvui.Window) bool {
    const window = win.backend.impl.window;
    const flags = sdl3.SDL_GetWindowFlags(window);
    if (flags & sdl3.SDL_WINDOW_MAXIMIZED != 0) return true;
    if (builtin.os.tag == .macos) {
        const raw_ptr = sdl3.SDL_GetPointerProperty(
            sdl3.SDL_GetWindowProperties(window),
            sdl3.SDL_PROP_WINDOW_COCOA_WINDOW_POINTER,
            null,
        );
        if (raw_ptr != null) {
            if (fizzy_macos_window_in_fullscreen_space(raw_ptr) != 0) return true;
            if (fizzy_macos_window_is_zoomed(raw_ptr) != 0) return true;
        }
        if (isFullscreenChromeHidden(win)) return true;
        return false;
    }
    return flags & sdl3.SDL_WINDOW_FULLSCREEN != 0;
}

pub fn setWindowStyle(win: *dvui.Window) void {
    if (builtin.os.tag == .macos) {
        const raw_ptr = sdl3.SDL_GetPointerProperty(
            sdl3.SDL_GetWindowProperties(win.backend.impl.window),
            sdl3.SDL_PROP_WINDOW_COCOA_WINDOW_POINTER,
            null,
        );
        if (raw_ptr != null) {
            const window = objc.Object.fromId(raw_ptr);

            // Re-applying styleMask while in a fullscreen Space exits the Space on macOS.
            if (fizzy_macos_window_in_fullscreen_space(raw_ptr) == 0) {
                // Allow content view to extend under the titlebar so vibrancy covers it.
                const style_mask = window.msgSend(c_ulong, "styleMask", .{});
                window.msgSend(void, "setStyleMask:", .{style_mask | NSWindowStyleMaskFullSizeContentView});
            }
            // This sets the titlebar to transparent so our effect view shows through.
            window.msgSend(void, "setTitlebarAppearsTransparent:", .{true});
            // Hide the title text in the titlebar (matches Windows, where we
            // draw our own chrome). `NSWindowTitleHidden` = 1. The window still
            // has a programmatic title (used by the Window menu / Dock) — only
            // the rendered titlebar string is hidden.
            window.msgSend(void, "setTitleVisibility:", .{@as(c_long, 1)});
            // Green button enters a native fullscreen Space (menu bar hidden).
            const NSWindowCollectionBehaviorFullScreenPrimary: c_ulong = 1 << 7;
            const behavior = window.msgSend(c_ulong, "collectionBehavior", .{});
            window.msgSend(void, "setCollectionBehavior:", .{behavior | NSWindowCollectionBehaviorFullScreenPrimary});
            fizzy_macos_window_prefer_fullscreen_space(raw_ptr);
        }
    } else if (builtin.os.tag == .windows) {
        const hwnd = getWin32Hwnd(win) orelse return;
        const hwnd_h = @as(win32.foundation.HWND, @ptrCast(hwnd));

        // Windows 11: Apply Acrylic (frosted glass) backdrop so title bar and extended frame show blur. Requires Build 22621+.
        // DWMSBT_TRANSIENTWINDOW = Acrylic is more visible than Mica; use MAINWINDOW for subtler Mica.
        const backdrop_type: u32 = DWMSBT_TRANSIENTWINDOW;
        _ = win32.graphics.dwm.DwmSetWindowAttribute(
            hwnd_h,
            @as(win32.graphics.dwm.DWMWINDOWATTRIBUTE, @enumFromInt(DWMWA_SYSTEMBACKDROP_TYPE)),
            &backdrop_type,
            @sizeOf(u32),
        );

        // Subclass so we can re-apply frame extension in WM_ACTIVATE (required by DWM for backdrop to show).
        _ = win32.ui.shell.SetWindowSubclass(hwnd_h, win32MicaSubclassProc, win32_mica_subclass_id, 0);

        // Hide the OS-drawn caption buttons (min/max/close) so they don't show through our custom-drawn ones.
        // Returning 0 from WM_NCCALCSIZE removes the non-client area, but on Win11 DWM still composites the
        // system caption buttons whenever WS_SYSMENU is present. Strip just WS_SYSMENU — the min/max box
        // styles only render buttons when WS_SYSMENU is also set, but they're still required for Aero Snap
        // (drag-to-top maximize, drag-to-edge half-snap), so we keep them.
        const WS_SYSMENU: isize = 0x00080000;
        const cur_style = win32.ui.windows_and_messaging.GetWindowLongPtrW(hwnd_h, win32.ui.windows_and_messaging.GWL_STYLE);
        _ = win32.ui.windows_and_messaging.SetWindowLongPtrW(hwnd_h, win32.ui.windows_and_messaging.GWL_STYLE, cur_style & ~WS_SYSMENU);

        // Extend the DWM frame (Acrylic) into the entire client area so the backdrop material shows there.
        _ = win32.graphics.dwm.DwmExtendFrameIntoClientArea(hwnd_h, &win32_mica_margins);

        // Optional: undocumented accent API for extra acrylic blur (Start menu / taskbar use this). May improve frosted look.
        applyWin32AcrylicAccent(hwnd_h);

        // Per MSDN: for backdrop to render, the client area background must be transparent or a black brush.
        // BLACK_BRUSH (4) lets DWM draw the backdrop material; a null brush can leave the area undefined.
        const black_brush = win32.graphics.gdi.GetStockObject(win32.graphics.gdi.GET_STOCK_OBJECT_FLAGS.BLACK_BRUSH);
        _ = win32.ui.windows_and_messaging.SetClassLongPtrW(
            hwnd_h,
            win32.ui.windows_and_messaging.GCLP_HBRBACKGROUND,
            @as(isize, @bitCast(@intFromPtr(black_brush))),
        );

        // Do not set WS_EX_LAYERED here: a layered main window is a common cause of broken mouse input on
        // native modal dialogs (SDL_ShowOpenFileDialog / tinyfd) when that window is the dialog owner.

        // Force WM_NCCALCSIZE so the client area extends over the title bar immediately (not only after maximize).
        const SWP_NOMOVE: u32 = 0x0002;
        const SWP_NOSIZE: u32 = 0x0001;
        const SWP_FRAMECHANGED: u32 = 0x0020;
        const swp_flags = @as(win32.ui.windows_and_messaging.SET_WINDOW_POS_FLAGS, @bitCast(SWP_NOMOVE | SWP_NOSIZE | SWP_FRAMECHANGED));
        _ = win32.ui.windows_and_messaging.SetWindowPos(hwnd_h, null, 0, 0, 0, 0, swp_flags);
    }
}

pub fn setTitlebarColor(win: *dvui.Window, color: dvui.Color) void {
    if (builtin.os.tag == .macos) {
        const raw_ptr = sdl3.SDL_GetPointerProperty(
            sdl3.SDL_GetWindowProperties(win.backend.impl.window),
            sdl3.SDL_PROP_WINDOW_COCOA_WINDOW_POINTER,
            null,
        );
        if (raw_ptr != null) {
            const window = objc.Object.fromId(raw_ptr);

            setWindowStyle(win);

            // Wrap content view in NSVisualEffectView once for vibrancy (blur behind window).
            wrapContentViewWithVibrancy(window);

            const NSColor = objc.getClass("NSColor").?;
            const new_color = NSColor.msgSend(objc.Object, "colorWithRed:green:blue:alpha:", .{
                @as(f64, @floatFromInt(color.r)) / 255.0,
                @as(f64, @floatFromInt(color.g)) / 255.0,
                @as(f64, @floatFromInt(color.b)) / 255.0,
                @as(f64, @floatFromInt(color.a)) / 255.0,
            });
            // This sets both the titlebar and the window background color.
            window.msgSend(void, "setBackgroundColor:", .{new_color.value});

            // Set window NSAppearance so the app (title bar, traffic lights, vibrancy) matches dvui theme.
            if (objc.getClass("NSAppearance")) |NSAppearance| {
                if (objc.getClass("NSString")) |NSString| {
                    const name_c: [*c]const u8 = if (dvui.themeGet().dark)
                        "NSAppearanceNameVibrantDark"
                    else
                        "NSAppearanceNameVibrantLight";
                    const name_obj = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{name_c});
                    if (name_obj.value != 0) {
                        const appearance = NSAppearance.msgSend(objc.Object, "appearanceNamed:", .{name_obj.value});
                        if (appearance.value != 0) {
                            window.msgSend(void, "setAppearance:", .{appearance.value});
                        }
                    }
                }
            }

            // SDL3 currently removes the shadow when the transparency flag for the window is set. This brings it back.
            window.msgSend(void, "setHasShadow:", .{true});
        }
    } else if (builtin.os.tag == .windows) {
        const hwnd = getWin32Hwnd(win) orelse return;
        const hwnd_h = @as(win32.foundation.HWND, @ptrCast(hwnd));

        setWindowStyle(win);

        // No caption/border tint; we draw our own title bar in the extended client area (see WM_NCCALCSIZE in subclass).
        const color_none: u32 = win32.graphics.dwm.DWMWA_COLOR_NONE;
        _ = win32.graphics.dwm.DwmSetWindowAttribute(hwnd_h, win32.graphics.dwm.DWMWA_CAPTION_COLOR, &color_none, @sizeOf(u32));
        _ = win32.graphics.dwm.DwmSetWindowAttribute(hwnd_h, win32.graphics.dwm.DWMWA_BORDER_COLOR, &color_none, @sizeOf(u32));
    }
}

/// Override the SDL app metadata DVUI sets to its example defaults. On macOS this
/// is what drives the app menu's `About <name>` / `Hide <name>` / `Quit <name>`
/// items. Must be called before `setupMacOSMenuBar` so the inserted Help menu
/// references the right product name.
pub fn setSdlAppMetadata(name: [*:0]const u8, version: [*:0]const u8, identifier: [*:0]const u8) void {
    _ = sdl3.SDL_SetAppMetadata(name, version, identifier);
}

var macos_menu_bar_set_up: bool = false;

/// Inserts a "File" menu into the macOS app menu bar (between Apple and Window). Safe to call multiple times; runs once.
pub fn setupMacOSMenuBar() void {
    if (builtin.os.tag != .macos) return;
    if (macos_menu_bar_set_up) return;
    const NSApplication = objc.getClass("NSApplication") orelse return;
    const ns_app = NSApplication.msgSend(objc.Object, "sharedApplication", .{});
    if (ns_app.value == 0) return;
    const main_menu = ns_app.msgSend(objc.Object, "mainMenu", .{});
    if (main_menu.value == 0) return;

    const NSString = objc.getClass("NSString") orelse return;
    const NSMenu = objc.getClass("NSMenu") orelse return;
    const NSMenuItem = objc.getClass("NSMenuItem") orelse return;
    const FizzyMenuTargetClass = objc.getClass("FizzyMenuTarget") orelse return;
    const target = FizzyMenuTargetClass.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "init", .{});
    if (target.value == 0) return;

    const file_menu_title_str = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"File".ptr});
    const file_menu = NSMenu.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "initWithTitle:", .{file_menu_title_str.value});
    if (file_menu.value == 0) return;

    const empty = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"".ptr});
    const key_f = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"f".ptr});
    const key_n = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"n".ptr});
    const key_o = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"o".ptr});
    const key_s = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"s".ptr});

    const NSImage = objc.getClass("NSImage") orelse return;

    // New — ⌘N
    {
        const new_title = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"New".ptr});
        const new_sel = fizzy_get_selector("newFile:") orelse return;
        const new_item = file_menu.msgSend(objc.Object, "addItemWithTitle:action:keyEquivalent:", .{
            new_title.value,
            new_sel,
            key_n.value,
        });
        if (new_item.value != 0) {
            new_item.msgSend(void, "setTarget:", .{target.value});
            new_item.msgSend(void, "setKeyEquivalentModifierMask:", .{NSEventModifierFlagCommand});
            setMenuItemImage(new_item, NSImage, NSString, "doc.badge.plus", "New");
        }
    }
    // Open Folder — ⌘F, folder icon
    {
        const open_folder_title = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"Open Folder".ptr});
        const open_folder_sel = fizzy_get_selector("openFolder:") orelse return;
        const open_folder_item = file_menu.msgSend(objc.Object, "addItemWithTitle:action:keyEquivalent:", .{
            open_folder_title.value,
            open_folder_sel,
            key_f.value,
        });
        if (open_folder_item.value != 0) {
            open_folder_item.msgSend(void, "setTarget:", .{target.value});
            open_folder_item.msgSend(void, "setKeyEquivalentModifierMask:", .{NSEventModifierFlagCommand});
            setMenuItemImage(open_folder_item, NSImage, NSString, "folder", "Open Folder");
        }
    }
    // Open Files — ⌘O, doc icon
    {
        const open_files_title = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"Open Files".ptr});
        const open_files_sel = fizzy_get_selector("openFiles:") orelse return;
        const open_files_item = file_menu.msgSend(objc.Object, "addItemWithTitle:action:keyEquivalent:", .{
            open_files_title.value,
            open_files_sel,
            key_o.value,
        });
        if (open_files_item.value != 0) {
            open_files_item.msgSend(void, "setTarget:", .{target.value});
            open_files_item.msgSend(void, "setKeyEquivalentModifierMask:", .{NSEventModifierFlagCommand});
            setMenuItemImage(open_files_item, NSImage, NSString, "doc.on.doc", "Open Files");
        }
    }

    const separator = NSMenuItem.msgSend(objc.Object, "separatorItem", .{});
    file_menu.msgSend(void, "addItem:", .{separator.value});

    // Save — ⌘S
    const save_title = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"Save".ptr});
    const save_sel = fizzy_get_selector("save:") orelse return;
    const save_item = file_menu.msgSend(objc.Object, "addItemWithTitle:action:keyEquivalent:", .{
        save_title.value,
        save_sel,
        key_s.value,
    });
    if (save_item.value != 0) {
        save_item.msgSend(void, "setTarget:", .{target.value});
        save_item.msgSend(void, "setKeyEquivalentModifierMask:", .{NSEventModifierFlagCommand});
    }

    // Save As — ⇧⌘S
    {
        const save_as_title = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"Save As…".ptr});
        const save_as_sel = fizzy_get_selector("saveAs:") orelse return;
        const save_as_item = file_menu.msgSend(objc.Object, "addItemWithTitle:action:keyEquivalent:", .{
            save_as_title.value,
            save_as_sel,
            key_s.value,
        });
        if (save_as_item.value != 0) {
            save_as_item.msgSend(void, "setTarget:", .{target.value});
            save_as_item.msgSend(void, "setKeyEquivalentModifierMask:", .{NSEventModifierFlagCommand | NSEventModifierFlagShift});
            setMenuItemImage(save_as_item, NSImage, NSString, "arrow.down.doc", "Save As");
        }
    }

    // Save All — ⌥⌘S (Option-Command-S, matches the common convention used by Xcode etc.)
    {
        const save_all_title = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"Save All".ptr});
        const save_all_sel = fizzy_get_selector("saveAll:") orelse return;
        const save_all_item = file_menu.msgSend(objc.Object, "addItemWithTitle:action:keyEquivalent:", .{
            save_all_title.value,
            save_all_sel,
            key_s.value,
        });
        if (save_all_item.value != 0) {
            save_all_item.msgSend(void, "setTarget:", .{target.value});
            save_all_item.msgSend(void, "setKeyEquivalentModifierMask:", .{NSEventModifierFlagCommand | NSEventModifierFlagOption});
            setMenuItemImage(save_all_item, NSImage, NSString, "square.and.arrow.down.on.square", "Save All");
        }
    }

    const file_title = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"File".ptr});
    const file_item = NSMenuItem.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "initWithTitle:action:keyEquivalent:", .{
        file_title.value,
        @as(usize, 0),
        empty.value,
    });
    if (file_item.value == 0) return;
    file_item.msgSend(void, "setSubmenu:", .{file_menu.value});
    main_menu.msgSend(void, "insertItem:atIndex:", .{ file_item.value, @as(c_ulong, 1) });

    // Edit menu — Copy, Paste, Undo, Redo, Transform (match DVUI menu)
    const key_c = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"c".ptr});
    const key_v = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"v".ptr});
    const key_z = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"z".ptr});
    const key_t = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"t".ptr});
    const key_e = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"e".ptr});
    const key_g = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"g".ptr});
    const key_m = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"m".ptr});

    const edit_menu_title_str = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"Edit".ptr});
    const edit_menu = NSMenu.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "initWithTitle:", .{edit_menu_title_str.value});
    if (edit_menu.value != 0) {
        addNativeMenuItem(edit_menu, NSMenuItem, NSString, target, "Copy", "copy:", @intFromPtr(key_c.value), NSEventModifierFlagCommand, @intFromPtr(empty.value));
        addNativeMenuItem(edit_menu, NSMenuItem, NSString, target, "Paste", "paste:", @intFromPtr(key_v.value), NSEventModifierFlagCommand, @intFromPtr(empty.value));
        edit_menu.msgSend(void, "addItem:", .{NSMenuItem.msgSend(objc.Object, "separatorItem", .{}).value});
        addNativeMenuItem(edit_menu, NSMenuItem, NSString, target, "Undo", "undo:", @intFromPtr(key_z.value), NSEventModifierFlagCommand, @intFromPtr(empty.value));
        addNativeMenuItem(edit_menu, NSMenuItem, NSString, target, "Redo", "redo:", @intFromPtr(key_z.value), NSEventModifierFlagCommand | NSEventModifierFlagShift, @intFromPtr(empty.value));
        edit_menu.msgSend(void, "addItem:", .{NSMenuItem.msgSend(objc.Object, "separatorItem", .{}).value});
        addNativeMenuItem(edit_menu, NSMenuItem, NSString, target, "Transform", "transform:", @intFromPtr(key_t.value), NSEventModifierFlagCommand, @intFromPtr(empty.value));
        edit_menu.msgSend(void, "addItem:", .{NSMenuItem.msgSend(objc.Object, "separatorItem", .{}).value});
        addNativeMenuItem(edit_menu, NSMenuItem, NSString, target, "Grid Layout…", "gridLayout:", @intFromPtr(key_g.value), NSEventModifierFlagCommand, @intFromPtr(empty.value));
        const edit_title = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"Edit".ptr});
        const edit_item = NSMenuItem.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "initWithTitle:action:keyEquivalent:", .{
            edit_title.value,
            @as(usize, 0),
            empty.value,
        });
        if (edit_item.value != 0) {
            edit_item.msgSend(void, "setSubmenu:", .{edit_menu.value});
            main_menu.msgSend(void, "insertItem:atIndex:", .{ edit_item.value, @as(c_ulong, 2) });
        }
    }

    // View menu — Show/Hide Explorer, Show DVUI Demo
    const view_menu_title_str = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"View".ptr});
    const view_menu = NSMenu.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "initWithTitle:", .{view_menu_title_str.value});
    if (view_menu.value != 0) {
        addNativeMenuItem(view_menu, NSMenuItem, NSString, target, "Show Explorer", "toggleExplorer:", @intFromPtr(key_e.value), NSEventModifierFlagCommand, @intFromPtr(empty.value));
        view_menu.msgSend(void, "addItem:", .{NSMenuItem.msgSend(objc.Object, "separatorItem", .{}).value});
        addNativeMenuItem(view_menu, NSMenuItem, NSString, target, "Show DVUI Demo", "showDvuiDemo:", @intFromPtr(empty.value), 0, @intFromPtr(empty.value));
        const view_title = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"View".ptr});
        const view_item = NSMenuItem.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "initWithTitle:action:keyEquivalent:", .{
            view_title.value,
            @as(usize, 0),
            empty.value,
        });
        if (view_item.value != 0) {
            view_item.msgSend(void, "setSubmenu:", .{view_menu.value});
            main_menu.msgSend(void, "insertItem:atIndex:", .{ view_item.value, @as(c_ulong, 3) });
        }
    }

    // App-menu cleanup:
    //   1. Retitle and re-target the auto-generated "About …" item from SDL's default about-panel to AboutFizzy.
    //   2. Substring-replace any remaining "DVUI App Example" in submenu titles ("Hide …", "Quit …", etc.).
    //      SDL stamped those titles using its own app metadata before our `setSdlAppMetadata` had a chance to run,
    //      and the labels are baked into the NSMenuItems — setting metadata later doesn't retroactively rename them.
    //   3. We do NOT add a Window submenu here — SDL/AppKit already inserts a top-level Window menu, and nesting one
    //      inside the app menu produced a visible duplicate.
    const app_menu_item = main_menu.msgSend(objc.Object, "itemAtIndex:", .{@as(c_ulong, 0)});
    const app_submenu = app_menu_item.msgSend(objc.Object, "submenu", .{});
    if (app_submenu.value != 0) {
        if (fizzy_get_selector("about:")) |about_sel| {
            const about_item = app_submenu.msgSend(objc.Object, "itemAtIndex:", .{@as(c_ulong, 0)});
            if (about_item.value != 0) {
                const about_title = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"About fizzy".ptr});
                about_item.msgSend(void, "setTitle:", .{about_title.value});
                about_item.msgSend(void, "setAction:", .{about_sel});
                about_item.msgSend(void, "setTarget:", .{target.value});
            }
        }

        // Patch every remaining "DVUI App Example" → "fizzy" in app-menu item titles.
        // `stringByReplacingOccurrencesOfString:withString:` is a no-op when the substring
        // isn't present, so it's safe to apply unconditionally over the whole menu.
        const search_str = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"DVUI App Example".ptr});
        const replacement_str = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"fizzy".ptr});
        const item_count = app_submenu.msgSend(c_long, "numberOfItems", .{});
        var idx: c_long = 0;
        while (idx < item_count) : (idx += 1) {
            const item = app_submenu.msgSend(objc.Object, "itemAtIndex:", .{idx});
            if (item.value == 0) continue;
            const cur_title = item.msgSend(objc.Object, "title", .{});
            if (cur_title.value == 0) continue;
            const new_title = cur_title.msgSend(objc.Object, "stringByReplacingOccurrencesOfString:withString:", .{ search_str.value, replacement_str.value });
            if (new_title.value != 0) {
                item.msgSend(void, "setTitle:", .{new_title.value});
            }
        }
    }

    // Help menu — Check for Updates… (matches the infobar fizzy button: opens the AboutFizzy dialog).
    const help_menu_title_str = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"Help".ptr});
    const help_menu = NSMenu.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "initWithTitle:", .{help_menu_title_str.value});
    if (help_menu.value != 0) {
        addNativeMenuItem(help_menu, NSMenuItem, NSString, target, "Check for Updates…", "checkForUpdates:", @intFromPtr(empty.value), 0, @intFromPtr(empty.value));
        help_menu.msgSend(void, "addItem:", .{NSMenuItem.msgSend(objc.Object, "separatorItem", .{}).value});

        // Report Bug → opens the GitHub Issues page in the user's browser.
        // Inlined (instead of using `addNativeMenuItem`) so we can attach an SF Symbol.
        if (fizzy_get_selector("reportBug:")) |report_bug_sel| {
            const bug_title = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"Report Bug…".ptr});
            const bug_item = help_menu.msgSend(objc.Object, "addItemWithTitle:action:keyEquivalent:", .{
                bug_title.value,
                report_bug_sel,
                empty.value,
            });
            if (bug_item.value != 0) {
                bug_item.msgSend(void, "setTarget:", .{target.value});
                setMenuItemImage(bug_item, NSImage, NSString, "ant.fill", "Report Bug");
            }
        }

        const help_item = NSMenuItem.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "initWithTitle:action:keyEquivalent:", .{
            help_menu_title_str.value,
            @as(usize, 0),
            empty.value,
        });
        if (help_item.value != 0) {
            help_item.msgSend(void, "setSubmenu:", .{help_menu.value});
            // Append at the end so the conventional macOS order (App, File, Edit, View, …, Window, Help) is preserved.
            main_menu.msgSend(void, "addItem:", .{help_item.value});
            // Tell AppKit this is the Help menu so the system search field is wired in.
            ns_app.msgSend(void, "setHelpMenu:", .{help_menu.value});
        }
    }

    // key_m was previously used by the now-removed nested Window submenu; keep the binding silent.
    _ = key_m;
    macos_menu_bar_set_up = true;
}

/// Sets an SF Symbol image on a menu item (macOS 11+). No-op if the image cannot be created.
fn setMenuItemImage(menu_item: objc.Object, NSImageClass: objc.Class, NSStringClass: objc.Class, symbol_name: [*:0]const u8, accessibility_desc: [*:0]const u8) void {
    const name_str = NSStringClass.msgSend(objc.Object, "stringWithUTF8String:", .{symbol_name});
    const desc_str = NSStringClass.msgSend(objc.Object, "stringWithUTF8String:", .{accessibility_desc});
    const img = NSImageClass.msgSend(objc.Object, "imageWithSystemSymbolName:accessibilityDescription:", .{
        name_str.value,
        desc_str.value,
    });
    if (img.value != 0) {
        img.msgSend(void, "setTemplate:", .{true});
        menu_item.msgSend(void, "setImage:", .{img.value});
    }
}

fn addNativeMenuItem(menu: objc.Object, _: objc.Class, NSStringClass: objc.Class, target: objc.Object, title: [*:0]const u8, action_name: [*:0]const u8, key_equiv_value: usize, modifier_mask: c_ulong, empty_str: usize) void {
    const sel = fizzy_get_selector(action_name) orelse return;
    const title_obj = NSStringClass.msgSend(objc.Object, "stringWithUTF8String:", .{title});
    const item = menu.msgSend(objc.Object, "addItemWithTitle:action:keyEquivalent:", .{
        title_obj.value,
        @intFromPtr(sel),
        if (key_equiv_value != 0) key_equiv_value else empty_str,
    });
    if (item.value != 0) {
        item.msgSend(void, "setTarget:", .{target.value});
        if (modifier_mask != 0) item.msgSend(void, "setKeyEquivalentModifierMask:", .{modifier_mask});
    }
}

fn addNativeMenuItemWithTarget(menu: objc.Object, _: objc.Class, NSStringClass: objc.Class, target: ?objc.Object, title: [*:0]const u8, action: *const anyopaque, key_equiv_value: usize, modifier_mask: c_ulong, empty_str: usize) void {
    const title_obj = NSStringClass.msgSend(objc.Object, "stringWithUTF8String:", .{title});
    const item = menu.msgSend(objc.Object, "addItemWithTitle:action:keyEquivalent:", .{
        title_obj.value,
        @intFromPtr(action),
        if (key_equiv_value != 0) key_equiv_value else empty_str,
    });
    if (item.value != 0) {
        if (target) |t| item.msgSend(void, "setTarget:", .{t.value});
        if (modifier_mask != 0) item.msgSend(void, "setKeyEquivalentModifierMask:", .{modifier_mask});
    }
}

/// Returns and clears a pending native menu action (macOS menu bar). Call once per frame; on non-macOS always returns null.
pub fn pollPendingNativeMenuAction() ?NativeMenuAction {
    const id = pending_native_menu_action_id.swap(-1, .acq_rel);
    if (id < 0 or id > @intFromEnum(NativeMenuAction.save_all)) return null;
    return @enumFromInt(id);
}

pub fn showSimpleMessage(title: [:0]const u8, message: [:0]const u8) void {
    if (sdl3.SDL_ShowSimpleMessageBox(sdl3.SDL_MESSAGEBOX_INFORMATION, title, message, dvui.currentWindow().backend.impl.window)) {
        std.log.debug("true!", .{});
    }
}

pub fn showSaveFileDialog(cb: *const fn (?[][:0]const u8) void, filters: []const DialogFileFilter, default_filename: []const u8, default_folder: ?[]const u8) void {
    const default: [:0]const u8 = blk: {
        if (default_folder) |folder| {
            break :blk std.fs.path.joinZ(fizzy.app.allocator, &.{ folder, default_filename }) catch "untitled";
        } else if (fizzy.editor.recents.last_save_folder) |last_save_folder| {
            break :blk std.fs.path.joinZ(fizzy.app.allocator, &.{ last_save_folder, default_filename }) catch "untitled";
        } else {
            break :blk std.fs.path.joinZ(fizzy.app.allocator, &.{ fizzy.editor.folder orelse "", default_filename }) catch "untitled";
        }
    };
    defer fizzy.app.allocator.free(default);
    // Do not use our borderless/custom-frame main window as the dialog parent on Windows: the shell
    // may inherit extended style and the picker loses normal frame/close affordances.
    const parent: ?*sdl3.SDL_Window = if (builtin.os.tag == .windows) null else dvui.currentWindow().backend.impl.window;
    sdl3.SDL_ShowSaveFileDialog(GenericSaveDialogCallback, @ptrCast(@alignCast(@constCast(cb))), parent, filters.ptr, @intCast(filters.len), default);
}

pub fn showOpenFileDialog(cb: *const fn (?[][:0]const u8) void, filters: []const DialogFileFilter, default_filename: []const u8, default_folder: ?[]const u8) void {
    const default: [:0]const u8 = blk: {
        if (default_folder) |folder| {
            break :blk std.fs.path.joinZ(fizzy.app.allocator, &.{ folder, default_filename }) catch "untitled";
        } else if (fizzy.editor.recents.last_open_folder) |last_open_folder| {
            break :blk std.fs.path.joinZ(fizzy.app.allocator, &.{ last_open_folder, default_filename }) catch "untitled";
        } else {
            break :blk std.fs.path.joinZ(fizzy.app.allocator, &.{ fizzy.editor.folder orelse "", default_filename }) catch "untitled";
        }
    };
    defer fizzy.app.allocator.free(default);
    const parent: ?*sdl3.SDL_Window = if (builtin.os.tag == .windows) null else dvui.currentWindow().backend.impl.window;
    sdl3.SDL_ShowOpenFileDialog(GenericOpenDialogCallback, @ptrCast(@alignCast(@constCast(cb))), parent, filters.ptr, @intCast(filters.len), default.ptr, true);
}

pub fn showOpenFolderDialog(cb: *const fn (?[][:0]const u8) void, default_folder: ?[]const u8) void {
    const default: [:0]const u8 = blk: {
        if (default_folder) |folder| {
            break :blk std.fmt.allocPrintSentinel(fizzy.app.allocator, "{s}", .{folder}, 0) catch "untitled";
        } else {
            if (fizzy.editor.recents.last_open_folder) |last_open_folder| {
                break :blk std.fmt.allocPrintSentinel(fizzy.app.allocator, "{s}", .{last_open_folder}, 0) catch "untitled";
            } else {
                break :blk std.fmt.allocPrintSentinel(fizzy.app.allocator, "{s}", .{fizzy.editor.folder orelse ""}, 0) catch "untitled";
            }
        }
    };
    defer fizzy.app.allocator.free(default);
    const parent: ?*sdl3.SDL_Window = if (builtin.os.tag == .windows) null else dvui.currentWindow().backend.impl.window;
    sdl3.SDL_ShowOpenFolderDialog(GenericOpenDialogCallback, @ptrCast(@alignCast(@constCast(cb))), parent, default.ptr, false);
}

fn GenericSaveDialogCallback(cb: ?*anyopaque, files: [*c]const [*c]const u8, _: c_int) callconv(.c) void {
    GenericDialogCallback(cb, files, .save);
}

fn GenericOpenDialogCallback(cb: ?*anyopaque, files: [*c]const [*c]const u8, _: c_int) callconv(.c) void {
    GenericDialogCallback(cb, files, .open);
}

fn GenericDialogCallback(cb: ?*anyopaque, files: [*c]const [*c]const u8, mode: enum { save, open }) void {
    const callback: *const fn (?[][:0]const u8) void = @ptrCast(@alignCast(@constCast(cb)));

    // Try to count the number of files until we hit a null pointer.
    var path_count: usize = 0;
    while (files[path_count] != null) : (path_count += 1) {}

    const zig_files: [][:0]const u8 = blk: {
        var result: [100][:0]const u8 = undefined; // Arbitrary max; refine as needed
        var i: usize = 0;
        while (i < path_count) : (i += 1) {
            result[i] = std.mem.span(files[i]);
        }
        break :blk result[0..path_count];
    };

    if (zig_files.len == 0) {
        callback(null);
        return;
    }

    { // Save the open or save folder for the next time the dialog is shown
        if (std.fs.path.dirname(zig_files[0])) |dir| {
            if (mode == .save) {
                if (fizzy.editor.recents.last_save_folder) |last_save_folder| {
                    fizzy.app.allocator.free(last_save_folder);
                }
                fizzy.editor.recents.last_save_folder = fizzy.app.allocator.dupe(u8, dir) catch {
                    dvui.log.err("Failed to dupe directory {s}", .{dir});
                    return;
                };
            } else {
                if (fizzy.editor.recents.last_open_folder) |last_open_folder| {
                    fizzy.app.allocator.free(last_open_folder);
                }
                fizzy.editor.recents.last_open_folder = fizzy.app.allocator.dupe(u8, dir) catch {
                    dvui.log.err("Failed to dupe directory {s}", .{dir});
                    return;
                };
            }
        }
    }

    callback(zig_files);
}

// ----------------------------------------------------------------------------
// File-open-from-OS routing.
//
// On macOS, double-clicking a registered document type in Finder fires an
// `openFiles:` Apple Event rather than spawning a new process — so our
// singleton's argv-forwarding path never sees it. SDL3 translates the event
// into `SDL_EVENT_DROP_FILE` on the running app. We install an event watch
// that queues the path into the singleton's pending list so `drainPending`
// opens it on the next frame.
// ----------------------------------------------------------------------------

// SDL window pointer captured at install time so the event-watch callback
// (which fires outside any dvui frame) can raise the window without
// touching `dvui.currentWindow()` (TLS-only, frame-only).
var captured_sdl_window: ?*sdl3.SDL_Window = null;

fn handleSdlFileEvent(event: ?*sdl3.SDL_Event) void {
    const e = event orelse return;
    if (e.type != sdl3.SDL_EVENT_DROP_FILE) return;
    const data_ptr = e.drop.data orelse return;
    const path = std.mem.span(data_ptr);
    singleton.queuePath(path);
    // Best-effort: raise the previously-captured SDL window.
    if (captured_sdl_window) |w| _ = sdl3.SDL_RaiseWindow(w);
}

fn sdlFileOpenEventWatch(_: ?*anyopaque, event: ?*sdl3.SDL_Event) callconv(.c) bool {
    handleSdlFileEvent(event);
    // SDL_AddEventWatch ignores the return value; keep the event in queue.
    return true;
}

fn sdlFileOpenDrainFilter(_: ?*anyopaque, event: ?*sdl3.SDL_Event) callconv(.c) bool {
    handleSdlFileEvent(event);
    // Keep the event in the queue (dvui's backend will harmlessly ignore it).
    return true;
}

/// Register an SDL event watch so that file-open events from the OS get
/// queued into the singleton's pending list. Also drains any DROP_FILE
/// events that were queued before the watch was installed (cold-launch
/// via macOS "Open With" can queue the event during SDL init, before
/// `AppInit` runs). Caller must pass the dvui window (we capture its SDL
/// handle so the callback can raise the window without touching dvui TLS
/// state that is only valid mid-frame).
pub fn installFileOpenEventHandling(win: *dvui.Window) void {
    captured_sdl_window = win.backend.impl.window;
    _ = sdl3.SDL_AddEventWatch(sdlFileOpenEventWatch, null);
    sdl3.SDL_FilterEvents(sdlFileOpenDrainFilter, null);
}
