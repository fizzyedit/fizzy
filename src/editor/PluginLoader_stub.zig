//! Wasm stub — dynamic plugin loading is native-only.
const std = @import("std");

pub const LoadError = error{Unsupported};

pub const LoadedLib = struct {
    path: []const u8,
};

pub fn resolvePluginPath(_: std.mem.Allocator, _: []const u8, _: []const u8) ![]const u8 {
    return error.Unsupported;
}

pub fn loadAndRegister(_: anytype, _: []const u8) LoadError!void {
    return error.Unsupported;
}
