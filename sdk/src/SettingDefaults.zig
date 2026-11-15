//! Defaults a plugin gives the app's own settings while it registers (`host.settings`), over the
//! ones the app was built with:
//!
//!     try host.settings.setDefault("theme", "Graphl Dark");
//!     try host.settings.setDefault("plugin_marketplace", false);
//!
//! A setting the user has not set starts on the default, and stays on it across restarts: the
//! settings file records only what differs from the defaults, these included. One the user set
//! keeps their value. The editor applies them once plugins have initialized (and again when a web
//! plugin loads); a key the app's settings do not have, or a value that does not parse as that
//! setting, logs and is skipped.

const std = @import("std");

const SettingDefaults = @This();

allocator: std.mem.Allocator,
/// Each default as the settings field's name and its value as ZON text, both our own copies.
entries: std.ArrayList(Entry) = .empty,
/// Moves on every `setDefault`, so the editor applies them again only when something changed.
generation: u32 = 0,

pub const Entry = struct {
    key: []u8,
    zon: [:0]u8,
};

/// `key` names a field of the app's settings, as `settings.zon` spells it (`theme`,
/// `plugin_marketplace`, `input_scheme`); `value` is anything `std.zon` can write that reads back
/// as that field's type (a string, a bool, a number, an enum literal). Calling again for the same
/// key replaces the earlier value.
pub fn setDefault(self: *SettingDefaults, key: []const u8, value: anytype) !void {
    var aw: std.Io.Writer.Allocating = .init(self.allocator);
    defer aw.deinit();
    std.zon.stringify.serialize(value, .{ .whitespace = false }, &aw.writer) catch return error.OutOfMemory;
    const zon = try aw.toOwnedSliceSentinel(0);
    errdefer self.allocator.free(zon);
    self.generation +%= 1;
    for (self.entries.items) |*e| {
        if (std.mem.eql(u8, e.key, key)) {
            self.allocator.free(e.zon);
            e.zon = zon;
            return;
        }
    }
    const key_copy = try self.allocator.dupe(u8, key);
    errdefer self.allocator.free(key_copy);
    try self.entries.append(self.allocator, .{ .key = key_copy, .zon = zon });
}

pub fn deinit(self: *SettingDefaults) void {
    for (self.entries.items) |e| {
        self.allocator.free(e.key);
        self.allocator.free(e.zon);
    }
    self.entries.deinit(self.allocator);
}
