//! The services the shell exposes to plugins, and the registries it owns. Plugins
//! receive a `*Host` instead of reaching into editor globals. Today the Host is
//! embedded in `Editor`; as the shell shrinks (Phases 1-3) more of the editor's
//! responsibilities move behind it.
//!
//! Phase 0: holds the plugin registry + service locator. Nothing is registered
//! yet — the existing pixel-art code still uses globals directly.
const std = @import("std");
const Plugin = @import("Plugin.zig");

pub const Host = @This();

allocator: std.mem.Allocator,

/// All registered plugins (static today; runtime-loaded dylibs in Phase 4).
plugins: std.ArrayListUnmanaged(*Plugin) = .empty,

/// Service locator for inter-plugin APIs: name -> opaque service vtable. E.g. the
/// workbench plugin registers "workbench" so editor plugins can place tabs and
/// draw per-branch explorer decorations without a compile-time dependency on it.
services: std.StringHashMapUnmanaged(*anyopaque) = .empty,

pub fn init(allocator: std.mem.Allocator) Host {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Host) void {
    self.plugins.deinit(self.allocator);
    self.services.deinit(self.allocator);
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
