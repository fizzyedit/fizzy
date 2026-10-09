const std = @import("std");

const dvui = @import("dvui");
const fizzy = @import("../../fizzy.zig");
const workbench = @import("workbench");
const icons = @import("icons");

const Core = @import("mach").Core;
const Entry = fizzy.Entry;
const Editor = fizzy.Editor;

const nfd = @import("nfd");
const PluginStore = @import("app").store.Store;
const Layout = @import("app").layout.Layout;

pub const Explorer = @This();

pub const files = workbench.files;
// pub const animations = @import("animations.zig");
// pub const keyframe_animations = @import("keyframe_animations.zig");
// The pixel-art project view is contributed by the plugin via `Host.registerSurface`,
// not re-exported here.
pub const settings = @import("settings.zig");

scroll_info: dvui.ScrollInfo = .{
    .horizontal = .auto,
},
rect: dvui.Rect = .{},
rect_screen: dvui.Rect.Physical = .{},
open_branches: std.AutoHashMap(dvui.Id, void) = undefined,
animations_ratio: f32 = 0.5,
closed: bool = false,
collapse_btn_anim_started: bool = false,

pub fn init() Explorer {
    return .{
        .open_branches = .init(fizzy.entry().allocator),
    };
}

pub fn deinit(self: *Explorer) void {
    // TODO: Free memory
    self.open_branches.deinit();
}

pub fn close(explorer: *Explorer, editor: *fizzy.Editor) void {
    explorer.closed = true;
    if (editor.regionFor(fizzy.sdk.keywords.ide.sidebar)) |r| r.close();
}

pub fn open(explorer: *Explorer, editor: *fizzy.Editor) void {
    explorer.closed = false;
    if (editor.regionFor(fizzy.sdk.keywords.ide.sidebar)) |r| r.open();
}

/// Shut the explorer from the floating button, or from a tap that put something in the center
/// worth seeing. `Region.close` withdraws the peek, so the narrow layout goes back to collapsing
/// it by itself.
pub fn peekClose(explorer: *Explorer, editor: *fizzy.Editor) void {
    explorer.closed = true;
    explorer.collapse_btn_anim_started = false;
    if (editor.regionFor(fizzy.sdk.keywords.ide.sidebar)) |r| r.close();
}

