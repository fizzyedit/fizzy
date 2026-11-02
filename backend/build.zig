//! Fizzy's native backend, as a package an app depends on: SDL3 for the window and its events, an
//! SDL_GPU renderer of its own with custom fragment programs (`GpuRenderer`), and the platform
//! pieces (title bars, the OS's glass, OS windows for floats, menus and dialogs: `platform`).
//!
//! An app builds dvui in its `custom` mode and wires this under it (`backendModule`);
//! `platformModule` gives the platform pieces to an app on this backend or on dvui's own SDL3 one.
//! dvui is the caller's and never pinned here, so the backend compiles against the app's dvui.
const std = @import("std");
const Translator = @import("translate_c").Translator;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_step = b.step("test", "Run the backend's std-only tests");
    const glass_look = b.createModule(.{ .root_source_file = b.path("src/glass_look.zig") });
    for (unit_tests) |t| {
        const compile = b.addTest(.{
            .name = t.name,
            .root_module = b.createModule(.{ .root_source_file = b.path(t.root), .target = target, .optimize = optimize }),
        });
        if (t.glass_look) compile.root_module.addImport("glass_look", glass_look);
        test_step.dependOn(&b.addRunArtifact(compile).step);
    }

    // The conformance suite as a program, for a real platform's driver. Today: Sim, to check the
    // suite itself.
    const winsys_module = b.createModule(.{ .root_source_file = b.path("winsys/root.zig"), .target = target, .optimize = optimize });
    const conformance = b.addExecutable(.{
        .name = "winsys-conformance",
        .root_module = b.createModule(.{
            .root_source_file = b.path("winsys/conformance/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "winsys", .module = winsys_module }},
        }),
    });
    const conformance_run = b.addRunArtifact(conformance);
    if (b.option([]const u8, "conformance-tag", "Run only the cases of this tag (all, needs_display, macos, windows, linux)")) |tag| conformance_run.addArgs(&.{ "--tag", tag });
    if (b.option([]const u8, "conformance-filter", "Run only the cases whose name contains this")) |text| conformance_run.addArgs(&.{ "--filter", text });
    if (b.option(bool, "conformance-list", "List the cases instead of running them") orelse false) conformance_run.addArg("--list");
    b.step("conformance", "Run the windowing conformance suite (-Dconformance-tag, -Dconformance-filter, -Dconformance-list)").dependOn(&conformance_run.step);

    // The interface compiles for the web too: no OS, no libc. `analysed` in the root makes the object
    // analyse every declaration, which a build of unreferenced code would not.
    const winsys_web = b.addObject(.{
        .name = "winsys-wasm32",
        .root_module = b.createModule(.{
            .root_source_file = b.path("winsys/root.zig"),
            .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }),
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&winsys_web.step);

    // The suites for fizzy's SDL patches (the `test:` patches in `patches/sdl`), on SDL's own test
    // harness, against the patched library. Arguments after `--` reach the runner:
    // `--filter <suite|test>`, `--require-gpu <driver>`.
    const test_sdl_step = b.step("test-sdl", "Build and run the suites for fizzy's SDL patches");
    const sdl_optimize: std.lang.OptimizeMode = if (optimize == .debug) .fast else optimize;
    if (sdlDependency(b, target, sdl_optimize, null)) |sdl| {
        const source = patchedSdl(b).?;
        const sdl_test = b.addLibrary(.{
            .name = "SDL3_test",
            .root_module = b.createModule(.{ .target = target, .optimize = sdl_optimize, .link_libc = true }),
        });
        sdl_test.root_module.addIncludePath(source.path(b, "include"));
        sdl_test.root_module.addCSourceFiles(.{
            .root = source.path(b, "src/test"),
            .files = &.{
                "SDL_test_assert.c", "SDL_test_common.c", "SDL_test_compare.c", "SDL_test_crc32.c",
                "SDL_test_font.c",   "SDL_test_fuzzer.c", "SDL_test_harness.c", "SDL_test_log.c",
                "SDL_test_md5.c",    "SDL_test_memory.c",
            },
        });
        const suites = b.addExecutable(.{
            .name = "testfizzy",
            .root_module = b.createModule(.{ .target = target, .optimize = sdl_optimize, .link_libc = true }),
        });
        suites.root_module.addIncludePath(source.path(b, "include"));
        suites.root_module.addCSourceFiles(.{
            .root = source.path(b, "test"),
            .files = &.{
                "testfizzy.c",                "testautomation_fizzy_gpu.c",
                "testautomation_fizzy_xkb.c", "testautomation_fizzy_wayland.c",
            },
        });
        suites.root_module.linkLibrary(sdl_test);
        suites.root_module.linkLibrary(sdl.artifact("SDL3"));
        const run = b.addRunArtifact(suites);
        run.addPassthruArgs();
        test_sdl_step.dependOn(&run.step);
    }
}

/// The backend's std-only files with tests of their own, relative to this package: run by
/// `zig build test` here, and by an app's own test step through `dependency.path(root)`.
pub const unit_tests = [_]struct {
    name: []const u8,
    root: []const u8,
    /// The root imports `glass_look` (`src/glass_look.zig`, std-only too).
    glass_look: bool = false,
}{
    .{ .name = "backend-window-layout-tests", .root = "src/platform/window_layout.zig" },
    // The hit test Windows' WM_NCHITTEST and Linux's SDL hit test both answer from.
    .{ .name = "backend-titlebar-tests", .root = "src/platform/titlebar.zig" },
    // Why each platform lacks the window materials it does, read from the resolver's offer.
    .{ .name = "backend-materials-tests", .root = "src/materials.zig", .glass_look = true },
    // The rounded frame Linux's blur behind the window is stepped into (`wayland_blur`).
    .{ .name = "backend-blur-region-tests", .root = "src/platform/blur_region.zig" },
    // The X11 arm of it: the `_KDE_NET_WM_BLUR_BEHIND_REGION` payload and which window managers read it.
    .{ .name = "backend-x11-blur-tests", .root = "src/platform/x11_blur.zig" },
    // Where a viewport's OS window is on the desktop and where its part of the frame lies.
    .{ .name = "backend-viewport-map-tests", .root = "src/viewport_map.zig" },
    // The backend's health counters: frame-time percentiles, per-frame counts, SDL's log counted
    // from any thread, a snapshot as ZON.
    .{ .name = "backend-health-tests", .root = "src/Health.zig" },
    // Which touch button each finger on the screen presses; a trackpad's fingers, none.
    .{ .name = "backend-touch-slots-tests", .root = "src/touch_slots.zig" },
    // The windowing interface (`winsys`): window, event, display, clipboard, dnd and IME types,
    // and the platform vtable every backend implements. std-only.
    .{ .name = "backend-winsys-tests", .root = "winsys/root.zig" },
    // The GPU device interface (`gpu`): the narrow surface `GpuRenderer` draws through, shader
    // formats and their pick, and the `Null` device. std-only.
    .{ .name = "backend-gpu-tests", .root = "gpu/root.zig" },
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
    optimize: std.lang.OptimizeMode,
    /// Null on a native build.
    macos_sdk: ?MacosSdk = null,
};

/// The `backend` module wired into each dvui: one per dvui module, however many executables use
/// it. dvui imports it by name, and a second module over the same file in one compilation is an
/// error.
var backend_modules: std.AutoHashMapUnmanaged(*std.Build.Module, *std.Build.Module) = .empty;
var glass_look_module: ?*std.Build.Module = null;

/// What every glass is at the window's opacity (`src/glass_look.zig`), std-only: one module for the
/// whole build, so the backend and the app's `core` that a build links together share it (a file
/// may belong to only one module). Pass it to `core_module.addImports` for a `core` linked beside
/// this backend.
pub fn glassLookModule(dep: *std.Build.Dependency) *std.Build.Module {
    if (glass_look_module) |m| return m;
    const m = dep.builder.createModule(.{ .root_source_file = dep.builder.path("src/glass_look.zig") });
    glass_look_module = m;
    return m;
}

/// The glass module for each dvui (`glassModule`), for the same reason.
var glass_modules: std.AutoHashMapUnmanaged(*std.Build.Module, *std.Build.Module) = .empty;

/// Fizzy's in-app glass (`src/glass/root.zig`: the frame target, the frosted backdrops, the liquid
/// glass and its program, motion) over `dvui_mod`: one per dvui, as the backend is, so the backend
/// and the app's `core` that a build links together share it. Pass it to `core_module.addImports`
/// for a `core` linked beside this backend.
pub fn glassModule(dep: *std.Build.Dependency, dvui_mod: *std.Build.Module) *std.Build.Module {
    if (glass_modules.get(dvui_mod)) |m| return m;
    const b = dep.builder;
    const m = b.createModule(.{ .root_source_file = b.path("src/glass/root.zig") });
    m.addImport("dvui", dvui_mod);
    m.addImport("glass_look", glassLookModule(dep));
    glass_modules.put(b.allocator, dvui_mod, m) catch @panic("OOM");
    return m;
}

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
    const sdl_optimize: std.lang.OptimizeMode = if (opts.optimize == .debug) .fast else opts.optimize;
    const sdl_dep = sdlDependency(b, opts.target, sdl_optimize, opts.macos_sdk);

    const sdl_translate_c: Translator = .init(b.dependency("translate_c", .{}), .{
        .c_source_file = b.path("src/sdl3-c.h"),
        .target = opts.target,
        .optimize = opts.optimize,
        .default_init = true,
    });
    if (sdl_dep) |sdl| sdl_translate_c.addIncludePath(sdl.artifact("SDL3").getEmittedIncludeTree());

    const m = b.createModule(.{
        .root_source_file = b.path("src/SDLBackend.zig"),
        .target = opts.target,
        .optimize = opts.optimize,
        .sanitize_c = .full,
        .link_libc = true,
        .imports = &.{
            .{ .name = "sdl3-c", .module = sdl_translate_c.mod },
            .{ .name = "dvui", .module = dvui_mod },
        },
    });
    if (sdl_dep) |sdl| m.linkLibrary(sdl.artifact("SDL3"));
    // The backend's AppKit helpers; the module calls them by name.
    if (opts.target.result.os.tag == .macos) {
        addMacosSdk(m, opts);
        m.addCSourceFile(.{ .file = b.path("src/macos_monitor.m") });
    }
    m.addImport("glass_look", glassLookModule(dep));
    // A plain dvui app's frame is drawn through the glass's frame target (`plainFrameBegin`), and
    // its floating windows are made of the glass (`floatingWindowBackground`). The
    // same module as the app's `core` takes (`glassModule`, one per dvui); it imports dvui, never
    // the backend.
    m.addImport("glass", glassModule(dep, dvui_mod));
    dvui_mod.addImport("backend", m);
    backend_modules.put(b.allocator, dvui_mod, m) catch @panic("OOM");
    return m;
}

