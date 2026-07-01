const std = @import("std");
const builtin = @import("builtin");

/// The OS "local configuration" root — fizzy's own canonical mapping (formerly `known-folders`
/// `.local_configuration`). **Single source of truth, shared by the runtime loader (`configRoot`
/// below) and the build-time plugin installer (`plugin_sdk.zig`'s `fizzyPluginsDir`)** so a
/// plugin's install location and the editor's load location can never drift apart. Pure: the
/// caller supplies the env values it read with its own env API.
///   macOS   `{home}/Library/Application Support`
///   Linux   `{xdg_config_home}` or `{home}/.config`
///   Windows `{local_app_data}`  (FOLDERID_LocalAppData — *not* Roaming/`%APPDATA%`)
pub fn localConfigRoot(
    os: std.Target.Os.Tag,
    allocator: std.mem.Allocator,
    home: ?[]const u8,
    xdg_config_home: ?[]const u8,
    local_app_data: ?[]const u8,
) !?[]const u8 {
    return switch (os) {
        .windows => local_app_data,
        .macos => if (home) |h|
            try std.fs.path.join(allocator, &.{ h, "Library", "Application Support" })
        else
            null,
        else => xdg_config_home orelse (if (home) |h|
            try std.fs.path.join(allocator, &.{ h, ".config" })
        else
            null),
    };
}

pub fn configRoot(
    io: std.Io,
    arena: std.mem.Allocator,
    environ: std.process.Environ,
    fallback: []const u8,
) ![]const u8 {
    _ = io;
    if (comptime builtin.target.cpu.arch == .wasm32) return fallback;
    const get = struct {
        fn f(env: std.process.Environ, a: std.mem.Allocator, name: []const u8) ?[]const u8 {
            return env.getAlloc(a, name) catch null;
        }
    }.f;
    const root = (localConfigRoot(
        builtin.target.os.tag,
        arena,
        get(environ, arena, "HOME"),
        get(environ, arena, "XDG_CONFIG_HOME"),
        get(environ, arena, "LOCALAPPDATA"),
    ) catch fallback) orelse fallback;
    return root;
}

pub fn configFolder(
    allocator: std.mem.Allocator,
    io: std.Io,
    arena: std.mem.Allocator,
    environ: std.process.Environ,
    fallback: []const u8,
) ![]const u8 {
    const config_root = try configRoot(io, arena, environ, fallback);
    return std.fs.path.join(allocator, &.{ config_root, "fizzy" }) catch fallback;
}

pub fn configFolderZ(
    buf: []u8,
    io: std.Io,
    environ: std.process.Environ,
    fallback: []const u8,
) ?[:0]const u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const folder = configFolder(arena.allocator(), io, arena.allocator(), environ, fallback) catch return null;
    if (folder.len + 1 > buf.len) return null;
    @memcpy(buf[0..folder.len], folder);
    buf[folder.len] = 0;
    return buf[0..folder.len :0];
}
