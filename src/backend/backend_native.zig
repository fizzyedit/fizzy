//! Fizzy's own use of its window: the platform pieces any app gets (`src/backend/native/platform`
//! — dialogs, files from the OS, gestures, chrome, geometry, the window monitor, the menu bar) with
//! fizzy's policy over them — where dialogs start, where geometry is kept (`layout.zon`), how high
//! the titlebar strip is, what its menus hold and when their items are enabled. The web build has
//! the same surface in `backend_web.zig`.
const fizzy = @import("../fizzy.zig");

const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const layout_file = @import("layout_file.zig");
const sdl3 = @import("backend").c;
const singleton = @import("app").single_instance;
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

/// Whether fizzy draws its own title bar here (Windows, Linux): widgets in its strip register
/// as interactive so the strip's drag does not take their clicks.
pub const custom_titlebar = platform.titlebar.active;
/// Whether the OS asks fizzy's title-bar hints where a press goes (`custom_titlebar`, and macOS).
pub const titlebar_hit_tested = platform.titlebar.hit_tested;
pub const TitleBarButton = platform.titlebar.TitleBarButton;
pub const resetTitleBarHints = platform.titlebar.resetTitleBarHints;
pub const setTitleBarStrip = platform.titlebar.setTitleBarStrip;
pub fn pushTitleBarInteractiveRect(r: dvui.Rect.Physical) void {
    platform.titlebar.pushTitleBarInteractiveRect(.{ .x = r.x, .y = r.y, .w = r.w, .h = r.h });
}
pub fn setTitleBarCaptionButtonRect(button: TitleBarButton, r: dvui.Rect.Physical) void {
    platform.titlebar.setTitleBarCaptionButtonRect(button, .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h });
}
pub const getHoveredTitleBarButton = platform.titlebar.getHoveredTitleBarButton;
pub const performTitleBarButton = platform.window.performTitleBarButton;

/// Linux: before the window is made, the app draws its own decorations and a drop shadow in
/// `insets` round the frame (`platform.linux_titlebar.useClientDecorations`). A no-op elsewhere.
pub const useClientDecorations = platform.linux_titlebar.useClientDecorations;
pub const ClientDecorationInsets = platform.linux_titlebar.Insets;

/// The margin round the window's frame for its shadow, in effect now (natural units: x left,
/// y top, w right, h bottom); zero but on Linux while the window floats.
pub fn frameInsets(win: *dvui.Window) dvui.Rect {
    const in = platform.linux_titlebar.frameInsets(win.backend.impl.window);
    return .{ .x = in.left, .y = in.top, .w = in.right, .h = in.bottom };
}
const getWin32Hwnd = platform.win32_titlebar.getWin32Hwnd;

/// Files the OS asks fizzy to open while it runs go to the single-instance queue, which opens
/// them on the next frame (`platform.open_events`).
pub fn installFileOpenEventHandling(win: *dvui.Window) void {
    platform.open_events.install(win, singleton.queuePath);
}

// AppKit geometry types for NSView frame/bounds (same layout as Foundation).
pub const SavedRegion = layout_file.SavedRegion;
pub const SavedShows = layout_file.SavedShows;
pub const saveRegions = layout_file.saveRegions;
pub const loadRegions = layout_file.loadRegions;
pub const freeRegions = layout_file.freeRegions;
pub const saveTree = layout_file.saveTree;
pub const loadTree = layout_file.loadTree;
const loadWindowFile = layout_file.loadWindowFile;
const writeWindowFile = layout_file.writeWindowFile;

/// Reveal the window after chrome + geometry are settled (it is created hidden): maximized when it
/// was left that way (Windows).
pub fn showWindow(win: *dvui.Window) void {
    platform.window.show(win, platform.geometry.restoredMaximized());
}

