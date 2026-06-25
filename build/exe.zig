const std = @import("std");
const dvui = @import("dvui");
const velopack = @import("velopack_zig");
const plugin = @import("../plugin_sdk.zig");
const common = @import("common.zig");
const plugins = @import("plugins.zig");
const sdk = @import("sdk.zig");

const pixi_plugin = plugins.pixi;
const workbench_plugin = plugins.workbench;
const code_plugin = plugins.code;
const example_plugin = plugins.example;
const ZipPackage = plugins.ZipPackage;
const MacosSdlPaths = common.MacosSdlPaths;

/// Install stripped exe + built-in plugin dylibs for `vpk pack --packDir`.
pub fn addVelopackPackDirInstall(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    fizzy: FizzyExecutable,
    pack_input_subdir: []const u8,
    pack_plugins_subdir: []const u8,
    after_step: *std.Build.Step,
) *std.Build.Step {
    const pack_exe_install_dir: std.Build.InstallDir = .{ .custom = pack_input_subdir };
    const pack_plugins_install_dir: std.Build.InstallDir = .{ .custom = pack_plugins_subdir };

    const install_pack_exe = b.addInstallArtifact(exe, .{
        .dest_dir = .{ .override = pack_exe_install_dir },
    });
    install_pack_exe.step.dependOn(after_step);

    var tail: *std.Build.Step = &install_pack_exe.step;

    if (fizzy.pixi_dylib) |dylib| {
        const install_pixi = plugin.installBuiltinPlugin(b, dylib, "pixi", pack_plugins_install_dir);
        install_pixi.step.dependOn(tail);
        tail = &install_pixi.step;
    }
    if (fizzy.workbench_dylib) |dylib| {
        const install_workbench = plugin.installBuiltinPlugin(b, dylib, "workbench", pack_plugins_install_dir);
        install_workbench.step.dependOn(tail);
        tail = &install_workbench.step;
    }
    if (fizzy.code_dylib) |dylib| {
        const install_code = plugin.installBuiltinPlugin(b, dylib, "code", pack_plugins_install_dir);
        install_code.step.dependOn(tail);
        tail = &install_code.step;
    }

    return tail;
}

pub const FizzyExecutable = struct {
    exe: *std.Build.Step.Compile,
    zstbi_module: *std.Build.Module,
    msf_gif_module: *std.Build.Module,
    known_folders: *std.Build.Module,
    sdk_module: *std.Build.Module,
    /// Native-only; `null` on wasm targets.
    pixi_dylib: ?*std.Build.Step.Compile = null,
    workbench_dylib: ?*std.Build.Step.Compile = null,
    code_dylib: ?*std.Build.Step.Compile = null,
};

