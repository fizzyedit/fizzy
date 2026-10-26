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
/// build check against the single `recorded_sdk_shape_fingerprint` literal in
/// `sdk/src/version.zig`.
/// When each build compiled a different dvui, they computed different fingerprints from that one
/// literal and no value satisfied both — every fix broke the other side, and the error blamed
/// `sdk_version`, which a bump cannot repair. One pin makes that state unreachable rather than
/// merely discouraged.
///
/// The direction is forced: `sdk/` ships standalone as `fizzy-sdk-v*.tar.gz` for third-party
/// plugins, so it must carry its own pin and can never read anything above its own root. The app
/// can always reach down into it.
// anytype: Dependency options are an open tuple forwarded to std.Build.
pub fn dvuiDependency(b: *std.Build, args: anytype) *std.Build.Dependency {
    // Only the SDK package's resolved dependency table is wanted here, not its artifacts, so its
    // own target/optimize are left at default; `args` carries the target dvui is really built for.
    return b.dependency("fizzy_sdk", .{}).builder.dependency("dvui", args);
}

pub fn addProxyBridgeModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.OptimizeMode,
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
    optimize: std.lang.OptimizeMode,
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
    optimize: std.lang.OptimizeMode,
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
    // Demo automation (`sdk/tape/`, `sdk/replay/`): the very modules `core` was given
    // (`core_module.addImports`), so a `Tape` here is the `Tape` there.
    app_module.addImport("tape", core_module.import_table.get("tape").?);
    app_module.addImport("replay", core_module.import_table.get("replay").?);
    app_module.addImport("crash", crashModule(b, target, optimize));
    // The remote-view protocol (`sdk/remote/`): std-only, so a host application's adapter links the
    // same files.
    app_module.addImport(
        "remote",
        b.createModule(.{ .target = target, .optimize = optimize, .root_source_file = b.path("sdk/remote/root.zig") }),
    );
    if (consumer) |c| {
        c.addImport("app", app_module);
        // The bundled demos' scripts (`src/editor/demos/`) need only `tape`, so they build on the
        // host too (`zig build demos`).
        c.addImport("tape", core_module.import_table.get("tape").?);
    }
    return app_module;
}

/// Crash reports (`app/crash/`): std-only, a module of its own so the plugin loader reaches it
/// from a test rooted at the loader as well as from the app.
pub fn crashModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.OptimizeMode) *std.Build.Module {
    return b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("app/crash/crash.zig"),
    });
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

/// The kinds of executable an app builds: the desktop ones (the plain executable and the one
/// `package` packs share a framework) and the web one.
pub const Platform = enum { native, web };

pub const BundledPlugin = struct {
    /// The plugin's import name and id — `plugin_id` in its root, `plugin.zig.zon`'s `.id`.
    name: []const u8,
    /// The plugin's static module. Null for one of fizzy's own (`fizzy.plugins`), which fizzy
    /// builds for each executable.
    module: ?*std.Build.Module = null,
    /// The kinds of executable that link it, each with its own module if it has one (built
    /// against that kind's framework). Null: every kind, with `module`.
    targets: ?[]const Target = null,

    pub const Target = struct {
        target: Platform,
        /// Null: the plugin's `module`.
        module: ?*std.Build.Module = null,
    };

    /// One of fizzy's own: no module for any executable.
    pub fn isFizzys(self: BundledPlugin) bool {
        if (self.module != null) return false;
        for (self.targets orelse &.{}) |t| if (t.module != null) return false;
        return true;
    }

    /// The entry as `platform`'s executables link it, or null if they do not.
    pub fn forPlatform(self: BundledPlugin, platform: Platform) ?BundledPlugin {
        const targets = self.targets orelse return self;
        for (targets) |t| if (t.target == platform) return .{
            .name = self.name,
            .module = t.module orelse self.module,
        };
        return null;
    }
};

/// The plugins `platform`'s executables link, in order, each with that kind's module.
pub fn pluginsFor(b: *std.Build, plugins: []const BundledPlugin, platform: Platform) ![]const BundledPlugin {
    var linked: std.ArrayList(BundledPlugin) = .empty;
    for (plugins) |p| {
        const entry = p.forPlatform(platform) orelse continue;
        for (linked.items) |l| if (std.mem.eql(u8, l.name, entry.name)) {
            std.log.err("fizzy: plugin '{s}' is listed twice", .{entry.name});
            return error.PluginListedTwice;
        };
        try linked.append(b.allocator, entry);
    }
    return linked.items;
}

/// The generated `bundled_plugins` module: `pub const modules = .{ @import("a"), @import("b") … }`
/// over the statically linked plugins, in order. The runtime (`app.App`) iterates it at
/// comptime for registration, the bundled-id check and each built-in's manifest; nothing in
/// the runtime names a plugin.
pub fn bundledPluginsModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.OptimizeMode,
    plugins: []const BundledPlugin,
) *std.Build.Module {
    var src = std.ArrayList(u8).empty;
    src.appendSlice(
        b.allocator,
        "//! Generated by the build: the plugins this application links in.\npub const " ++
            "modules = .{\n",
    ) catch @panic("OOM");
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

/// Wire an app-owned code or ZON layout against this target's framework modules.
pub fn wireAppLayout(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.OptimizeMode,
    app_layout: ?std.Build.LazyPath,
    dvui: *std.Build.Module,
    app: *std.Build.Module,
    core: *std.Build.Module,
    sdk_module: *std.Build.Module,
    consumer: *std.Build.Module,
) void {
    if (app_layout) |path| {
        const is_zon = std.mem.endsWith(u8, path.getDisplayName(), ".zon");
        const app_layout_mod = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = if (is_zon) b.addWriteFiles().add("app_layout_spec.zig", spec_shim) else path,
        });
        if (is_zon) app_layout_mod.addAnonymousImport("app_layout_spec", .{ .root_source_file = path });
        app_layout_mod.addImport("dvui", dvui);
        app_layout_mod.addImport("app", app);
        app_layout_mod.addImport("core", core);
        app_layout_mod.addImport("fizzy_sdk", sdk_module);
        consumer.addImport("app_layout", app_layout_mod);
    }
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
