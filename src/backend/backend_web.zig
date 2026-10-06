//! Wasm-target stubs for `backend.zig`'s public surface. Mirrors the native API so
//! `fizzy.backend.X` keeps type-checking on web — call sites that would do something
//! native-only (window decorations, native menus, OS file dialogs) compile to no-ops
//! or browser equivalents (file picker + download).

const std = @import("std");
const dvui = @import("dvui");
const builtin = @import("builtin");
const core = @import("core");
const layout_file = @import("layout_file.zig");
const fizzy = @import("../fizzy.zig");

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

pub const custom_titlebar = false;
pub const titlebar_hit_tested = false;
pub const TitleBarButton = enum { minimize, maximize, close };

/// The web backend allocates nothing on the app's behalf — no native dialogs, no native menu.
/// Accepted and ignored so the startup path is the same on every target.
pub fn setAllocator(_: std.mem.Allocator) void {}

pub const DialogMode = enum { save, open };

pub const DialogDirs = struct {
    ctx: *anyopaque,
    initial: *const fn (ctx: *anyopaque, mode: DialogMode) ?[]const u8,
    remember: *const fn (ctx: *anyopaque, mode: DialogMode, dir: []const u8) void,
};

/// The browser's file picker starts wherever the browser decides; there is no directory to
/// suggest and none to remember. Accepted and ignored so the startup path is the same on every
/// target.
pub fn setDialogDirs(_: DialogDirs) void {}

pub fn resetTitleBarHints() void {}

pub fn setTitleBarStrip(_: f32, _: i32) void {}

pub fn pushTitleBarInteractiveRect(_: dvui.Rect.Physical) void {}

pub fn setTitleBarCaptionButtonRect(_: TitleBarButton, _: dvui.Rect.Physical) void {}

pub fn performTitleBarButton(_: *dvui.Window, _: TitleBarButton) void {}

pub fn frameInsets(_: *dvui.Window) dvui.Rect {
    return .{};
}

pub fn getHoveredTitleBarButton() ?TitleBarButton {
    return null;
}

pub fn isMaximized(_: *dvui.Window) bool {
    return true;
}

pub fn coversDesktop(_: *dvui.Window) bool {
    return true;
}

pub fn enteringSpace(_: *dvui.Window) bool {
    return false;
}

pub fn setWindowStyle(_: *dvui.Window) void {}

/// Symmetric with the native API: a browser tab cannot take focus for itself, and the OAuth
/// popup already returns to the page that opened it.
pub fn raiseWindow() void {}

/// The page's `keydown` check (`web/index.html`): it writes `KeyboardEvent.key` here, then asks
/// `FizzyWebKeyBound` whether the app binds it — see `Keybinds.webKeyBound`.
export fn FizzyWebKeyBuffer() [*]u8 {
    return &fizzy.Editor.Keybinds.web_key_buf;
}

export fn FizzyWebKeyBound(key_len: usize, mods: u32) bool {
    return fizzy.Editor.Keybinds.webKeyBound(key_len, mods);
}

/// The page's own functions. Only a wasm build has a page; the integration tests compile this
/// backend natively.
const page = if (builtin.target.cpu.arch == .wasm32) struct {
    extern "fizzy" fn fizzy_web_toggle_fullscreen() void;
} else struct {
    fn fizzy_web_toggle_fullscreen() void {}
};

/// The page's Fullscreen API (`web/index.html`), which also takes the keyboard lock so the
/// shortcuts a browser keeps for itself (⌘W, ⌘T, Ctrl+Tab) reach the app while full screen.
/// Runs a frame after the key press or click that asked for it, which is inside the browser's
/// user-activation window.
pub fn toggleFullscreen() void {
    page.fizzy_web_toggle_fullscreen();
}

/// Symmetric with the native API: no window state to restore on web.
pub fn restoreWindowState(_: *dvui.Window) void {}

/// Symmetric with the native API: the web canvas is always visible.
pub fn showWindow(_: *dvui.Window) void {}

