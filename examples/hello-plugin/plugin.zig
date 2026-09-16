//! One surface, keyworded for the sidebar, drawing a label. Everything a plugin must have and
//! nothing else — copy this before `plugins/text` when the plugin owns no documents.
const std = @import("std");
const sdk = @import("fizzy_sdk");
const dvui = @import("dvui");

pub const plugin_options = @import("fizzy_plugin_options");
pub const plugin_id = plugin_options.id;

var plugin: sdk.Plugin = .{
    .state = undefined,
    .vtable = &vtable,
    .id = plugin_id,
    .display_name = plugin_options.name,
};

const vtable: sdk.Plugin.VTable = .{};

var frames: u64 = 0;

pub fn register(host: *sdk.Host) !void {
    plugin.state = @ptrCast(&frames);
    try host.registerPlugin(&plugin);
    try host.registerSurface(.{
        .id = "hello.greeting",
        .owner = &plugin,
        .icon = .{ .tvg = dvui.entypo.emoji_happy },
        .title = "Hello",
        .keywords = sdk.keywords.ide.sidebar,
        .draw = draw,
    });
}

fn draw(_: ?*anyopaque) anyerror!dvui.App.Result {
    frames += 1;
    dvui.label(@src(), "Hello from a bundled plugin ({d} frames)", .{frames}, .{ .padding = dvui.Rect.all(8) });
    return .ok;
}
