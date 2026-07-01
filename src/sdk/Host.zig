//! The services the shell exposes to plugins, and the registries it owns. Plugins
//! receive a `*Host` instead of reaching into editor globals; it holds the plugin
//! registry, the shell region registries, and a service locator. The Host is
//! embedded in `Editor`.
const std = @import("std");
const dvui = @import("dvui");
const Plugin = @import("Plugin.zig");
const regions = @import("regions.zig");
const EditorAPI = @import("EditorAPI.zig");
const DocHandle = @import("DocHandle.zig");
const WorkbenchPaneView = @import("WorkbenchPane.zig").WorkbenchPaneView;

pub const Host = @This();

pub const SidebarView = regions.SidebarView;
pub const BottomView = regions.BottomView;
pub const CenterProvider = regions.CenterProvider;
pub const MenuContribution = regions.MenuContribution;
pub const MenuSectionContribution = regions.MenuSectionContribution;
pub const SettingsSection = regions.SettingsSection;
pub const Command = regions.Command;

/// Per-plugin opaque settings blobs: plugin id -> serialized JSON. The Host owns the
/// key + value strings; the shell persists them verbatim under "plugins" in
/// settings.json and never interprets them.
pub const PluginSettings = std.StringArrayHashMapUnmanaged([]const u8);

/// Optional tint for a workbench file-tree row background. `color_index` is the row's
/// stable index during the current tree draw (workbench increments per file). Return
/// null to defer to the next resolver or the theme default.
pub const FileRowFillColor = struct {
    /// Contributing plugin (null = shell built-in). Used to scope teardown in
    /// `unregisterPlugin` when a plugin is unloaded at runtime.
    owner: ?*Plugin = null,
    ctx: ?*anyopaque = null,
    color: *const fn (ctx: ?*anyopaque, color_index: usize) ?dvui.Color,
};

/// A registered inter-plugin service plus the plugin that owns it, so a runtime
/// unload can remove the owner's services. `owner` is null for shell-registered
/// services with no single plugin owner.
pub const ServiceEntry = struct {
    ptr: *anyopaque,
    owner: ?*Plugin = null,
};

/// A file-tree row icon drawer. The workbench file tree calls registered drawers in order at
/// each file row's icon slot; the first that returns `true` wins, otherwise the workbench draws
/// a generic filesystem default. This lets the plugin that owns a file type draw its own icon (a
/// glyph, a thumbnail, anything) instead of the shell hardcoding per-extension icons. `ext` is
/// the extension including the dot, as on disk (compare case-insensitively); `path` is absolute;
/// `color` is the row's themed icon color.
pub const FileIcon = struct {
    owner: ?*Plugin = null,
    ctx: ?*anyopaque = null,
    draw: *const fn (ctx: ?*anyopaque, ext: []const u8, path: []const u8, color: dvui.Color) bool,
};

allocator: std.mem.Allocator,

/// All registered plugins (statically compiled in, or loaded from a runtime dylib).
plugins: std.ArrayListUnmanaged(*Plugin) = .empty,

/// Service locator for inter-plugin APIs: name -> opaque service vtable. E.g. the
/// workbench plugin registers "workbench" so editor plugins can place tabs and
/// draw per-branch explorer decorations without a compile-time dependency on it.
services: std.StringHashMapUnmanaged(ServiceEntry) = .empty,

/// The shell's read/utility surface (arena, folder, shared settings, dirty mark),
/// installed by the shell during startup. Null until installed (headless/test).
shell_api: ?EditorAPI = null,

/// Opaque per-plugin settings store (see `PluginSettings`).
plugin_settings: PluginSettings = .empty,

/// File-tree row fill tints (workbench asks the Host; editor plugins register).
file_row_fill_colors: std.ArrayListUnmanaged(FileRowFillColor) = .empty,

/// File-tree row icon drawers (workbench asks the Host; plugins register for their file types).
file_icons: std.ArrayListUnmanaged(FileIcon) = .empty,

