// These are functions specific to the backend, which is currently SDL3
const fizzy = @import("../fizzy.zig");

const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const core = @import("core");
const layout_file = @import("layout_file.zig");
const sdl3 = @import("backend").c;
const objc = @import("objc");
const win32 = @import("win32");
const singleton = @import("app").single_instance;
const window_layout = @import("app").window.layout;
const Constants = @import("../editor/Constants.zig");
const KeybindSettings = @import("../editor/KeybindSettings.zig");
const menu_model = @import("../editor/menu_model.zig");
const AppInfo = @import("app").AppInfo;

/// The window and platform pieces any app on these backends gets (`src/backend/native/platform`):
/// dialogs, files from the OS, gestures, the window's chrome and state, Windows' title bar. What
/// follows them here is fizzy's own use of them.
const platform = @import("platform");

pub const setAllocator = platform.dialogs.setAllocator;
pub const DialogDirs = platform.dialogs.DialogDirs;
pub const DialogMode = platform.dialogs.DialogMode;
pub const setDialogDirs = platform.dialogs.setDialogDirs;
pub const DialogFileFilter = platform.dialogs.DialogFileFilter;
pub const showSaveFileDialog = platform.dialogs.showSaveFileDialog;
pub const showOpenFileDialog = platform.dialogs.showOpenFileDialog;
pub const showOpenFolderDialog = platform.dialogs.showOpenFolderDialog;
pub const pollPendingDialogResult = platform.dialogs.pollPendingDialogResult;
fn alloc() std.mem.Allocator {
    return platform.dialogs.allocator();
}

pub const installTrackpadGestureMonitor = platform.gestures.installTrackpadGestureMonitor;
pub const takeTrackpadPinchRatio = platform.gestures.takeTrackpadPinchRatio;

pub const isMaximized = platform.window.isMaximized;
pub const isFullscreenChromeHidden = platform.window.isFullscreenChromeHidden;
pub const setWindowStyle = platform.window.setStyle;
pub const setTitlebarColor = platform.window.setBackground;
pub const raiseWindow = platform.window.raise;
pub const toggleFullscreen = platform.window.toggleFullscreen;

pub const TitleBarButton = platform.win32_titlebar.TitleBarButton;
pub const resetTitleBarHints = platform.win32_titlebar.resetTitleBarHints;
pub const setTitleBarStrip = platform.win32_titlebar.setTitleBarStrip;
pub const pushTitleBarInteractiveRect = platform.win32_titlebar.pushTitleBarInteractiveRect;
pub const setTitleBarCaptionButtonRect = platform.win32_titlebar.setTitleBarCaptionButtonRect;
pub const getHoveredTitleBarButton = platform.win32_titlebar.getHoveredTitleBarButton;
const getWin32Hwnd = platform.win32_titlebar.getWin32Hwnd;

/// Files the OS asks fizzy to open while it runs go to the single-instance queue, which opens
/// them on the next frame (`platform.open_events`).
pub fn installFileOpenEventHandling(win: *dvui.Window) void {
    platform.open_events.install(win, singleton.queuePath);
}

// AppKit geometry types for NSView frame/bounds (same layout as Foundation).
const NSPoint = extern struct { x: f64, y: f64 };
const NSSize = extern struct { width: f64, height: f64 };
const NSRect = extern struct { origin: NSPoint, size: NSSize };

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
    // (window.zon) and disabled in dvui, so there is nothing to toggle here.
    if (!macosTransitionSyncActive()) return;
    macosSyncContentViews(back.window);
    macosSyncRendererSize(back.window, true);
}

/// Saved vsync setting while a manual live resize has it switched off.
var macos_live_resize_saved_vsync: ?c_int = null;