/// Upstream SDL with fizzy's patches applied: `patches/sdl/*.patch` in name order, by zig-patch.
/// Null until the lazy dependencies are fetched. How the patches are made, and how SDL is
/// updated: fizzy's docs/DEPENDENCIES.md.
fn patchedSdl(b: *std.Build) ?std.Build.LazyPath {
    const io = b.graph.io;
    var names: std.ArrayList([]const u8) = .empty;
    b.dependOnDirectoryContents(b.path("patches/sdl"));
    var dir = b.root.openDir(io, "patches/sdl", .{ .iterate = true }) catch |err|
        std.debug.panic("backend: open patches/sdl: {t}", .{err});
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch |err| std.debug.panic("backend: list patches/sdl: {t}", .{err})) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".patch")) continue;
        names.append(b.allocator, b.dupe(entry.name)) catch @panic("OOM");
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, l: []const u8, r: []const u8) bool {
            return std.mem.lessThan(u8, l, r);
        }
    }.lessThan);
    const patches = b.allocator.alloc(std.Build.LazyPath, names.items.len) catch @panic("OOM");
    for (patches, names.items) |*p, name| p.* = b.path(b.pathJoin(&.{ "patches/sdl", name }));

    const upstream = b.lazyDependency("sdl_source", .{}) orelse return null;
    const patch = b.lazyDependency("patch", .{ .source = upstream.path(""), .patches = patches }) orelse return null;
    return patch.namedLazyPath("patched");
}

/// sdl_zig building `patchedSdl` instead of its own copy of the same release.
fn sdlDependency(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.OptimizeMode,
    macos_sdk: ?MacosSdk,
) ?*std.Build.Dependency {
    const source = patchedSdl(b) orelse return null;
    return if (macos_sdk) |p|
        b.lazyDependency("sdl", .{
            .target = target,
            .optimize = optimize,
            .sdl_source = source,
            .include_path = p.include,
            .framework_path = p.framework,
            .library_path = p.lib,
        })
    else
        b.lazyDependency("sdl", .{ .target = target, .optimize = optimize, .sdl_source = source });
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
