//! Fizzy's native backend, as a package an app depends on: SDL3 for the window and its events, an
//! SDL_GPU renderer of its own with custom fragment programs (`GpuRenderer`), and the platform
//! pieces (title bars, the OS's glass, OS windows for floats, menus and dialogs: `platform`).
//!
//! An app builds dvui in its `custom` mode and wires this under it (`backendModule`);
//! `platformModule` gives the platform pieces to an app on this backend or on dvui's own SDL3 one.
//! dvui is the caller's and never pinned here, so the backend compiles against the app's dvui.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_step = b.step("test", "Run the backend's std-only tests");
    for (unit_tests) |t| {
        const compile = b.addTest(.{
            .name = t.name,
            .root_module = b.createModule(.{ .root_source_file = b.path(t.root), .target = target, .optimize = optimize }),
        });
        test_step.dependOn(&b.addRunArtifact(compile).step);
    }
}

/// The backend's std-only files with tests of their own, relative to this package: run by
/// `zig build test` here, and by an app's own test step through `dependency.path(root)`.
pub const unit_tests = [_]struct { name: []const u8, root: []const u8 }{
    .{ .name = "backend-window-layout-tests", .root = "src/platform/window_layout.zig" },
    // The hit test Windows' WM_NCHITTEST and Linux's SDL hit test both answer from.
    .{ .name = "backend-titlebar-tests", .root = "src/platform/titlebar.zig" },
    // The rounded frame Linux's blur behind the window is stepped into (`wayland_blur`).
    .{ .name = "backend-blur-region-tests", .root = "src/platform/blur_region.zig" },
    // Where a viewport's OS window is on the desktop and where its part of the frame lies.
    .{ .name = "backend-viewport-map-tests", .root = "src/viewport_map.zig" },
    // The backend's health counters: frame-time percentiles, per-frame counts, SDL's log counted
    // from any thread, a snapshot as ZON.
    .{ .name = "backend-health-tests", .root = "src/Health.zig" },
};

/// Where the macOS SDK is, for a macOS target that is not the host's own (`-Dtarget=aarch64-macos`
/// on Apple Silicon): Zig finds it alone for a native build only.
pub const MacosSdk = struct {
    include: std.Build.LazyPath,
    framework: std.Build.LazyPath,
    lib: std.Build.LazyPath,
};

pub const Options = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    /// Null on a native build.
    macos_sdk: ?MacosSdk = null,
};

/// The `backend` module wired into each dvui: one per dvui module, however many executables use
/// it. dvui imports it by name, and a second module over the same file in one compilation is an
/// error.
var backend_modules: std.AutoHashMapUnmanaged(*std.Build.Module, *std.Build.Module) = .empty;
/// The `platform` module for each backend module, for the same reason.
var platform_modules: std.AutoHashMapUnmanaged(*std.Build.Module, *std.Build.Module) = .empty;

/// The backend under `dvui_mod`, a dvui built with `.backend = .custom`, and imported by it as
/// `backend`. Call `platformModule` with the result too: the backend imports the platform pieces.
pub fn backendModule(dep: *std.Build.Dependency, dvui_mod: *std.Build.Module, opts: Options) *std.Build.Module {
    if (backend_modules.get(dvui_mod)) |m| return m;
    const b = dep.builder;

    // Optimized in a Debug app too: Zig builds C in Debug unoptimized and with its undefined-
    // behaviour checks on every call, and SDL is on every frame's path — event pumping, the GPU
    // device, every window's present. A Debug frame spent much of itself there (`sample`), and a
    // window's way into full screen ran at half the display's rate in Debug alone. The app's own
    // code stays Debug; stepping into SDL's C is what a Debug app gives up.
    const sdl_optimize: std.builtin.OptimizeMode = if (opts.optimize == .Debug) .ReleaseFast else opts.optimize;
    const sdl_dep = if (opts.macos_sdk) |p|
        b.lazyDependency("sdl", .{
            .target = opts.target,
            .optimize = sdl_optimize,
            .include_path = p.include,
            .framework_path = p.framework,
            .library_path = p.lib,
        })
    else
        b.lazyDependency("sdl", .{ .target = opts.target, .optimize = sdl_optimize });

    const sdl_translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/sdl3-c.h"),
        .target = opts.target,
        .optimize = opts.optimize,
    });
    if (sdl_dep) |sdl| sdl_translate_c.addIncludePath(sdl.artifact("SDL3").getEmittedIncludeTree());

    const m = b.createModule(.{
        .root_source_file = b.path("src/SDLBackend.zig"),
        .target = opts.target,
        .optimize = opts.optimize,
        .sanitize_c = .full,
        .link_libc = true,
        .imports = &.{
            .{ .name = "sdl3-c", .module = sdl_translate_c.createModule() },
            .{ .name = "dvui", .module = dvui_mod },
        },
    });
    if (sdl_dep) |sdl| m.linkLibrary(sdl.artifact("SDL3"));
    // The backend's AppKit helpers; the module calls them by name.
    if (opts.target.result.os.tag == .macos) {
        addMacosSdk(m, opts);
        m.addCSourceFile(.{ .file = b.path("src/macos_monitor.m") });
    }
    dvui_mod.addImport("backend", m);
    backend_modules.put(b.allocator, dvui_mod, m) catch @panic("OOM");
    return m;
}

