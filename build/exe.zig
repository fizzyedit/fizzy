const std = @import("std");
// dvui's build API via the SDK package, which owns the repo's only dvui pin.
const dvui = @import("fizzy_sdk").dvui;
// Vendored Velopack glue — see build/velopack.zig header (never `@import("velopack_zig")`).
const velopack = @import("velopack.zig");
const plugin = @import("fizzy_sdk").plugin;
const core_mod = @import("fizzy_sdk").core_module;
const common = @import("common.zig");
const plugins = @import("plugins.zig");
const sdk = @import("sdk.zig");

const workbench_plugin = plugins.workbench;
const text_plugin = plugins.text;
const markdown_plugin = plugins.markdown;
const image_plugin = plugins.image;
const archive_plugin = plugins.archive;
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

    if (fizzy.workbench_dylib) |dylib| {
        const install_workbench = plugin.installBuiltinPlugin(b, dylib, "workbench", pack_plugins_install_dir);
        install_workbench.step.dependOn(tail);
        tail = &install_workbench.step;
    }
    if (fizzy.text_dylib) |dylib| {
        const install_text = plugin.installBuiltinPlugin(b, dylib, "text", pack_plugins_install_dir);
        install_text.step.dependOn(tail);
        tail = &install_text.step;
    }
    if (fizzy.markdown_dylib) |dylib| {
        const install_markdown = plugin.installBuiltinPlugin(b, dylib, "markdown", pack_plugins_install_dir);
        install_markdown.step.dependOn(tail);
        tail = &install_markdown.step;
    }
    if (fizzy.image_dylib) |dylib| {
        const install_image = plugin.installBuiltinPlugin(b, dylib, "image", pack_plugins_install_dir);
        install_image.step.dependOn(tail);
        tail = &install_image.step;
    }

    return tail;
}

pub const FizzyExecutable = struct {
    exe: *std.Build.Step.Compile,
    /// Native-only; `null` on wasm targets.
    workbench_dylib: ?*std.Build.Step.Compile = null,
    text_dylib: ?*std.Build.Step.Compile = null,
    markdown_dylib: ?*std.Build.Step.Compile = null,
    image_dylib: ?*std.Build.Step.Compile = null,
    /// Fizzy's own native backend module (`src/backend/native/SDLBackend.zig`) the executable
    /// draws with; null for dvui's `sdl3` backend.
    backend: ?*std.Build.Module = null,
};

/// What the native executable draws with.
pub const NativeBackend = enum {
    /// Fizzy's own backend (`src/backend/native/`): SDL3 for the window and events, an
    /// SDL_GPU renderer of its own, custom fragment programs.
    fizzy,
    /// dvui's SDL3 backend: SDL_Renderer, fixed shaders.
    sdl3,
};

/// Fizzy's own everywhere: on Windows its D3D12 swapchain composites the transparent window
/// through DirectComposition (fizzyedit/SDL) over the Acrylic backdrop, and its custom programs
/// (the liquid glass) run there as they do on Metal and Vulkan. `-Dnative-backend=sdl3` still
/// builds dvui's.
pub fn defaultNativeBackend(target: std.Build.ResolvedTarget) NativeBackend {
    _ = target;
    return .fizzy;
}

/// dvui as the executable links it, and the backend under it.
const NativeDvui = struct {
    dep: *std.Build.Dependency,
    dvui: *std.Build.Module,
    backend: *std.Build.Module,
};

/// The `backend` module wired into each dvui built for fizzy's own backend. One per dvui
/// module, however many executables use it: dvui imports it by name, and a second module over
/// the same file in one compilation is an error.
var fizzy_backend_modules: std.AutoHashMapUnmanaged(*std.Build.Module, *std.Build.Module) = .empty;