/// Style the window (macOS: frame == content first), put it back where it was left
/// (`platform.geometry`, kept in fizzy's `layout.zon`), and follow it through Spaces, zooms and
/// live resizes (`platform.macos_monitor`). Called from `AppInit` while the window is still hidden:
/// the frame is restored on top of the chrome, so the chrome's own resizing cannot move it.
pub fn restoreWindowState(win: *dvui.Window) void {
    platform.window.attach(win);
    if (comptime builtin.os.tag == .macos) setWindowStyle(win);
    if (win.backend.impl.init_opts_save) |opts| if (opts.pref_path) |dir| {
        layout_store_dir = dir;
        platform.geometry.setStore(.{ .load = layoutStoreLoad, .save = layoutStoreSave });
    };
    platform.geometry.restore(win);
    platform.macos_monitor.install(win);
}

/// Keep where the window is for the next launch. Call at shutdown (AppDeinit).
pub fn saveWindowGeometry(win: *dvui.Window) void {
    platform.geometry.save(win);
}

/// Called at the end of AppInit: the monitor may drive frames through window animations now.
pub const macosLaunchComplete = platform.macos_monitor.launchComplete;

/// OS windows besides the main one, each showing a part of the one frame — a float popped out
/// (`docs/POPOUT_WINDOWS_PLAN.md`, the backend's `Viewport`). Fizzy's own backend only: on dvui's
/// SDL3 backend (`-Dnative-backend=sdl3`) there are none, as on the web, and floats stay in.
pub const viewports = struct {
    const Impl = @import("backend");
    pub const supported = @hasDecl(Impl, "viewportOpen");
    pub const Viewport = if (supported) Impl.Viewport else struct {};
    /// Physical pixels of the frame.
    pub const Rect = if (supported) Impl.viewport_map.Rect else struct { x: f32 = 0, y: f32 = 0, w: f32 = 0, h: f32 = 0 };

    /// Whether this run can open viewports: not on Wayland, where a window cannot be placed.
    pub fn available() bool {
        if (comptime !supported) return false;
        return Impl.viewportsAvailable();
    }

    /// A viewport over `at` (the frame as the main window shows it), its window opening over that
    /// place on the desktop, hidden until a frame is presented into it. Its own part of the frame
    /// is `frameOf`.
    pub fn open(at: Rect, title: [:0]const u8) ?*Viewport {
        if (comptime !supported) return null;
        return dvui.currentWindow().backend.impl.viewportOpen(at, title);
    }

    pub fn close(vp: *Viewport) void {
        if (comptime !supported) return;
        dvui.currentWindow().backend.impl.viewportClose(vp);
    }

    /// The part of the frame `vp` shows, physical pixels: in its band, past the main window.
    pub fn frameOf(vp: *const Viewport) Rect {
        if (comptime !supported) return .{};
        return vp.frame;
    }

    /// Put `vp`'s window where it shows `frame`; the part of the frame it then shows.
    pub fn place(vp: *Viewport, frame: Rect) Rect {
        if (comptime !supported) return frame;
        return dvui.currentWindow().backend.impl.viewportPlace(vp, frame);
    }

    /// Hand `vp` this frame's picture of its part of the frame, drawn into `target`, or nothing.
    pub fn present(vp: *Viewport, target: ?dvui.TextureTarget) void {
        if (comptime !supported) return;
        dvui.currentWindow().backend.impl.viewportPresent(vp, target);
    }

    /// Where `vp`'s window is now, in the main window's part of the frame (physical pixels from
    /// its top left): where its float goes when it comes back.
    pub fn inMain(vp: *const Viewport) Rect {
        if (comptime !supported) return .{};
        return dvui.currentWindow().backend.impl.viewportInMain(vp);
    }

    /// Put `vp`'s window where it shows `frame` of the main window's frame (past its edge, for a
    /// float split out under a drag); the part of the frame it then shows.
    pub fn placeMain(vp: *Viewport, frame: Rect) Rect {
        if (comptime !supported) return frame;
        return dvui.currentWindow().backend.impl.viewportPlaceMain(vp, frame);
    }

    /// `frame` of the main window's frame as the same desktop place in `vp`'s band.
    pub fn bandFromMain(vp: *const Viewport, frame: Rect) Rect {
        if (comptime !supported) return frame;
        return dvui.currentWindow().backend.impl.viewportBandFromMain(vp, frame);
    }

    /// Whether `vp`'s window has shown a frame yet.
    pub fn shown(vp: *const Viewport) bool {
        if (comptime !supported) return false;
        return dvui.currentWindow().backend.impl.viewportShown(vp);
    }

    /// Where a held pointer is read: by the window it is over, or pinned to the main window's
    /// frame or a viewport's band while a window is moved or resized.
    pub const Pin = if (supported) Impl.PointerPin else union(enum) { none, main, viewport: *Viewport };
    pub fn pinPointer(pin: Pin) void {
        if (comptime !supported) return;
        dvui.currentWindow().backend.impl.viewportPinPointer(pin);
    }

    /// Whether the OS frames a viewport's window itself — its corners and its shadow (Windows:
    /// DWM) — so the window is exactly the float's glass. Otherwise it is the glass with a clear
    /// margin round it, which the float draws its own shadow in.
    pub const os_frame = supported and builtin.os.tag == .windows;

    /// A material behind the float's glass in `vp`'s window — its rounded rect `inset` physical
    /// pixels in from the window's edge, `radius` its corners — for the float's frost to read the
    /// desktop through, in the app's light or dark (`dark`). False where the platform has none
    /// (yet).
    pub fn glass(vp: *Viewport, inset: f32, radius: f32, dark: bool) bool {
        if (comptime !supported) return false;
        return dvui.currentWindow().backend.impl.viewportGlass(vp, inset, radius, dark);
    }

    /// The main window leaves a hole in its picture under `vp`'s glass this frame
    /// (`core.FrameTarget.hole`), so the float's glass and the window's material over it show
    /// what is behind the main window there rather than its picture again. True where that may be
    /// done (macOS: the hole and the window change in one transaction) — only then may the main
    /// window cut it.
    pub fn mainHole(vp: *Viewport, on: bool) bool {
        if (comptime !supported) return false;
        return dvui.currentWindow().backend.impl.viewportMainHole(vp, on);
    }

    /// Whether a viewport's window comes up with its first picture, in one transaction with the
    /// main window's (macOS): its float can leave the main window's picture on that very frame.
    /// Elsewhere it stays in the main window's until its window has shown a frame.
    pub const shows_atomically = supported and builtin.os.tag == .macos;

    /// Whether the OS moves a viewport's window by its float's header (`hints`). Not on macOS,
    /// where the app does, as it resizes it there: AppKit's window drag runs in the window server
    /// and tells the app where the window went after it has gone, so what the glass showed of the
    /// main window behind it trailed the window, caught up, and trailed again.
    pub const os_moves = supported and builtin.os.tag != .macos;

    /// The OS asked to close `vp`'s window.
    pub fn closeRequested(vp: *const Viewport) bool {
        if (comptime !supported) return false;
        return vp.close_requested;
    }

    /// Where a press on `vp`'s window is the OS's, from its float this frame (physical pixels of
    /// the frame): `drag` its header, less `keep` (its close button), moves the window; `edge` in
    /// from `glass`'s sides resizes it. Null: all of it is the app's.
    /// `app_side` / `app_corner`: the float's own resize zones, the app's over its header where
    /// the OS resizes from no edge (macOS).
    pub const Hints = struct { drag: Rect, keep: Rect, glass: Rect, edge: f32, app_side: f32 = 0, app_corner: f32 = 0 };
    pub fn hints(vp: *Viewport, h: ?Hints) void {
        if (comptime !supported) return;
        dvui.currentWindow().backend.impl.viewportHints(vp, if (h) |x| .{ .drag = x.drag, .keep = x.keep, .glass = x.glass, .edge = x.edge, .app_side = x.app_side, .app_corner = x.app_corner } else null);
    }

    /// Where `vp`'s window shows in the frame now, when the OS has moved or resized it since the
    /// last ask — where its float goes.
    pub fn osPlaced(vp: *Viewport) ?Rect {
        if (comptime !supported) return null;
        return dvui.currentWindow().backend.impl.viewportOsPlaced(vp);
    }

    /// The press the OS took to move or resize `vp`'s window was let go; `resized` unless the
    /// window was only moved.
    pub const MoveEnd = struct { resized: bool };
    pub fn osMoveEnded(vp: *Viewport) ?MoveEnd {
        if (comptime !supported) return null;
        const e = dvui.currentWindow().backend.impl.viewportOsMoveEnded(vp) orelse return null;
        return .{ .resized = e.resized };
    }

    /// Hand the drag under way to the OS, which moves `vp`'s window from then on. False where it
    /// is not done: the app goes on moving it.
    pub fn dragMove(vp: *Viewport) bool {
        if (comptime !supported) return false;
        return dvui.currentWindow().backend.impl.viewportDragMove(vp);
    }

    /// What `vp`'s window is called: in the taskbar, the Window menu, the window switcher.
    pub fn setTitle(vp: *Viewport, text: []const u8) void {
        if (comptime !supported) return;
        dvui.currentWindow().backend.impl.viewportTitle(vp, text);
    }

    /// The least the OS may resize `vp`'s window to, physical pixels.
    pub fn minSize(vp: *Viewport, w: f32, h: f32) void {
        if (comptime !supported) return;
        dvui.currentWindow().backend.impl.viewportMinSize(vp, w, h);
    }
};