// ---- shell region registries -----------------------------------------------
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
/// Nested items contributed into an open parent menu (e.g. View > Example).
menu_sections: std.ArrayListUnmanaged(MenuSectionContribution) = .empty,
/// Settings sections (Settings view renders each under its title, grouped by owner).
settings_sections: std.ArrayListUnmanaged(SettingsSection) = .empty,
/// Plugin-contributed commands, invoked by id (menus, keybinds, palette) — see `Command`.
commands: std.ArrayListUnmanaged(Command) = .empty,

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
    self.menu_sections.deinit(self.allocator);
    self.settings_sections.deinit(self.allocator);
    self.commands.deinit(self.allocator);
    self.file_row_fill_colors.deinit(self.allocator);
    self.file_icons.deinit(self.allocator);
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

pub fn swapDocs(self: *Host, a_index: usize, b_index: usize) void {
    if (self.shell_api) |a| a.swapDocs(a_index, b_index);
}

pub fn allocDocId(self: *Host) u64 {
    return if (self.shell_api) |a| a.allocDocId() else 0;
}

pub fn explorerViewportWidth(self: *Host) f32 {
    return if (self.shell_api) |a| a.explorerViewportWidth() else 0;
}

pub fn docFromPath(self: *Host, path: []const u8) ?DocHandle {
    return if (self.shell_api) |a| a.docFromPath(path) else null;
}

pub fn openFilePath(self: *Host, path: []const u8, grouping: u64) !bool {
    return if (self.shell_api) |a| try a.openFilePath(path, grouping) else false;
}

pub fn openOrFocusFileAtGrouping(self: *Host, path: []const u8, grouping: u64) !?usize {
    return if (self.shell_api) |a| try a.openOrFocusFileAtGrouping(path, grouping) else null;
}

pub fn closeDocById(self: *Host, id: u64) !void {
    if (self.shell_api) |a| return a.closeDocById(id);
}

pub fn setProjectFolder(self: *Host, path: []const u8) !void {
    return if (self.shell_api) |a| try a.setProjectFolder(path) else error.ShellNotInstalled;
}

pub fn closeProjectFolder(self: *Host) void {
    if (self.shell_api) |a| a.closeProjectFolder();
}

pub fn recentFolderCount(self: *Host) usize {
    return if (self.shell_api) |a| a.recentFolderCount() else 0;
}

pub fn recentFolderAt(self: *Host, index: usize) ?[]const u8 {
    return if (self.shell_api) |a| a.recentFolderAt(index) else null;
}

pub fn openInFileBrowser(self: *Host, path: []const u8) !void {
    return if (self.shell_api) |a| try a.openInFileBrowser(path) else error.ShellNotInstalled;
}

pub fn isPathIgnored(
    self: *Host,
    project_root: []const u8,
    abs_path: []const u8,
    name: []const u8,
    kind: std.Io.File.Kind,
) bool {
    return if (self.shell_api) |a| a.isPathIgnored(project_root, abs_path, name, kind) else false;
}

pub fn explorerBranchIsOpen(self: *Host, branch_id: dvui.Id) bool {
    return if (self.shell_api) |a| a.explorerBranchIsOpen(branch_id) else false;
}

pub fn setExplorerBranchOpen(self: *Host, branch_id: dvui.Id, open: bool) void {
    if (self.shell_api) |a| a.setExplorerBranchOpen(branch_id, open);
}

pub fn drawWorkspaces(self: *Host, index: usize) !dvui.App.Result {
    return if (self.shell_api) |a| try a.drawWorkspaces(index) else .ok;
}

pub fn showOpenFolderDialog(self: *Host, cb: EditorAPI.OpenPathsCallback, default_folder: ?[]const u8) void {
    if (self.shell_api) |a| a.showOpenFolderDialog(cb, default_folder);
}

pub fn showOpenFileDialog(
    self: *Host,
    cb: EditorAPI.OpenPathsCallback,
    filters: []const EditorAPI.SaveDialogFilter,
    default_filename: []const u8,
    default_folder: ?[]const u8,
) void {
    if (self.shell_api) |a| a.showOpenFileDialog(cb, filters, default_filename, default_folder);
}

pub fn save(self: *Host) !void {
    if (self.shell_api) |a| return a.save();
}

pub fn requestPrepareFrame(self: *Host) void {
    if (self.shell_api) |a| a.requestPrepareFrame();
}

pub fn refresh(self: *Host) void {
    if (self.shell_api) |a| a.refresh();
}

pub fn allocUntitledPath(self: *Host) ![]u8 {
    return if (self.shell_api) |a| try a.allocUntitledPath() else error.ShellNotInstalled;
}