/// Frames during a manual live resize are paced by SDL's 60Hz timer inside AppKit's
/// resize-tracking loop; a vsync-blocking present there only delays the tracker's next
/// mouse event, so quick drags fall behind the pointer. Off for the drag, restored after.
export fn fizzy_macos_window_live_resize_vsync(active: c_int) void {
    if (comptime builtin.os.tag != .macos) return;
    const window = macos_monitor_window orelse return;
    // Fizzy's own backend sets its swapchain's present mode; dvui's SDL_Renderer one its renderer's.
    const Backend = @import("backend");
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
    const renderer = sdl3.SDL_GetRenderer(window) orelse return;
    if (active != 0) {
        if (macos_live_resize_saved_vsync != null) return;
        var vsync: c_int = 0;
        if (!sdl3.SDL_GetRenderVSync(renderer, &vsync)) return;
        macos_live_resize_saved_vsync = vsync;
        _ = sdl3.SDL_SetRenderVSync(renderer, 0);
    } else if (macos_live_resize_saved_vsync) |vsync| {
        macos_live_resize_saved_vsync = null;
        _ = sdl3.SDL_SetRenderVSync(renderer, vsync);
    }
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

// Frame-based geometry persistence. fizzy's window is a frame == content window (full-size
// content view), which dvui's content-based `WindowGeometry` can't represent — so fizzy persists
// the actual NSWindow.frame (AppKit bottom-left points) itself, macOS-only, in `layout.zon`
// beside the regions. dvui's own persistence is disabled (persist_window_geometry = false in
// App.startOptions).
/// `layout.zon` — what a shape's regions and window frame were left as. The file code lives in
/// `layout_file.zig` over `core.fs`, so the web backend shares it; the macOS geometry save
/// below is the one native-only writer.
pub const SavedRegion = layout_file.SavedRegion;
pub const SavedShows = layout_file.SavedShows;
pub const saveRegions = layout_file.saveRegions;
pub const loadRegions = layout_file.loadRegions;
pub const freeRegions = layout_file.freeRegions;
pub const saveTree = layout_file.saveTree;
pub const loadTree = layout_file.loadTree;
const SavedFrame = layout_file.SavedFrame;
const loadWindowFile = layout_file.loadWindowFile;
const writeWindowFile = layout_file.writeWindowFile;

/// The saved NSWindow frame, or null if there's none yet / it's degenerate (w/h < 1) — same
/// contract `loadSavedFrame` had before the rename. macOS-only caller (`restoreWindowState`).
fn loadSavedFrame(dir: []const u8) ?SavedFrame {
    const gpa = std.heap.page_allocator;
    const f = loadWindowFile(gpa, dir);
    if (f.w < 1 or f.h < 1) {
        std.zon.parse.free(gpa, f);
        return null;
    }
    return f;
}

/// Read-modify-write: preserves whatever ratios are already on disk, overrides only the frame
/// geometry. macOS-only caller (`saveWindowGeometry`).
fn writeSavedFrame(dir: []const u8, x: f64, y: f64, w: f64, h: f64) void {
    const gpa = std.heap.page_allocator;
    var f = loadWindowFile(gpa, dir);
    defer std.zon.parse.free(gpa, f);
    f.x = x;
    f.y = y;
    f.w = w;
    f.h = h;
    writeWindowFile(dir, f);
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
    platform.window.attach(win);
    if (comptime builtin.os.tag == .windows) restoreWin32Placement(win);
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
        // owns it via window.zon.
        macos_monitor_window = window;
        // `begin_hook` is now a per-backend field (dvui moved it off the module).
        back.begin_hook = macosAppPreBeginSync;
        fizzy_macos_window_install_resize_observer(cocoa);
    }
}

/// Persist the current windowed NSWindow.frame. Call at shutdown (AppDeinit) so
/// the next launch restores the exact frame. No-op on non-macOS.
pub fn saveWindowGeometry(win: *dvui.Window) void {
    if (comptime builtin.os.tag == .windows) return saveWin32Placement(win);
    if (comptime builtin.os.tag != .macos) return;
    const back = win.backend.impl;
    const dir = (back.init_opts_save orelse return).pref_path orelse return;
    const cocoa = cocoaWindowOf(back.window) orelse return;
    var out4: [4]f64 = .{0} ** 4;
    fizzy_macos_window_current_windowed_frame(cocoa, &out4);
    if (out4[2] < 1 or out4[3] < 1) return;
    writeSavedFrame(dir, out4[0], out4[1], out4[2], out4[3]);
}

// Windows: the window's placement — its normal (restored) rect in workspace coordinates and
// whether it is maximized — the way Windows itself remembers windows. Frame-based, as macOS's is:
// fizzy's client area is the whole window (`WM_NCCALCSIZE`), which dvui's content-rect
// persistence cannot represent.
const WINDOWPLACEMENT = if (builtin.os.tag == .windows) win32.ui.windows_and_messaging.WINDOWPLACEMENT else void;

fn saveWin32Placement(win: *dvui.Window) void {
    if (comptime builtin.os.tag != .windows) return;
    const dir = (win.backend.impl.init_opts_save orelse return).pref_path orelse return;
    const hwnd: win32.foundation.HWND = @ptrCast(getWin32Hwnd(win) orelse return);
    var wp = std.mem.zeroes(WINDOWPLACEMENT);
    wp.length = @sizeOf(WINDOWPLACEMENT);
    if (win32.ui.windows_and_messaging.GetWindowPlacement(hwnd, &wp) == 0) return;
    const r = wp.rcNormalPosition;
    if (r.right - r.left < 1 or r.bottom - r.top < 1) return;
    const gpa = std.heap.page_allocator;
    var f = loadWindowFile(gpa, dir);
    defer std.zon.parse.free(gpa, f);
    f.x = @floatFromInt(r.left);
    f.y = @floatFromInt(r.top);
    f.w = @floatFromInt(r.right - r.left);
    f.h = @floatFromInt(r.bottom - r.top);
    f.maximized = @as(u32, @bitCast(wp.showCmd)) == @as(u32, @bitCast(win32.ui.windows_and_messaging.SW_SHOWMAXIMIZED)) or
        wp.flags.RESTORETOMAXIMIZED != 0;
    writeWindowFile(dir, f);
}