/// Fizzy keeps the window's geometry in `layout.zon`, beside its regions — one file for where the
/// window and everything in it were left, and the file it has always kept the frame in.
var layout_store_dir: []const u8 = "";

fn layoutStoreLoad(_: ?*anyopaque) ?platform.geometry.Geometry {
    const gpa = std.heap.page_allocator;
    const f = loadWindowFile(gpa, layout_store_dir);
    defer std.zon.parse.free(gpa, f);
    if (f.w < 1 or f.h < 1) return null;
    return .{ .x = f.x, .y = f.y, .w = f.w, .h = f.h, .state = if (f.maximized) .maximized else .normal };
}

fn layoutStoreSave(_: ?*anyopaque, g: platform.geometry.Geometry) void {
    // Read-modify-write: the regions and tree on disk stay as they are.
    const gpa = std.heap.page_allocator;
    var f = loadWindowFile(gpa, layout_store_dir);
    defer std.zon.parse.free(gpa, f);
    f.x = g.x;
    f.y = g.y;
    f.w = g.w;
    f.h = g.h;
    f.maximized = g.state == .maximized;
    writeWindowFile(layout_store_dir, f);
}

/// Height of the top strip that keeps editor content clear of the traffic lights: collapsed in a
/// fullscreen Space, back early as the window leaves one so the traffic lights never overlap a
/// pane mid-transition; a zoom without a Space keeps the full strip. Fizzy's titlebar heights
/// over the window's state (`platform.macos_monitor.titlebarState`).
pub fn titlebarStripHeight(win: *dvui.Window) f32 {
    if (builtin.os.tag != .macos) return Constants.titlebar_height;
    const t = platform.macos_monitor.titlebarState(win);
    return platform.window_layout.chooseTitlebarStrip(.{
        .collapsed = t.collapsed,
        .restoring_chrome = t.restoring_chrome,
        .live_inset = t.live_inset,
        .saved_inset = t.saved_inset,
        .titlebar_height = Constants.titlebar_height,
        .titlebar_top_buffer = Constants.titlebar_top_buffer,
    });
}

