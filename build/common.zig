const std = @import("std");

const plugin = @import("../plugin_sdk.zig");
const update = @import("../update.zig");
const GitDependency = update.GitDependency;

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

pub fn addUpdateStep(b: *std.Build) void {
    const step = b.step("update", "update git dependencies");
    step.makeFn = updateStep;
}

fn updateStep(step: *std.Build.Step, _: std.Build.Step.MakeOptions) !void {
    const deps = &.{
        GitDependency{
            .url = "https://github.com/foxnne/zig-objc",
            .branch = "main",
        },
        GitDependency{
            .url = "https://github.com/kristoff-it/zigwin32",
            .branch = "fix/zig16",
        },
        GitDependency{
            .url = "https://github.com/foxnne/zig-lib-icons",
            .branch = "dvui",
        },
        GitDependency{
            .url = "https://github.com/foxnne/dvui-dev",
            .branch = "main",
        },
    };
    try update.update_dependency(step.owner.allocator, step.owner.graph.io, deps);
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

/// SDL (via dvui → lazy `sdl3`) requires SDK layout when `-Dtarget=*-macos` is not "native".
pub const MacosSdlPaths = struct {
    include: std.Build.LazyPath,
    framework: std.Build.LazyPath,
    lib: std.Build.LazyPath,
};

fn resolveMacosSdkPath(b: *std.Build) ![]const u8 {
    if (b.graph.environ_map.get("SDKROOT")) |sdk| {
        const trimmed = std.mem.trim(u8, sdk, " \t\r\n");
        if (trimmed.len > 0) {
            return b.dupePath(trimmed);
        }
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
            std.log.err("SDL on macOS: explicit -Dtarget=*-macos needs an SDK path. xcrun exited with code {d}. Install Xcode Command Line Tools or set SDKROOT.", .{code});
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

pub fn macosSdlPathsForExplicitTarget(b: *std.Build, target: std.Build.ResolvedTarget) !?MacosSdlPaths {
    if (target.result.os.tag != .macos) return null;
    if (b.graph.host.result.os.tag != .macos) return null;
    if (target.query.isNative()) return null;

    const sdk = try resolveMacosSdkPath(b);
    return MacosSdlPaths{
        .include = .{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/include" }) },
        .framework = .{ .cwd_relative = b.pathJoin(&.{ sdk, "System/Library/Frameworks" }) },
        .lib = .{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/lib" }) },
    };
}