pub fn createDocument(self: *Host, path: []const u8, grid: EditorAPI.NewDocGrid) !DocHandle {
    return if (self.shell_api) |a| try a.createDocument(path, grid) else error.ShellNotInstalled;
}

pub fn setExplorerNewFilePath(self: *Host, path: []const u8) !void {
    return if (self.shell_api) |a| try a.setExplorerNewFilePath(path) else error.ShellNotInstalled;
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

/// Register a plugin under its self-declared `id`. The `id` is the single source of truth
/// for routing (`pluginById`, `pluginForExtension`); a folder name or dylib path is not.
/// Rejects a second plugin claiming an already-registered `id` so routing can never become
/// ambiguous — the dylib loader turns this into a failed load the user is told about
/// (built-in ids always win, since they register first).
pub fn registerPlugin(self: *Host, plugin: *Plugin) !void {
    if (self.pluginById(plugin.id) != null) return error.DuplicatePluginId;
    try self.plugins.append(self.allocator, plugin);
}

/// Remove every contribution, service, and registry entry owned by `plugin`, then drop
/// the plugin itself. The inverse of `registerPlugin` + the `register*` calls a plugin
/// makes in its `register`. Used by the runtime unload path (the store's "disable" /
/// "uninstall"); built-in plugins are never unregistered.
///
/// **Ordering matters for the dylib case:** a contribution's `id`/`title` slices and the
/// `*Plugin` itself live in the plugin image's static memory. The caller must invoke
/// this *before* `dlclose`, so that the active-selection ids (which may point into that
/// image) are compared and reset while the memory is still mapped.
pub fn unregisterPlugin(self: *Host, plugin: *Plugin) void {
    removeOwned(SidebarView, &self.sidebar_views, plugin);
    removeOwned(BottomView, &self.bottom_views, plugin);
    removeOwned(CenterProvider, &self.center_providers, plugin);
    removeOwned(MenuContribution, &self.menus, plugin);
    removeOwned(MenuSectionContribution, &self.menu_sections, plugin);
    removeOwned(SettingsSection, &self.settings_sections, plugin);
    removeOwned(Command, &self.commands, plugin);
    removeOwned(FileRowFillColor, &self.file_row_fill_colors, plugin);
    removeOwned(FileIcon, &self.file_icons, plugin);

    // Services: free the owned key strings and drop the entries.
    {
        var it = self.services.iterator();
        var doomed: std.ArrayListUnmanaged([]const u8) = .empty;
        defer doomed.deinit(self.allocator);
        while (it.next()) |e| {
            if (e.value_ptr.owner == plugin) doomed.append(self.allocator, e.key_ptr.*) catch {};
        }
        for (doomed.items) |name| _ = self.services.remove(name);
    }

    // Drop the plugin from the registry (pointer identity; no `owner` field here).
    for (self.plugins.items, 0..) |p, i| {
        if (p == plugin) {
            _ = self.plugins.orderedRemove(i);
            break;
        }
    }

    // Active-selection ids may name a now-removed view; reset so the next frame falls
    // back to a still-registered contribution (or none).
    if (self.active_sidebar_view) |id| {
        if (!self.hasSidebarView(id)) self.active_sidebar_view = null;
    }
    if (self.active_bottom_view) |id| {
        if (!self.hasBottomView(id)) self.active_bottom_view = null;
    }
    if (self.active_center) |id| {
        if (!self.hasCenterProvider(id)) self.active_center = null;
    }
}

/// Compact a registry in place, dropping every entry whose `owner` is `plugin`.
/// `T` must have an `owner: ?*Plugin` field (all contribution structs do).
fn removeOwned(comptime T: type, list: *std.ArrayListUnmanaged(T), plugin: *Plugin) void {
    var w: usize = 0;
    for (list.items) |item| {
        const owned = if (item.owner) |o| o == plugin else false;
        if (!owned) {
            list.items[w] = item;
            w += 1;
        }
    }
    list.items.len = w;
}

fn hasSidebarView(self: *Host, id: []const u8) bool {
    for (self.sidebar_views.items) |*v| if (std.mem.eql(u8, v.id, id)) return true;
    return false;
}

fn hasBottomView(self: *Host, id: []const u8) bool {
    for (self.bottom_views.items) |*v| if (std.mem.eql(u8, v.id, id)) return true;
    return false;
}

fn hasCenterProvider(self: *Host, id: []const u8) bool {
    for (self.center_providers.items) |*p| if (std.mem.eql(u8, p.id, id)) return true;
    return false;
}

/// Lookup a registered plugin by stable id (`"pixi"`, `"workbench"`, …).
pub fn pluginById(self: *Host, id: []const u8) ?*Plugin {
    for (self.plugins.items) |plugin| {
        if (std.mem.eql(u8, plugin.id, id)) return plugin;
    }
    return null;
}

/// First registered plugin that implements `createDocument` (for shell New File flows).
pub fn pluginWithCreateDocument(self: *Host) ?*Plugin {
    for (self.plugins.items) |plugin| {
        if (plugin.vtable.createDocument != null) return plugin;
    }
    return null;
}

pub fn registerFileRowFillColor(self: *Host, resolver: FileRowFillColor) !void {
    try self.file_row_fill_colors.append(self.allocator, resolver);
}

/// First non-null tint from registered resolvers, or null for the workbench theme default.
pub fn fileRowFillColor(self: *Host, color_index: usize) ?dvui.Color {
    for (self.file_row_fill_colors.items) |resolver| {
        if (resolver.color(resolver.ctx, color_index)) |color| return color;
    }
    return null;
}

pub fn registerFileIcon(self: *Host, drawer: FileIcon) !void {
    try self.file_icons.append(self.allocator, drawer);
}

/// Draw the file-tree row icon for `ext`/`path` via the first registered drawer that handles it.
/// Returns true if a plugin drew it; false means the caller should draw a generic default.
pub fn drawFileIcon(self: *Host, ext: []const u8, path: []const u8, color: dvui.Color) bool {
    for (self.file_icons.items) |drawer| {
        if (drawer.draw(drawer.ctx, ext, path, color)) return true;
    }
    return false;
}

/// Register an inter-plugin service. `owner` is the contributing plugin (null for a
/// shell-registered service); it lets `unregisterPlugin` drop the service on unload.
pub fn registerService(self: *Host, name: []const u8, service: *anyopaque, owner: ?*Plugin) !void {
    try self.services.put(self.allocator, name, .{ .ptr = service, .owner = owner });
}

pub fn getService(self: *Host, name: []const u8) ?*anyopaque {
    return if (self.services.get(name)) |entry| entry.ptr else null;
}

/// Typed service lookup. `Service` must declare `service_name` and match the registered layout.
pub fn getServiceTyped(self: *Host, comptime Service: type) ?*Service {
    const ptr = self.getService(Service.service_name) orelse return null;
    return @ptrCast(@alignCast(ptr));
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

/// Move a bottom-panel tab from `from_index` to `to_index`.
pub fn reorderBottomView(self: *Host, from_index: usize, to_index: usize) void {
    if (from_index >= self.bottom_views.items.len or to_index >= self.bottom_views.items.len) return;
    if (from_index == to_index) return;
    const item = self.bottom_views.items[from_index];
    _ = self.bottom_views.orderedRemove(from_index);
    self.bottom_views.insert(self.allocator, to_index, item) catch return;
}

pub fn setSidebarViewHidden(self: *Host, id: []const u8, hidden: bool) void {
    for (self.sidebar_views.items) |*view| {
        if (std.mem.eql(u8, view.id, id)) {
            view.hidden = hidden;
            return;
        }
    }
}

/// Fluent sugar — same fields as `SidebarView`, without a new ABI type.
pub fn registerSidebar(
    self: *Host,
    spec: struct {
        id: []const u8,
        title: []const u8,
        icon: []const u8,
        draw: *const fn (ctx: ?*anyopaque) anyerror!void,
        owner: ?*Plugin = null,
        hidden: bool = false,
        draw_workspace: ?*const fn (ctx: ?*anyopaque, pane: *WorkbenchPaneView) anyerror!void = null,
    },
) !void {
    try self.registerSidebarView(.{
        .id = spec.id,
        .title = spec.title,
        .icon = spec.icon,
        .draw = spec.draw,
        .owner = spec.owner,
        .hidden = spec.hidden,
        .draw_workspace = spec.draw_workspace,
    });
}

pub fn registerBottom(
    self: *Host,
    spec: struct {
        id: []const u8,
        title: []const u8,
        draw: *const fn (ctx: ?*anyopaque) anyerror!void,
        owner: ?*Plugin = null,
        persistent: bool = false,
    },
) !void {
    try self.registerBottomView(.{
        .id = spec.id,
        .title = spec.title,
        .draw = spec.draw,
        .owner = spec.owner,
        .persistent = spec.persistent,
    });
}

pub fn registerCenter(
    self: *Host,
    spec: struct {
        id: []const u8,
        draw: *const fn (ctx: ?*anyopaque) anyerror!dvui.App.Result,
        owner: ?*Plugin = null,
    },
) !void {
    try self.registerCenterProvider(.{
        .id = spec.id,
        .draw = spec.draw,
        .owner = spec.owner,
    });
}

pub fn registerCenterProvider(self: *Host, provider: CenterProvider) !void {
    try self.center_providers.append(self.allocator, provider);
    if (self.active_center == null) self.active_center = provider.id;
}

pub fn registerMenu(self: *Host, menu: MenuContribution) !void {
    try self.menus.append(self.allocator, menu);
}

pub fn registerMenuSection(self: *Host, section: MenuSectionContribution) !void {
    try self.menu_sections.append(self.allocator, section);
}

pub fn registerSettingsSection(self: *Host, section: SettingsSection) !void {
    try self.settings_sections.append(self.allocator, section);
}

// ---- commands --------------------------------------------------------------

/// Register a plugin command. Ids should be plugin-namespaced (`"pixelart.packProject"`).
pub fn registerCommand(self: *Host, cmd: Command) !void {
    try self.commands.append(self.allocator, cmd);
}

/// The registered command with `id`, or null.
pub fn command(self: *Host, id: []const u8) ?*Command {
    for (self.commands.items) |*c| {
        if (std.mem.eql(u8, c.id, id)) return c;
    }
    return null;
}

/// Whether `id` is registered and currently enabled (absent `isEnabled` = enabled).
/// Unknown ids are treated as disabled.
pub fn commandEnabled(self: *Host, id: []const u8) bool {
    const c = self.command(id) orelse return false;
    const owner = c.owner orelse return true;
    return if (c.isEnabled) |f| f(owner.state) else true;
}

/// Run the command `id` (no-op when unknown). The owner's opaque `state` is passed to `run`.
pub fn runCommand(self: *Host, id: []const u8) !void {
    const c = self.command(id) orelse return;
    const owner = c.owner orelse return;
    try c.run(owner.state);
}

// ---- active selection ------------------------------------------------------

pub fn setActiveSidebarView(self: *Host, id: []const u8) void {
    self.active_sidebar_view = id;
}

pub fn isActiveSidebarView(self: *Host, id: []const u8) bool {
    const active = self.active_sidebar_view orelse return false;
    return std.mem.eql(u8, active, id);
}

/// The currently active sidebar view, or the first visible registered view as fallback.
pub fn activeSidebarView(self: *Host) ?*SidebarView {
    if (self.active_sidebar_view) |id| {
        for (self.sidebar_views.items) |*v| {
            if (std.mem.eql(u8, v.id, id)) return v;
        }
    }
    return self.firstVisibleSidebarView();
}

pub fn firstVisibleSidebarView(self: *Host) ?*SidebarView {
    for (self.sidebar_views.items) |*v| {
        if (!v.hidden) return v;
    }
    return null;
}

pub fn hasPersistentBottomView(self: *Host) bool {
    for (self.bottom_views.items) |*v| {
        if (v.persistent) return true;
    }
    return false;
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

/// The registered plugin with the highest priority (lowest numeric value) for `ext`,
/// or null if none claims it. Specialized plugins claim known types at low values;
/// the code plugin claims every extension at `Plugin.file_type_fallback_priority`.
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

/// Open a "new document" dialog. `parent_path` (when set) targets an on-disk folder; `id_extra`
/// disambiguates launches from distinct explorer rows. Dispatches to the first plugin that
/// provides a new-document dialog.
/// TODO: with more than one editor plugin, present a typed "New > <kind>" chooser instead of
/// picking the first provider.
pub fn requestNewDocument(self: *Host, parent_path: ?[]const u8, id_extra: usize) void {
    for (self.plugins.items) |plugin| {
        if (plugin.vtable.requestNewDocumentDialog) |f| {
            f(plugin.state, parent_path, id_extra);
            return;
        }
    }
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

test "unregisterPlugin removes a plugin's contributions, service, and resets active ids" {
    const noopDraw = struct {
        fn f(_: ?*anyopaque) anyerror!void {}
    }.f;
    const noopCenter = struct {
        fn f(_: ?*anyopaque) anyerror!dvui.App.Result {
            return .ok;
        }
    }.f;
    const noopRun = struct {
        fn f(_: *anyopaque) anyerror!void {}
    }.f;
    const noColor = struct {
        fn f(_: ?*anyopaque, _: usize) ?dvui.Color {
            return null;
        }
    }.f;
    const noIcon = struct {
        fn f(_: ?*anyopaque, _: []const u8, _: []const u8, _: dvui.Color) bool {
            return false;
        }
    }.f;

    var host = Host.init(testing.allocator);
    defer host.deinit();

    const vtable = Plugin.VTable{};
    var plugin = Plugin{ .state = undefined, .vtable = &vtable, .id = "victim", .display_name = "Victim" };
    var service_obj: u32 = 0;

    // A second, surviving plugin so we can prove only the victim's entries are removed.
    var keeper = Plugin{ .state = undefined, .vtable = &vtable, .id = "keeper", .display_name = "Keeper" };

    try host.registerPlugin(&keeper);
    try host.registerPlugin(&plugin);
    try host.registerSidebarView(.{ .id = "keeper.view", .owner = &keeper, .icon = "", .title = "K", .draw = noopDraw });
    try host.registerSidebarView(.{ .id = "victim.view", .owner = &plugin, .icon = "", .title = "V", .draw = noopDraw });
    try host.registerBottomView(.{ .id = "victim.bottom", .owner = &plugin, .title = "V", .draw = noopDraw });
    try host.registerCenterProvider(.{ .id = "victim.center", .owner = &plugin, .draw = noopCenter });
    try host.registerMenu(.{ .id = "victim.menu", .owner = &plugin, .draw = noopDraw });
    try host.registerMenuSection(.{ .id = "victim.section", .parent_menu_id = "shell.menu.view", .owner = &plugin, .draw = noopDraw });
    try host.registerSettingsSection(.{ .id = "victim.settings", .owner = &plugin, .title = "V", .draw = noopDraw });
    try host.registerCommand(.{ .id = "victim.cmd", .owner = &plugin, .title = "V", .run = noopRun });
    try host.registerFileRowFillColor(.{ .owner = &plugin, .color = noColor });
    try host.registerFileIcon(.{ .owner = &plugin, .draw = noIcon });
    try host.registerService("victim.svc", &service_obj, &plugin);

    // Active sidebar view points at the victim (keeper registered first, but force it).
    host.setActiveSidebarView("victim.view");
    host.setActiveBottomView("victim.bottom");
    host.setActiveCenter("victim.center");

    host.unregisterPlugin(&plugin);

    // The victim is gone; the keeper survives.
    try testing.expect(host.pluginById("victim") == null);
    try testing.expect(host.pluginById("keeper") != null);

    // Every victim contribution is gone; keeper's sidebar view remains.
    try testing.expectEqual(@as(usize, 1), host.sidebar_views.items.len);
    try testing.expectEqualStrings("keeper.view", host.sidebar_views.items[0].id);
    try testing.expectEqual(@as(usize, 0), host.bottom_views.items.len);
    try testing.expectEqual(@as(usize, 0), host.center_providers.items.len);
    try testing.expectEqual(@as(usize, 0), host.menus.items.len);
    try testing.expectEqual(@as(usize, 0), host.menu_sections.items.len);
    try testing.expectEqual(@as(usize, 0), host.settings_sections.items.len);
    try testing.expectEqual(@as(usize, 0), host.commands.items.len);
    try testing.expectEqual(@as(usize, 0), host.file_row_fill_colors.items.len);
    try testing.expectEqual(@as(usize, 0), host.file_icons.items.len);
    try testing.expect(host.getService("victim.svc") == null);

    // Active selections that named removed contributions reset to null; the next frame
    // falls back to a still-registered view.
    try testing.expect(host.active_sidebar_view == null);
    try testing.expect(host.active_bottom_view == null);
    try testing.expect(host.active_center == null);
}
