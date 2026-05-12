const std = @import("std");
const builtin = @import("builtin");
const fizzy = @import("../fizzy.zig");
const dvui = @import("dvui");
const App = fizzy.App;
const Editor = fizzy.Editor;

const Pane = @import("explorer/Explorer.zig").Pane;

pub const Sidebar = @This();

pub fn init() !Sidebar {
    return .{};
}

pub fn deinit() void {
    // TODO: Free memory
}

pub fn draw(_: Sidebar) !bool {
    const vbox = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .vertical,
        .background = false,
        .min_size_content = .{ .w = 40, .h = 100 },
    });
    defer vbox.deinit();

    const options = [_]struct { pane: Pane, icon: []const u8 }{
        .{ .pane = .files, .icon = dvui.entypo.folder },
        .{ .pane = .tools, .icon = dvui.entypo.pencil },
        .{ .pane = .sprites, .icon = dvui.entypo.grid },
        //.{ .pane = .animations, .icon = dvui.entypo.controller_play },
        //.{ .pane = .keyframe_animations, .icon = dvui.entypo.key },
        .{ .pane = .project, .icon = dvui.entypo.box },
        .{ .pane = .settings, .icon = dvui.entypo.cog },
    };

    var ret: bool = false;

    for (options) |option| {
        if (try drawOption(option.pane, option.icon, 20)) {
            ret = true;
        }
    }

    return ret;
}

fn drawOption(option: Pane, icon: []const u8, size: f32) !bool {
    const selected = option == fizzy.editor.explorer.pane;
    var ret: bool = false;

    const theme = dvui.themeGet();

    var bw: dvui.ButtonWidget = undefined;

    bw.init(@src(), .{}, .{
        .id_extra = @intFromEnum(option),
        .min_size_content = .{ .h = size },
    });
    defer bw.deinit();
    bw.processEvents();

    // Register the button as interactive in the title bar so clicks reach DVUI even when the
    // button overlaps the top drag strip on Windows. Only the topmost sidebar button(s) actually
    // sit inside the strip — anything below is registered harmlessly (no overlap with drag rect).
    if (builtin.os.tag == .windows) {
        const r = bw.data().rectScale().r;
        const strip_h = (fizzy.editor.settings.titlebar_top_buffer + fizzy.editor.settings.titlebar_height) * dvui.windowNaturalScale();
        if (r.y < strip_h) fizzy.backend.pushTitleBarInteractiveRect(r);
    }

    const color: dvui.Color = if (selected) theme.color(.highlight, .fill) else if (bw.hovered()) theme.color(.window, .text) else theme.color(.window, .fill);

    dvui.icon(
        @src(),
        @tagName(option),
        icon,
        .{ .fill_color = color },
        .{
            .min_size_content = .{ .h = size },
        },
    );

    if (bw.clicked()) {
        fizzy.editor.explorer.pane = option;
        dvui.refresh(null, @src(), null);
        ret = true;
    }

    if (!selected) {
        var tooltip: dvui.FloatingTooltipWidget = undefined;
        tooltip.init(@src(), .{
            .active_rect = bw.data().rectScale().r,
            .delay = 350_000,
        }, .{
            .id_extra = @intFromEnum(option),
            .color_fill = dvui.themeGet().color(.window, .fill),
            .border = dvui.Rect.all(0),
            .box_shadow = .{
                .color = .black,
                .shrink = 0,
                .corner_radius = dvui.Rect.all(8),
                .offset = .{ .x = 0, .y = 2 },
                .fade = 4,
                .alpha = 0.2,
            },
        });
        defer tooltip.deinit();

        if (tooltip.shown()) {
            var animator = dvui.animate(@src(), .{
                .kind = .alpha,
                .duration = 350_000,
            }, .{
                .expand = .both,
            });
            defer animator.deinit();

            var vbox2 = dvui.box(@src(), .{ .dir = .vertical }, dvui.FloatingTooltipWidget.defaults.override(.{
                .background = false,
                .expand = .both,
                .border = dvui.Rect.all(0),
            }));
            defer vbox2.deinit();

            var tl2 = dvui.textLayout(@src(), .{}, .{
                .background = false,
                .padding = dvui.Rect.all(4),
            });
            tl2.format("{s}", .{fizzy.Editor.Explorer.title(option, true)}, .{
                .font = dvui.Font.theme(.heading),
            });
            tl2.deinit();
        }
    }

    return ret;
}
