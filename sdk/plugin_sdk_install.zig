//! Copy a built plugin, or a program it installs beside itself, into fizzy's plugins directory:
//! `zig build install`'s dev convenience, wired by `fizzy.plugin.install` and `.installBeside`.
//! A program run by a Run step, because Zig 0.17's build has no custom steps.
//!
//! Usage: `plugin_sdk_install <built artifact> <name> <file name>`. It lands at
//! `<plugins>/<name>/<file name>`, where `<plugins>` is `$FIZZY_PROFILE/plugins` when that is set
//! (a relative profile is taken from the working directory, the plugin's own) and otherwise the
//! host's fizzy plugins directory, the one the editor scans. Read here, at make time, so the
//! build's configure step never depends on the environment.
const std = @import("std");
const builtin = @import("builtin");
const paths = @import("paths.zig");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 4) {
        std.debug.print("usage: plugin_sdk_install <built dylib> <name> <file name>\n", .{});
        std.process.exit(2);
    }
    const src, const name, const file_name = .{ args[1], args[2], args[3] };

    const plugins_dir = pluginsDir(arena, init.environ_map) catch |err| {
        // A bare CI runner has no config home; packaging must not fail on a dev convenience.
        std.log.warn("fizzy: skipping plugin dev install (no config home: {t})", .{err});
        return;
    };
    // This plugin's own `{plugins}/{name}` directory, and whatever above it is missing — a
    // profile's whole tree, the first time a sandbox is built into.
    const dir = try std.fs.path.join(arena, &.{ plugins_dir, name });
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, dir) catch {};

    const dest = try std.fs.path.join(arena, &.{ dir, file_name });
    const data = try cwd.readFileAlloc(io, src, arena, .limited(512 * 1024 * 1024));
    // The source's permissions, so a program installed beside the plugin stays executable.
    const permissions = (try cwd.statFile(io, src, .{})).permissions;
    // Sibling temp file + rename, not a truncating write onto `dest`: a running fizzy may be
    // reading `dest` right now (`PluginLoader.stableLoadCopyPath` copies from it), and on Windows
    // a plain overwrite of a file the editor still has open fails outright. The rename also means
    // a crash mid-write never leaves a half-written dylib at the load path.
    const tmp = try arena.print("{s}.part", .{dest});
    try cwd.writeFile(io, .{ .sub_path = tmp, .data = data, .flags = .{ .permissions = permissions } });
    try std.Io.Dir.rename(cwd, tmp, cwd, dest, io);
    std.log.info("fizzy: installed {s} → {s}", .{ file_name, dest });
}

/// `{local_config}/fizzy/plugins`, mirroring the runtime loader (`core/paths.zig`), or
/// `<profile>/plugins` under `FIZZY_PROFILE` (`app/profile.zig`), so a sandbox build never
/// replaces the plugin a person has installed.
fn pluginsDir(arena: std.mem.Allocator, env: *const std.process.Environ.Map) ![]const u8 {
    if (env.get("FIZZY_PROFILE")) |profile| {
        if (profile.len > 0) return std.fs.path.resolve(arena, &.{ profile, "plugins" });
    }
    const config_root = (try paths.localConfigRoot(
        builtin.target.os.tag,
        arena,
        env.get("HOME"),
        env.get("XDG_CONFIG_HOME"),
        env.get("LOCALAPPDATA"),
    )) orelse return error.NoConfigHome;
    return std.fs.path.join(arena, &.{ config_root, "fizzy", "plugins" });
}