fn restoreWin32Placement(win: *dvui.Window) void {
    if (comptime builtin.os.tag != .windows) return;
    const dir = (win.backend.impl.init_opts_save orelse return).pref_path orelse return;
    const hwnd: win32.foundation.HWND = @ptrCast(getWin32Hwnd(win) orelse return);
    const f = loadSavedFrame(dir) orelse return;
    defer std.zon.parse.free(std.heap.page_allocator, f);
    var rect: win32.foundation.RECT = .{
        .left = @intFromFloat(f.x),
        .top = @intFromFloat(f.y),
        .right = @intFromFloat(f.x + f.w),
        .bottom = @intFromFloat(f.y + f.h),
    };
    // Only onto a monitor that is still there.
    if (win32.graphics.gdi.MonitorFromRect(&rect, win32.graphics.gdi.MONITOR_DEFAULTTONULL) == null) return;
    var wp = std.mem.zeroes(WINDOWPLACEMENT);
    wp.length = @sizeOf(WINDOWPLACEMENT);
    // The window is still hidden: placed hidden, it shows where it was left when `showWindow`
    // reveals it, maximized if it was (`restore_maximized`).
    wp.showCmd = win32.ui.windows_and_messaging.SW_HIDE;
    wp.rcNormalPosition = rect;
    _ = win32.ui.windows_and_messaging.SetWindowPlacement(hwnd, &wp);
    restore_maximized = f.maximized;
}

/// Show the window maximized when it is revealed: it was left that way (Windows).
var restore_maximized = false;

/// Reveal the window after chrome + geometry are settled (it is created hidden): maximized when it
/// was left that way (Windows).
pub fn showWindow(win: *dvui.Window) void {
    platform.window.show(win, restore_maximized);
    restore_maximized = false;
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

// macOS native menu bar (top bar): action ids match FizzyMenuTarget.m

/// Every fixed menu-bar item, by the action it performs, kept so a rebind can push the new
/// chord onto the item. Without this the `NSMenu` key equivalent stays whatever it was built
/// with: `Keybinds.tick` deliberately skips these commands on macOS (the native menu already
/// ran them), so after rebinding, the new chord had nothing dispatching it and the old one kept
/// working. See `setNativeMenuShortcut`.
var native_menu_items: [menu_model.flat_commands.len]?objc.Object = @splat(null);

/// Point a menu item at a different chord. `key` is the key-equivalent character (lowercase,
/// as AppKit expects — the shift modifier is carried in the mask, not the case); passing null
/// clears the shortcut, which is the right outcome for a chord AppKit can't express.
pub fn setNativeMenuShortcut(tag: usize, key: ?[]const u8, modifier_mask: c_ulong) void {
    if (comptime builtin.os.tag != .macos) return;
    if (tag >= native_menu_items.len) return;
    applyKeyEquivalent(native_menu_items[tag] orelse return, key, modifier_mask);
}

/// `setNativeMenuShortcut` for a plugin-contributed item, keyed by its index in
/// `Host.native_menu_items` — the same index `rebuildDynamicNativeMenus` stamps as the item's
/// tag. Silently does nothing when that item isn't currently in the bar (hidden, or its plugin
/// unloaded), which is the same shape as a stale tag above.
pub fn setDynamicNativeMenuShortcut(index: usize, key: ?[]const u8, modifier_mask: c_ulong) void {
    if (comptime builtin.os.tag != .macos) return;
    for (dynamic_leaf_items.items) |entry| {
        if (entry.index != index) continue;
        applyKeyEquivalent(entry.item, key, modifier_mask);
        return;
    }
}

fn applyKeyEquivalent(item: objc.Object, key: ?[]const u8, modifier_mask: c_ulong) void {
    const NSString = objc.getClass("NSString") orelse return;

    var buf: [8]u8 = undefined;
    const text: [:0]const u8 = blk: {
        const k = key orelse break :blk "";
        if (k.len >= buf.len) break :blk "";
        @memcpy(buf[0..k.len], k);
        buf[k.len] = 0;
        break :blk buf[0..k.len :0];
    };

    const str = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{text.ptr});
    item.msgSend(void, "setKeyEquivalent:", .{str.value});
    item.msgSend(void, "setKeyEquivalentModifierMask:", .{if (key == null) @as(c_ulong, 0) else modifier_mask});
}

pub const modifier_command: c_ulong = NSEventModifierFlagCommand;
pub const modifier_shift: c_ulong = NSEventModifierFlagShift;
pub const modifier_option: c_ulong = NSEventModifierFlagOption;
pub const modifier_control: c_ulong = NSEventModifierFlagControl;

// Queue a single pending native action id.
// This may be written from an AppKit callback thread, so use an atomic.
var pending_native_menu_action_id: std.atomic.Value(c_int) = .init(-1);
/// Whether the pending action fired as a key equivalent (see `NativeMenuAction.from_key`).
var pending_native_menu_action_from_key: std.atomic.Value(bool) = .init(false);

