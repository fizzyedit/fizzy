//! The services the shell exposes to plugins, and the registries it owns. Plugins
//! receive a `*Host` instead of reaching into editor globals. Today the Host is
//! embedded in `Editor`; as the shell shrinks (Phases 1-3) more of the editor's
//! responsibilities move behind it.
//!
//! Phase 0: holds the plugin registry + service locator. Nothing is registered
//! yet — the existing pixel-art code still uses globals directly.
const std = @import("std");
const dvui = @import("dvui");
const Plugin = @import("Plugin.zig");
const regions = @import("regions.zig");
const EditorAPI = @import("EditorAPI.zig");
const DocHandle = @import("DocHandle.zig");

pub const Host = @This();

pub const SidebarView = regions.SidebarView;
pub const BottomView = regions.BottomView;
pub const CenterProvider = regions.CenterProvider;
pub const MenuContribution = regions.MenuContribution;
pub const SettingsSection = regions.SettingsSection;

/// Per-plugin opaque settings blobs: plugin id -> serialized JSON. The Host owns the
/// key + value strings; the shell persists them verbatim under "plugins" in
/// settings.json and never interprets them.
pub const PluginSettings = std.StringArrayHashMapUnmanaged([]const u8);

allocator: std.mem.Allocator,

/// All registered plugins (static today; runtime-loaded dylibs in Phase 4).
plugins: std.ArrayListUnmanaged(*Plugin) = .empty,

/// Service locator for inter-plugin APIs: name -> opaque service vtable. E.g. the
/// workbench plugin registers "workbench" so editor plugins can place tabs and
/// draw per-branch explorer decorations without a compile-time dependency on it.
services: std.StringHashMapUnmanaged(*anyopaque) = .empty,

/// The shell's read/utility surface (arena, folder, shared settings, dirty mark),
/// installed by the shell during startup. Null until installed (headless/test).
shell_api: ?EditorAPI = null,

/// Opaque per-plugin settings store (see `PluginSettings`).
plugin_settings: PluginSettings = .empty,

// ---- shell region registries (Phase 2) -------------------------------------
// The shell iterates these instead of hardcoded enums/switches. Items keep their
// registration order, which is the order they appear in the UI.

/// Left-region (explorer) views, one per sidebar icon.
sidebar_views: std.ArrayListUnmanaged(SidebarView) = .empty,
/// Bottom-panel views (shown as a tab strip).
bottom_views: std.ArrayListUnmanaged(BottomView) = .empty,
/// Center ("main window") providers; the active one draws the whole center.
center_providers: std.ArrayListUnmanaged(CenterProvider) = .empty,
/// Menubar contributions (non-macOS in-app menu bar).
menus: std.ArrayListUnmanaged(MenuContribution) = .empty,
/// Settings sections (Settings view renders each under its title, grouped by owner).
settings_sections: std.ArrayListUnmanaged(SettingsSection) = .empty,

/// Active selection by contribution id (null = use the first registered).
active_sidebar_view: ?[]const u8 = null,
active_bottom_view: ?[]const u8 = null,
active_center: ?[]const u8 = null,

pub fn init(allocator: std.mem.Allocator) Host {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Host) void {
    self.plugins.deinit(self.allocator);
    self.services.deinit(self.allocator);
    self.sidebar_views.deinit(self.allocator);
    self.bottom_views.deinit(self.allocator);
    self.center_providers.deinit(self.allocator);
    self.menus.deinit(self.allocator);
    self.settings_sections.deinit(self.allocator);
    {
        var it = self.plugin_settings.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            self.allocator.free(e.value_ptr.*);
        }
        self.plugin_settings.deinit(self.allocator);
    }
}

// ---- shell services (installed by the shell during startup) ----------------

/// Install the shell's read/utility surface. Called once during startup.
pub fn installShell(self: *Host, api: EditorAPI) void {
    self.shell_api = api;
}

/// Per-frame arena allocator (reset every frame; do not free). Asserts the shell is installed.
pub fn arena(self: *Host) std.mem.Allocator {
    return self.shell_api.?.arena();
}

/// Open project root folder, or null when none is open.
pub fn folder(self: *Host) ?[]const u8 {
    return if (self.shell_api) |a| a.folder() else null;
}

/// User palettes folder (config), or null on platforms without one.
pub fn paletteFolder(self: *Host) ?[]const u8 {
    return if (self.shell_api) |a| a.paletteFolder() else null;
}

/// Mark shell settings dirty so the debounced autosave persists them.
pub fn markSettingsDirty(self: *Host) void {
    if (self.shell_api) |a| a.markSettingsDirty();
}

/// Shell-owned content-area opacity (matches the shell chrome). 1.0 if no shell installed.
pub fn contentOpacity(self: *Host) f32 {
    return if (self.shell_api) |a| a.contentOpacity() else 1.0;
}