/// dvui in its `custom` mode with fizzy's backend linked under it — as `build/web.zig` does for
/// the web. Every option is the one dvui's own `sdl3` mode sets, so dvui's shape, and with it
/// the plugin ABI fingerprint, is the same either way.
fn fizzyNativeDvui(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    accesskit: dvui.AccesskitOptions,
    macos_sdl_paths: ?MacosSdlPaths,
) NativeDvui {
    const dep = sdk.dvuiDependency(b, .{
        .target = target,
        .optimize = optimize,
        .backend = .custom,
        .accesskit = accesskit,
        .libc = true,
        .freetype = true,
        .@"tiny-file-dialogs" = true,
        .@"stb-image" = true,
        .@"tree-sitter" = true,
    });
    const dvui_mod = dep.module("dvui");
    if (fizzy_backend_modules.get(dvui_mod)) |backend| return .{ .dep = dep, .dvui = dvui_mod, .backend = backend };

    // SDL3 from fizzy's own pin, not dvui's: the backend is fizzy's, and so are the SDL patches it
    // needs (docs/DEPENDENCIES.md). The wrapper already builds without GameInput.
    //
    // Optimized in a Debug app too: Zig builds C in Debug unoptimized and with its undefined-
    // behaviour checks on every call, and SDL is on every frame's path — event pumping, the GPU
    // device, every window's present. A Debug frame spent much of itself there (`sample`), and a
    // window's way into full screen ran at half the display's rate in Debug alone (the user).
    // Fizzy's own code stays Debug; stepping into SDL's C is what a Debug app gives up.
    const sdl_optimize: std.builtin.OptimizeMode = if (optimize == .Debug) .ReleaseFast else optimize;
    const sdl_dep = if (macos_sdl_paths) |p|
        b.lazyDependency("sdl", .{
            .target = target,
            .optimize = sdl_optimize,
            .include_path = p.include,
            .framework_path = p.framework,
            .library_path = p.lib,
        })
    else
        b.lazyDependency("sdl", .{ .target = target, .optimize = sdl_optimize });

    const sdl_translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/backend/native/sdl3-c.h"),
        .target = target,
        .optimize = optimize,
    });
    if (sdl_dep) |sdl| sdl_translate_c.addIncludePath(sdl.artifact("SDL3").getEmittedIncludeTree());

    const backend = b.createModule(.{
        .root_source_file = b.path("src/backend/native/SDLBackend.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_c = .full,
        .link_libc = true,
        .imports = &.{
            .{ .name = "sdl3-c", .module = sdl_translate_c.createModule() },
            .{ .name = "dvui", .module = dvui_mod },
        },
    });
    if (sdl_dep) |sdl| backend.linkLibrary(sdl.artifact("SDL3"));
    dvui_mod.addImport("backend", backend);
    fizzy_backend_modules.put(b.allocator, dvui_mod, backend) catch @panic("OOM");
    return .{ .dep = dep, .dvui = dvui_mod, .backend = backend };
}

/// The `platform` module (`src/backend/native/platform`) for each backend module: one per
/// backend, as the backend itself is, since fizzy's backend imports it by name too.
var platform_modules: std.AutoHashMapUnmanaged(*std.Build.Module, *std.Build.Module) = .empty;