/// Called from FizzyMenuTarget.m when user picks a native menu item. Runs on main thread.
export fn FizzyNativeMenuAction(id: c_int, from_key: bool) void {
    pending_native_menu_action_from_key.store(from_key, .release);
    pending_native_menu_action_id.store(id, .release);
}

/// A native menu item the user activated. `from_key` means a ⌘-key equivalent, not a click:
/// AppKit runs the menu action *and* passes the keystroke on to SDL, so the key event is still
/// on its way to whatever widget has focus — a command that would otherwise synthesize one
/// (paste into a text field) must not.
pub const NativeMenuAction = struct {
    index: usize,
    from_key: bool,
};

// Queue a single pending generic (plugin `NativeMenuItem`) action tag. Same threading note
// as `pending_native_menu_action_id` above.
var pending_generic_native_menu_action_tag: std.atomic.Value(c_int) = .init(-1);

/// Called from FizzyMenuTarget.m's `genericMenuAction:` (shared by every plugin-contributed
/// native menu item) with the clicked `NSMenuItem`'s `tag` — an index into
/// `host.native_menu_items`, assigned by `rebuildDynamicNativeMenus`. Runs on main thread.
export fn FizzyNativeMenuGenericAction(tag: c_int) void {
    pending_generic_native_menu_action_tag.store(tag, .release);
}

/// Called from `FizzyMenuTarget.m`'s `validateMenuItem:` (an `NSMenuItemValidation` hook
/// AppKit calls synchronously, on the main thread, whenever a menu is about to show — this
/// is the *only* way to grey out a native `NSMenu` item, unlike the in-app DVUI menu bar
/// (`Menu.zig`), which recomputes "enabled" on every draw) with the clicked item's `tag`,
/// set to the matching `NativeMenuAction` by `addNativeMenuItem`/`setupMacOSMenuBar`.
///
/// Mirrors the exact greying conditions `Menu.zig` already computes for the DVUI menu bar.
/// Every function this touches (`Editor.activeDoc`, `Plugin.isDirty`/`canUndo`/`canRedo`,
/// `Editor.activeDocHasCommand`/`activeDocCommandEnabled`, `Editor.open_files`) is plain
/// `Host`/`Editor` state — none of it touches `dvui.currentWindow()` — so it's safe to call
/// from outside `Window.begin`/`end`, unlike e.g. the save/open dialog callbacks (see
/// `pollPendingDialogResult`).
/// True while the app must not act on key presses at all. AppKit matches an `NSMenu` key
/// equivalent and fires its action before the key ever reaches SDL, so the only way to stop
/// `cmd+o` from opening a folder picker while the settings pane is capturing a chord is to
/// report the menu items disabled — AppKit will not perform a disabled item's key equivalent.
export fn FizzyNativeMenuInputBlocked() callconv(.c) bool {
    return KeybindSettings.isRecording();
}

export fn FizzyNativeMenuActionEnabled(tag: c_int) callconv(.c) bool {
    if (KeybindSettings.isRecording()) return false;
    if (tag < 0) return true;
    const item = menu_model.byTag(@intCast(tag)) orelse return true;
    // Copy/Paste stay enabled here even when the active document can't do them: a disabled
    // NSMenuItem does not perform its key equivalent, and on macOS that is the only way the
    // chord reaches the app at all, including the focused widgets that handle it themselves.
    if (item.native_always_enabled) return true;
    // `visible` items that aren't visible are shown greyed rather than removed — rebuilding the
    // retained NSMenu on every state change isn't worth it for the same information.
    if (item.visible) |f| {
        if (!f(fizzy.editor())) return false;
    }
    const enabled = item.enabled orelse return true;
    return enabled(fizzy.editor());
}

/// Same idea as `FizzyNativeMenuActionEnabled` above, but for a plugin-contributed
/// `NativeMenuItem` (`tag` indexes `host.native_menu_items`, like `FizzyNativeMenuGenericAction`
/// resolves). These have no `visible`/`enabled` fields of their own: an item names its `Command`
/// via `NativeMenuItem.command` so the enabled state is the command's, on both menu bars
/// (`Editor.fizzyDrawMenuItem` greys the in-app row the same way). No `command` means "always
/// enabled", same as a dvui row with no `command_id`.
export fn FizzyNativeMenuGenericActionEnabled(tag: c_int) callconv(.c) bool {
    if (KeybindSettings.isRecording()) return false;
    if (tag < 0) return true;
    const items = fizzy.editor().app.host.native_menu_items.items;
    if (tag >= items.len) return true;
    const cmd = items[@intCast(tag)].command orelse return true;
    return fizzy.editor().app.host.commandEnabled(cmd);
}

/// Current label for a model item, so state-dependent titles ("Show Explorer" / "Hide
/// Explorer") track the app. AppKit menus are retained state; validation runs just before a
/// menu displays, which is when this is called.
export fn FizzyNativeMenuItemTitle(tag: c_int) callconv(.c) ?[*:0]const u8 {
    if (tag < 0) return null;
    const item = menu_model.byTag(@intCast(tag)) orelse return null;
    return switch (item.title) {
        .static => null, // already correct; nothing to rewrite
        .dynamic => |f| f(fizzy.editor()).ptr,
    };
}

