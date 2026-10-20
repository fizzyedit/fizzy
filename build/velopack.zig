//! Vendored Velopack build glue for the fizzy app build.
//!
//! Mirrors graphl-tech/velopack-zig's `build.zig`; keep in sync if that repo's layout changes.
//! Vendored rather than `@import("velopack_zig")`, which would make the lazy dependency eager in
//! every consumer (AGENTS.md, "Keep the plugin build free of app-only dependencies").
const std = @import("std");
const builtin = @import("builtin");
const common = @import("common.zig");

/// The resolved `velopack_zig` dependency (from `b.lazyDependency("velopack_zig", .{})`).
/// `vz.builder` is velopack-zig's own builder — the equivalent of velopack-zig's internal
/// `ownBuilder(b)` — used to reach its bundled deps + tool sources.
pub const Dep = *std.Build.Dependency;

var trim_velopack_tool: ?*std.Build.Step.Compile = null;
var run_env_tool: ?*std.Build.Step.Compile = null;
var c_modules_given: std.AutoHashMapUnmanaged(*std.Build.Module, void) = .empty;
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
            .optimize = .debug,
        }),
    });
    trim_velopack_tool = t;
    return t;
}

/// velopack-zig's `tools/run_env.zig`: runs a command with environment changes applied when it
/// runs. Zig 0.17's `Run.setEnvironmentVariable` copies the whole configure-time environment into
/// the cached configuration, so a variable set later never reaches the command; and
/// `Run.addPathDir` is gone. Every command here that needs its environment changed goes through it.
fn runEnvTool(vz: Dep) *std.Build.Step.Compile {
    if (run_env_tool) |t| return t;
    const own = vz.builder;
    const t = own.addExecutable(.{
        .name = "run-env",
        .root_module = own.createModule(.{
            .root_source_file = vz.path("tools/run_env.zig"),
            .target = own.graph.host,
            .optimize = .debug,
        }),
    });
    run_env_tool = t;
    return t;
}

/// `dotnet vpk`, for `vpk pack` and the arguments the caller adds: with `DOTNET_ROLL_FORWARD`
/// (vpk targets an older .NET than is typically installed) and, for a Linux target, the bundled
/// `mksquashfs` on its PATH (for the AppImage).
pub fn addVpkRun(b: *std.Build, vz: Dep, target: std.Build.ResolvedTarget) !*std.Build.Step.Run {
    const run = b.addRunArtifact(runEnvTool(vz));
    run.addArgs(&.{ "--env", "DOTNET_ROLL_FORWARD=Major" });
    if (target.result.os.tag == .linux) if (try buildMksquashfs(vz)) |m| {
        run.addArg("--path");
        run.addDirectoryArg(m.bin_dir);
    };
    run.addArgs(&.{ "--", "dotnet", "vpk" });
    return run;
}

/// `Velopack.h` as a Zig module, through translate-c: Zig 0.17 removed `@cImport`. Imported as
/// `velopack_c` by the modules `linkVelopack` is given.
fn velopackCModule(b: *std.Build, vz: Dep, target: std.Build.ResolvedTarget, optimize: std.lang.OptimizeMode) *std.Build.Module {
    const tc = b.addTranslateC(.{
        .root_source_file = vz.builder.dependency("velopack", .{}).path("include/Velopack.h"),
        .target = target,
        .optimize = optimize,
    });
    return tc.createModule();
}

pub const LinkVelopackOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.lang.OptimizeMode,
    /// Modules that call Velopack's C API (the `app` module's updater does): each gets
    /// `Velopack.h` as the `velopack_c` import.
    c_modules: []const *std.Build.Module = &.{},
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

    // Once per module: the integration, demo and bench tests share one `app` module.
    for (opts.c_modules) |m| {
        const gop = c_modules_given.getOrPut(b.allocator, m) catch @panic("OOM");
        if (!gop.found_existing) m.addImport("velopack_c", velopackCModule(b, vz, target, opts.optimize));
    }

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
    /// The directory holding `mksquashfs`, resolved when the build runs.
    bin_dir: std.Build.LazyPath,
};

