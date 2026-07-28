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
const Constants = @import("../editor/Constants.zig");
const KeybindSettings = @import("../editor/KeybindSettings.zig");
const menu_model = @import("../editor/menu_model.zig");

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
    // (window.zon) and disabled in dvui, so there is nothing to toggle here.
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

// Frame-based geometry persistence, plus (cross-platform) the explorer/panel split ratios —
// both are "window shape" state, persisted separately from `settings.zon` so dragging a splitter
// doesn't touch the user's actual settings file (see docs comment on `Constants.zig`). fizzy's
// window is a frame == content window (full-size content view), which dvui's content-based
// `WindowGeometry` can't represent — so fizzy persists the actual NSWindow.frame (AppKit
// bottom-left points) itself, macOS-only. dvui's own persistence is disabled
// (persist_window_geometry = false in App.startOptions). Stored next to where dvui would write,
// in the configured pref_path.
//
// Two independent writers touch this same file — the macOS-only geometry save (at shutdown) and
// the cross-platform ratio save (debounced, on every platform) — so both read-modify-write
// (`loadWindowFile` then override only their own fields) rather than overwriting the whole file,
// so neither ever clobbers what the other most recently wrote.
const SavedFrame = struct {
    x: f64 = 0,
    y: f64 = 0,
    w: f64 = 0,
    h: f64 = 0,
    explorer_ratio: f32 = 0.35,
    panel_ratio: f32 = 0.25,
};
const window_file = "window.zon";

fn windowFilePath(buf: []u8, dir: []const u8) ?[:0]const u8 {
    const sep = std.fs.path.sep_str;
    if (std.mem.endsWith(u8, dir, sep)) {
        return std.fmt.bufPrintZ(buf, "{s}{s}", .{ dir, window_file }) catch null;
    }
    return std.fmt.bufPrintZ(buf, "{s}{s}{s}", .{ dir, sep, window_file }) catch null;
}

/// Reads every field of `window.zon`, falling back to `SavedFrame`'s own defaults for whatever
/// is missing or unparseable (never null — simplifies every caller, which only cares about the
/// subset of fields it owns).
fn loadWindowFile(dir: []const u8) SavedFrame {
    var path_buf: [1024]u8 = undefined;
    const path = windowFilePath(&path_buf, dir) orelse return .{};
    const data = std.Io.Dir.cwd().readFileAlloc(dvui.io, path, std.heap.page_allocator, .limited(1024)) catch return .{};
    defer std.heap.page_allocator.free(data);
    var nul_buf: [1025]u8 = undefined;
    if (data.len >= nul_buf.len) return .{};
    @memcpy(nul_buf[0..data.len], data);
    nul_buf[data.len] = 0;
    return std.zon.parse.fromSlice(
        SavedFrame,
        std.heap.page_allocator,
        nul_buf[0..data.len :0],
        null,
        .{ .ignore_unknown_fields = true },
    ) catch .{};
}

fn writeWindowFile(dir: []const u8, f: SavedFrame) void {
    var path_buf: [1024]u8 = undefined;
    const path = windowFilePath(&path_buf, dir) orelse return;
    var aw = std.Io.Writer.Allocating.init(std.heap.page_allocator);
    defer aw.deinit();
    std.zon.stringify.serialize(f, .{}, &aw.writer) catch return;
    std.Io.Dir.createDirAbsolute(dvui.io, dir, .default_dir) catch {};
    std.Io.Dir.cwd().writeFile(dvui.io, .{ .sub_path = path, .data = aw.written() }) catch {
        std.log.err("failed to write window.zon", .{});
    };
}

/// The saved NSWindow frame, or null if there's none yet / it's degenerate (w/h < 1) — same
/// contract `loadSavedFrame` had before the rename. macOS-only caller (`restoreWindowState`).
fn loadSavedFrame(dir: []const u8) ?SavedFrame {
    const f = loadWindowFile(dir);
    if (f.w < 1 or f.h < 1) return null;
    return f;
}