/// The app menu's "About <app>", which AppKit creates rather than the model.
export fn FizzyNativeMenuAboutAction() callconv(.c) void {
    pending_native_menu_about.store(true, .release);
}
var pending_native_menu_about: std.atomic.Value(bool) = .init(false);

/// A Recent Folders click. The index is into `editor.app.recents.folders`, newest last.
export fn FizzyNativeRecentFolderAction(index: c_int) callconv(.c) void {
    if (index < 0) return;
    pending_native_recent_folder.store(index, .release);
}
var pending_native_recent_folder: std.atomic.Value(c_int) = .init(-1);

/// Returns and clears a pending Recent Folders selection.
pub fn pollPendingRecentFolder() ?usize {
    const i = pending_native_recent_folder.swap(-1, .acq_rel);
    if (i < 0) return null;
    return @intCast(i);
}

/// `FizzyGetSelector` from `FizzyMenuTarget.m` — turns a selector name into a SEL without
/// linking the Objective-C runtime here directly.
extern fn FizzyGetSelector(name: [*:0]const u8) ?*anyopaque;

fn fizzy_get_selector(name: [*:0]const u8) ?*anyopaque {
    return FizzyGetSelector(name);
}

/// Returns and clears a pending app-menu About click.
pub fn pollPendingAbout() bool {
    return pending_native_menu_about.swap(false, .acq_rel);
}

/// Height of the top strip that keeps editor content clear of the traffic lights.
/// Collapsed during fullscreen Space; expanded early when exiting so
/// traffic lights don't overlap left-anchored panes mid-transition.
/// Zoom/maximize without a Space keeps the full strip.
pub fn titlebarStripHeight(win: *dvui.Window) f32 {
    if (builtin.os.tag != .macos) return Constants.titlebar_height;
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
        .titlebar_height = Constants.titlebar_height,
        .titlebar_top_buffer = Constants.titlebar_top_buffer,
    });
}

/// Override the SDL app metadata DVUI sets to its example defaults. On macOS this
/// is what drives the app menu's `About <name>` / `Hide <name>` / `Quit <name>`
/// items. Must be called before `setupMacOSMenuBar` so the inserted Help menu
/// references the right product name.
pub fn setSdlAppMetadata(name: [*:0]const u8, version: [*:0]const u8, identifier: [*:0]const u8) void {
    _ = sdl3.SDL_SetAppMetadata(name, version, identifier);
}

var macos_menu_bar_set_up: bool = false;

// ---- plugin-contributed native menus (macOS) -------------------------------------------
// `setupMacOSMenuBar` builds the fixed App/File/Edit/View/Help menus below and stashes
// handles to them (plus the shared target + Help's insertion point) here, so
// `rebuildDynamicNativeMenus` can append plugin `NativeMenuItem`s into them, and create
// whole new top-level menus for plugin-owned `MenuContribution`s, without rebuilding the
// fixed menus. Called once at startup (from the end of `setupMacOSMenuBar`) and again on
// every plugin load/unload/hide-toggle (see `Editor.zig`).
var native_main_menu: ?objc.Object = null;
var native_menu_target: ?objc.Object = null;
var native_help_item: ?objc.Object = null;
var native_file_menu: ?objc.Object = null;
var native_edit_menu: ?objc.Object = null;
var native_view_menu: ?objc.Object = null;
var native_help_menu: ?objc.Object = null;
/// Top-level NSMenus, indexed like `menu_model.menu_bar`.
var native_submenus: [menu_model.menu_bar.len]?objc.Object = @splat(null);
/// The Recent Folders submenu and the item carrying it, rebuilt as the recents list changes.
var native_recent_folders_menu: ?objc.Object = null;
var native_recent_folders_item: ?objc.Object = null;

const DynamicTopLevelMenu = struct { item: objc.Object, menu: objc.Object };
/// `index` is the item's position in `Host.native_menu_items` — its `NSMenuItem` tag, and the
/// handle `setDynamicNativeMenuShortcut` restamps a rebound chord through.
const DynamicLeafItem = struct { parent_menu: objc.Object, item: objc.Object, index: usize };

/// Plugin-created top-level menus (main-menu items) from the previous rebuild, torn down
/// at the start of the next one.
var dynamic_top_level_menus: std.ArrayListUnmanaged(DynamicTopLevelMenu) = .empty;
/// Plugin leaf items injected into any menu (built-in or plugin-owned) from the previous
/// rebuild, torn down at the start of the next one.
var dynamic_leaf_items: std.ArrayListUnmanaged(DynamicLeafItem) = .empty;

fn isBuiltinNativeMenuId(id: []const u8) bool {
    return menu_model.submenuFor(id) != null;
}