/// Whether the OS window is currently maximized. False if no shell installed (headless/web).
pub fn isMaximized(self: *Host) bool {
    return if (self.shell_api) |a| a.isMaximized() else false;
}

pub fn isMacOS(self: *Host) bool {
    return if (self.shell_api) |a| a.isMacOS() else false;
}

pub fn appliesNativeWindowOpacity(self: *Host) bool {
    return if (self.shell_api) |a| a.appliesNativeWindowOpacity() else false;
}

/// The explorer pane's content rect (shell layout). Zero rect if no shell installed.
pub fn explorerRect(self: *Host) dvui.Rect {
    return if (self.shell_api) |a| a.explorerRect() else .{};
}

/// The explorer scroll area's virtual content size (shell layout). Zero size if no shell installed.
pub fn explorerVirtualSize(self: *Host) dvui.Size {
    return if (self.shell_api) |a| a.explorerVirtualSize() else .{};
}

/// Run the platform's native "save file" dialog. No-op if no shell installed (headless/test).
pub fn showSaveDialog(
    self: *Host,
    cb: EditorAPI.SaveDialogCallback,
    filters: []const EditorAPI.SaveDialogFilter,
    default_filename: []const u8,
    default_folder: ?[]const u8,
) void {
    if (self.shell_api) |a| a.showSaveDialog(cb, filters, default_filename, default_folder);
}

/// Shell-owned UI icon spritesheet. Asserts the shell is installed.
pub fn uiAtlas(self: *Host) EditorAPI.UiAtlasView {
    return self.shell_api.?.uiAtlas();
}

/// The actively focused open document, or null when none.
pub fn activeDoc(self: *Host) ?DocHandle {
    return if (self.shell_api) |a| a.activeDoc() else null;
}

pub fn docByIndex(self: *Host, index: usize) ?DocHandle {
    return if (self.shell_api) |a| a.docByIndex(index) else null;
}

pub fn docById(self: *Host, id: u64) ?DocHandle {
    return if (self.shell_api) |a| a.docById(id) else null;
}

pub fn docIndex(self: *Host, id: u64) ?usize {
    return if (self.shell_api) |a| a.docIndex(id) else null;
}

pub fn openDocCount(self: *Host) usize {
    return if (self.shell_api) |a| a.openDocCount() else 0;
}

pub fn setActiveDocIndex(self: *Host, index: usize) void {
    if (self.shell_api) |a| a.setActiveDocIndex(index);
}

pub fn allocDocId(self: *Host) u64 {
    return if (self.shell_api) |a| a.allocDocId() else 0;
}

pub fn accept(self: *Host) !void {
    if (self.shell_api) |a| return a.accept();
}

pub fn cancel(self: *Host) !void {
    if (self.shell_api) |a| return a.cancel();
}

pub fn copy(self: *Host) !void {
    if (self.shell_api) |a| return a.copy();
}

pub fn paste(self: *Host) !void {
    if (self.shell_api) |a| return a.paste();
}

pub fn transform(self: *Host) !void {
    if (self.shell_api) |a| return a.transform();
}

pub fn save(self: *Host) !void {
    if (self.shell_api) |a| return a.save();
}

pub fn requestCompositeWarmup(self: *Host) void {
    if (self.shell_api) |a| a.requestCompositeWarmup();
}

pub fn requestGridLayoutDialog(self: *Host) void {
    if (self.shell_api) |a| a.requestGridLayoutDialog();
}

pub fn allocUntitledPath(self: *Host) ![]u8 {
    return if (self.shell_api) |a| try a.allocUntitledPath() else error.ShellNotInstalled;
}

pub fn createDocument(self: *Host, path: []const u8, grid: EditorAPI.NewDocGrid) !DocHandle {
    return if (self.shell_api) |a| try a.createDocument(path, grid) else error.ShellNotInstalled;
}

pub fn requestSaveAs(self: *Host) void {
    if (self.shell_api) |a| a.requestSaveAs();
}

pub fn requestWebSave(self: *Host, kind: EditorAPI.WebSaveKind) void {
    if (self.shell_api) |a| a.requestWebSave(kind);
}

pub fn cancelPendingSaveDialog(self: *Host) void {
    if (self.shell_api) |a| a.cancelPendingSaveDialog();
}

pub fn setPendingCloseDocId(self: *Host, id: u64) void {
    if (self.shell_api) |a| a.setPendingCloseDocId(id);
}

pub fn queueCloseAfterSave(self: *Host, id: u64) !void {
    if (self.shell_api) |a| return a.queueCloseAfterSave(id);
}

pub fn trackQuitSaveInFlight(self: *Host, id: u64) !void {
    if (self.shell_api) |a| return a.trackQuitSaveInFlight(id);
}

pub fn resumeSaveAllQuit(self: *Host) void {
    if (self.shell_api) |a| a.resumeSaveAllQuit();
}

pub fn abortSaveAllQuit(self: *Host) void {
    if (self.shell_api) |a| a.abortSaveAllQuit();
}

