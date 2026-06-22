//! Thin menu helpers for plugin contributions. Mirrors shell `Menu.zig` patterns
//! without importing the editor.
const std = @import("std");
const dvui = @import("dvui");

pub fn menuItem(
    src: std.builtin.SourceLocation,
    label_str: []const u8,
    init_opts: dvui.MenuItemWidget.InitOptions,
    
    opts: dvui.Options,
) ?dvui.Rect.Natural {
    var mi = dvui.menuItem(src, init_opts, opts);

    var ret: ?dvui.Rect.Natural = null;
    if (mi.activeRect()) |r| ret = r;

    var label_opts = opts;
    label_opts.margin = dvui.Rect.all(0);
    label_opts.padding = dvui.Rect.all(0);
    dvui.labelNoFmt(src, label_str, .{}, label_opts);
    mi.deinit();
    return ret;
}

pub fn menuItemWithChevron(
    src: std.builtin.SourceLocation,
    label_str: []const u8,
    init_opts: dvui.MenuItemWidget.InitOptions,
    opts: dvui.Options,
) ?dvui.Rect.Natural {
    var mi = dvui.menuItem(src, init_opts, opts);

    var ret: ?dvui.Rect.Natural = null;
    if (mi.activeRect()) |r| ret = r;

    var label_opts = opts;
    label_opts.margin = dvui.Rect.all(0);
    label_opts.padding = dvui.Rect.all(0);
    dvui.labelNoFmt(src, label_str, .{}, label_opts);

    dvui.icon(src, "chevron_right", dvui.entypo.chevron_small_right, .{
        .stroke_color = dvui.themeGet().color(.control, .text).opacity(0.5),
        .fill_color = dvui.themeGet().color(.control, .text).opacity(0.5),
    }, .{
        .expand = .none,
        .gravity_x = 1.0,
        .gravity_y = 0.5,
        .margin = dvui.Rect.all(0),
        .padding = dvui.Rect.all(0),
    });

    mi.deinit();
    return ret;
}

pub fn submenu(
    src: std.builtin.SourceLocation,
    label_str: []const u8,
    opts: dvui.Options,
    draw_body: *const fn () anyerror!void,
) !void {
    if (menuItemWithChevron(src, label_str, .{ .submenu = true }, opts)) |r| {
        var anim = dvui.animate(src, .{ .kind = .alpha, .duration = 250_000 }, .{ .expand = .both });
        defer anim.deinit();

        var fw = dvui.floatingMenu(src, .{ .from = r }, .{});
        defer fw.deinit();

        try draw_body();
    }
}
