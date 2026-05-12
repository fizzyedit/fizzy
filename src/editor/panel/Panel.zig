const std = @import("std");
const builtin = @import("builtin");

const dvui = @import("dvui");
const fizzy = @import("../../fizzy.zig");

const Core = @import("mach").Core;
const App = fizzy.App;
const Editor = fizzy.Editor;
const Packer = fizzy.Packer;

pub const Panel = @This();

pub const Sprites = @import("sprites.zig");

sprites: Sprites = .{},
pane: Pane = .sprites,
paned: *fizzy.dvui.PanedWidget = undefined,
scroll_info: dvui.ScrollInfo = .{
    .horizontal = .auto,
},

pub const Pane = enum(u32) {
    sprites,
};

pub fn init() Panel {
    return .{};
}

pub fn deinit(_: *Panel) void {}

pub fn draw(panel: *Panel) !dvui.App.Result {
    // var scroll_area = dvui.scrollArea(@src(), .{ .scroll_info = &panel.scroll_info }, .{
    //     .expand = .both,
    // });
    // defer scroll_area.deinit();

    var content_color = dvui.themeGet().color(.window, .fill);

    switch (builtin.os.tag) {
        .macos => {
            content_color = if (!fizzy.backend.isMaximized(dvui.currentWindow())) content_color.opacity(fizzy.editor.settings.content_opacity) else content_color;
        },
        .windows => {
            content_color = if (!fizzy.backend.isMaximized(dvui.currentWindow())) content_color.opacity(fizzy.editor.settings.content_opacity) else content_color;
        },
        else => {},
    }

    var vbox = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = true,
        .color_fill = content_color,
    });
    defer vbox.deinit();

    switch (panel.pane) {
        .sprites => try panel.sprites.draw(),
    }

    return .ok;
}