pub fn addFizzyExecutableForTarget(
    b: *std.Build,
    resolved_target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    accesskit: dvui.AccesskitOptions,
    build_opts: *std.Build.Step.Options,
    workbench_opts: *std.Build.Step.Options,
    zip_pkg: ZipPackage,
    assets_module: *std.Build.Module,
    process_assets_step: *std.Build.Step,
    macos_sdl_paths: ?MacosSdlPaths,
    velopack_enabled: bool,
) !FizzyExecutable {
    const dvui_dep = if (macos_sdl_paths) |p|
        b.dependency("dvui", .{
            .target = resolved_target,
            .optimize = optimize,
            .backend = .sdl3,
            .accesskit = accesskit,
            .system_include_path = p.include,
            .system_framework_path = p.framework,
            .library_path = p.lib,
        })
    else
        b.dependency("dvui", .{ .target = resolved_target, .optimize = optimize, .backend = .sdl3, .accesskit = accesskit });

    const dvui_proxy_dep = b.dependency("dvui", .{
        .target = resolved_target,
        .optimize = optimize,
        .backend = .proxy,
        .accesskit = .off,
    });
    const dvui_proxy_mod = dvui_proxy_dep.module("dvui_proxy");
    const proxy_bridge_host_mod = sdk.addProxyBridgeModule(b, resolved_target, optimize, dvui_dep, dvui_dep.module("dvui_sdl3"));
    const proxy_bridge_plugin_mod = dvui_proxy_dep.module("proxy_bridge");

    const zstbi_module = pixi_plugin.addZstbiModule(b, resolved_target, optimize, false);
    const msf_gif_module = pixi_plugin.addMsfGifModule(b, resolved_target, optimize, false);

    const exe = b.addExecutable(.{
        .name = "fizzy",
        .root_module = b.addModule("App", .{
            .target = resolved_target,
            .optimize = optimize,
            .root_source_file = .{ .cwd_relative = "src/App.zig" },
        }),
    });
    exe.root_module.strip = false;

    exe.root_module.addImport("assets", assets_module);
    const known_folders = b.dependency("known_folders", .{
        .target = resolved_target,
        .optimize = optimize,
    }).module("known-folders");
    exe.root_module.addImport("known-folders", known_folders);
    exe.root_module.addOptions("build_opts", build_opts);
    exe.step.dependOn(process_assets_step);

    if (optimize != .Debug) {
        switch (resolved_target.result.os.tag) {
            .windows => {
                exe.subsystem = .Windows;
                // MSVC's libcmt links `WinMainCRTStartup` (needs `WinMain`) for /SUBSYSTEM:WINDOWS.
                // Fizzy exposes `main`, so force the C `main` entry which works for either subsystem.
                if (resolved_target.result.abi == .msvc) {
                    exe.entry = .{ .symbol_name = "mainCRTStartup" };
                }
            },
            else => exe.subsystem = .Posix,
        }
    }

    exe.root_module.addImport("zstbi", zstbi_module);
    exe.root_module.addImport("msf_gif", msf_gif_module);
    exe.root_module.addImport("zip", zip_pkg.module);
    exe.root_module.addImport("dvui", dvui_dep.module("dvui_sdl3"));
    exe.root_module.addImport("backend", dvui_dep.module("sdl3"));

    // Shared `core` module (gfx/math/fs/generated atlas/platform/paths/dvui hub +
    // generic widgets). Imports only `dvui`, `icons`, and `known-folders`.
    const core_module = b.createModule(.{
        .target = resolved_target,
        .optimize = optimize,
        .root_source_file = b.path("src/core/core.zig"),
    });
    core_module.addImport("dvui", dvui_dep.module("dvui_sdl3"));
    core_module.addImport("known-folders", known_folders);
    exe.root_module.addImport("core", core_module);

    var icons_module: ?*std.Build.Module = null;
    if (b.lazyDependency("icons", .{ .target = resolved_target, .optimize = optimize })) |dep| {
        exe.root_module.addImport("icons", dep.module("icons"));
        core_module.addImport("icons", dep.module("icons"));
        icons_module = dep.module("icons");
    }

    const core_proxy_module = b.createModule(.{
        .target = resolved_target,
        .optimize = optimize,
        .root_source_file = b.path("src/core/core.zig"),
    });
    core_proxy_module.addImport("dvui", dvui_proxy_mod);
    core_proxy_module.addImport("known-folders", known_folders);
    if (icons_module) |icons| core_proxy_module.addImport("icons", icons);

    const sdk_module = sdk.wireSdkModule(b, resolved_target, optimize, dvui_dep.module("dvui_sdl3"), proxy_bridge_host_mod, core_module, exe.root_module);
    const sdk_proxy_module = sdk.wireSdkModule(b, resolved_target, optimize, dvui_proxy_mod, proxy_bridge_plugin_mod, core_proxy_module, null);
    _ = pixi_plugin.addStaticModule(b, resolved_target, optimize, .{
        .dvui = dvui_dep.module("dvui_sdl3"),
        .core = core_module,
        .sdk = sdk_module,
        .assets = assets_module,
        .zip = zip_pkg.module,
        .zstbi = zstbi_module,
        .msf_gif = msf_gif_module,
        .icons = icons_module,
        .backend = dvui_dep.module("sdl3"),
    }, exe.root_module);
    _ = workbench_plugin.addStaticModule(b, resolved_target, optimize, .{
        .dvui = dvui_dep.module("dvui_sdl3"),
        .core = core_module,
        .sdk = sdk_module,
        .icons = icons_module,
        .backend = dvui_dep.module("sdl3"),
    }, workbench_opts, exe.root_module);
    _ = code_plugin.addStaticModule(b, resolved_target, optimize, .{
        .dvui = dvui_dep.module("dvui_sdl3"),
        .core = core_module,
        .sdk = sdk_module,
    }, exe.root_module);
    _ = example_plugin.addStaticModule(b, resolved_target, optimize, .{
        .dvui = dvui_dep.module("dvui_sdl3"),
        .core = core_module,
        .sdk = sdk_module,
    }, exe.root_module);

    const pixi_dylib: ?*std.Build.Step.Compile = if (resolved_target.result.cpu.arch != .wasm32) blk: {
        const dylib = pixi_plugin.addDylib(b, resolved_target, optimize, .{
            .dvui = dvui_proxy_mod,
            .core = core_proxy_module,
            .sdk = sdk_proxy_module,
            .proxy_bridge = proxy_bridge_plugin_mod,
            .assets = assets_module,
            .zip = zip_pkg.module,
            .zstbi = zstbi_module,
            .msf_gif = msf_gif_module,
            .icons = icons_module,
            .backend = null,
        });
        pixi_plugin.linkZipNative(dylib);
        break :blk dylib;
    } else null;

    const workbench_dylib: ?*std.Build.Step.Compile = if (resolved_target.result.cpu.arch != .wasm32) blk: {
        break :blk workbench_plugin.addDylib(b, resolved_target, optimize, .{
            .dvui = dvui_proxy_mod,
            .core = core_proxy_module,
            .sdk = sdk_proxy_module,
            .proxy_bridge = proxy_bridge_plugin_mod,
            .icons = icons_module,
            .backend = null,
        }, workbench_opts);
    } else null;

    const code_dylib: ?*std.Build.Step.Compile = if (resolved_target.result.cpu.arch != .wasm32) blk: {
        break :blk code_plugin.addDylib(b, resolved_target, optimize, .{
            .dvui = dvui_proxy_mod,
            .core = core_proxy_module,
            .sdk = sdk_proxy_module,
            .proxy_bridge = proxy_bridge_plugin_mod,
        });
    } else null;

    const singleton_app_dep = b.dependency("dvui_singleton_app", .{
        .target = resolved_target,
        .optimize = optimize,
    });
    exe.root_module.addImport("singleton_app", singleton_app_dep.module("singleton_app"));

    if (resolved_target.result.os.tag == .macos) {
        if (macos_sdl_paths) |p| {
            // Non-"native" macOS targets (`-Dtarget=aarch64-macos` on Apple Silicon, etc.) need the
            // same SDK layout for Obj-C sources as for SDL; zig-objc paths do not always reach .m
            // compiles (e.g. Security.framework → <libDER/DERItem.h>).
            exe.root_module.addSystemIncludePath(p.include);
            exe.root_module.addSystemFrameworkPath(p.framework);
            exe.root_module.addLibraryPath(p.lib);
        }
        if (b.lazyDependency("zig_objc", .{
            .target = resolved_target,
            .optimize = optimize,
        })) |dep| {
            exe.root_module.addImport("objc", dep.module("objc"));
        }
        exe.root_module.addCSourceFile(.{ .file = std.Build.path(b, "src/backend/objc/FizzyVisualEffectView.m") });
        exe.root_module.addCSourceFile(.{ .file = std.Build.path(b, "src/backend/objc/FizzyMenuTarget.m") });
        exe.root_module.addCSourceFile(.{ .file = std.Build.path(b, "src/backend/objc/FizzyTrackpadGesture.m") });
        exe.root_module.addCSourceFile(.{ .file = std.Build.path(b, "src/backend/objc/FizzyWindowMonitor.m") });
    } else if (resolved_target.result.os.tag == .windows) {
        if (b.lazyDependency("zigwin32", .{})) |dep| {
            exe.root_module.addImport("win32", dep.module("win32"));
        }
        exe.root_module.linkSystemLibrary("comctl32", .{});

        // Embed assets/windows/fizzy.rc -> fizzy.ico into the exe so Explorer,
        // Taskbar, Alt-Tab and the Velopack-generated Start Menu shortcut all
        // show the right icon without any runtime work. fizzy.ico must be a
        // multi-resolution ICO with 16/32/48/256 px frames (see the README in
        // that directory).
        exe.root_module.addWin32ResourceFile(.{
            .file = b.path("assets/windows/fizzy.rc"),
        });
    }

    // Zig's bundled libc++/libcxxabi cannot compile against MSVC headers
    // (vcruntime_typeinfo.h's ::type_info vs libc++'s own, redefined bad_cast,
    // etc.). We always feed MSVC's own STL via --libc for *-windows-msvc — on a
    // cross host and on a native Windows host using .velopack-msvc alike — so
    // libc++ must be off for the msvc ABI regardless of host.
    const exe_is_windows_msvc = resolved_target.result.os.tag == .windows and
        resolved_target.result.abi == .msvc;
    exe.root_module.link_libcpp = !exe_is_windows_msvc;
    pixi_plugin.linkZipNative(exe);
    if (velopack_enabled) {
        try velopack.linkVelopack(b, exe, .{ .target = resolved_target, .optimize = optimize });
    }

    return .{
        .exe = exe,
        .zstbi_module = zstbi_module,
        .msf_gif_module = msf_gif_module,
        .known_folders = known_folders,
        .sdk_module = sdk_module,
        .pixi_dylib = pixi_dylib,
        .workbench_dylib = workbench_dylib,
        .code_dylib = code_dylib,
    };
}