/// Build the bundled mksquashfs for Linux AppImage packaging. Returns null on Windows hosts and
/// on the first build before the lazy `squashfs` dep is fetched.
pub fn buildMksquashfs(vz: Dep) !?MksquashfsBuild {
    const own = vz.builder;
    if (own.graph.host.result.os.tag == .windows) return null;
    const dep = own.lazyDependency("squashfs", .{
        .target = own.graph.host,
        .optimize = .fast,
    }) orelse return null;
    return .{ .bin_dir = dep.artifact("mksquashfs").getEmittedBin().dirname() };
}

/// Install MSVC + Windows SDK into `<build_root>/<install_dir>` and emit zig-libc-*.ini,
/// via velopack-zig's bundled setup scripts.
pub fn addMsvcupSetupStep(
    b: *std.Build,
    vz: Dep,
    install_dir: ?[]const u8,
) *std.Build.Step.Run {
    const resolved_install_dir: []const u8 = if (install_dir) |p|
        if (std.fs.path.isAbsolute(p)) b.dupePath(p) else (b.root.joinString(b.allocator, p) catch @panic("OOM"))
    else
        (b.root.joinString(b.allocator, ".velopack-msvc") catch @panic("OOM"));

    const env_path = vz.builder.root.joinString(b.allocator, "tools/msvcup.env") catch |e|
        std.debug.panic("velopack: resolve msvcup.env: {}", .{e});
    const gen_path = vz.builder.root.joinString(b.allocator, "tools/gen_zig_libc_msvc.zig") catch |e|
        std.debug.panic("velopack: resolve gen_zig_libc_msvc.zig: {}", .{e});

    // Through `run_env`, not `setEnvironmentVariable` (see `runEnvTool`).
    const run = b.addRunArtifact(runEnvTool(vz));
    run.addArgs(&.{
        "--env", b.fmt("VELOPACK_ZIG_ENV_FILE={s}", .{env_path}),
        "--env", b.fmt("VELOPACK_ZIG_GEN_SCRIPT={s}", .{gen_path}),
        "--env", b.fmt("VELOPACK_ZIG_ZIG={s}", .{b.graph.zig_exe}),
        "--",
    });
    switch (builtin.target.os.tag) {
        .windows => {
            const script_path = vz.builder.root.joinString(b.allocator, "tools/setup-msvc.ps1") catch |e|
                std.debug.panic("velopack: resolve setup-msvc.ps1: {}", .{e});
            run.addArgs(&.{
                "powershell", "-NoProfile", "-ExecutionPolicy",   "Bypass",
                "-File",      script_path,  resolved_install_dir,
            });
        },
        else => {
            const script_path = vz.builder.root.joinString(b.allocator, "tools/setup-msvc.sh") catch |e|
                std.debug.panic("velopack: resolve setup-msvc.sh: {}", .{e});
            run.addArgs(&.{ "bash", script_path, resolved_install_dir });
        },
    }
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
        const abs = if (std.fs.path.isAbsolute(p)) b.dupePath(p) else (b.root.joinString(b.allocator, p) catch @panic("OOM"));
        b.dependOnFileContents(b.graph.cwdRelativePath(abs));
        return .{ .libc_path = abs, .needs_setup = false };
    }

    const arch_suffix: []const u8 = switch (target.result.cpu.arch) {
        .x86_64 => "x64",
        .aarch64 => "arm64",
        else => return .{ .libc_path = null, .needs_setup = false },
    };
    const rel = b.fmt("{s}/zig-libc-{s}.ini", .{ opts.install_dir_name, arch_suffix });

    common.dependOnPathExistence(b, rel);
    const exists = blk: {
        b.root.access(b.graph.io, rel, .{}) catch break :blk false;
        break :blk true;
    };

    if (exists) return .{ .libc_path = (b.root.joinString(b.allocator, rel) catch @panic("OOM")), .needs_setup = false };
    if (opts.fetch_if_missing) return .{ .libc_path = (b.root.joinString(b.allocator, rel) catch @panic("OOM")), .needs_setup = true };
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
