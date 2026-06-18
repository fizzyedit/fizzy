const std = @import("std");

const dvui = @import("dvui");
const fizzy = @import("../../fizzy.zig");
const icons = @import("icons");

const Core = @import("mach").Core;
const App = fizzy.App;
const Editor = fizzy.Editor;
const Packer = fizzy.Packer;

const nfd = @import("nfd");

pub const Explorer = @This();

pub const files = @import("../../plugins/workbench/files.zig");
pub const Tools = @import("../../plugins/pixelart/explorer/tools.zig");
pub const Sprites = @import("../../plugins/pixelart/explorer/sprites.zig");
// pub const animations = @import("animations.zig");
// pub const keyframe_animations = @import("keyframe_animations.zig");
pub const project = @import("../../plugins/pixelart/explorer/project.zig");
pub const settings = @import("settings.zig");

sprites: Sprites = .{},
tools: Tools = .{},
paned: *fizzy.dvui.PanedWidget = undefined,
scroll_info: dvui.ScrollInfo = .{
    .horizontal = .auto,
},
rect: dvui.Rect = .{},
rect_screen: dvui.Rect.Physical = .{},
open_branches: std.AutoHashMap(dvui.Id, void) = undefined,
pinned_palettes: bool = false,
layers_ratio: f32 = 0.5,
animations_ratio: f32 = 0.5,
closed: bool = false,

/// Peek state: when the explorer is collapsed (small window), a sidebar tap slides the
/// explorer fully in and it stays open until the user clicks the floating collapse button
/// at the bottom-right. No auto-close timer — that path caused a per-frame refresh that
/// kept the app from settling after the open animation finished.
peek_open: bool = false,
collapse_btn_anim_started: bool = false,

pub fn init() Explorer {
    return .{
        .open_branches = .init(fizzy.app.allocator),
    };
}

pub fn deinit(self: *Explorer) void {
    // TODO: Free memory
    self.open_branches.deinit();
}

pub fn close(explorer: *Explorer) void {
    explorer.paned.animateSplit(0.0, dvui.easing.outQuint);
    explorer.closed = true;
}

pub fn open(explorer: *Explorer) void {
    if (explorer.paned.collapsed()) {
        // Already peeking: do nothing. The peek stays open until the floating collapse
        // button is clicked — sidebar taps don't toggle it back closed (and we no longer
        // need to refresh any timer).
        if (!explorer.peek_open) explorer.peekOpen();
        return;
    }

    if (fizzy.editor.settings.explorer_ratio > 0.0) {
        explorer.paned.animateSplit(fizzy.editor.settings.explorer_ratio, dvui.easing.outBack);
    } else {
        explorer.paned.animateSplit(0.2, dvui.easing.outBack);
    }

    explorer.closed = false;
}

pub fn peekOpen(explorer: *Explorer) void {
    explorer.paned.animateSplit(1.0, dvui.easing.outBack);
    explorer.peek_open = true;
    explorer.closed = false;
}

pub fn peekClose(explorer: *Explorer) void {
    explorer.peek_open = false;
    explorer.paned.animateSplit(0.0, dvui.easing.outQuint);
    explorer.closed = true;
    explorer.collapse_btn_anim_started = false;
}

pub fn draw(explorer: *Explorer) !dvui.App.Result {
    const vbox = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = false,
    });
    defer vbox.deinit();

    explorer.rect = vbox.data().rect;
    explorer.rect_screen = vbox.data().rectScale().r;

    try drawHeader(explorer);

    _ = dvui.spacer(@src(), .{});

    const pane_vbox = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = false,
    });

    var scroll = dvui.scrollArea(@src(), .{ .scroll_info = &explorer.scroll_info, .horizontal_bar = .auto_overlay, .vertical_bar = .auto_overlay }, .{
        .expand = .both,
        .background = false,
    });

    if (!fizzy.editor.host.isActiveSidebarView(@import("../../plugins/workbench/plugin.zig").view_files)) {
        fizzy.editor.file_tree_data_id = null;
        if (fizzy.editor.tab_drag_from_tree_path) |p| {
            fizzy.app.allocator.free(p);
            fizzy.editor.tab_drag_from_tree_path = null;
        }
    }

    if (fizzy.editor.host.activeSidebarView()) |view| {
        try view.draw(view.ctx);
    }

    const vertical_scroll = scroll.si.offset(.vertical);
    const horizontal_scroll = scroll.si.offset(.horizontal);

    scroll.deinit();

    if (vertical_scroll > 0.0) {
        fizzy.dvui.drawEdgeShadow(pane_vbox.data().contentRectScale(), .top, .{});
    }

    if (explorer.scroll_info.virtual_size.h > explorer.scroll_info.viewport.h) {
        fizzy.dvui.drawEdgeShadow(pane_vbox.data().contentRectScale(), .bottom, .{});
    }

    pane_vbox.deinit();

    if (explorer.scroll_info.virtual_size.w > explorer.scroll_info.viewport.w) {
        fizzy.dvui.drawEdgeShadow(vbox.data().contentRectScale(), .right, .{});
    }

    if (horizontal_scroll > 0.0) {
        fizzy.dvui.drawEdgeShadow(vbox.data().contentRectScale(), .left, .{});
    }

    // Peek-only floating collapse button. Drawn last so it overlays everything else in the
    // explorer pane. Only appears while we're full-screen peeking on a collapsed paned.
    if (explorer.peek_open and explorer.paned.collapsed()) {
        drawCollapseButton(explorer);
    }

    return .ok;
}