// ---- The native menu bar: fizzy's menus (`menu_model`) on the platform's (`platform.menu`) ----

pub const modifier_command = platform.menu.modifier_command;
pub const modifier_shift = platform.menu.modifier_shift;
pub const modifier_option = platform.menu.modifier_option;
pub const modifier_control = platform.menu.modifier_control;

/// A native menu item the user activated: its index among `menu_model`'s commands. `from_key`
/// means a ⌘-key equivalent, not a click: AppKit runs the menu action *and* passes the keystroke
/// on to SDL, so the key event is still on its way to whatever widget has focus — a command that
/// would otherwise synthesize one (paste into a text field) must not.
pub const NativeMenuAction = struct {
    index: usize,
    from_key: bool,
};

/// `menu_model.menu_bar` as the platform's menus: the same tree `Menu.zig` draws. Each command's
/// tag is its depth-first index among command items, which resolves back to a command id.
/// Recent Folders is a list the app fills as recents change; open actions and plugin sections
/// are the in-app bar's (natively a plugin's items come in as extras, `rebuildDynamicNativeMenus`).
const native_menus: []const platform.menu.Menu = blk: {
    @setEvalBranchQuota(20_000);
    var menus: [menu_model.menu_bar.len]platform.menu.Menu = undefined;
    var tag: u32 = 0;
    for (&menu_model.menu_bar, 0..) |*sub, i| {
        var entries: [sub.items.len]platform.menu.Entry = undefined;
        var n: usize = 0;
        for (sub.items) |item| switch (item) {
            .separator => {
                entries[n] = .separator;
                n += 1;
            },
            .command => |cmd| {
                entries[n] = .{ .command = .{ .title = cmd.title.resolveStatic(), .tag = tag, .symbol = cmd.sf_symbol } };
                n += 1;
                tag += 1;
            },
            .recent_folders => {
                entries[n] = .{ .list = .{ .title = "Recent Folders" } };
                n += 1;
            },
            .open_actions, .plugin_section, .submenu => {},
        };
        const done = entries[0..n].*;
        menus[i] = .{
            .id = sub.id,
            .aliases = sub.aliases,
            .title = sub.title,
            .entries = &done,
            .help = std.mem.eql(u8, sub.id, "fizzy.menu.help"),
        };
    }
    const done = menus;
    break :blk &done;
};