fn resolveBuiltinNativeMenu(id: []const u8) ?objc.Object {
    for (menu_model.menu_bar, 0..) |sub, i| {
        if (menu_model.menuMatches(sub, id)) return native_submenus[i];
    }
    return null;
}

/// Rebuild every plugin-contributed native menu item from the current `fizzy.editor().app.host`
/// registry state. Tears down the previous dynamic set first, so this is safe (and cheap
/// enough) to call on every plugin load/unload/hide-toggle — a full rebuild avoids diffing
/// against arbitrary prior state, at the cost of some churn AppKit already expects from
/// `NSMenu` mutation.
pub fn rebuildDynamicNativeMenus() void {
    if (builtin.os.tag != .macos) return;
    if (!macos_menu_bar_set_up) return;
    const main_menu = native_main_menu orelse return;
    const target = native_menu_target orelse return;

    // Teardown: remove everything the previous rebuild added.
    for (dynamic_leaf_items.items) |entry| {
        entry.parent_menu.msgSend(void, "removeItem:", .{entry.item.value});
    }
    dynamic_leaf_items.clearRetainingCapacity();
    for (dynamic_top_level_menus.items) |entry| {
        main_menu.msgSend(void, "removeItem:", .{entry.item.value});
    }
    dynamic_top_level_menus.clearRetainingCapacity();

    const host = &fizzy.editor().app.host;

    const NSMenu = objc.getClass("NSMenu") orelse return;
    const NSMenuItem = objc.getClass("NSMenuItem") orelse return;
    const NSString = objc.getClass("NSString") orelse return;
    const NSImage = objc.getClass("NSImage") orelse return;
    const empty = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"".ptr});
    const generic_sel = fizzy_get_selector("genericMenuAction:") orelse return;

    // Pass 1: create a native top-level menu for every visible, titled, plugin-owned
    // `MenuContribution` that has at least one visible `NativeMenuItem` targeting it.
    // Menus with no native leaf items (in-app-bar-only, or untitled) are skipped.
    var created: std.StringHashMapUnmanaged(objc.Object) = .empty;
    defer created.deinit(alloc());

    for (host.menus.items) |mc| {
        if (mc.hidden or mc.title.len == 0) continue;
        if (isBuiltinNativeMenuId(mc.id)) continue;
        const has_items = blk: {
            for (host.native_menu_items.items) |ni| {
                if (!ni.hidden and std.mem.eql(u8, ni.parent_menu_id, mc.id)) break :blk true;
            }
            break :blk false;
        };
        if (!has_items) continue;

        const title_z = alloc().dupeZ(u8, mc.title) catch continue;
        defer alloc().free(title_z);
        const title_str = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{title_z.ptr});

        const menu = NSMenu.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "initWithTitle:", .{title_str.value});
        if (menu.value == 0) continue;
        const item = NSMenuItem.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "initWithTitle:action:keyEquivalent:", .{
            title_str.value,
            @as(usize, 0),
            empty.value,
        });
        if (item.value == 0) continue;
        item.msgSend(void, "setSubmenu:", .{menu.value});

        // Insert right before Help so ordering stays (…, View, <plugin menus…>, Help).
        if (native_help_item) |help_item| {
            const idx = main_menu.msgSend(c_long, "indexOfItem:", .{help_item.value});
            if (idx >= 0) {
                main_menu.msgSend(void, "insertItem:atIndex:", .{ item.value, @as(c_ulong, @intCast(idx)) });
            } else {
                main_menu.msgSend(void, "addItem:", .{item.value});
            }
        } else {
            main_menu.msgSend(void, "addItem:", .{item.value});
        }

        dynamic_top_level_menus.append(alloc(), .{ .item = item, .menu = menu }) catch {};
        created.put(alloc(), mc.id, menu) catch {};
    }

    // Pass 2: append every visible `NativeMenuItem` into its resolved parent menu (either a
    // built-in one, or one just created above). Items whose parent can't be resolved (e.g.
    // targeting an untitled/hidden `MenuContribution`) are skipped.
    for (host.native_menu_items.items, 0..) |ni, idx| {
        if (ni.hidden) continue;
        const parent_menu: objc.Object = resolveBuiltinNativeMenu(ni.parent_menu_id) orelse
            (created.get(ni.parent_menu_id) orelse continue);

        const title_z = alloc().dupeZ(u8, ni.title) catch continue;
        defer alloc().free(title_z);
        const title_str = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{title_z.ptr});

        const item = parent_menu.msgSend(objc.Object, "addItemWithTitle:action:keyEquivalent:", .{
            title_str.value,
            @intFromPtr(generic_sel),
            empty.value,
        });
        if (item.value == 0) continue;
        item.msgSend(void, "setTarget:", .{target.value});
        // Tag with the item's index in `host.native_menu_items`, resolved back on click
        // in `Editor.zig`'s `flushQueuedNativeMenuItems`.
        item.msgSend(void, "setTag:", .{@as(c_long, @intCast(idx))});
        if (ni.sf_symbol) |sym| {
            if (alloc().dupeZ(u8, sym)) |sym_z| {
                defer alloc().free(sym_z);
                setMenuItemImage(item, NSImage, NSString, sym_z.ptr, title_z.ptr);
            } else |_| {}
        }

        dynamic_leaf_items.append(alloc(), .{
            .parent_menu = parent_menu,
            .item = item,
            .index = idx,
        }) catch {};
    }

    // The items above are built with no key equivalent; their chords come from the keymap, and
    // this is what puts them there. Both callers of this function (startup, and every plugin
    // load/unload/hide-toggle) reach it *after* the keymap is rebuilt, so nothing else would —
    // the fixed bar hits the same ordering hazard, which is why `setupMacOSMenuBar` ends with
    // the same call.
    fizzy.Editor.Keybinds.syncNativeMenuShortcuts(fizzy.editor());
}

