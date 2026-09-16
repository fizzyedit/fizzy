const std = @import("std");

/// The repo's one dvui, borrowed from the `sdk/` package instead of pinned by the app.
///
/// dvui is not a dependency of the root package at all: `sdk/build.zig.zon` declares the only pin
/// and this reaches through to it, so there is a single place to bump a version or point at a local
/// checkout. `args` is forwarded to dvui's own build untouched (backend, target, optimize, …), so
/// callers keep full control of *how* it is built; only *which* dvui is shared.
///
/// Worth the indirection because the two are not free to disagree. dvui types reachable from the
/// plugin boundary feed `dylib.sdk_shape_fingerprint`, which both the app build and the plugin-SDK
/// build check against the single `recorded_sdk_shape_fingerprint` literal in `sdk/src/version.zig`.
/// When each build compiled a different dvui, they computed different fingerprints from that one
/// literal and no value satisfied both — every fix broke the other side, and the error blamed
/// `sdk_version`, which a bump cannot repair. One pin makes that state unreachable rather than
/// merely discouraged.
///
/// The direction is forced: `sdk/` ships standalone as `fizzy-sdk-v*.tar.gz` for third-party
/// plugins, so it must carry its own pin and can never read anything above its own root. The app
/// can always reach down into it.
pub fn dvuiDependency(b: *std.Build, args: anytype) *std.Build.Dependency {
    // Only the SDK package's resolved dependency table is wanted here, not its artifacts, so its
    // own target/optimize are left at default; `args` carries the target dvui is really built for.
    return b.dependency("fizzy_sdk", .{}).builder.dependency("dvui", args);
}

pub fn addProxyBridgeModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    dvui_dep: *std.Build.Dependency,
    dvui_module: *std.Build.Module,
) *std.Build.Module {
    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = dvui_dep.path("src/backends/proxy_bridge.zig"),
    });
    mod.addImport("dvui", dvui_module);
    return mod;
}

pub fn wireSdkModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    dvui_module: *std.Build.Module,
    proxy_bridge_module: *std.Build.Module,
    core_module: *std.Build.Module,
    consumer: ?*std.Build.Module,
) *std.Build.Module {
    const sdk_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("sdk/src/sdk.zig"),
    });
    sdk_module.addImport("dvui", dvui_module);
    sdk_module.addImport("proxy_bridge", proxy_bridge_module);
    sdk_module.addImport("core", core_module);
    // `sdk_version` as a *named* module rather than a relative `@import`: `sdk/sdk_version.zig`
    // is the single edit site for the triplet, but it sits outside this module's root
    // (`sdk/src/`), and Zig confines a module's relative imports to its own root — a named
    // module is the only way in. Wired identically on the third-party path in
    // `sdk/plugin_sdk.zig`'s `exportModules`; both must stay in step or `version.zig` fails to
    // compile (loudly, at the first build).
    sdk_module.addImport("sdk_version", b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("sdk/sdk_version.zig"),
    }));
    if (consumer) |c| c.addImport("fizzy_sdk", sdk_module);
    return sdk_module;
}

/// Create the `app` module — the framework an application switches on (the plugin store today).
///
/// Separate from `core` because of the dylib boundary: this may depend on the network, the
/// filesystem and `dlopen`, none of which belongs inside a plugin. Wired the same way for the
/// exe, the web build and the tests so the three cannot drift.
pub fn wireAppModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    dvui_module: *std.Build.Module,
    core_module: *std.Build.Module,
    sdk_module: *std.Build.Module,
    icons_module: ?*std.Build.Module,
    markdown_module: ?*std.Build.Module,
    /// The filesystem-watching backend, when this build has one. Absent on the web, where the
    /// watchers are never started.
    nightwatch_module: ?*std.Build.Module,
    /// The application's build-time identity and feature flags — its repo url, whether it ships
    /// an updater. Each app generates its own; fizzy's is `build/exe.zig`'s options step.
    build_opts: *std.Build.Step.Options,
    /// The single-instance backend (unix sockets / named pipes), when this build has one.
    /// Absent on the web, where one tab is one application.
    singleton_module: ?*std.Build.Module,
    consumer: ?*std.Build.Module,
) *std.Build.Module {
    const app_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("app/root.zig"),
    });
    app_module.addImport("dvui", dvui_module);
    app_module.addImport("core", core_module);
    app_module.addImport("fizzy_sdk", sdk_module);
    if (icons_module) |icons| app_module.addImport("icons", icons);
    if (markdown_module) |md| app_module.addImport("markdown", md);
    if (nightwatch_module) |nw| app_module.addImport("nightwatch", nw);
    app_module.addImport("build_opts", buildOptsModule(build_opts));
    if (singleton_module) |sm| app_module.addImport("singleton_app", sm);
    if (consumer) |c| c.addImport("app", app_module);
    return app_module;
}

/// One module per `Options` step, shared by every consumer.
///
/// `addOptions` creates a *new* module each time it is called, and the generated `options.zig`
/// would then belong to two of them — which Zig refuses outright ("file exists in modules
/// build_opts and build_opts0"). The exe, the web build, the tests and the `app` module all read
/// the same options, so they must all read the same module.
var build_opts_modules: std.AutoHashMapUnmanaged(*std.Build.Step.Options, *std.Build.Module) = .empty;

pub fn buildOptsModule(opts: *std.Build.Step.Options) *std.Build.Module {
    if (build_opts_modules.get(opts)) |m| return m;
    const m = opts.createModule();
    build_opts_modules.put(opts.step.owner.graph.arena, opts, m) catch @panic("OOM");
    return m;
}

pub const BundledPlugin = struct {
    /// The plugin's import name and id — `plugin_id` in its root, `plugin.zig.zon`'s `.id`.
    name: []const u8,
    /// Null for a plugin this target does not build (markdown on wasm); it is left out.
    module: ?*std.Build.Module,
};

/// The generated `bundled_plugins` module: `pub const modules = .{ @import("a"), @import("b") … }`
/// over the statically linked plugins, in order. The runtime (`app.App`) iterates it at
/// comptime for registration, the bundled-id check and each built-in's manifest; nothing in
/// the runtime names a plugin.
pub fn bundledPluginsModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    plugins: []const BundledPlugin,
) *std.Build.Module {
    var src = std.ArrayList(u8).empty;
    src.appendSlice(b.allocator, "//! Generated by the build: the plugins this application links in.\npub const modules = .{\n") catch @panic("OOM");
    for (plugins) |p| {
        if (p.module == null) continue;
        src.appendSlice(b.allocator, "    @import(\"") catch @panic("OOM");
        src.appendSlice(b.allocator, p.name) catch @panic("OOM");
        src.appendSlice(b.allocator, "\"),\n") catch @panic("OOM");
    }
    src.appendSlice(b.allocator, "};\n") catch @panic("OOM");
    const wf = b.addWriteFiles();
    const root = wf.add("bundled_plugins.zig", src.items);
    const mod = b.createModule(.{ .root_source_file = root, .target = target, .optimize = optimize });
    for (plugins) |p| {
        if (p.module) |m| mod.addImport(p.name, m);
    }
    return mod;
}