/// Symmetric with the native API: no window geometry to persist on web.
pub fn saveWindowGeometry(_: *dvui.Window) void {}

/// `layout.zon` lives in `localStorage` on the web, through `core.fs` — the same file code as
/// the desktop (`layout_file.zig`).
pub const SavedRegion = layout_file.SavedRegion;
pub const SavedShows = layout_file.SavedShows;
pub const saveRegions = layout_file.saveRegions;
pub const loadRegions = layout_file.loadRegions;
pub const freeRegions = layout_file.freeRegions;
pub const saveTree = layout_file.saveTree;
pub const loadTree = layout_file.loadTree;

/// Symmetric with the native API: no AppKit pump on web.
pub fn macosLaunchComplete() void {}

/// Symmetric with the native API: a page has one canvas, so a float never leaves it.
pub const viewports = struct {
    pub const supported = false;
    pub fn available() bool {
        return false;
    }
    pub const Viewport = struct {};
    pub const Rect = struct { x: f32 = 0, y: f32 = 0, w: f32 = 0, h: f32 = 0 };

    pub fn open(_: Rect, _: [:0]const u8) ?*Viewport {
        return null;
    }
    pub fn close(_: *Viewport) void {}
    pub fn frameOf(_: *const Viewport) Rect {
        return .{};
    }
    pub fn place(_: *Viewport, frame: Rect) Rect {
        return frame;
    }
    pub fn present(_: *Viewport, _: ?dvui.TextureTarget) void {}
    pub fn inMain(_: *const Viewport) Rect {
        return .{};
    }
    pub const os_frame = false;
    pub const os_buttons = false;
    pub const carries = false;
    pub fn seeThrough(_: *Viewport, _: bool) void {}
    pub fn fade(_: *Viewport, _: f32) void {}
    pub fn maximized(_: *const Viewport) bool {
        return false;
    }
    pub fn coversDesktop(_: *const Viewport) bool {
        return false;
    }
    pub fn enteringSpace(_: *const Viewport) bool {
        return false;
    }
    pub fn carryShape(_: *Viewport, _: ?f32, _: f32) void {}
    pub fn carryLens(_: *Viewport, _: bool) void {}
    pub fn windowGlass(_: *Viewport, _: WindowGlassLook) bool {
        return false;
    }
    pub fn buttonsWidth(_: *Viewport) f32 {
        return 0;
    }
    pub fn windowRadius() f32 {
        return 0;
    }
    pub fn openCarry(_: Rect) ?*Viewport {
        return null;
    }
    pub const menus = false;
    pub fn appActive() bool {
        return true;
    }
    pub fn openMenu(_: Rect, _: f32, _: bool) ?*Viewport {
        return null;
    }
    pub fn mainOffset(_: *Viewport, _: dvui.Point.Physical) void {}
    pub const GlassShape = extern struct { x: f64, y: f64, w: f64, h: f64, radius: f64, lit: f64, alpha: f64 };
    pub fn liquidGlass() bool {
        return false;
    }
    pub fn openOverlay(_: Rect) ?*Viewport {
        return null;
    }
    pub const GlassMaterial = struct { variant: i32, style: i32 };
    pub const GlassLook = struct {
        under: GlassMaterial,
        over: GlassMaterial,
        over_share: f32,
        glass: f32 = 1,
        fill: dvui.Color = .black,
        fill_opacity: f32 = 0,
        lit_toward: dvui.Color = .white,
        lit_amount: f32 = 0,
        bevel: f32 = 0,
        bevel_cap: f32 = 0,
        bevel_clear: f32 = 0,
    };
    pub fn overlayGlass(_: *Viewport, _: []const GlassShape, _: f32, _: GlassLook) void {}
    pub fn displayInMain() Rect {
        return .{};
    }
    pub const Hints = struct { drag: Rect, keep: Rect, glass: Rect, edge: f32, app_side: f32 = 0, app_corner: f32 = 0 };
    pub fn hints(_: *Viewport, _: ?Hints) void {}
    pub fn osPlaced(_: *Viewport) ?Rect {
        return null;
    }
    pub const MoveEnd = struct { resized: bool };
    pub fn osMoveEnded(_: *Viewport) ?MoveEnd {
        return null;
    }
    pub fn dragMove(_: *Viewport) bool {
        return false;
    }
    pub fn minSize(_: *Viewport, _: f32, _: f32) void {}
    pub fn setTitle(_: *Viewport, _: []const u8) void {}
    pub fn glass(_: *Viewport, _: f32, _: f32, _: bool) bool {
        return false;
    }
    pub fn placeMain(_: *Viewport, frame: Rect) Rect {
        return frame;
    }
    pub fn bandFromMain(_: *const Viewport, frame: Rect) Rect {
        return frame;
    }
    pub fn shown(_: *const Viewport) bool {
        return false;
    }
    pub const Pin = union(enum) { none, main, viewport: *Viewport };
    pub fn pinPointer(_: Pin) void {}
    pub fn closeRequested(_: *const Viewport) bool {
        return false;
    }
};