/// Inserts a "File" menu into the macOS app menu bar (between Apple and Window). Safe to call multiple times; runs once.
pub fn setupMacOSMenuBar() void {
    if (builtin.os.tag != .macos) return;
    if (macos_menu_bar_set_up) return;
    const NSApplication = objc.getClass("NSApplication") orelse return;
    const ns_app = NSApplication.msgSend(objc.Object, "sharedApplication", .{});
    if (ns_app.value == 0) return;
    const main_menu = ns_app.msgSend(objc.Object, "mainMenu", .{});
    if (main_menu.value == 0) return;
    native_main_menu = main_menu;

    const NSString = objc.getClass("NSString") orelse return;
    const NSMenu = objc.getClass("NSMenu") orelse return;
    const NSMenuItem = objc.getClass("NSMenuItem") orelse return;
    const FizzyMenuTargetClass = objc.getClass("FizzyMenuTarget") orelse return;
    const target = FizzyMenuTargetClass.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "init", .{});
    if (target.value == 0) return;
    native_menu_target = target;

    const empty = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"".ptr});
    const NSImage = objc.getClass("NSImage") orelse return;
    const action_sel = fizzy_get_selector("menuAction:") orelse return;

    // Build every top-level menu from `menu_model`, the same tree `Menu.zig` draws. Each item's
    // tag is its depth-first index among command items, which is all the C boundary needs: one
    // integer that resolves back to a command id. The fourteen hand-written Objective-C
    // forwarding methods and the `NativeMenuAction` enum they switched on existed only to carry
    // that integer, and are gone.
    var tag: c_long = 0;
    inline for (&menu_model.menu_bar, 0..) |*sub, sub_index| {
        const sub_title = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{sub.title.ptr});
        const menu = NSMenu.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "initWithTitle:", .{sub_title.value});
        if (menu.value != 0) {
            native_submenus[sub_index] = menu;

            inline for (sub.items) |item| {
                switch (item) {
                    .separator => menu.msgSend(void, "addItem:", .{NSMenuItem.msgSend(objc.Object, "separatorItem", .{}).value}),

                    .command => |c| {
                        const item_title = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{c.title.resolveStatic().ptr});
                        const mi = menu.msgSend(objc.Object, "addItemWithTitle:action:keyEquivalent:", .{
                            item_title.value,
                            @intFromPtr(action_sel),
                            empty.value,
                        });
                        if (mi.value != 0) {
                            mi.msgSend(void, "setTarget:", .{target.value});
                            mi.msgSend(void, "setTag:", .{tag});
                            if (c.sf_symbol) |sym| setMenuItemImage(mi, NSImage, NSString, sym, c.title.resolveStatic());
                            native_menu_items[@intCast(tag)] = mi;
                        }
                        tag += 1;
                    },

                    // Populated later: recents aren't loaded when the bar is built, and plugin
                    // sections arrive as plugins register. Both get a placeholder submenu here
                    // so their position in the menu is fixed by the model rather than by
                    // whatever order the rebuilds happen to run in.
                    .recent_folders => {
                        const rf_title = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"Recent Folders".ptr});
                        const rf_item = menu.msgSend(objc.Object, "addItemWithTitle:action:keyEquivalent:", .{
                            rf_title.value,
                            @as(usize, 0),
                            empty.value,
                        });
                        if (rf_item.value != 0) {
                            const rf_menu = NSMenu.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "initWithTitle:", .{rf_title.value});
                            if (rf_menu.value != 0) {
                                rf_item.msgSend(void, "setSubmenu:", .{rf_menu.value});
                                native_recent_folders_menu = rf_menu;
                                native_recent_folders_item = rf_item;
                            }
                        }
                    },

                    // Natively an open action is the plugin's own `NativeMenuItem`, appended
                    // to File with the rest of its native items; the fixed slot is the in-app
                    // bar's.
                    .open_actions, .plugin_section, .submenu => {},
                }
            }

            const bar_item = NSMenuItem.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "initWithTitle:action:keyEquivalent:", .{
                sub_title.value,
                @as(usize, 0),
                empty.value,
            });
            if (bar_item.value != 0) {
                bar_item.msgSend(void, "setSubmenu:", .{menu.value});
                if (comptime std.mem.eql(u8, sub.id, "fizzy.menu.help")) {
                    // Help goes last so the conventional order (App, File, Edit, View, …,
                    // Window, Help) survives, and AppKit wires in its search field.
                    main_menu.msgSend(void, "addItem:", .{bar_item.value});
                    ns_app.msgSend(void, "setHelpMenu:", .{menu.value});
                    native_help_item = bar_item;
                } else {
                    main_menu.msgSend(void, "insertItem:atIndex:", .{ bar_item.value, @as(c_ulong, sub_index + 1) });
                }
            }
        }
    }

    // App-menu cleanup:
    //   1. Retitle and re-target the auto-generated "About …" item from SDL's default about-panel to AboutFizzy.
    //   (The Hide / Quit titles are already this app's: its metadata is set before SDL builds the menu,
    //   from the start options — `Entry.startOptions`.)
    //   2. We do NOT add a Window submenu here — SDL/AppKit already inserts a top-level Window menu, and nesting one
    //      inside the app menu produced a visible duplicate.
    const app_menu_item = main_menu.msgSend(objc.Object, "itemAtIndex:", .{@as(c_ulong, 0)});
    const app_submenu = app_menu_item.msgSend(objc.Object, "submenu", .{});
    if (app_submenu.value != 0) {
        if (fizzy_get_selector("about:")) |about_sel| {
            const about_item = app_submenu.msgSend(objc.Object, "itemAtIndex:", .{@as(c_ulong, 0)});
            if (about_item.value != 0) {
                const about_title = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{AppInfo.about_title_z.ptr});
                about_item.msgSend(void, "setTitle:", .{about_title.value});
                about_item.msgSend(void, "setAction:", .{about_sel});
                about_item.msgSend(void, "setTarget:", .{target.value});
            }
        }

    }

    macos_menu_bar_set_up = true;

    // Add any plugin-contributed native menus/items already registered by this point
    // (built-in static plugins register in `postInit`, which runs before this function).
    rebuildDynamicNativeMenus();
    rebuildNativeRecentFolders();

    // Items are built with no key equivalent; the chords come from the keymap. `buildKeymap`
    // also stamps them, but the two run in either order depending on startup path — this ran
    // first at boot, so every File/Edit shortcut was stamped onto items that did not exist yet
    // and never restamped. The menus showed no chords, and because `nativeMenuOwnsChord` still
    // told `dispatch` the native menu owned them, nothing handled those keys at all.
    fizzy.Editor.Keybinds.syncNativeMenuShortcuts(fizzy.editor());
}

