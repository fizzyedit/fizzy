const std = @import("std");
const builtin = @import("builtin");

/// Lexically canonical form of `path`: `.` / `..` components collapsed, duplicate and trailing
/// separators removed (`/` itself is preserved). Purely textual — no syscalls, no symlink
/// resolution — so it is safe to call on paths that don't exist yet and on any thread.
///
/// Exists because a path that only *differs* lexically (`~/dev/fizzy/.` vs `~/dev/fizzy`, the
/// shape `fizzy .` produces by joining cwd with the literal argument) still names the same
/// directory to the OS while comparing unequal to everything that derives a key from it —
/// recents dedupe, and language servers, which are handed the project folder as a `rootUri`
/// and quietly fail to locate the build root when it carries a `.` component. Normalize at the
/// boundary (argv resolution, `setProjectFolder`, `openFilePath` / `docFromPath`, recents
/// load/append) so nothing downstream can ever see the odd spelling.
pub fn normalize(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.fs.path.resolve(allocator, &.{path});
}

/// `normalize` of `base` joined with `path`; an absolute `path` wins outright (so a
/// cwd + argv pair resolves the way a shell would).
pub fn normalizeJoin(allocator: std.mem.Allocator, base: []const u8, path: []const u8) ![]u8 {
    return std.fs.path.resolve(allocator, &.{ base, path });
}

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

// Posix spellings only — `normalize` delegates to `std.fs.path.resolve`, which switches on the
// native OS, so these assertions are skipped when the test host is Windows (the Windows
// canonicalization rules, including drive-letter casing, are std's own tested territory).
const skip_posix_cases = @import("builtin").target.os.tag == .windows;

test normalize {
    if (skip_posix_cases) return error.SkipZigTest;
    const ta = std.testing.allocator;
    const cases = [_]struct { in: []const u8, want: []const u8 }{
        // The shape `fizzy .` used to produce: same directory, different string.
        .{ .in = "/Users/me/dev/fizzy/.", .want = "/Users/me/dev/fizzy" },
        .{ .in = "/Users/me/dev/fizzy/./.", .want = "/Users/me/dev/fizzy" },
        .{ .in = "/Users/me/dev/fizzy/", .want = "/Users/me/dev/fizzy" },
        .{ .in = "/Users/me/dev/fizzy///", .want = "/Users/me/dev/fizzy" },
        .{ .in = "/Users/me/dev//fizzy", .want = "/Users/me/dev/fizzy" },
        .{ .in = "/Users/me/dev/pixi/../fizzy", .want = "/Users/me/dev/fizzy" },
        .{ .in = "/Users/me/dev/fizzy", .want = "/Users/me/dev/fizzy" },
        // File paths — same collapse `openFilePath` relies on so `a/./b.zig` can't
        // double-open against an already-loaded `a/b.zig`.
        .{ .in = "/Users/me/dev/fizzy/./src/editor/Editor.zig", .want = "/Users/me/dev/fizzy/src/editor/Editor.zig" },
        .{ .in = "/Users/me/dev/fizzy/src/../src/main.zig", .want = "/Users/me/dev/fizzy/src/main.zig" },
        // Root survives as the one path that keeps its separator.
        .{ .in = "/", .want = "/" },
        .{ .in = "/.", .want = "/" },
    };
    for (cases) |c| {
        const got = try normalize(ta, c.in);
        defer ta.free(got);
        std.testing.expectEqualStrings(c.want, got) catch |err| {
            std.debug.print("normalize(\"{s}\")\n", .{c.in});
            return err;
        };
    }
}

test normalizeJoin {
    if (skip_posix_cases) return error.SkipZigTest;
    const ta = std.testing.allocator;

    // `fizzy .` from the project directory.
    const dot = try normalizeJoin(ta, "/Users/me/dev/fizzy", ".");
    defer ta.free(dot);
    try std.testing.expectEqualStrings("/Users/me/dev/fizzy", dot);

    const rel = try normalizeJoin(ta, "/Users/me/dev", "fizzy/src/");
    defer ta.free(rel);
    try std.testing.expectEqualStrings("/Users/me/dev/fizzy/src", rel);

    const up = try normalizeJoin(ta, "/Users/me/dev/fizzy", "../pixi");
    defer ta.free(up);
    try std.testing.expectEqualStrings("/Users/me/dev/pixi", up);

    // An absolute argument ignores the base, as a shell would.
    const abs = try normalizeJoin(ta, "/Users/me/dev", "/tmp/scratch/.");
    defer ta.free(abs);
    try std.testing.expectEqualStrings("/tmp/scratch", abs);
}