pub const WindowGlassLook = struct {
    under_variant: i32,
    under_style: i32,
    over_variant: i32,
    over_style: i32,
    frost: f32,
    blur: f32,
    glass: f32,
    fill: dvui.Color,
    fill_opacity: f32,
    top_fill: f32,
    radius: f32,
    clear: f32,
    feather: f32,
};
pub fn windowGlass(_: *dvui.Window, _: WindowGlassLook) bool {
    return false;
}

pub fn titlebarStripHeight(_: *dvui.Window) f32 {
    return 0;
}

pub fn setTitlebarColor(_: *dvui.Window, _: dvui.Color) void {}

pub fn setSdlAppMetadata(_: [*:0]const u8, _: [*:0]const u8, _: [*:0]const u8) void {}

pub fn setupMacOSMenuBar() void {}

// Browser trackpad pinch arrives as a `wheel` event with `ctrlKey=true` (synthesized by every
// modern browser). The bootstrap JS in `web/index.html` intercepts those events in the
// capture phase, prevents the browser's default page-zoom, and forwards the magnification
// delta into the wasm export below. Same accumulator pattern as the macOS native trackpad
// monitor — the canvas widget drains via `takeTrackpadPinchRatio` once per frame.
var pending_pinch_ratio: f32 = 1.0;

/// Called from `web/index.html` via `app.instance.exports.FizzyWebTrackpadMagnification`
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

/// Mirrors the native signature: a tag into `menu_model.flat_commands`. No native menu bar
/// on web, so nothing is ever pending.
pub const NativeMenuAction = struct { index: usize, from_key: bool };
pub fn pollPendingNativeMenuAction() ?NativeMenuAction {
    return null;
}

pub fn pollPendingGenericNativeMenuAction() ?usize {
    return null;
}

/// No app menu on web, so there is never a pending About click.
pub fn pollPendingAbout() bool {
    return false;
}

/// No native Recent Folders submenu on web — the dvui menu handles the list directly.
pub fn pollPendingRecentFolder() ?usize {
    return null;
}

/// Chords live entirely in the keymap on web; there are no native menu items to stamp.
pub fn setNativeMenuShortcut(_: usize, _: ?[]const u8, _: c_ulong) void {}

pub fn setDynamicNativeMenuShortcut(_: usize, _: ?[]const u8, _: c_ulong) void {}

pub const modifier_command: c_ulong = 0;
pub const modifier_shift: c_ulong = 0;
pub const modifier_option: c_ulong = 0;
pub const modifier_control: c_ulong = 0;

/// Web's dialog callbacks run synchronously within the frame already (`WebSaveAs.callAfter`), so
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

/// The dvui menu re-reads the recents list every frame, so there is no retained
/// native submenu to rebuild here (see `backend_native.rebuildNativeRecentFolders`).
pub fn rebuildNativeRecentFolders() void {}

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
