//! The side pane: the region content a rail drives. It draws the header, the scroll policy and the
//! peek-only collapse button around whichever surface the place currently shows.
const std = @import("std");
const dvui = @import("dvui");
const core = @import("core");
const icons = @import("icons");
const sdk = @import("fizzy_sdk");
const Layout = @import("Layout.zig");

const SidePane = @This();

scroll_info: dvui.ScrollInfo = .{
    .horizontal = .auto,
},
rect: dvui.Rect = .{},
rect_screen: dvui.Rect.Physical = .{},
collapse_btn_anim_started: bool = false,
/// Cleared at the start of `draw` and set on the frame the collapse button is pressed; the
/// caller reads it after `draw`.
collapse_requested: bool = false,

/// Draws the pane *chrome* - header, scroll policy, collapse button - around whichever
/// surface currently matches `keywords`. The chrome is the app's; the body is the plugin's.
///
/// The body is resolved through the layout's match set rather than the registry, so a user's
/// keyword override moves the body on screen instead of only changing `Layout.matching`.
///
/// `region` is the pane's own region, if the layout has one; the collapse button shows while it peeks.
pub fn draw(
    self: *SidePane,
    f: *Layout,
    keywords: []const []const u8,
    region: ?Layout.Region,
) Layout.Region.Error!dvui.App.Result {
    self.collapse_requested = false;

    const vbox = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = false,
    });
    defer vbox.deinit();

    self.rect = vbox.data().rect;
    self.rect_screen = vbox.data().rectScale().r;

    drawHeader(f, keywords);

    _ = dvui.spacer(@src(), .{});

    const pane_vbox = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = false,
    });

    // A surface that scrolls itself (`Surface.scrolls_itself`) gets exactly the space this region
    // has, on both axes, and decides for itself. Scrolling it here as well meant two policies on
    // one direction: a second vertical bar on top of its own, and horizontally a ratchet - the
    // pane capped its width at its viewport, this made room for that width, and the viewport
    // could then never be narrower than it had just been told to be.
    const self_scrolling = if (f.selected(keywords)) |view| view.scrolls_itself else false;
    if (self_scrolling) {
        self.scroll_info.vertical = .given;
        self.scroll_info.horizontal = .none;
        // Left over from a surface that did scroll sideways; a pane that cannot scroll has
        // nowhere to be scrolled to.
        self.scroll_info.viewport.x = 0;
        self.scroll_info.viewport.y = 0;
    } else {
        self.scroll_info.vertical = .auto;
        self.scroll_info.horizontal = .auto;
    }

    // No bars at all around a surface that scrolls itself, rather than bars decided against a size
    // that only says there is nothing to scroll: the scroll area decides on its bars from the size
    // it was last given, a frame old - while the window shrank, every frame of it, last frame's
    // height overflowed this frame's, and a bar showed beside the pane's own until it stopped.
    const bar: dvui.ScrollInfo.ScrollBarMode = if (self_scrolling) .hide else .auto_overlay;
    var scroll = core.widgets.ScrollArea.init(@src(), .{ .scroll_info = &self.scroll_info, .horizontal_bar = bar, .vertical_bar = bar }, .{
        .expand = .both,
        .background = false,
    });
    // This frame's viewport, measured just now, before the surface lays out in it: given last
    // frame's, it was a frame too tall as the window shrank (its foot clipped) and a frame too short
    // as it grew.
    if (self_scrolling) self.scroll_info.virtual_size = .{ .w = self.scroll_info.viewport.w, .h = self.scroll_info.viewport.h };

    // Through the layout, not `Host.selectedSurface`: the host remembers which
    // view was chosen here and hands it back whether or not this place still
    // holds it. Drag Files out to the main area and it is claimed by what it
    // was dropped on - the rail drops the icon, and the host would still hand
    // back Files to draw in the body, until a click on some other icon moved
    // the remembered choice. `f.selected` reads the choice against what the
    // place actually shows, which is the only reading that can never say that.
    const shown = f.selected(keywords);

    if (shown) |surface| {
        // Through the layout's swap: choosing another view on the rail blurs from one body to
        // the next, as every region does. The body's own box, so the capture of the outgoing
        // view can be unpacked before the incoming one draws. The blur bleeds past the pane's
        // edge and feathers out over the rail beside it: the pane has no card, and a blur that
        // stopped dead at an edge nothing on screen draws read as clipped. Not upward: the title
        // above is the pane's own, already names the new view, and stays sharp.
        var body = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .background = false });
        defer body.deinit();
        _ = try f.drawSwappedIn(sdk.keywords.groupKey(keywords), body, surface, .{ .left = true, .right = true, .bottom = true });
    }

    scroll.deinit();

    // Two calls rather than one: `pane_vbox` has to deinit between the vertical and horizontal
    // hints, since the horizontal ones are drawn over the outer `vbox` instead.
    core.draw.drawScrollEdgeShadows(pane_vbox.data().contentRectScale(), null, &self.scroll_info, .{});

    pane_vbox.deinit();

    core.draw.drawScrollEdgeShadows(null, vbox.data().contentRectScale(), &self.scroll_info, .{});

    // Peek-only floating collapse button. Drawn last so it overlays everything else in the
    // side pane. Only while the region is *peeking*: open on a window too narrow to hold it
    // beside the center, which is the one state where there is no split to drag it shut by.
    if (region) |r| {
        if (r.isPeeking()) drawCollapseButton(self, r) else self.collapse_btn_anim_started = false;
    }

    return .ok;
}

fn drawCollapseButton(self: *SidePane, r: Layout.Region) void {
    // A glass bubble, as the controls over a document are (`core.widgets.glass_button`).
    const button_size = core.widgets.glass_button.size;
    const margin: f32 = 12;
    const wr = dvui.windowRect();

    const anim_id = dvui.Id.update(r.id, "collapse_btn");
    if (!self.collapse_btn_anim_started) {
        self.collapse_btn_anim_started = true;
        dvui.animation(anim_id, "_appear", .{
            .start_val = 0.0,
            .end_val = 1.0,
            .end_time = core.motion.duration(450_000),
            .easing = core.motion.enter,
        });
    }

    var s: f32 = 1.0;
    if (dvui.animationGet(anim_id, "_appear")) |a| s = a.value();
    if (s < 0.0) s = 0.0;

    const sized = button_size * s;
    if (sized < 0.5) return;

    // Grows from its own centre.
    const centre: dvui.Point = .{ .x = wr.w - margin - button_size / 2, .y = wr.h - margin - button_size / 2 };
    const rect: dvui.Rect = .{ .x = centre.x - sized / 2, .y = centre.y - sized / 2, .w = sized, .h = sized };
    if (core.widgets.glass_button.bubble(@src(), rect, icons.tvg.lucide.@"panel-left-close", .{ .label = "Collapse Side Pane" })) {
        self.collapse_requested = true;
    }
}

fn drawHeader(f: *Layout, keywords: []const []const u8) void {
    const view = f.selected(keywords) orelse return;
    const header_title = std.ascii.allocUpperString(dvui.currentWindow().arena(), view.title) catch view.title;

    dvui.labelNoFmt(@src(), header_title, .{}, .{ .font = dvui.Font.theme(.heading) });
}
