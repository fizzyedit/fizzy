const std = @import("std");

/// App-side re-export of the plugin build API (lives in `sdk/`). Plugins should depend on
/// the `sdk/` package directly — see AGENTS.md — not this root package.
///
/// Reached through the dependency rather than by path (`sdk/plugin_sdk.zig`): the app consumes
/// `sdk/` as a package so the two can share one dvui pin, and a file may belong to only one module,
/// so claiming these for the root's build module would make that impossible.
pub const plugin = @import("fizzy_sdk").plugin;

pub fn build(b: *std.Build) !void {
    const windows_msvc_libc_opt = b.option([]const u8, "windows-msvc-libc", "zig libc manifest for *-windows-msvc when cross-compiling; forwarded by packageall for Windows children") orelse null;
    const fetch_msvc_opt = b.option(bool, "fetch-msvc", "If *-windows-msvc libc is missing under .velopack-msvc/, run msvcup-setup first (downloads MSVC+SDK; requires network). Defaults to true on Windows hosts targeting *-windows-msvc.") orelse null;

    const macos_sign_app_identity = b.option([]const u8, "macos-sign-app", "macOS codesign identity for the app bundle (e.g. 'Developer ID Application: NAME (TEAMID)')") orelse
        b.graph.environ_map.get("FIZZY_MACOS_SIGN_APP");
    const macos_sign_install_identity = b.option([]const u8, "macos-sign-installer", "macOS codesign identity for the installer pkg (e.g. 'Developer ID Installer: NAME (TEAMID)')") orelse
        b.graph.environ_map.get("FIZZY_MACOS_SIGN_INSTALLER");
    const macos_notary_profile = b.option([]const u8, "macos-notary-profile", "notarytool keychain profile name (run `xcrun notarytool store-credentials <name>` first)") orelse
        b.graph.environ_map.get("FIZZY_MACOS_NOTARY_PROFILE");

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const base: @import("build/app.zig").Options = .{
        .windows_msvc_libc_opt = windows_msvc_libc_opt,
        .fetch_msvc_opt = fetch_msvc_opt,
        .macos_sign_app_identity = macos_sign_app_identity,
        .macos_sign_install_identity = macos_sign_install_identity,
        .macos_notary_profile = macos_notary_profile,
        // What fizzy-the-app ships in its web build beyond the built-ins. The browser cannot
        // load a plugin at runtime, so this is the one place a third-party plugin is named
        // in this repo — as build data, the way an app built on fizzy lists its own. By
        // directory while the plugin is a sibling checkout (see `Options.web_plugin_dirs`);
        // by URL-pinned dependency (`web_plugin_deps`) once it is published.
        // Empty on purpose: web plugins load at runtime as side modules (`?plugin=<id>`, and
        // the store). A checkout can still be bundled statically here while developing it —
        // `.{ .dir = "../fizzyedit/atlas", .modules = &.{ .{ .name = "batch2d", .root =
        // "src/batch2d/root.zig" }, … } }`.
        .web_plugin_dirs = &.{},
    };

    // A consumer that bundles plugins of its own cannot say so through `b.dependency`
    // options (a plugin is a module from another package, not a value), so it passes
    // `defer-app` here and calls `buildApp` below with its plugin modules instead.
    const app = @import("build/app.zig");
    const cfg = try app.readConfig(b, target, base);
    if (b.option(bool, "defer-app", "Do not build the application here; the consumer calls `buildApp` with its own plugins") orelse false) {
        deferred = .{ .target = target, .optimize = optimize, .base = base, .cfg = cfg };
        return;
    }
    try app.construct(b, target, optimize, base, cfg);
}

/// What `build` parsed for a `defer-app` consumer, so `buildApp` need not re-declare the
/// standard options on the same builder.
var deferred: ?struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    base: @import("build/app.zig").Options,
    cfg: @import("build/app.zig").Config,
} = null;

pub const BundledPlugin = @import("build/sdk.zig").BundledPlugin;

/// Fizzy's own plugins, as entries in the list `buildApp` links: `fizzy.plugins.text`, or
/// `fizzy.plugins.all` for every one in fizzy's own order. Fizzy builds each for every executable.
/// `workbench` must be listed for now, because the editor still holds its state
/// (fizzyedit/plans#13).
pub const plugins = @import("build/plugins.zig").entries;