pub fn startPackProject(self: *Host) !void {
    if (self.shell_api) |a| return a.startPackProject();
}

pub fn isPackingActive(self: *Host) bool {
    return if (self.shell_api) |a| a.isPackingActive() else false;
}

// ---- per-plugin settings store ---------------------------------------------

/// The stored settings blob for `id` (serialized JSON), or null if none. The returned
/// slice is owned by the Host and valid until the next `storePluginSettings` for `id`.
pub fn loadPluginSettings(self: *Host, id: []const u8) ?[]const u8 {
    return self.plugin_settings.get(id);
}

/// Store `json` as `id`'s settings blob (replacing any previous), and mark the shell
/// settings dirty so it persists. The Host copies both `id` and `json`.
pub fn storePluginSettings(self: *Host, id: []const u8, json: []const u8) !void {
    const dup = try self.allocator.dupe(u8, json);
    errdefer self.allocator.free(dup);
    if (self.plugin_settings.getPtr(id)) |slot| {
        self.allocator.free(slot.*);
        slot.* = dup;
    } else {
        const key = try self.allocator.dupe(u8, id);
        try self.plugin_settings.put(self.allocator, key, dup);
    }
    self.markSettingsDirty();
}

pub fn registerPlugin(self: *Host, plugin: *Plugin) !void {
    try self.plugins.append(self.allocator, plugin);
}

pub fn registerService(self: *Host, name: []const u8, service: *anyopaque) !void {
    try self.services.put(self.allocator, name, service);
}

pub fn getService(self: *Host, name: []const u8) ?*anyopaque {
    return self.services.get(name);
}

// ---- region registration (called from a plugin's register / postInit) -------

pub fn registerSidebarView(self: *Host, view: SidebarView) !void {
    try self.sidebar_views.append(self.allocator, view);
    if (self.active_sidebar_view == null) self.active_sidebar_view = view.id;
}

pub fn registerBottomView(self: *Host, view: BottomView) !void {
    try self.bottom_views.append(self.allocator, view);
    if (self.active_bottom_view == null) self.active_bottom_view = view.id;
}

pub fn registerCenterProvider(self: *Host, provider: CenterProvider) !void {
    try self.center_providers.append(self.allocator, provider);
    if (self.active_center == null) self.active_center = provider.id;
}

pub fn registerMenu(self: *Host, menu: MenuContribution) !void {
    try self.menus.append(self.allocator, menu);
}

pub fn registerSettingsSection(self: *Host, section: SettingsSection) !void {
    try self.settings_sections.append(self.allocator, section);
}

// ---- active selection ------------------------------------------------------

pub fn setActiveSidebarView(self: *Host, id: []const u8) void {
    self.active_sidebar_view = id;
}

pub fn isActiveSidebarView(self: *Host, id: []const u8) bool {
    const active = self.active_sidebar_view orelse return false;
    return std.mem.eql(u8, active, id);
}

/// The currently active sidebar view, or the first registered as a fallback.
pub fn activeSidebarView(self: *Host) ?*SidebarView {
    if (self.active_sidebar_view) |id| {
        for (self.sidebar_views.items) |*v| {
            if (std.mem.eql(u8, v.id, id)) return v;
        }
    }
    if (self.sidebar_views.items.len > 0) return &self.sidebar_views.items[0];
    return null;
}

pub fn setActiveBottomView(self: *Host, id: []const u8) void {
    self.active_bottom_view = id;
}

pub fn isActiveBottomView(self: *Host, id: []const u8) bool {
    const active = self.active_bottom_view orelse return false;
    return std.mem.eql(u8, active, id);
}

pub fn activeBottomView(self: *Host) ?*BottomView {
    if (self.active_bottom_view) |id| {
        for (self.bottom_views.items) |*v| {
            if (std.mem.eql(u8, v.id, id)) return v;
        }
    }
    if (self.bottom_views.items.len > 0) return &self.bottom_views.items[0];
    return null;
}

pub fn setActiveCenter(self: *Host, id: []const u8) void {
    self.active_center = id;
}

pub fn activeCenter(self: *Host) ?*CenterProvider {
    if (self.active_center) |id| {
        for (self.center_providers.items) |*p| {
            if (std.mem.eql(u8, p.id, id)) return p;
        }
    }
    if (self.center_providers.items.len > 0) return &self.center_providers.items[0];
    return null;
}

/// The registered plugin with the highest priority (lowest value) for `ext`, or
/// null if none claims it. Used in Phase 3 to route file opens to the right plugin.
pub fn pluginForExtension(self: *Host, ext: []const u8) ?*Plugin {
    var best: ?*Plugin = null;
    var best_priority: u8 = 255;
    for (self.plugins.items) |plugin| {
        if (plugin.fileTypePriority(ext)) |p| {
            if (best == null or p < best_priority) {
                best = plugin;
                best_priority = p;
            }
        }
    }
    return best;
}
