//! Vendored Velopack build glue for the fizzy app build.
//!
//! Mirrors `~/dev/velopack-zig/build.zig`; keep in sync if that repo's layout changes.
const std = @import("std");
const builtin = @import("builtin");

/// The resolved `velopack_zig` dependency (from `b.lazyDependency("velopack_zig", .{})`).
/// `vz.builder` is velopack-zig's own builder — the equivalent of velopack-zig's internal
/// `ownBuilder(b)` — used to reach its bundled deps + tool sources.
pub const Dep = *std.Build.Dependency;

var trim_velopack_tool: ?*std.Build.Step.Compile = null;
var dotnet_restore_cache: std.AutoHashMapUnmanaged(*std.Build, *std.Build.Step.Run) = .{};

fn cachedDotnetToolRestore(b: *std.Build) *std.Build.Step.Run {
    const gop = dotnet_restore_cache.getOrPut(b.allocator, b) catch @panic("OOM");
    if (!gop.found_existing) {
        // `.config/dotnet-tools.json` lives at the fizzy repo root (== `b` here).
        const r = b.addSystemCommand(&.{ "dotnet", "tool", "restore" });
        r.setCwd(b.path("."));
        gop.value_ptr.* = r;
    }
    return gop.value_ptr.*;
}

fn trimVelopackLibTool(vz: Dep) *std.Build.Step.Compile {
    if (trim_velopack_tool) |t| return t;
    const own = vz.builder;
    const t = own.addExecutable(.{
        .name = "trim-velopack-lib",
        .root_module = own.createModule(.{
            .root_source_file = vz.path("tools/trim_velopack_lib.zig"),
            .target = own.graph.host,
            .optimize = .Debug,
        }),
    });
    trim_velopack_tool = t;
    return t;
}

pub const LinkVelopackOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
};

/// Add include path + the correct prebuilt static lib + Windows ws2_32/bcrypt +
/// macOS @loader_path / Linux $ORIGIN rpath, and attach a cached `dotnet tool restore`.
pub fn linkVelopack(
    b: *std.Build,
    vz: Dep,
    compile: *std.Build.Step.Compile,
    opts: LinkVelopackOptions,
) !void {
    const velopack_dep = vz.builder.dependency("velopack", .{});
    const target = opts.target;

    compile.root_module.addIncludePath(velopack_dep.path("include"));

    const lib_name = switch (target.result.os.tag) {
        .linux => switch (target.result.cpu.arch) {
            .x86_64 => "velopack_libc_linux_x64_gnu.a",
            .aarch64 => "velopack_libc_linux_arm64_gnu.a",
            else => @panic("velopack: unsupported linux arch"),
        },
        .macos => switch (target.result.cpu.arch) {
            .x86_64 => "velopack_libc_osx_x64_gnu.a",
            .aarch64 => "velopack_libc_osx_arm64_gnu.a",
            else => @panic("velopack: unsupported macos arch"),
        },
        .windows => switch (target.result.cpu.arch) {
            .x86_64 => "velopack_libc_win_x64_msvc.lib",
            .aarch64 => "velopack_libc_win_arm64_msvc.lib",
            .x86 => "velopack_libc_win_x86_msvc.lib",
            else => @panic("velopack: unsupported windows arch"),
        },
        else => @panic("velopack: unsupported OS"),
    };
    const lib_src = velopack_dep.path(b.fmt("lib-static/{s}", .{lib_name}));

    if (target.result.os.tag == .windows and target.result.abi == .msvc) {
        // Copy the read-only dep file into a writable WriteFiles output, then trim
        // duplicate `compiler_builtins-*` members with `zig ar` (Velopack's Rust libs
        // collide with Zig's compiler_rt at link time).
        const wf = b.addWriteFiles();
        const lib_copy = wf.addCopyFile(lib_src, lib_name);
        const trim = b.addRunArtifact(trimVelopackLibTool(vz));
        trim.addArg(b.graph.zig_exe);
        trim.addFileArg(lib_copy);
        trim.step.dependOn(&wf.step);
        compile.root_module.addObjectFile(lib_copy);
        compile.step.dependOn(&trim.step);
    } else {
        compile.root_module.addObjectFile(lib_src);
    }

    if (target.result.os.tag == .windows) {
        compile.root_module.linkSystemLibrary("ws2_32", .{});
        compile.root_module.linkSystemLibrary("bcrypt", .{});
    }
    switch (target.result.os.tag) {
        .linux => {
            compile.root_module.addRPathSpecial("$ORIGIN");
            compile.root_module.linkSystemLibrary("gcc_s", .{});
        },
        .macos => compile.root_module.addRPathSpecial("@loader_path"),
        else => {},
    }

    compile.step.dependOn(&cachedDotnetToolRestore(b).step);
}

pub const MksquashfsBuild = struct {
    step: *std.Build.Step,
    bin_dir: []const u8,
};

/// Build the bundled mksquashfs for Linux AppImage packaging. Returns null on
/// non-Linux hosts and on the first build before the lazy `squashfs` dep is fetched.
pub fn buildMksquashfs(b: *std.Build, vz: Dep) !?MksquashfsBuild {
    const own = vz.builder;
    if (own.graph.host.result.os.tag == .windows) return null;

    const dep = own.lazyDependency("squashfs", .{
        .target = own.graph.host,
        .optimize = .ReleaseFast,
    }) orelse return null;

    const mksquashfs_art = dep.artifact("mksquashfs");
    const install_mksquashfs = b.addInstallArtifact(mksquashfs_art, .{
        .dest_dir = .{ .override = .{ .custom = "velopack-mksquashfs" } },
    });

    return MksquashfsBuild{
        .step = &install_mksquashfs.step,
        .bin_dir = b.getInstallPath(.{ .custom = "velopack-mksquashfs" }, ""),
    };
}

