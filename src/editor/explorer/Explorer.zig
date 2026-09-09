const std = @import("std");

const dvui = @import("dvui");
const fizzy = @import("../../fizzy.zig");
const workbench = @import("workbench");
const icons = @import("icons");

const Core = @import("mach").Core;
const App = fizzy.App;
const Editor = fizzy.Editor;

const nfd = @import("nfd");
const PluginStore = @import("../PluginStore.zig");
const Frame = @import("../layout/Frame.zig");

pub const Explorer = @This();

pub const files = workbench.files;
// pub const animations = @import("animations.zig");
// pub const keyframe_animations = @import("keyframe_animations.zig");
// The pixel-art project view is contributed by the plugin via `Host.registerSidebarView`,
// not re-exported here.
pub const settings = @import("settings.zig");

paned: *fizzy.dvui.PanedWidget = undefined,
scroll_info: dvui.ScrollInfo = .{
    .horizontal = .auto,
},
rect: dvui.Rect = .{},
rect_screen: dvui.Rect.Physical = .{},
open_branches: std.AutoHashMap(dvui.Id, void) = undefined,
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
        .open_branches = .init(fizzy.app().allocator),
    };
}

pub fn deinit(self: *Explorer) void {
    // TODO: Free memory
    self.open_branches.deinit();
}

/// The split whose docked half shows sidebar content, or null when this app's shape declared
/// none. Replaces the `explorer.paned` pointer a shape used to have to publish — see
/// `Editor.splitFor`.
fn split(editor: *fizzy.Editor) ?fizzy.Editor.RegisteredSplit {
    return editor.splitFor(fizzy.sdk.keywords.ide.sidebar);
}

pub fn close(explorer: *Explorer, editor: *fizzy.Editor) void {
    const s = split(editor) orelse return;
    s.paned.animateSplit(0.0, dvui.easing.outQuint);
    explorer.closed = true;
}

pub fn open(explorer: *Explorer, editor: *fizzy.Editor) void {
    const s = split(editor) orelse return;
    if (s.paned.collapsed()) {
        // Already peeking: do nothing. The peek stays open until the floating collapse
        // button is clicked — sidebar taps don't toggle it back closed (and we no longer
        // need to refresh any timer).
        if (!explorer.peek_open) explorer.peekOpen(editor);
        return;
    }

    if (editor.explorer_ratio > 0.0) {
        s.paned.animateSplit(editor.explorer_ratio, dvui.easing.outBack);
    } else {
        s.paned.animateSplit(0.2, dvui.easing.outBack);
    }

    explorer.closed = false;
}

pub fn peekOpen(explorer: *Explorer, editor: *fizzy.Editor) void {
    const s = split(editor) orelse return;
    s.paned.animateSplit(1.0, dvui.easing.outBack);
    explorer.peek_open = true;
    explorer.closed = false;
}

pub fn peekClose(explorer: *Explorer, editor: *fizzy.Editor) void {
    const s = split(editor) orelse return;
    explorer.peek_open = false;
    s.paned.animateSplit(0.0, dvui.easing.outQuint);
    explorer.closed = true;
    explorer.collapse_btn_anim_started = false;
}

/// Draws the explorer *chrome* — header, scroll policy, collapse button — around whichever
/// surface currently matches `keywords`. The chrome is the app's; the body is the plugin's.
///
/// Before Phase 4c this resolved the body through `host.activeSidebarView()`, i.e. the legacy
/// registry, which meant a user's keyword override changed what `Frame.matching` returned but
/// nothing moved on screen.
pub fn draw(
    explorer: *Explorer,
    editor: *fizzy.Editor,
    f: *Frame,
    keywords: []const []const u8,
) !dvui.App.Result {
    const vbox = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = false,
    });
    defer vbox.deinit();

    explorer.rect = vbox.data().rect;
    explorer.rect_screen = vbox.data().rectScale().r;

    try drawHeader(explorer, f, keywords);

    _ = dvui.spacer(@src(), .{});

    const pane_vbox = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = false,
    });

    // The Plugins tab owns its own vertical scroll areas (installed + store panes inside
    // a paned widget). With the default `.auto` vertical mode, each inner scrollArea
    // reports its full content height as min_size, which bubbles up here and triggers
    // a second explorer-level vertical bar on top of the pane scrollbars. Pin vertical
    // scroll to `.given` for that tab so we fill the viewport and let the panes scroll.
    const self_vert_scroll = blk: {
        if (f.selected(keywords)) |view| {
            break :blk std.mem.eql(u8, view.id, PluginStore.view_id);
        }
        break :blk false;
    };
    if (self_vert_scroll) {
        explorer.scroll_info.vertical = .given;
        if (explorer.scroll_info.viewport.h > 0) {
            explorer.scroll_info.virtual_size.h = explorer.scroll_info.viewport.h;
        }
    } else {
        explorer.scroll_info.vertical = .auto;
    }

    var scroll = dvui.scrollArea(@src(), .{ .scroll_info = &explorer.scroll_info, .horizontal_bar = .auto_overlay, .vertical_bar = .auto_overlay }, .{
        .expand = .both,
        .background = false,
    });

    if (comptime workbench.has_file_tree) {
        if (!editor.host.isActiveSidebarView(fizzy.Editor.workbench_files_view)) {
            editor.resetFileTreeWhenFilesHidden();
        }
    }

    if (editor.host.activeSidebarView()) |view| {
        try view.draw(view.ctx);
    }

    scroll.deinit();

    if (self_vert_scroll) {
        explorer.scroll_info.virtual_size.h = explorer.scroll_info.viewport.h;
    }

    // Two calls rather than one: `pane_vbox` has to deinit between the vertical and horizontal
    // hints, since the horizontal ones are drawn over the outer `vbox` instead.
    fizzy.dvui.drawScrollEdgeShadows(pane_vbox.data().contentRectScale(), null, &explorer.scroll_info, .{});

    pane_vbox.deinit();

    fizzy.dvui.drawScrollEdgeShadows(null, vbox.data().contentRectScale(), &explorer.scroll_info, .{});

    // Peek-only floating collapse button. Drawn last so it overlays everything else in the
    // explorer pane. Only appears while we're full-screen peeking on a collapsed paned.
    if (split(editor)) |sp| {
        if (explorer.peek_open and sp.paned.collapsed()) drawCollapseButton(explorer, editor);
    }

    return .ok;
}

fn drawCollapseButton(explorer: *Explorer, editor: *fizzy.Editor) void {
    // Styled to match the floating Edit pill (see `Workspace.drawEditPill`): circular
    // background, same content.fill / content.text color pair, same drop shadow.
    const button_size: f32 = 48;
    const btn_radius: f32 = button_size / 2;
    const margin: f32 = 8;
    const wr = dvui.windowRect();

    const sp = split(editor) orelse return;
    const anim_id = dvui.Id.update(sp.paned.data().id, "collapse_btn");
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
        .corners = dvui.CornerRect.all(btn_radius),
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
            .corners = dvui.CornerRect.all(btn_radius),
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
        explorer.peekClose(editor);
    }
}

pub fn hovered(_: *Explorer, editor: *fizzy.Editor) bool {
    const s = split(editor) orelse return false;
    return fizzy.dvui.hovered(s.paned.data());
}

pub fn drawHeader(_: *Explorer, f: *Frame, keywords: []const []const u8) !void {
    const view = f.selected(keywords) orelse return;
    const header_title = std.ascii.allocUpperString(dvui.currentWindow().arena(), view.title) catch view.title;

    dvui.labelNoFmt(@src(), header_title, .{}, .{ .font = dvui.Font.theme(.heading) });
}
