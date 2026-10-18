const std = @import("std");

const plugin = @import("fizzy_sdk").plugin;

/// Install `{id}.{ext}` flat under a `plugins/` directory (no `lib` prefix).
pub fn attachBuiltinPluginInstall(
    b: *std.Build,
    parent: *std.Build.Step,
    dylib: *std.Build.Step.Compile,
    id: []const u8,
    plugins_dir: std.Build.InstallDir,
) void {
    parent.dependOn(&plugin.installBuiltinPlugin(b, dylib, id, plugins_dir).step);
}

/// Where `dir` is under the install prefix, resolved when the build runs: Zig 0.17 has no
/// install path at configure time.
pub fn installDirPath(dir: std.Build.InstallDir) std.Build.LazyPath {
    return switch (dir) {
        .prefix => .{ .relative = .{ .base = .install_prefix } },
        .lib => .{ .relative = .{ .base = .install_lib } },
        .bin => .{ .relative = .{ .base = .install_bin } },
        .header => .{ .relative = .{ .base = .install_include } },
        .custom => |sub| .{ .relative = .{ .base = .install_prefix, .sub_path = sub } },
    };
}

/// Installed artifacts go under `zig-out/<this>/…` so `packageall` and parallel targets never clobber each other.
pub fn zigOutSubdirForTarget(b: *std.Build, rt: std.Build.ResolvedTarget) []const u8 {
    const arch_name: []const u8 = switch (rt.result.cpu.arch) {
        .x86_64 => "x86-64",
        .aarch64 => "arm64",
        else => @tagName(rt.result.cpu.arch),
    };
    const os_name: []const u8 = switch (rt.result.os.tag) {
        .windows => "windows",
        .linux => "linux",
        .macos => "macos",
        else => @tagName(rt.result.os.tag),
    };
    const base = b.fmt("{s}-{s}", .{ arch_name, os_name });
    if (std.mem.indexOfScalar(u8, base, '_') == null)
        return base;
    const buf = b.allocator.alloc(u8, base.len) catch @panic("OOM");
    @memcpy(buf, base);
    for (buf) |*byte| {
        if (byte.* == '_') byte.* = '-';
    }
    return buf;
}

/// SDL (fizzy's own `sdl` for its backend, dvui's lazy `sdl3` for dvui's) requires SDK layout when
/// `-Dtarget=*-macos` is not "native".
pub const MacosSdlPaths = struct {
    include: std.Build.LazyPath,
    framework: std.Build.LazyPath,
    lib: std.Build.LazyPath,
};

/// `-Dmacos-sdk`, else `xcrun`. Not `SDKROOT`: Zig 0.17 caches the build's configuration without
/// regard to the environment.
fn resolveMacosSdkPath(b: *std.Build, explicit: ?[]const u8) ![]const u8 {
    if (explicit) |sdk| {
        const trimmed = std.mem.trim(u8, sdk, " \t\r\n");
        if (trimmed.len > 0) return b.dupePath(trimmed);
    }

    const argv: []const []const u8 = &.{
        "xcrun",
        "--sdk",
        "macosx",
        "--show-sdk-path",
    };
    const run = try std.process.run(b.allocator, b.graph.io, .{
        .argv = argv,
        .stdout_limit = std.Io.Limit.limited(4096),
        .stderr_limit = std.Io.Limit.limited(4096),
    });
    defer {
        b.allocator.free(run.stdout);
        b.allocator.free(run.stderr);
    }
    switch (run.term) {
        .exited => |code| if (code != 0) {
            std.log.err("SDL on macOS: explicit -Dtarget=*-macos needs an SDK path. xcrun exited with code {d}. Install Xcode Command Line Tools or pass -Dmacos-sdk=<path>.", .{code});
            return error.MacosSdkPath;
        },
        else => {
            std.log.err("SDL on macOS: xcrun --show-sdk-path failed", .{});
            return error.MacosSdkPath;
        },
    }
    const path = std.mem.trimEnd(u8, run.stdout, " \t\r\n");
    if (path.len == 0) return error.MacosSdkPath;
    return b.dupePath(path);
}

pub fn macosSdlPathsForExplicitTarget(b: *std.Build, target: std.Build.ResolvedTarget, macos_sdk: ?[]const u8) !?MacosSdlPaths {
    if (target.result.os.tag != .macos) return null;
    if (b.graph.host.result.os.tag != .macos) return null;
    if (target.query.isNative()) return null;

    const sdk = try resolveMacosSdkPath(b, macos_sdk);
    return MacosSdlPaths{
        .include = .{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/include" }) },
        .framework = .{ .cwd_relative = b.pathJoin(&.{ sdk, "System/Library/Frameworks" }) },
        .lib = .{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/lib" }) },
    };
}

/// Declare to Zig 0.17's configure cache that the build read whether `rel` exists: the file itself
/// when it does, and otherwise the nearest directory that exists, since the maker cannot load a
/// configuration that depends on a path inside a missing directory ("configuration failed:
/// FileSystemFailure"). Making the file changes that directory, so the build still reconfigures.
pub fn dependOnPathExistence(b: *std.Build, rel: []const u8) void {
    b.root.access(b.graph.io, rel, .{}) catch {
        var dir = std.fs.path.dirname(rel);
        while (dir) |d| : (dir = std.fs.path.dirname(d)) {
            b.root.access(b.graph.io, d, .{}) catch continue;
            return b.dependOnDirectoryMetadata(b.path(d));
        }
        return b.dependOnDirectoryMetadata(b.path("."));
    };
    b.dependOnFileMetadata(b.path(rel));
}
