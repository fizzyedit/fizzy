//! Dashboard: what needs the person, one card at a time. One surface, the Needs-you carousel
//! (`dashboard.view`), a view on the rail by default, drawn from the cards the `dashboard.cards`
//! service offers (`sdk.services.dashboard_cards`): the app, a team layer or a plugin provides
//! them and hears which action the person picked. The plugin owns no cards and no colours of its
//! own; it draws from the host's theme, so another app's look applies.
//!
//! With no provider registered, it shows a small demo of three cards (`src/demo_cards.zig`) so it
//! can be tried. The demo is never registered as the service, so a provider loaded at any time,
//! before or after this plugin, is the one listed; an app with one of its own never sees them.
//!
//! Commands: `dashboard.show` reveals the view wherever it lives; `dashboard.status` answers the
//! carousel's state as ZON (how many cards, which is shown, how many are drawn), for an agent.
const std = @import("std");
const sdk = @import("fizzy_sdk");
const dvui = @import("dvui");
pub const View = @import("src/View.zig");
const demo_cards = @import("src/demo_cards.zig");

/// Injected at build time from `plugin.zig.zon`.
pub const plugin_options = @import("fizzy_plugin_options");
pub const plugin_id = plugin_options.id;

pub const view_id = "dashboard.view";

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
    demo_cards.reset();
    try host.registerSurface(.{
        .id = view_id,
        .owner = &plugin,
        .title = "Dashboard",
        .icon = .{ .tvg = dvui.entypo.documents },
        .keywords = sdk.keywords.ide.sidebar,
        .scrolls_itself = true,
        .draw = drawView,
    });
    try host.registerCommand(.{
        .id = sdk.Plugin.commandId(plugin_id, "show"),
        .owner = &plugin,
        .title = "Show Dashboard",
        .run = cmdShow,
        .icon = dvui.entypo.documents,
    });
    try host.registerCommand(.{
        .id = sdk.Plugin.commandId(plugin_id, "status"),
        .owner = &plugin,
        .title = "Dashboard Status",
        // Its answer is ZON for an agent; a person has the view.
        .visibility = .internal,
        .runWith = cmdStatus,
    });
}

fn deinit(_: *anyopaque) void {
    View.carousel = .{};
    host_ptr = null;
}

fn drawView(_: ?*anyopaque) anyerror!dvui.App.Result {
    const host = host_ptr orelse return .ok;
    View.draw(host);
    return .ok;
}

/// "Show Dashboard": the view, wherever it lives, its place opened if it was shut.
fn cmdShow(state: *anyopaque) anyerror!void {
    const host: *sdk.Host = @ptrCast(@alignCast(state));
    _ = host.revealSurface(view_id);
}

fn cmdStatus(state: *anyopaque, call: *sdk.Command.Call) anyerror!void {
    const host: *sdk.Host = @ptrCast(@alignCast(state));
    const count = View.provider(host).list().len;
    var out: std.Io.Writer.Allocating = .init(call.arena);
    try out.writer.print(".{{ .count = {d}, .index = {d}, .drawn = {d} }}\n", .{ count, View.carousel.index, View.drawn });
    call.result = out.written();
}

test {
    _ = @import("src/Carousel.zig");
    _ = demo_cards;
    _ = View;
}