/// Read-modify-write: preserves whatever ratios are already on disk, overrides only the frame
/// geometry. macOS-only caller (`saveWindowGeometry`).
fn writeSavedFrame(dir: []const u8, x: f64, y: f64, w: f64, h: f64) void {
    var f = loadWindowFile(dir);
    f.x = x;
    f.y = y;
    f.w = w;
    f.h = h;
    writeWindowFile(dir, f);
}

/// Read-modify-write: preserves whatever frame geometry is already on disk, overrides only the
/// explorer/panel split ratios. Cross-platform (called from `Editor`'s debounced autosave on
/// every OS, not just macOS).
pub fn saveWindowRatios(dir: []const u8, explorer_ratio: f32, panel_ratio: f32) void {
    var f = loadWindowFile(dir);
    f.explorer_ratio = explorer_ratio;
    f.panel_ratio = panel_ratio;
    writeWindowFile(dir, f);
}

/// Explorer/panel split ratios from `window.zon`, or `SavedFrame`'s own defaults if the file
/// doesn't exist yet (fresh install). Cross-platform; call once at startup.
pub fn loadWindowRatios(dir: []const u8) struct { explorer_ratio: f32, panel_ratio: f32 } {
    const f = loadWindowFile(dir);
    return .{ .explorer_ratio = f.explorer_ratio, .panel_ratio = f.panel_ratio };
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
    if (comptime builtin.os.tag != .macos) return;
    const back = win.backend.impl;
    const dir = (back.init_opts_save orelse return).pref_path orelse return;
    const cocoa = cocoaWindowOf(back.window) orelse return;
    var out4: [4]f64 = .{0} ** 4;
    fizzy_macos_window_current_windowed_frame(cocoa, &out4);
    if (out4[2] < 1 or out4[3] < 1) return;
    writeSavedFrame(dir, out4[0], out4[1], out4[2], out4[3]);
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

/// Called from FizzyMenuTarget.m when user picks a native menu item. Runs on main thread.
export fn FizzyNativeMenuAction(id: c_int) void {
    pending_native_menu_action_id.store(id, .release);
}

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
        if (!f(fizzy.editor)) return false;
    }
    const enabled = item.enabled orelse return true;
    return enabled(fizzy.editor);
}

/// Current label for a model item, so state-dependent titles ("Show Explorer" / "Hide
/// Explorer") track the app. AppKit menus are retained state; validation runs just before a
/// menu displays, which is when this is called. The macOS View menu used to say "Show
/// Explorer" permanently, because its title was baked in at construction.
export fn FizzyNativeMenuItemTitle(tag: c_int) callconv(.c) ?[*:0]const u8 {
    if (tag < 0) return null;
    const item = menu_model.byTag(@intCast(tag)) orelse return null;
    return switch (item.title) {
        .static => null, // already correct; nothing to rewrite
        .dynamic => |f| f(fizzy.editor).ptr,
    };
}

/// The app menu's "About fizzy", which AppKit creates rather than the model.
export fn FizzyNativeMenuAboutAction() callconv(.c) void {
    pending_native_menu_about.store(true, .release);
}
var pending_native_menu_about: std.atomic.Value(bool) = .init(false);

/// A Recent Folders click. The index is into `editor.recents.folders`, newest last.
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