/// Wire the bundled mksquashfs into a `vpk pack` Run for Linux targets (no-op otherwise).
pub fn attachMksquashfsToVpkRun(
    b: *std.Build,
    vz: Dep,
    run: *std.Build.Step.Run,
    target: std.Build.ResolvedTarget,
) !void {
    if (target.result.os.tag != .linux) return;
    const built = (try buildMksquashfs(b, vz)) orelse return;
    run.addPathDir(built.bin_dir);
    run.step.dependOn(built.step);
}

/// Install MSVC + Windows SDK into `<build_root>/<install_dir>` and emit zig-libc-*.ini,
/// via velopack-zig's bundled setup scripts.
pub fn addMsvcupSetupStep(
    b: *std.Build,
    vz: Dep,
    install_dir: ?[]const u8,
) *std.Build.Step.Run {
    const resolved_install_dir: []const u8 = if (install_dir) |p|
        if (std.fs.path.isAbsolute(p)) b.dupePath(p) else b.pathFromRoot(p)
    else
        b.pathFromRoot(".velopack-msvc");

    const env_path = vz.path("tools/msvcup.env").getPath3(b, null).toString(b.allocator) catch |e|
        std.debug.panic("velopack: resolve msvcup.env: {}", .{e});
    const gen_path = vz.path("tools/gen_zig_libc_msvc.zig").getPath3(b, null).toString(b.allocator) catch |e|
        std.debug.panic("velopack: resolve gen_zig_libc_msvc.zig: {}", .{e});

    const run: *std.Build.Step.Run = switch (builtin.os.tag) {
        .windows => blk: {
            const script_path = vz.path("tools/setup-msvc.ps1").getPath3(b, null).toString(b.allocator) catch |e|
                std.debug.panic("velopack: resolve setup-msvc.ps1: {}", .{e});
            break :blk b.addSystemCommand(&.{
                "powershell", "-NoProfile", "-ExecutionPolicy",   "Bypass",
                "-File",      script_path,  resolved_install_dir,
            });
        },
        else => blk: {
            const script_path = vz.path("tools/setup-msvc.sh").getPath3(b, null).toString(b.allocator) catch |e|
                std.debug.panic("velopack: resolve setup-msvc.sh: {}", .{e});
            break :blk b.addSystemCommand(&.{ "bash", script_path, resolved_install_dir });
        },
    };
    run.setEnvironmentVariable("VELOPACK_ZIG_ENV_FILE", env_path);
    run.setEnvironmentVariable("VELOPACK_ZIG_GEN_SCRIPT", gen_path);
    run.setEnvironmentVariable("VELOPACK_ZIG_ZIG", b.graph.zig_exe);
    return run;
}

pub const ResolveWindowsMsvcLibcOptions = struct {
    explicit_path: ?[]const u8 = null,
    install_dir_name: []const u8 = ".velopack-msvc",
    fetch_if_missing: bool = false,
};

pub const ResolvedWindowsMsvcLibc = struct {
    libc_path: ?[]const u8,
    needs_setup: bool,
};

/// Locate the right zig-libc-*.ini for *-windows-msvc. Pure path logic — does NOT need
/// the velopack_zig dependency, so it is safe to call before (or without) resolving Velopack.
pub fn resolveWindowsMsvcLibc(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    opts: ResolveWindowsMsvcLibcOptions,
) ResolvedWindowsMsvcLibc {
    if (target.result.os.tag != .windows or target.result.abi != .msvc)
        return .{ .libc_path = null, .needs_setup = false };

    if (opts.explicit_path) |p| {
        const abs = if (std.fs.path.isAbsolute(p)) b.dupePath(p) else b.pathFromRoot(p);
        return .{ .libc_path = abs, .needs_setup = false };
    }

    const arch_suffix: []const u8 = switch (target.result.cpu.arch) {
        .x86_64 => "x64",
        .aarch64 => "arm64",
        else => return .{ .libc_path = null, .needs_setup = false },
    };
    const rel = b.fmt("{s}/zig-libc-{s}.ini", .{ opts.install_dir_name, arch_suffix });

    const exists = blk: {
        b.build_root.handle.access(b.graph.io, rel, .{}) catch break :blk false;
        break :blk true;
    };

    if (exists) return .{ .libc_path = b.pathFromRoot(rel), .needs_setup = false };
    if (opts.fetch_if_missing) return .{ .libc_path = b.pathFromRoot(rel), .needs_setup = true };
    return .{ .libc_path = null, .needs_setup = false };
}

/// Apply a zig-libc INI to every reachable *-windows-msvc compile. Pure — no velopack dep.
pub fn applyWindowsMsvcLibcRecursive(
    b: *std.Build,
    roots: []const *std.Build.Step.Compile,
    libc_lp: std.Build.LazyPath,
) void {
    var seen = std.AutoHashMap(*std.Build.Step.Compile, void).init(b.allocator);
    defer seen.deinit();
    for (roots) |root| {
        const compiles = std.Build.Step.Compile.getCompileDependencies(root, true);
        for (compiles) |c| {
            const gop = seen.getOrPut(c) catch @panic("OOM");
            if (gop.found_existing) continue;
            const rt = c.root_module.resolved_target orelse continue;
            if (rt.result.os.tag == .windows and rt.result.abi == .msvc) {
                c.setLibCFile(libc_lp);
            }
        }
    }
}
