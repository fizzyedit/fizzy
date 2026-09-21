const std = @import("std");

/// App-side re-export of the plugin build API (lives in `sdk/`). Plugins should depend on
/// the `sdk/` package directly — see CLAUDE.md — not this root package.
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
    const cfg = try app.readConfig(b, target, base) orelse return;
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
///     .{ .name = "pixi", .module = b.dependency("pixi", .{ .target = target, .optimize = optimize }).module("plugin") },
/// });
/// b.installArtifact(fizzy_dep.artifact("myapp"));
/// ```
///
/// `name` is the plugin's id (its root's `plugin_id`); `module` its static module, which the
/// plugin package exports and which fizzy wires to `dvui`, `core`, `fizzy_sdk` and `icons`.
/// Fizzy's own four are always bundled ahead of these.
pub fn buildApp(fizzy_dep: *std.Build.Dependency, plugins: []const BundledPlugin) !void {
    const d = deferred orelse @panic("fizzy.buildApp: pass `.@\"defer-app\" = true` to b.dependency(\"fizzy\", …) first");
    var opts = d.base;
    opts.app_plugins = plugins;
    try @import("build/app.zig").construct(fizzy_dep.builder, d.target, d.optimize, opts, d.cfg);
}