/// Rebuild every plugin-contributed native menu item from the current `fizzy.editor.host`
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

    const host = &fizzy.editor.host;

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
    defer created.deinit(fizzy.app.allocator);

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

        const title_z = fizzy.app.allocator.dupeZ(u8, mc.title) catch continue;
        defer fizzy.app.allocator.free(title_z);
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

        dynamic_top_level_menus.append(fizzy.app.allocator, .{ .item = item, .menu = menu }) catch {};
        created.put(fizzy.app.allocator, mc.id, menu) catch {};
    }

    // Pass 2: append every visible `NativeMenuItem` into its resolved parent menu (either a
    // built-in one, or one just created above). Items whose parent can't be resolved (e.g.
    // targeting an untitled/hidden `MenuContribution`) are skipped.
    for (host.native_menu_items.items, 0..) |ni, idx| {
        if (ni.hidden) continue;
        const parent_menu: objc.Object = resolveBuiltinNativeMenu(ni.parent_menu_id) orelse
            (created.get(ni.parent_menu_id) orelse continue);

        const title_z = fizzy.app.allocator.dupeZ(u8, ni.title) catch continue;
        defer fizzy.app.allocator.free(title_z);
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
            if (fizzy.app.allocator.dupeZ(u8, sym)) |sym_z| {
                defer fizzy.app.allocator.free(sym_z);
                setMenuItemImage(item, NSImage, NSString, sym_z.ptr, title_z.ptr);
            } else |_| {}
        }

        dynamic_leaf_items.append(fizzy.app.allocator, .{
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
    fizzy.Editor.Keybinds.syncNativeMenuShortcuts(fizzy.editor);
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

                    .plugin_section, .submenu => {},
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
    fizzy.Editor.Keybinds.syncNativeMenuShortcuts(fizzy.editor);
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
    const folders = fizzy.editor.recents.folders.items;

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
pub fn pollPendingNativeMenuAction() ?usize {
    const id = pending_native_menu_action_id.swap(-1, .acq_rel);
    if (id < 0 or id >= menu_model.flat_commands.len) return null;
    return @intCast(id);
}

/// Returns and clears a pending generic native menu item tag (plugin `NativeMenuItem`s).
/// Call once per frame; on non-macOS always returns null.
pub fn pollPendingGenericNativeMenuAction() ?usize {
    const tag = pending_generic_native_menu_action_tag.swap(-1, .acq_rel);
    if (tag < 0) return null;
    return @intCast(tag);
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

// Native open/save dialogs on macOS complete asynchronously via the Cocoa run loop, which is
// pumped from `SDL_WaitEvent` between frames — i.e. outside `dvui.Window.begin`/`end`. Callers
// (plugin dialog callbacks) routinely touch dvui state that requires `dvui.currentWindow()`
// (e.g. stashing `dvui.currentWindow()` on a `FileLoadJob`), which panics if invoked directly
// from here. So we only capture the result here and hand it off; the actual callback runs from
// `pollPendingDialogResult`, called once per frame from inside the shell's frame tick.
const PendingDialogResult = struct {
    callback: *const fn (?[][:0]const u8) void,
    files: ?[][:0]const u8,
};
var pending_dialog_results: std.ArrayListUnmanaged(PendingDialogResult) = .empty;

/// Drain one queued dialog result per call. Call once per frame from inside
/// `Window.begin`/`end` (e.g. `Editor.tick`) so callbacks are free to touch dvui state.
pub fn pollPendingDialogResult() ?PendingDialogResult {
    if (pending_dialog_results.items.len == 0) return null;
    return pending_dialog_results.orderedRemove(0);
}

fn GenericDialogCallback(cb: ?*anyopaque, files: [*c]const [*c]const u8, mode: enum { save, open }) void {
    const callback: *const fn (?[][:0]const u8) void = @ptrCast(@alignCast(@constCast(cb)));

    // Try to count the number of files until we hit a null pointer.
    var path_count: usize = 0;
    while (files[path_count] != null) : (path_count += 1) {}

    if (path_count == 0) {
        pending_dialog_results.append(fizzy.app.allocator, .{ .callback = callback, .files = null }) catch {
            dvui.log.err("Failed to queue dialog result", .{});
        };
        return;
    }

    // Dupe every path (and the slice holding them) into memory that outlives this callback,
    // since the `files` pointers are only valid for the duration of this call.
    const zig_files: [][:0]const u8 = fizzy.app.allocator.alloc([:0]const u8, path_count) catch {
        dvui.log.err("Failed to allocate dialog result paths", .{});
        return;
    };
    var allocated: usize = 0;
    for (0..path_count) |i| {
        zig_files[i] = fizzy.app.allocator.dupeZ(u8, std.mem.span(files[i])) catch {
            dvui.log.err("Failed to dupe dialog result path", .{});
            for (zig_files[0..allocated]) |f| fizzy.app.allocator.free(f);
            fizzy.app.allocator.free(zig_files);
            return;
        };
        allocated += 1;
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

    pending_dialog_results.append(fizzy.app.allocator, .{ .callback = callback, .files = zig_files }) catch {
        dvui.log.err("Failed to queue dialog result", .{});
        for (zig_files) |f| fizzy.app.allocator.free(f);
        fizzy.app.allocator.free(zig_files);
    };
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