/// Window and platform pieces for apps on either SDL3 backend: dvui and the backend's SDL, plus
/// zig-objc on macOS and zigwin32 on Windows. Fizzy's own backend imports it as well, so an app on
/// that backend reaches it as `backend.platform`.
fn platformModule(
    b: *std.Build,
    native: NativeDvui,
    native_backend: NativeBackend,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    if (platform_modules.get(native.backend)) |m| return m;
    const m = b.createModule(.{
        .root_source_file = b.path("src/backend/native/platform/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    m.addImport("dvui", native.dvui);
    m.addImport("backend", native.backend);
    switch (target.result.os.tag) {
        .macos => if (b.lazyDependency("zig_objc", .{ .target = target, .optimize = optimize })) |dep| {
            m.addImport("objc", dep.module("objc"));
        },
        .windows => if (b.lazyDependency("zigwin32", .{})) |dep| {
            m.addImport("win32", dep.module("win32"));
        },
        else => {},
    }
    if (native_backend == .fizzy) native.backend.addImport("platform", m);
    platform_modules.put(b.allocator, native.backend, m) catch @panic("OOM");
    return m;
}

pub fn addFizzyExecutableForTarget(
    b: *std.Build,
    /// Null on the configure pass that fetches Velopack (`app.readConfig`).
    vz: ?velopack.Dep,
    resolved_target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    accesskit: dvui.AccesskitOptions,
    native_backend: NativeBackend,
    build_opts: *std.Build.Step.Options,
    workbench_opts: *std.Build.Step.Options,
    assets_module: *std.Build.Module,
    macos_sdl_paths: ?MacosSdlPaths,
    velopack_enabled: bool,
    /// The application's short name (see app/AppInfo.zig) — the executable's name. Passed in
    /// rather than hardcoded so an app built on fizzy as a library names its own binary.
    app_name: []const u8,
    /// Consumer-owned layout file. When set, Editor calls `app_layout.layout(ctx, *Layout)`
    /// instead of fizzy's own shape. `ctx` is `context()` if the file exports it, else
    /// `Host.layout_ctx`. The file imports `dvui`, `app`, `core`, and `fizzy_sdk` — not
    /// `fizzy` / `Editor` — so the module graph does not cycle.
    app_layout: ?std.Build.LazyPath,
    /// Plugins the application bundles beyond fizzy's own four: each a static module from a
    /// plugin package (`plugin_dep.module("plugin")`), linked in and listed in the generated
    /// `bundled_plugins` module under its plugin id.
    app_plugins: []const sdk.BundledPlugin,
) !FizzyExecutable {
    const native: NativeDvui = switch (native_backend) {
        .fizzy => fizzyNativeDvui(b, resolved_target, optimize, accesskit, macos_sdl_paths),
        .sdl3 => blk: {
            const dep = if (macos_sdl_paths) |p|
                sdk.dvuiDependency(b, .{
                    .target = resolved_target,
                    .optimize = optimize,
                    .backend = .sdl3,
                    .accesskit = accesskit,
                    .system_include_path = p.include,
                    .system_framework_path = p.framework,
                    .library_path = p.lib,
                })
            else
                sdk.dvuiDependency(b, .{ .target = resolved_target, .optimize = optimize, .backend = .sdl3, .accesskit = accesskit });
            break :blk .{ .dep = dep, .dvui = dep.module("dvui_sdl3"), .backend = dep.module("sdl3") };
        },
    };
    const dvui_dep = native.dep;
    const dvui_mod = native.dvui;

    const dvui_proxy_dep = sdk.dvuiDependency(b, .{
        .target = resolved_target,
        .optimize = optimize,
        .backend = .proxy,
        .accesskit = .off,
    });
    const dvui_proxy_mod = dvui_proxy_dep.module("dvui_proxy");
    const proxy_bridge_host_mod = sdk.addProxyBridgeModule(b, resolved_target, optimize, dvui_dep, dvui_mod);
    const proxy_bridge_plugin_mod = dvui_proxy_dep.module("proxy_bridge");

    const exe = b.addExecutable(.{
        .name = app_name,
        .root_module = b.addModule("App", .{
            .target = resolved_target,
            .optimize = optimize,
            // `b.path`, not `.cwd_relative`: this resolves against *fizzy's* build root, which
            // is what makes the package consumable. A cwd-relative path silently works while
            // fizzy builds itself (cwd is fizzy's root) and fails with FileNotFound the moment
            // an outside package depends on fizzy — see fizzyedit/example-app.
            .root_source_file = b.path("src/Entry.zig"),
        }),
    });
    exe.root_module.strip = false;

    exe.root_module.addImport("assets", assets_module);
    exe.root_module.addImport("build_opts", sdk.buildOptsModule(build_opts));

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

    exe.root_module.addImport("dvui", dvui_mod);
    exe.root_module.addImport("backend", native.backend);
    exe.root_module.addImport("platform", platformModule(b, native, native_backend, resolved_target, optimize));

    // Shared `core` module (gfx/math/fs/generated atlas/platform/paths/dvui hub +
    // generic widgets). Import set is shared with the plugin SDK path — see sdk/core_module.zig.
    const core_module = b.createModule(.{
        .target = resolved_target,
        .optimize = optimize,
        .root_source_file = b.path("core/core.zig"),
    });
    const icons_module = core_mod.addImports(b, core_module, dvui_mod, b.dependency("fizzy_sdk", .{}).builder, resolved_target, optimize);
    exe.root_module.addImport("core", core_module);
    if (icons_module) |icons| exe.root_module.addImport("icons", icons);

    const core_proxy_module = b.createModule(.{
        .target = resolved_target,
        .optimize = optimize,
        .root_source_file = b.path("core/core.zig"),
    });
    _ = core_mod.addImports(b, core_proxy_module, dvui_proxy_mod, b.dependency("fizzy_sdk", .{}).builder, resolved_target, optimize);

    // `macos_fsevents` is load-bearing for `FolderWatcher`: it watches a whole project folder,
    // and the kqueue fallback needs a file descriptor per directory *and* per file — exactly the
    // shape that exhausts the fd limit on a real repo. FSEvents covers the subtree with one
    // stream. The option only exists when nightwatch is built for macOS, hence the split.
    const nightwatch_dep = if (resolved_target.result.os.tag == .macos)
        b.lazyDependency("nightwatch", .{ .target = resolved_target, .optimize = optimize, .macos_fsevents = true })
    else
        b.lazyDependency("nightwatch", .{ .target = resolved_target, .optimize = optimize });
    if (nightwatch_dep) |dep| {
        exe.root_module.addImport("nightwatch", dep.module("nightwatch"));
    }

    const sdk_module = sdk.wireSdkModule(b, resolved_target, optimize, dvui_mod, proxy_bridge_host_mod, core_module, exe.root_module);
    const sdk_proxy_module = sdk.wireSdkModule(b, resolved_target, optimize, dvui_proxy_mod, proxy_bridge_plugin_mod, core_proxy_module, null);
    const workbench_module = workbench_plugin.addStaticModule(b, resolved_target, optimize, .{
        .dvui = dvui_mod,
        .core = core_module,
        .sdk = sdk_module,
        .icons = icons_module,
        .backend = native.backend,
    }, workbench_opts, exe.root_module);
    const text_module = text_plugin.addStaticModule(b, resolved_target, optimize, .{
        .dvui = dvui_mod,
        .core = core_module,
        .sdk = sdk_module,
        .icons = icons_module,
    }, exe.root_module);
    const image_module = image_plugin.addStaticModule(b, resolved_target, optimize, .{
        .dvui = dvui_mod,
        .core = core_module,
        .sdk = sdk_module,
    }, exe.root_module);
    const archive_module = archive_plugin.addStaticModule(b, resolved_target, optimize, .{
        .dvui = dvui_mod,
        .core = core_module,
        .sdk = sdk_module,
    }, exe.root_module);
    const markdown_module: ?*std.Build.Module = if (resolved_target.result.cpu.arch != .wasm32)
        markdown_plugin.addStaticModule(b, resolved_target, optimize, .{
            .dvui = dvui_mod,
            .core = core_module,
            .sdk = sdk_module,
        }, exe.root_module)
    else
        null;

    // What this application bundles, as build data: a generated module whose `modules` tuple
    // names every statically linked plugin, so the runtime registers, probes and falls back
    // to whatever is listed here and never a plugin by name. An app built on fizzy lists its
    // own.
    var bundled_list: std.ArrayList(sdk.BundledPlugin) = .empty;
    try bundled_list.appendSlice(b.allocator, &.{
        .{ .name = "workbench", .module = workbench_module },
        .{ .name = "text", .module = text_module },
        .{ .name = "image", .module = image_module },
        .{ .name = "archive", .module = archive_module },
        .{ .name = "markdown", .module = markdown_module },
    });
    for (app_plugins) |p| {
        const src_mod = p.module orelse {
            try bundled_list.append(b.allocator, p);
            continue;
        };
        // A copy per executable, not the plugin package's module itself: this function builds
        // more than one exe (the packaged, Velopack-linked one beside the plain one), each with
        // its own `dvui`/`core`/`fizzy_sdk`, and one module cannot import both sets. The copy
        // keeps the plugin's own imports — its manifest options, its dependencies — and gets
        // this exe's framework modules.
        const m = b.createModule(.{
            .target = resolved_target,
            .optimize = optimize,
            .root_source_file = src_mod.root_source_file,
            .link_libc = resolved_target.result.cpu.arch != .wasm32,
        });
        var it = src_mod.import_table.iterator();
        while (it.next()) |kv| {
            const name = kv.key_ptr.*;
            if (std.mem.eql(u8, name, "dvui") or std.mem.eql(u8, name, "core") or std.mem.eql(u8, name, "fizzy_sdk") or std.mem.eql(u8, name, "icons")) continue;
            m.addImport(name, kv.value_ptr.*);
        }
        m.addImport("dvui", dvui_mod);
        m.addImport("core", core_module);
        m.addImport("fizzy_sdk", sdk_module);
        if (icons_module) |icons| m.addImport("icons", icons);
        exe.root_module.addImport(p.name, m);
        try bundled_list.append(b.allocator, .{ .name = p.name, .module = m });
    }
    const bundled = sdk.bundledPluginsModule(b, resolved_target, optimize, bundled_list.items);
    exe.root_module.addImport("bundled_plugins", bundled);

    const singleton_app_dep = b.dependency("dvui_singleton_app", .{
        .target = resolved_target,
        .optimize = optimize,
    });
    exe.root_module.addImport("singleton_app", singleton_app_dep.module("singleton_app"));

    // The `app` framework module: the plugin store and what it needs. Fizzy is its first
    // consumer, not its owner — see `app/root.zig`.
    const app_module = sdk.wireAppModule(b, resolved_target, optimize, dvui_mod, core_module, sdk_module, icons_module, markdown_module, if (nightwatch_dep) |dep| dep.module("nightwatch") else null, build_opts, singleton_app_dep.module("singleton_app"), exe.root_module);
    app_module.addImport("bundled_plugins", bundled);

    if (app_layout) |path| {
        // A `.zon` shape is data, not code, so it gets a generated shim that imports the file as
        // a typed `layout.Shape` and walks it. Everything downstream — Editor's call, the
        // module's imports, `has_app_layout` — is unchanged, because from here on the two kinds
        // of shape are the same thing: a module exporting `layout(?*anyopaque, *Layout)`.
        const is_zon = std.mem.endsWith(u8, path.getDisplayName(), ".zon");
        const app_layout_mod = b.createModule(.{
            .target = resolved_target,
            .optimize = optimize,
            .root_source_file = if (is_zon) b.addWriteFiles().add("app_layout_spec.zig", spec_shim) else path,
        });
        if (is_zon) app_layout_mod.addAnonymousImport("app_layout_spec", .{ .root_source_file = path });
        app_layout_mod.addImport("dvui", dvui_mod);
        app_layout_mod.addImport("app", app_module);
        app_layout_mod.addImport("core", core_module);
        app_layout_mod.addImport("fizzy_sdk", sdk_module);
        exe.root_module.addImport("app_layout", app_layout_mod);
    }

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

    const text_dylib: ?*std.Build.Step.Compile = if (resolved_target.result.cpu.arch != .wasm32) blk: {
        break :blk text_plugin.addDylib(b, resolved_target, optimize, .{
            .dvui = dvui_proxy_mod,
            .core = core_proxy_module,
            .sdk = sdk_proxy_module,
            .proxy_bridge = proxy_bridge_plugin_mod,
            .icons = icons_module,
        });
    } else null;

    const markdown_dylib: ?*std.Build.Step.Compile = if (resolved_target.result.cpu.arch != .wasm32) blk: {
        break :blk markdown_plugin.addDylib(b, resolved_target, optimize, .{
            .dvui = dvui_proxy_mod,
            .core = core_proxy_module,
            .sdk = sdk_proxy_module,
            .proxy_bridge = proxy_bridge_plugin_mod,
        });
    } else null;

    const image_dylib: ?*std.Build.Step.Compile = if (resolved_target.result.cpu.arch != .wasm32) blk: {
        break :blk image_plugin.addDylib(b, resolved_target, optimize, .{
            .dvui = dvui_proxy_mod,
            .core = core_proxy_module,
            .sdk = sdk_proxy_module,
            .proxy_bridge = proxy_bridge_plugin_mod,
        });
    } else null;

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
        exe.root_module.addCSourceFile(.{ .file = std.Build.path(b, "src/backend/native/platform/macos/visual_effect_view.m") });
        exe.root_module.addCSourceFile(.{ .file = std.Build.path(b, "src/backend/native/platform/macos/menu_target.m") });
        exe.root_module.addCSourceFile(.{ .file = std.Build.path(b, "src/backend/native/platform/macos/window_monitor.m") });
        exe.root_module.addCSourceFile(.{ .file = std.Build.path(b, "src/backend/native/platform/macos/live_resize_trace.m") });
        // The native backend's AppKit helpers, compiled here with fizzy's other Objective-C
        // (the root module is where the SDK's headers are found on a native build); the
        // backend module calls them by name.
        if (native_backend == .fizzy) {
            exe.root_module.addCSourceFile(.{ .file = std.Build.path(b, "src/backend/native/macos_monitor.m") });
        }
    } else if (resolved_target.result.os.tag == .windows) {
        if (b.lazyDependency("zigwin32", .{})) |dep| {
            exe.root_module.addImport("win32", dep.module("win32"));
            // The updater (`app/update`) calls into Windows too, from the `app` module.
            app_module.addImport("win32", dep.module("win32"));
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
    if (velopack_enabled) if (vz) |v| {
        try velopack.linkVelopack(b, v, exe, .{ .target = resolved_target, .optimize = optimize, .include_modules = &.{app_module} });
    };

    return .{
        .exe = exe,
        .workbench_dylib = workbench_dylib,
        .text_dylib = text_dylib,
        .markdown_dylib = markdown_dylib,
        .image_dylib = image_dylib,
        .backend = if (native_backend == .fizzy) native.backend else null,
    };
}

/// The whole of a `.zon` shape's generated module: import the file as a `Shape` — which is where
/// it is type-checked, at comptime, against the field names and enums `Shape` declares —
/// and hand it to the same walk a hand-written shape's calls would have performed itself.
const spec_shim =
    \\//! Generated for `-Dapp-layout=<file>.zon`. See `app/layout/Shape.zig`.
    \\const dvui = @import("dvui");
    \\const layout_ns = @import("app").layout;
    \\
    \\pub const shape: layout_ns.Shape = @import("app_layout_spec");
    \\
    \\pub fn layout(_: ?*anyopaque, f: *layout_ns.Layout) !dvui.App.Result {
    \\    try layout_ns.Shape.apply(shape, f);
    \\    return .ok;
    \\}
    \\
;
