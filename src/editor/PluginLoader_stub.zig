//! Wasm stub — dynamic plugin loading is native-only (no `dlopen` in the browser; web plugins
//! are statically linked). The shell still references these types in cross-platform code
//! (e.g. the Settings → Plugins list), so `LoadedLib` mirrors the read-shape of the real
//! `PluginLoader.LoadedLib`. On wasm `loaded_plugin_libs` is always empty, so the values are
//! never produced — only the type has to satisfy those field accesses.
const std = @import("std");

pub const LoadError = error{Unsupported};

pub const PluginVersionInfo = struct {
    plugin_version: std.SemanticVersion = .{ .major = 0, .minor = 0, .patch = 0 },
    built_with_sdk_version: std.SemanticVersion = .{ .major = 0, .minor = 0, .patch = 0 },
    min_sdk_version: std.SemanticVersion = .{ .major = 0, .minor = 0, .patch = 0 },
    declared_id: ?[]const u8 = null,
};

pub const LoadedLib = struct {
    path: []const u8,
    plugin_id: []const u8 = "",
    version_info: PluginVersionInfo = .{},
};

pub fn resolvePluginPath(_: std.mem.Allocator, _: []const u8, _: []const u8) ![]const u8 {
    return error.Unsupported;
}

pub fn loadAndRegister(_: anytype, _: []const u8) LoadError!void {
    return error.Unsupported;
}
