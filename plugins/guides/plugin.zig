//! Guides: every demo the app can play, a click away (fizzyedit/plans#30). One surface, a view on
//! the rail (`guides.view`) listing what the `demos` service lists — fizzy's own tour first, then
//! each a plugin registered (`Host.registerDemo`) — each with its length and chapters. A click on
//! a guide plays it from the start, a click on a chapter from there; the one playing is marked.
//!
//! It is drawn from what any plugin can reach (`sdk.services.demos`), which is the point of it
//! being a plugin: an app on fizzy bundles it or leaves it out, and one with no demo player gets
//! a view saying so.
//!
//! Commands: `guides.show` reveals the view wherever it lives.
const std = @import("std");
const sdk = @import("fizzy_sdk");
const dvui = @import("dvui");
const List = @import("src/List.zig");

/// Injected at build time from `plugin.zig.zon`.
pub const plugin_options = @import("fizzy_plugin_options");
pub const plugin_id = plugin_options.id;

pub const view_id = "guides.view";

var plugin: sdk.Plugin = .{
    .state = undefined,
    .vtable = &vtable,
    .id = plugin_id,
    .display_name = plugin_options.name,
};

const vtable: sdk.Plugin.VTable = .{ .deinit = deinit };

var host_ptr: ?*sdk.Host = null;

pub fn register(host: *sdk.Host) !void {
    host_ptr = host;
    plugin.state = @ptrCast(host);
    try host.registerPlugin(&plugin);
    try host.registerSurface(.{
        .id = view_id,
        .owner = &plugin,
        .title = "Guides",
        .icon = .{ .tvg = dvui.entypo.graduation_cap },
        .keywords = sdk.keywords.ide.sidebar,
        .scrolls_itself = true,
        .draw = drawView,
    });
    try host.registerCommand(.{
        .id = sdk.Plugin.commandId(plugin_id, "show"),
        .owner = &plugin,
        .title = "Show Guides",
        .run = cmdShow,
        .icon = dvui.entypo.graduation_cap,
    });
}

fn deinit(state: *anyopaque) void {
    const host: *sdk.Host = @ptrCast(@alignCast(state));
    List.deinit(host.allocator);
    host_ptr = null;
}

fn drawView(_: ?*anyopaque) anyerror!dvui.App.Result {
    const host = host_ptr orelse return .ok;
    List.draw(host.allocator, host.getServiceTyped(sdk.services.demos.Api));
    return .ok;
}

/// "Show Guides": the view, wherever it lives, its place opened if it was shut.
fn cmdShow(state: *anyopaque) anyerror!void {
    const host: *sdk.Host = @ptrCast(@alignCast(state));
    _ = host.revealSurface(view_id);
}
