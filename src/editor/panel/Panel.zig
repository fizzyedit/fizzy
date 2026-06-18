const std = @import("std");
const builtin = @import("builtin");

const dvui = @import("dvui");
const fizzy = @import("../../fizzy.zig");

const Core = @import("mach").Core;
const App = fizzy.App;
const Editor = fizzy.Editor;
const Packer = fizzy.Packer;

pub const Panel = @This();

paned: *fizzy.dvui.PanedWidget = undefined,
scroll_info: dvui.ScrollInfo = .{
    .horizontal = .auto,
},

pub fn init() Panel {
    return .{};
}

pub fn deinit(_: *Panel) void {}

pub fn draw(_: *Panel) !dvui.App.Result {
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

    const host = &fizzy.editor.host;

    // Tab strip across registered bottom views; one active at a time. With a single
    // view we skip the strip so the panel looks exactly as before (no lone tab).
    if (host.bottom_views.items.len > 1) try drawTabStrip(host);

    if (host.activeBottomView()) |view| {
        try view.draw(view.ctx);
    }

    return .ok;
}

fn drawTabStrip(host: *fizzy.Editor.Host) !void {
    var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .background = false,
    });
    defer hbox.deinit();

    const theme = dvui.themeGet();
    for (host.bottom_views.items, 0..) |*view, i| {
        const selected = host.isActiveBottomView(view.id);
        if (dvui.button(@src(), view.title, .{ .draw_focus = false }, .{
            .id_extra = i,
            .style = if (selected) .highlight else .window,
            .color_text = if (selected) theme.color(.highlight, .text) else theme.color(.window, .text),
        })) {
            host.setActiveBottomView(view.id);
        }
    }
}
