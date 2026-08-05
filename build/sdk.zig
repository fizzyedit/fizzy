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
/// build check against the single `recorded_sdk_shape_fingerprint` literal in `src/sdk/version.zig`.
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
        .root_source_file = b.path("src/sdk/sdk.zig"),
    });
    sdk_module.addImport("dvui", dvui_module);
    sdk_module.addImport("proxy_bridge", proxy_bridge_module);
    sdk_module.addImport("core", core_module);
    // `sdk_version` as a *named* module rather than a relative `@import`: `sdk/sdk_version.zig`
    // is the single edit site for the triplet, but it sits outside this module's root
    // (`src/sdk/`), and Zig confines a module's relative imports to its own root — a named
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
