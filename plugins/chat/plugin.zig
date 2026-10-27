//! Chat: a conversation and its composer, over the `chat.provider` service. One surface for the
//! sidebar (`chat.view`) draws the provider's messages and a composer; whoever has a conversation
//! (the host app, a team plugin) registers the provider and this shows it. Owns no conversation:
//! when nothing offers one it registers a small in-memory one, so the surface can be tried alone.
//!
//! Commands: `chat.show` reveals the view wherever it lives.
const std = @import("std");
const sdk = @import("fizzy_sdk");
const dvui = @import("dvui");
pub const DemoProvider = @import("src/DemoProvider.zig");
pub const View = @import("src/View.zig");

/// Injected at build time from `plugin.zig.zon`.
pub const plugin_options = @import("fizzy_plugin_options");
pub const plugin_id = plugin_options.id;

pub const view_id = "chat.view";

var plugin: sdk.Plugin = .{
    .state = undefined,
    .vtable = &vtable,
    .id = plugin_id,
    .display_name = plugin_options.name,
};

const vtable: sdk.Plugin.VTable = .{ .deinit = deinit };

var host_ptr: ?*sdk.Host = null;
var view: View = .{};
var demo: DemoProvider = undefined;
var demo_api: sdk.services.chat.Api = undefined;
var demo_registered = false;

pub fn register(host: *sdk.Host) !void {
    host_ptr = host;
    plugin.state = @ptrCast(host);
    try host.registerPlugin(&plugin);
    try host.registerSurface(.{
        .id = view_id,
        .owner = &plugin,
        .title = "Chat",
        .icon = .{ .tvg = dvui.entypo.chat },
        .keywords = sdk.keywords.ide.sidebar,
        .scrolls_itself = true,
        .draw = drawView,
    });
    try host.registerCommand(.{
        .id = sdk.Plugin.commandId(plugin_id, "show"),
        .owner = &plugin,
        .title = "Show Chat",
        .run = cmdShow,
        .icon = dvui.entypo.chat,
    });
    if (host.getServiceTyped(sdk.services.chat.Api) == null) {
        demo = .{ .allocator = host.allocator };
        demo_api = demo.api();
        try host.registerService(sdk.services.chat.Api, &demo_api, &plugin);
        demo_registered = true;
    }
}

fn deinit(state: *anyopaque) void {
    const host: *sdk.Host = @ptrCast(@alignCast(state));
    view.deinit(host.allocator);
    view = .{};
    if (demo_registered) demo.deinit();
    demo_registered = false;
    host_ptr = null;
}

// lint-allow(anyerror): the surface draw signature is the SDK's
fn drawView(_: ?*anyopaque) anyerror!dvui.App.Result {
    const host = host_ptr orelse return .ok;
    view.draw(host.allocator, host.getServiceTyped(sdk.services.chat.Api));
    return .ok;
}

/// "Show Chat": the view, wherever it lives, its place opened if it was shut.
// lint-allow(anyerror): the command run signature is the SDK's
fn cmdShow(state: *anyopaque) anyerror!void {
    const host: *sdk.Host = @ptrCast(@alignCast(state));
    _ = host.revealSurface(view_id);
}

test {
    _ = DemoProvider;
}