/// The window and platform pieces (`src/platform`) for an app on `backend_mod`: this package's
/// backend (`backendModule`), which imports them in turn, or dvui's own SDL3 backend. The app
/// reaches them as `platform`.
pub fn platformModule(dep: *std.Build.Dependency, dvui_mod: *std.Build.Module, backend_mod: *std.Build.Module, opts: Options) *std.Build.Module {
    if (platform_modules.get(backend_mod)) |m| return m;
    const b = dep.builder;
    const m = b.createModule(.{
        .root_source_file = b.path("src/platform/root.zig"),
        .target = opts.target,
        .optimize = opts.optimize,
        .link_libc = true,
    });
    m.addImport("dvui", dvui_mod);
    m.addImport("backend", backend_mod);
    switch (opts.target.result.os.tag) {
        .macos => if (objcModule(dep, opts)) |objc| m.addImport("objc", objc),
        .windows => if (win32Module(dep)) |win32| m.addImport("win32", win32),
        else => {},
    }
    // This package's backend imports the platform pieces by name; dvui's SDL3 one does not.
    var it = backend_modules.valueIterator();
    while (it.next()) |own| if (own.* == backend_mod) backend_mod.addImport("platform", m);
    platform_modules.put(b.allocator, backend_mod, m) catch @panic("OOM");
    return m;
}

/// The platform's Objective-C (`src/platform/macos/*.m`), added to an executable's root module: an
/// app on this backend calls it once for its executable. `platformModule` does not carry it, because
/// it calls back into the platform's Zig by name, which only a compile that reaches those files
/// emits: carried by the module, a test that imports the backend alone would fail to link.
pub fn addPlatformObjC(dep: *std.Build.Dependency, root_module: *std.Build.Module, opts: Options) void {
    if (opts.target.result.os.tag != .macos) return;
    const b = dep.builder;
    addMacosSdk(root_module, opts);
    root_module.addCSourceFile(.{ .file = b.path("src/platform/macos/visual_effect_view.m") });
    root_module.addCSourceFile(.{ .file = b.path("src/platform/macos/menu_target.m") });
    root_module.addCSourceFile(.{ .file = b.path("src/platform/macos/window_monitor.m") });
    root_module.addCSourceFile(.{ .file = b.path("src/platform/macos/live_resize_trace.m") });
}

/// zig-objc, from this package's pin, for an app's own AppKit code. Null on the configure pass
/// that fetches it (Zig runs the build again).
pub fn objcModule(dep: *std.Build.Dependency, opts: Options) ?*std.Build.Module {
    const objc = dep.builder.lazyDependency("zig_objc", .{ .target = opts.target, .optimize = opts.optimize }) orelse return null;
    return objc.module("objc");
}

/// `viewports` for a backend without OS windows besides the main one (`src/viewports_none.zig`):
/// dvui's own, its testing backend, the web. An app that builds on either kind imports it as
/// `viewports_none` and takes the backend's own `viewports` where it has one. Needs only dvui,
/// so nothing of SDL is fetched for it.
pub fn viewportsNoneModule(dep: *std.Build.Dependency, dvui_mod: *std.Build.Module) *std.Build.Module {
    const m = dep.builder.createModule(.{ .root_source_file = dep.builder.path("src/viewports_none.zig") });
    m.addImport("dvui", dvui_mod);
    return m;
}

/// zigwin32, from this package's pin, for an app's own Windows code. Null on the configure pass
/// that fetches it.
pub fn win32Module(dep: *std.Build.Dependency) ?*std.Build.Module {
    const win32 = dep.builder.lazyDependency("zigwin32", .{}) orelse return null;
    return win32.module("win32");
}

/// A non-native macOS target's SDK, for a module's Objective-C: zig-objc's paths do not always
/// reach `.m` compiles (Security.framework's `<libDER/DERItem.h>`).
fn addMacosSdk(m: *std.Build.Module, opts: Options) void {
    const p = opts.macos_sdk orelse return;
    m.addSystemIncludePath(p.include);
    m.addSystemFrameworkPath(p.framework);
    m.addLibraryPath(p.lib);
}