/// Draws the explorer *chrome* — header, scroll policy, collapse button — around whichever
/// surface currently matches `keywords`. The chrome is the app's; the body is the plugin's.
///
/// The body is resolved through the layout's match set rather than the registry, so a user's
/// keyword override moves the body on screen instead of only changing `Layout.matching`.
pub fn draw(
    explorer: *Explorer,
    editor: *fizzy.Editor,
    f: *Layout,
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

    // A surface that scrolls itself (`Surface.scrolls_itself`) gets exactly the space this region
    // has, on both axes, and decides for itself. Scrolling it here as well meant two policies on
    // one direction: a second vertical bar on top of its own, and horizontally a ratchet — the
    // pane capped its width at its viewport, this made room for that width, and the viewport
    // could then never be narrower than it had just been told to be.
    const self_scrolling = if (f.selected(keywords)) |view| view.scrolls_itself else false;
    if (self_scrolling) {
        explorer.scroll_info.vertical = .given;
        explorer.scroll_info.horizontal = .none;
        // Left over from a surface that did scroll sideways; a pane that cannot scroll has
        // nowhere to be scrolled to.
        explorer.scroll_info.viewport.x = 0;
        explorer.scroll_info.viewport.y = 0;
    } else {
        explorer.scroll_info.vertical = .auto;
        explorer.scroll_info.horizontal = .auto;
    }

    // No bars at all around a surface that scrolls itself, rather than bars decided against a size
    // that only says there is nothing to scroll: the scroll area decides on its bars from the size
    // it was last given, a frame old — while the window shrank, every frame of it, last frame's
    // height overflowed this frame's, and a bar showed beside the pane's own until it stopped.
    const bar: dvui.ScrollInfo.ScrollBarMode = if (self_scrolling) .hide else .auto_overlay;
    var scroll = dvui.scrollArea(@src(), .{ .scroll_info = &explorer.scroll_info, .horizontal_bar = bar, .vertical_bar = bar }, .{
        .expand = .both,
        .background = false,
    });
    // This frame's viewport, measured just now, before the surface lays out in it: given last
    // frame's, it was a frame too tall as the window shrank (its foot clipped) and a frame too short
    // as it grew.
    if (self_scrolling) explorer.scroll_info.virtual_size = .{ .w = explorer.scroll_info.viewport.w, .h = explorer.scroll_info.viewport.h };

    // Through the layout, not `Host.selectedSurface`: the host remembers which
    // view was chosen here and hands it back whether or not this place still
    // holds it. Drag Files out to the main area and it is claimed by what it
    // was dropped on — the rail drops the icon, and the host would still hand
    // back Files to draw in the body, until a click on some other icon moved
    // the remembered choice. `f.selected` reads the choice against what the
    // place actually shows, which is the only reading that can never say that.
    const shown = f.selected(keywords);

    if (comptime workbench.has_file_tree) {
        const showing_files = if (shown) |s| std.mem.eql(u8, s.id, fizzy.Editor.workbench_files_view) else false;
        if (!showing_files) editor.resetFileTreeWhenFilesHidden();
    }

    if (shown) |surface| {
        // Through the layout's swap: choosing another view on the rail blurs from one body to
        // the next, as every region does. The body's own box, so the capture of the outgoing
        // view can be unpacked before the incoming one draws. The blur bleeds past the pane's
        // edge and feathers out over the rail beside it: the pane has no card, and a blur that
        // stopped dead at an edge nothing on screen draws read as clipped. Not upward: the title
        // above is the explorer's own, already names the new view, and stays sharp.
        var body = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .background = false });
        defer body.deinit();
        _ = try f.drawSwappedIn(fizzy.sdk.keywords.groupKey(keywords), body, surface, .{ .left = true, .right = true, .bottom = true });
    }

    scroll.deinit();

    // Two calls rather than one: `pane_vbox` has to deinit between the vertical and horizontal
    // hints, since the horizontal ones are drawn over the outer `vbox` instead.
    fizzy.core.draw.drawScrollEdgeShadows(pane_vbox.data().contentRectScale(), null, &explorer.scroll_info, .{});

    pane_vbox.deinit();

    fizzy.core.draw.drawScrollEdgeShadows(null, vbox.data().contentRectScale(), &explorer.scroll_info, .{});

    // Peek-only floating collapse button. Drawn last so it overlays everything else in the
    // explorer pane. Only while the region is *peeking*: open on a window too narrow to hold it
    // beside the center, which is the one state where there is no split to drag it shut by.
    if (editor.regionFor(fizzy.sdk.keywords.ide.sidebar)) |r| {
        if (r.isPeeking()) drawCollapseButton(explorer, editor) else explorer.collapse_btn_anim_started = false;
    }

    return .ok;
}

fn drawCollapseButton(explorer: *Explorer, editor: *fizzy.Editor) void {
    // Styled to match the floating Edit pill (see `Workspace.drawEditPill`): circular
    // background, same content.fill / content.text color pair, same drop shadow.
    const button_size: f32 = fizzy.core.widgets.round_button_size;
    const btn_radius: f32 = button_size / 2;
    const margin: f32 = 8;
    const wr = dvui.windowRect();

    const r = editor.regionFor(fizzy.sdk.keywords.ide.sidebar) orelse return;
    const anim_id = dvui.Id.update(r.id, "collapse_btn");
    if (!explorer.collapse_btn_anim_started) {
        explorer.collapse_btn_anim_started = true;
        dvui.animation(anim_id, "_appear", .{
            .start_val = 0.0,
            .end_val = 1.0,
            .end_time = fizzy.core.motion.duration(450_000),
            .easing = fizzy.core.motion.enter,
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
        .label = .{ .text = "Collapse Explorer" },
        .expand = .both,
        .corners = dvui.CornerRect.all(btn_radius),
        .background = true,
        .color_fill = .{ .color = dvui.themeGet().color(.content, .fill) },
        .color_fill_hover = .{ .color = dvui.themeGet().color(.content, .fill).lighten(if (dvui.themeGet().dark) 10.0 else -10.0) },
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
    fizzy.core.icon.icon(
        @src(),
        "collapse_explorer",
        icons.tvg.lucide.@"panel-left-close",
        .{ .stroke_color = .{ .color = icon_color }, .fill_color = .{ .color = icon_color } },
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
    _ = editor;
    // The sidebar is a region now, and a region is a plain box — there is no widget handle to ask
    // about hover. Nothing reads this today; it returns false rather than pretending.
    return false;
}

pub fn drawHeader(_: *Explorer, f: *Layout, keywords: []const []const u8) !void {
    const view = f.selected(keywords) orelse return;
    const header_title = std.ascii.allocUpperString(dvui.currentWindow().arena(), view.title) catch view.title;

    dvui.labelNoFmt(@src(), header_title, .{}, .{ .font = dvui.Font.theme(.heading) });
}