/// Build the macOS menu bar from `menu_model`. Once; safe to call again.
pub fn setupMacOSMenuBar() void {
    if (builtin.os.tag != .macos) return;
    platform.menu.install(native_menus, .{
        .enabled = menuEnabled,
        .title = menuTitle,
        .input_blocked = menuInputBlocked,
    }, AppInfo.about_title_z);
    // Plugin items already registered (built-in static plugins register in `postInit`, before
    // this), the recents, and the chords: the items are built with none, and the keymap may
    // have stamped them before they existed.
    rebuildDynamicNativeMenus();
    rebuildNativeRecentFolders();
    fizzy.Editor.Keybinds.syncNativeMenuShortcuts(fizzy.editor());
}

/// True while keys must not act at all: capturing a chord in the Keyboard Shortcuts settings.
fn menuInputBlocked(_: ?*anyopaque) bool {
    return KeybindSettings.isRecording();
}

/// Whether a menu item can be chosen now — the same greying the in-app bar (`Menu.zig`) does.
/// Everything it reads is plain `Host`/`Editor` state, safe outside a frame.
fn menuEnabled(_: ?*anyopaque, ref: platform.menu.Ref) bool {
    if (KeybindSettings.isRecording()) return false;
    switch (ref.section) {
        .bar => {
            const item = menu_model.byTag(ref.tag) orelse return true;
            // Copy/Paste stay enabled even when the active document can't do them: a disabled
            // NSMenuItem does not perform its key equivalent, and on macOS that is the only way
            // the chord reaches the app at all, including focused widgets that handle it.
            if (item.native_always_enabled) return true;
            // A `visible` item that isn't is shown greyed rather than removed: rebuilding the
            // retained NSMenu on every state change isn't worth it for the same information.
            if (item.visible) |f| if (!f(fizzy.editor())) return false;
            const enabled = item.enabled orelse return true;
            return enabled(fizzy.editor());
        },
        // A plugin's item is its command's, on both bars; no command is always enabled.
        .extra => {
            const items = fizzy.editor().app.host.native_menu_items.items;
            if (ref.tag >= items.len) return true;
            const cmd = items[ref.tag].command orelse return true;
            return fizzy.editor().app.host.commandEnabled(cmd);
        },
        .list => return true,
    }
}

/// A model item's label now, for one that follows the app ("Show Explorer" / "Hide Explorer").
fn menuTitle(_: ?*anyopaque, ref: platform.menu.Ref) ?[*:0]const u8 {
    if (ref.section != .bar) return null;
    const item = menu_model.byTag(ref.tag) orelse return null;
    return switch (item.title) {
        .static => null,
        .dynamic => |f| f(fizzy.editor()).ptr,
    };
}

