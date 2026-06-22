//! Example plugin — the canonical, minimal Fizzy plugin and the copy-me template for new
//! plugins. It registers a single sidebar view that renders a greeting and a click counter:
//! the smallest useful shape, namely identity + `register` + one `Host.register*` contribution
//! + plugin-owned state. The host injects only the allocator and `*Host` (read through
//! `sdk.allocator()` / `sdk.host()`), so there is no storage file to write.
//!
//! This plugin implements no document hooks — it is a "shell" plugin (contributes a pane), not
//! an "editor" plugin (opens/saves/draws files). For the editor shape, see the `code` plugin.
//!
//! To start a new plugin: copy this folder, rename the id/name, and implement your feature in
//! `src/plugin.zig`. See docs/PLUGINS.md.
const std = @import("std");
// Shared deps + sibling types come through the plugin's `<name>.zig` hub (`../example.zig`),
// the conventional `@import("<package>")` namespace. A single-file plugin could import `sdk`
// and `dvui` directly; using the hub is what scales as `src/` grows.
const example = @import("../example.zig");
const sdk = example.sdk;
const dvui = example.dvui;
const State = example.State;

/// Build-injected options. `version` is forwarded from this plugin's `build.zig.zon` (see the
/// `fizzy.plugin.create` call in `build.zig`), so the release version lives in exactly one place.
const plugin_options = @import("fizzy_plugin_options");

/// Identity + versions embedded in the dylib (and read by the host on load). Bump the version in
/// `build.zig.zon`, not here — `manifest.version` reads it from the injected options module.
pub const manifest = sdk.PluginManifest{
    .id = "example",
    .name = "Example",
    .version = plugin_options.version,
};

/// Stable, plugin-namespaced contribution id.
const view_hello = "example.hello";

var plugin: sdk.Plugin = .{
    .state = undefined,
    .vtable = &vtable,
    .id = "example",
    .display_name = "Example",
};

/// Only the hooks this plugin needs; every other vtable field stays `null`.
const vtable: sdk.Plugin.VTable = .{
    .deinit = deinit,
};

/// The plugin's own singleton state — just a variable it owns. The SDK holds gpa/host.
var plugin_state: State = .{};

/// Entry point the host calls once at startup (static) or after dlopen (dynamic). Wire state,
/// register the plugin, then add any sidebar/bottom/center/menu/settings contributions.
pub fn register(host: *sdk.Host) !void {
    plugin.state = @ptrCast(&plugin_state);
    try host.registerPlugin(&plugin);
    try host.registerSidebarView(.{
        .id = view_hello,
        .owner = &plugin,
        .icon = dvui.entypo.rocket,
        .title = "Example",
        .draw = drawHello,
    });
}

/// Stable `*Plugin` for constructing `DocHandle.owner` / lookups (unused here, but part of the
/// conventional plugin surface).
pub fn pluginPtr() *sdk.Plugin {
    return &plugin;
}

fn deinit(_: *anyopaque) void {
    plugin_state.deinit(sdk.allocator());
}

/// Fills the left pane while this sidebar view is active.
fn drawHello(_: ?*anyopaque) anyerror!void {
    var box = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .margin = .all(8) });
    defer box.deinit();

    dvui.label(@src(), "Hello from the example plugin!", .{}, .{});
    dvui.label(@src(), "Clicks: {d}", .{plugin_state.clicks}, .{});
    if (dvui.button(@src(), "Click me", .{}, .{ .expand = .horizontal })) {
        plugin_state.clicks += 1;
    }
}