/// Build the application in a consumer's graph, with the plugins the consumer bundles.
///
/// ```zig
/// const fizzy = @import("fizzy");
/// const fizzy_dep = b.dependency("fizzy", .{
///     .target = target,
///     .optimize = optimize,
///     .@"defer-app" = true,
///     .@"app-name" = @as([]const u8, "myapp"),
///     .@"app-layout" = b.path("src/layout.zig"),
/// });
/// try fizzy.buildApp(fizzy_dep, &.{
///     fizzy.plugins.workbench,
///     fizzy.plugins.text,
///     .{ .name = "pixi", .module = b.dependency("pixi", .{ .target = target, .optimize = optimize }).module("plugin") },
/// });
/// b.installArtifact(fizzy_dep.artifact("myapp"));
/// ```
///
/// `linked` is everything the app links, in registration order (the order of the sidebar's
/// views): fizzy's own (`fizzy.plugins`) and the app's. For an app's, `name` is the plugin's id
/// (its root's `plugin_id`) and `module` its static module, which the plugin package exports and
/// which fizzy wires to `dvui`, `core`, `fizzy_sdk` and `icons`.
pub fn buildApp(fizzy_dep: *std.Build.Dependency, linked: []const BundledPlugin) !void {
    const d = deferred orelse @panic("fizzy.buildApp: pass `.@\"defer-app\" = true` to b.dependency(\"fizzy\", …) first");
    var opts = d.base;
    // Until fizzyedit/example-app lists fizzy's plugins itself (its CI and fizzy's build each
    // other's main): a list naming none of fizzy's gets all of them ahead of its own, as before.
    // Goes in fizzyedit/plans#13 step 2.
    const names_fizzys = for (linked) |p| {
        if (p.module == null) break true;
    } else false;
    opts.app_plugins = if (names_fizzys) linked else try std.mem.concat(fizzy_dep.builder.allocator, BundledPlugin, &.{ &plugins.all, linked });
    try @import("build/app.zig").construct(fizzy_dep.builder, d.target, d.optimize, opts, d.cfg);
}

/// What a dvui app of its own builds on (`addDvui`): fizzy's backend, with OS windows besides the
/// main one, or dvui's own SDL3 backend, with the main window only.
pub const NativeBackend = @import("build/exe.zig").NativeBackend;

/// A plain dvui app — dvui's widgets and `dvui.App`, nothing of fizzy the editor — on `backend`:
/// `root_module` gets `dvui` (fizzy's pin), its `backend`, and `viewports_none`, so the same code
/// builds on either backend:
///
/// ```zig
/// const backend = @import("backend");
/// const viewports = if (@hasDecl(backend, "viewports")) backend.viewports else @import("viewports_none");
/// ```
///
/// On fizzy's backend it also gets `platform` (the window's chrome and state), and on macOS the
/// backend's Objective-C, compiled into it. Give `root_module` its target and optimize mode first.
pub fn addDvui(fizzy_dep: *std.Build.Dependency, root_module: *std.Build.Module, backend: NativeBackend) !void {
    const b = fizzy_dep.builder;
    const exe = @import("build/exe.zig");
    const target = root_module.resolved_target orelse @panic("fizzy.addDvui: give the root module its target first");
    const optimize = root_module.optimize orelse .Debug;
    const macos_sdl_paths = try @import("build/common.zig").macosSdlPathsForExplicitTarget(b, target);
    const native = exe.nativeDvui(b, backend, target, optimize, .off, macos_sdl_paths);
    root_module.addImport("dvui", native.dvui);
    root_module.addImport("backend", native.backend);
    const backend_dep = exe.backendDependency(b);
    root_module.addImport("viewports_none", @import("fizzy_backend").viewportsNoneModule(backend_dep, native.dvui));
    if (backend == .fizzy) {
        root_module.addImport("platform", exe.platformModule(b, native, target, optimize, macos_sdl_paths));
        @import("fizzy_backend").addPlatformObjC(backend_dep, root_module, exe.backendOptions(target, optimize, macos_sdl_paths));
    }
}
