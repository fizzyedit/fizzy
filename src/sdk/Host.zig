//! The services the shell exposes to plugins, and the registries it owns. Plugins
//! receive a `*Host` instead of reaching into editor globals. Today the Host is
//! embedded in `Editor`; as the shell shrinks (Phases 1-3) more of the editor's
//! responsibilities move behind it.
//!
//! Phase 0: holds the plugin registry + service locator. Nothing is registered
//! yet — the existing pixel-art code still uses globals directly.
const std = @import("std");
const Plugin = @import("Plugin.zig");
const regions = @import("regions.zig");

pub const Host = @This();

pub const SidebarView = regions.SidebarView;
pub const BottomView = regions.BottomView;
pub const CenterProvider = regions.CenterProvider;
pub const MenuContribution = regions.MenuContribution;

allocator: std.mem.Allocator,

/// All registered plugins (static today; runtime-loaded dylibs in Phase 4).
plugins: std.ArrayListUnmanaged(*Plugin) = .empty,

/// Service locator for inter-plugin APIs: name -> opaque service vtable. E.g. the
/// workbench plugin registers "workbench" so editor plugins can place tabs and
/// draw per-branch explorer decorations without a compile-time dependency on it.
services: std.StringHashMapUnmanaged(*anyopaque) = .empty,

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