/// Fill the Recent Folders submenu from the current recents list.
///
/// AppKit menus are retained state, so unlike the dvui menu — which just re-reads the list every
/// frame — this has to be rebuilt whenever the list changes. Recent Folders had no macOS
/// representation at all before the model; it existed only in the dvui bar.
pub fn rebuildNativeRecentFolders() void {
    if (comptime builtin.os.tag != .macos) return;
    const menu = native_recent_folders_menu orelse return;
    const target = native_menu_target orelse return;
    const NSString = objc.getClass("NSString") orelse return;
    const sel = fizzy_get_selector("recentFolderAction:") orelse return;

    menu.msgSend(void, "removeAllItems", .{});

    const empty = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"".ptr});
    const folders = fizzy.editor().app.recents.folders.items;

    // Newest first, matching the dvui menu's reverse walk.
    var i: usize = folders.len;
    while (i > 0) : (i -= 1) {
        const folder = folders[i - 1];
        // `stringWithUTF8String:` needs a sentinel; recents are plain slices.
        var buf: [1024]u8 = undefined;
        if (folder.len >= buf.len) continue;
        @memcpy(buf[0..folder.len], folder);
        buf[folder.len] = 0;

        const title = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{@as([*:0]const u8, @ptrCast(&buf))});
        const item = menu.msgSend(objc.Object, "addItemWithTitle:action:keyEquivalent:", .{
            title.value,
            @intFromPtr(sel),
            empty.value,
        });
        if (item.value != 0) {
            item.msgSend(void, "setTarget:", .{target.value});
            item.msgSend(void, "setTag:", .{@as(c_long, @intCast(i - 1))});
        }
    }

    if (native_recent_folders_item) |it| {
        it.msgSend(void, "setHidden:", .{folders.len == 0});
    }
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
    if (id < 0 or id >= menu_model.flat_commands.len) return null;
    return .{ .index = @intCast(id), .from_key = pending_native_menu_action_from_key.load(.acquire) };
}

/// Returns and clears a pending generic native menu item tag (plugin `NativeMenuItem`s).
/// Call once per frame; on non-macOS always returns null.
pub fn pollPendingGenericNativeMenuAction() ?usize {
    const tag = pending_generic_native_menu_action_tag.swap(-1, .acq_rel);
    if (tag < 0) return null;
    return @intCast(tag);
}

