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

