//! The guides view's one list: a row per demo (its title and length), and under it a row per
//! chapter (its title and where it starts). A row plays from where it says; the demo playing is
//! drawn as selected. The service refuses a demo over unsaved work or while a live tape drives,
//! and tells the person why itself.
const std = @import("std");
const sdk = @import("fizzy_sdk");
const dvui = @import("dvui");
const core = @import("core");

const Api = sdk.services.demos.Api;

pub fn draw(service: ?*Api) void {
    var scroll = dvui.scrollArea(@src(), .{ .horizontal = .none, .vertical_bar = .auto_overlay }, .{ .expand = .both, .background = false });
    defer scroll.deinit();
    var body = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .padding = .all(6) });
    defer body.deinit();

    const api = service orelse {
        dvui.labelNoFmt(@src(), "This app plays no demos.", .{}, .{ .color_text = .{ .color = dim() } });
        return;
    };
    const demos = api.list();
    if (demos.len == 0) {
        dvui.labelNoFmt(@src(), "No guides yet.", .{}, .{ .color_text = .{ .color = dim() } });
        return;
    }
    const playing = api.current();
    for (demos, 0..) |d, i| {
        const current = if (playing) |p| std.mem.eql(u8, p, d.name) else false;
        if (row(i * 1000, d.title, d.ms, current, .guide)) _ = api.play(d.name, 0);
        for (d.chapters, 0..) |c, j| {
            // The first chapter is where the guide starts: its row would say the same as the guide's.
            if (c.at == 0) continue;
            if (row(i * 1000 + j + 1, c.title, c.at, false, .chapter)) _ = api.play(d.name, c.at);
        }
    }
}

const Kind = enum { guide, chapter };

/// A row the width of the view, `title` on the left and `ms` as a time on the right: a guide's
/// length, or where a chapter starts. True when clicked.
fn row(id_extra: usize, title: []const u8, ms: u32, selected: bool, kind: Kind) bool {
    const theme = dvui.themeGet();
    var button: dvui.ButtonWidget = undefined;
    button.init(@src(), .{ .draw_focus = true }, .{
        .id_extra = id_extra,
        .expand = .horizontal,
        .margin = .{ .x = if (kind == .chapter) 14 else 0, .y = if (kind == .guide) 4 else 0 },
        .padding = .{ .x = 6, .w = 6, .y = 3, .h = 3 },
        .color_fill = .{ .color = if (selected) theme.color(.highlight, .fill) else core.widgets.hoverRestFill(theme.color(.window, .fill_hover)) },
        .color_fill_hover = .{ .color = theme.color(.window, .fill_hover) },
        .color_fill_press = .{ .color = theme.color(.window, .fill_press) },
    });
    defer button.deinit();
    button.processEvents();
    button.drawBackground();

    var line = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    defer line.deinit();
    const text_color: dvui.Color = if (selected) theme.color(.highlight, .text) else if (kind == .chapter) dim() else theme.color(.window, .text);
    // The time first: a box gives its children room in order, so it always fits and a long title
    // is the one cut short.
    var buf: [16]u8 = undefined;
    dvui.labelNoFmt(@src(), clock(&buf, ms), .{}, .{ .gravity_x = 1, .gravity_y = 0.5, .margin = .{ .x = 8 }, .color_text = .{ .color = if (selected) text_color else dim() } });
    dvui.labelNoFmt(@src(), title, .{}, .{ .color_text = .{ .color = text_color }, .gravity_y = 0.5 });
    return button.clicked();
}

/// `ms` as m:ss.
fn clock(buf: []u8, ms: u32) []const u8 {
    const s = ms / 1000;
    return std.fmt.bufPrint(buf, "{d}:{d:0>2}", .{ s / 60, s % 60 }) catch "";
}

fn dim() dvui.Color {
    return dvui.themeGet().color(.window, .text).opacity(0.6);
}