/// Rebuild every plugin-contributed native menu and item from the host's registry: on every
/// plugin load, unload and hide-toggle. Each item's tag is its index in `host.native_menu_items`.
pub fn rebuildDynamicNativeMenus() void {
    if (builtin.os.tag != .macos) return;
    const host = &fizzy.editor().app.host;
    var menus: std.ArrayListUnmanaged(platform.menu.ExtraMenu) = .empty;
    defer menus.deinit(alloc());
    var items: std.ArrayListUnmanaged(platform.menu.ExtraItem) = .empty;
    defer items.deinit(alloc());
    for (host.menus.items) |mc| {
        if (mc.hidden) continue;
        menus.append(alloc(), .{ .id = mc.id, .title = mc.title }) catch {};
    }
    for (host.native_menu_items.items, 0..) |ni, i| {
        if (ni.hidden) continue;
        items.append(alloc(), .{ .menu_id = ni.parent_menu_id, .title = ni.title, .symbol = ni.sf_symbol, .tag = @intCast(i) }) catch {};
    }
    platform.menu.setExtras(menus.items, items.items);
    // The items are built with no key equivalent; this is what puts the keymap's chords on them.
    fizzy.Editor.Keybinds.syncNativeMenuShortcuts(fizzy.editor());
}

/// How many folders the Recent Folders list was last filled with: a choice's position in it,
/// newest first, back to an index into the recents.
var native_recent_count: usize = 0;

/// Fill the Recent Folders submenu from the recents, newest first. AppKit menus are retained
/// state, so this has to run whenever the list changes.
pub fn rebuildNativeRecentFolders() void {
    if (comptime builtin.os.tag != .macos) return;
    const folders = fizzy.editor().app.recents.folders.items;
    const titles = alloc().alloc([]const u8, folders.len) catch return;
    defer alloc().free(titles);
    for (folders, 0..) |f, i| titles[folders.len - 1 - i] = f;
    native_recent_count = folders.len;
    platform.menu.setList(0, titles);
}

/// Returns and clears a pending Recent Folders choice, as an index into the recents.
pub fn pollPendingRecentFolder() ?usize {
    const a = platform.menu.pollActivation(.list) orelse return null;
    if (a.ref.tag >= native_recent_count) return null;
    return native_recent_count - 1 - a.ref.tag;
}

/// Returns and clears a pending app-menu About click.
pub const pollPendingAbout = platform.menu.pollAbout;

/// Returns and clears a pending native menu action (macOS menu bar). Call once per frame.
pub fn pollPendingNativeMenuAction() ?NativeMenuAction {
    const a = platform.menu.pollActivation(.bar) orelse return null;
    if (a.ref.tag >= menu_model.flat_commands.len) return null;
    return .{ .index = a.ref.tag, .from_key = a.from_key };
}

/// Returns and clears a pending plugin menu item, as its index in `host.native_menu_items`.
pub fn pollPendingGenericNativeMenuAction() ?usize {
    const a = platform.menu.pollActivation(.extra) orelse return null;
    return a.ref.tag;
}

/// Point a menu item at a different chord (`key` lowercase, as AppKit expects; null clears it,
/// right for a chord AppKit can't express).
pub fn setNativeMenuShortcut(tag: usize, key: ?[]const u8, modifier_mask: c_ulong) void {
    platform.menu.setKeyEquivalent(.{ .section = .bar, .tag = @intCast(tag) }, key, modifier_mask);
}

/// `setNativeMenuShortcut` for a plugin's item, keyed by its index in `host.native_menu_items`.
pub fn setDynamicNativeMenuShortcut(index: usize, key: ?[]const u8, modifier_mask: c_ulong) void {
    platform.menu.setKeyEquivalent(.{ .section = .extra, .tag = @intCast(index) }, key, modifier_mask);
}

/// Override the SDL app metadata DVUI sets to its example defaults. On macOS this
/// is what drives the app menu's `About <name>` / `Hide <name>` / `Quit <name>`
/// items. Must be called before `setupMacOSMenuBar` so the inserted Help menu
/// references the right product name.
pub fn setSdlAppMetadata(name: [*:0]const u8, version: [*:0]const u8, identifier: [*:0]const u8) void {
    _ = sdl3.SDL_SetAppMetadata(name, version, identifier);
}