fn drawCollapseButton(explorer: *Explorer) void {
    // Styled to match the floating Edit pill (see `Workspace.drawEditPill`): circular
    // background, same content.fill / content.text color pair, same drop shadow.
    const button_size: f32 = 48;
    const btn_radius: f32 = button_size / 2;
    const margin: f32 = 8;
    const wr = dvui.windowRect();

    const anim_id = dvui.Id.update(explorer.paned.data().id, "collapse_btn");
    if (!explorer.collapse_btn_anim_started) {
        explorer.collapse_btn_anim_started = true;
        dvui.animation(anim_id, "_appear", .{
            .start_val = 0.0,
            .end_val = 1.0,
            .end_time = 450_000,
            .easing = dvui.easing.outBack,
        });
    }

    var s: f32 = 1.0;
    if (dvui.animationGet(anim_id, "_appear")) |a| s = a.value();
    if (s < 0.0) s = 0.0;

    const sized = button_size * s;
    if (sized < 0.5) return;

    var fw: dvui.FloatingWidget = undefined;
    fw.init(@src(), .{ .mouse_events = true }, .{
        .rect = .{
            .x = wr.w - margin - sized,
            .y = wr.h - margin - sized,
            .w = sized,
            .h = sized,
        },
    });
    defer fw.deinit();

    var bw: dvui.ButtonWidget = undefined;
    bw.init(@src(), .{}, .{
        .expand = .both,
        .corner_radius = dvui.Rect.all(btn_radius),
        .background = true,
        .color_fill = dvui.themeGet().color(.content, .fill),
        .color_fill_hover = dvui.themeGet().color(.content, .fill).lighten(if (dvui.themeGet().dark) 10.0 else -10.0),
        .color_border = .transparent,
        .padding = .all(0),
        .margin = .all(margin),
        .min_size_content = .{ .w = button_size, .h = button_size },
        .box_shadow = .{
            .color = .black,
            .alpha = 0.2,
            .fade = 4,
            .offset = .{ .x = 0, .y = 2 },
            .corner_radius = dvui.Rect.all(btn_radius),
        },
    });
    defer bw.deinit();
    bw.processEvents();
    bw.drawBackground();

    const icon_color = dvui.themeGet().color(.content, .text);
    dvui.icon(
        @src(),
        "collapse_explorer",
        icons.tvg.lucide.@"panel-left-close",
        .{ .stroke_color = icon_color, .fill_color = icon_color },
        .{
            .expand = .ratio,
            .gravity_x = 0.5,
            .gravity_y = 0.5,
            .min_size_content = .{ .w = 1.0, .h = 1.0 },
            .padding = .all(6),
        },
    );

    if (bw.clicked()) {
        explorer.peekClose();
    }
}

pub fn hovered(explorer: *Explorer) bool {
    return fizzy.dvui.hovered(explorer.paned.data());
}

pub fn drawHeader(_: *Explorer) !void {
    const view = fizzy.editor.host.activeSidebarView() orelse return;
    const header_title = std.ascii.allocUpperString(dvui.currentWindow().arena(), view.title) catch view.title;

    dvui.labelNoFmt(@src(), header_title, .{}, .{ .font = dvui.Font.theme(.heading) });
}
