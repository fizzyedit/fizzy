//! Wasm-target stubs for `backend.zig`'s public surface. Mirrors the native API so
//! `fizzy.backend.X` keeps type-checking on web — call sites that would do something
//! native-only (window decorations, native menus, OS file dialogs) compile to no-ops
//! or browser equivalents (file picker + download).

const std = @import("std");
const dvui = @import("dvui");
const builtin = @import("builtin");

const WebFileIo = if (builtin.target.cpu.arch == .wasm32)
    @import("../editor/WebFileIo.zig")
else
    struct {};

// Mirrors `sdl3.SDL_DialogFileFilter`'s layout. Native backend re-exports
// the SDL3 type as `DialogFileFilter`; the editor uses `fizzy.backend.DialogFileFilter`
// at call sites so both arches see one coherent type.
pub const DialogFileFilter = extern struct {
    name: [*:0]const u8,
    pattern: [*:0]const u8,
};
/// Back-compat alias: a few internal callers still use the SDL-style name.
pub const SDL_DialogFileFilter = DialogFileFilter;

pub const NativeMenuAction = enum(c_int) {
    open_folder = 0,
    open_files = 1,
    save = 2,
    copy = 3,
    paste = 4,
    undo = 5,
    redo = 6,
    toggle_explorer = 8,
    show_dvui_demo = 9,
    save_as = 10,
    new_file = 11,
    about = 13,
    check_for_updates = 14,
    report_bug = 15,
    save_all = 16,
};

pub const TitleBarButton = enum { minimize, maximize, close };

pub fn resetTitleBarHints() void {}

pub fn setTitleBarStrip(_: f32, _: i32) void {}

pub fn pushTitleBarInteractiveRect(_: dvui.Rect.Physical) void {}

pub fn setTitleBarCaptionButtonRect(_: TitleBarButton, _: dvui.Rect.Physical) void {}

pub fn getHoveredTitleBarButton() ?TitleBarButton {
    return null;
}

pub fn performWindowButton(_: *dvui.Window, _: TitleBarButton) void {}

pub fn isMaximized(_: *dvui.Window) bool {
    return true;
}

pub fn setWindowStyle(_: *dvui.Window) void {}

/// Symmetric with the native API: no window state to restore on web.
pub fn restoreWindowState(_: *dvui.Window) void {}

/// Symmetric with the native API: the web canvas is always visible.
pub fn showWindow(_: *dvui.Window) void {}

/// Symmetric with the native API: no window geometry to persist on web.
pub fn saveWindowGeometry(_: *dvui.Window) void {}

/// Symmetric with the native API: no AppKit pump on web.
pub fn macosLaunchComplete() void {}


pub fn titlebarStripHeight(_: *dvui.Window) f32 {
    return 0;
}

pub fn setTitlebarColor(_: *dvui.Window, _: dvui.Color) void {}

pub fn setSdlAppMetadata(_: [*:0]const u8, _: [*:0]const u8, _: [*:0]const u8) void {}

pub fn setupMacOSMenuBar() void {}

// Browser trackpad pinch arrives as a `wheel` event with `ctrlKey=true` (synthesized by every
// modern browser). The bootstrap JS in `web/shell.html` intercepts those events in the
// capture phase, prevents the browser's default page-zoom, and forwards the magnification
// delta into the wasm export below. Same accumulator pattern as the macOS native trackpad
// monitor — the canvas widget drains via `takeTrackpadPinchRatio` once per frame.
var pending_pinch_ratio: f32 = 1.0;

/// Called from `web/shell.html` via `app.instance.exports.FizzyWebTrackpadMagnification`
/// for every pinch wheel event. `delta` is a small relative magnification (positive = zoom in)
/// derived from `-ev.deltaY` scaled to match macOS NSEvent magnification magnitudes.
export fn FizzyWebTrackpadMagnification(delta: f32) void {
    if (delta == 0.0) return;
    pending_pinch_ratio *= (1.0 + delta);
}

/// Symmetric with the native API: nothing to install on web because the JS bootstrap wires
/// the wheel listener at page load.
pub fn installTrackpadGestureMonitor() void {}

/// Symmetric with the native API.
pub fn isFullscreenChromeHidden(win: *dvui.Window) bool {
    return isMaximized(win);
}

/// Drain and reset the accumulated trackpad pinch ratio. Matches the native API so the canvas
/// widget can call it unconditionally without per-platform branching.
pub fn takeTrackpadPinchRatio() f32 {
    const prev = pending_pinch_ratio;
    pending_pinch_ratio = 1.0;
    return prev;
}

pub fn pollPendingNativeMenuAction() ?NativeMenuAction {
    return null;
}

pub fn pollPendingGenericNativeMenuAction() ?usize {
    return null;
}

/// Web's dialog callbacks run synchronously from `WebFileIo` within the frame already, so
/// there's nothing to drain here. Kept symmetric with the native backend's deferred-dispatch
/// queue (see `backend_native.pollPendingDialogResult`) so `Editor.tick` can call it unconditionally.
pub const PendingDialogResult = struct {
    callback: *const fn (?[][:0]const u8) void,
    files: ?[][:0]const u8,
};
pub fn pollPendingDialogResult() ?PendingDialogResult {
    return null;
}

/// Symmetric with the native API: no native menu bar on web (the in-app dvui bar draws
/// `host.menus`/`host.menu_sections` directly, same as non-macOS native).
pub fn rebuildDynamicNativeMenus() void {}

pub fn showSimpleMessage(_: [:0]const u8, _: [:0]const u8) void {}

pub fn showSaveFileDialog(
    cb: *const fn (?[][:0]const u8) void,
    filters: []const DialogFileFilter,
    default_filename: []const u8,
    default_folder: ?[]const u8,
) void {
    if (comptime builtin.target.cpu.arch == .wasm32) {
        WebFileIo.showSaveFileDialog(cb, filters, default_filename, default_folder);
    }
}

pub fn showOpenFileDialog(
    cb: *const fn (?[][:0]const u8) void,
    filters: []const DialogFileFilter,
    default_filename: []const u8,
    default_folder: ?[]const u8,
) void {
    if (comptime builtin.target.cpu.arch == .wasm32) {
        WebFileIo.showOpenFileDialog(cb, filters, default_filename, default_folder);
    }
}

pub fn showOpenFolderDialog(
    _: *const fn (?[][:0]const u8) void,
    _: ?[]const u8,
) void {
    if (comptime builtin.target.cpu.arch == .wasm32) {
        const Dialogs = @import("../editor/dialogs/Dialogs.zig");
        Dialogs.WebFolderUnavailable.request();
    }
}

pub fn installFileOpenEventHandling(_: *dvui.Window) void {}

/// Called from `Editor.tick` on wasm to consume file-picker uploads.
pub fn pollWebFileIo(editor: *anyopaque) void {
    if (comptime builtin.target.cpu.arch == .wasm32) {
        WebFileIo.pollOpenPicker(@ptrCast(@alignCast(editor)));
    }
}
