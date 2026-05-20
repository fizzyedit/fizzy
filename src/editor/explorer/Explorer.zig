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

pub const files = @import("files.zig");
pub const Tools = @import("tools.zig");
pub const Sprites = @import("sprites.zig");
// pub const animations = @import("animations.zig");
// pub const keyframe_animations = @import("keyframe_animations.zig");
pub const project = @import("project.zig");
pub const settings = @import("settings.zig");

sprites: Sprites = .{},
tools: Tools = .{},
pane: Pane = .files,
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
/// explorer fully in. It stays open until `peek_duration_ns` pass with no pointer input
/// inside the explorer rect, then slides back out. Sidebar taps during peek refresh the
/// deadline rather than retriggering the animation.
peek_open: bool = false,
peek_deadline_ns: i128 = 0,
collapse_btn_anim_started: bool = false,

const peek_duration_ns: i128 = 2_000_000_000;

pub const Pane = enum(u32) {
    files,
    tools,
    sprites,
    animations,
    keyframe_animations,
    project,
    settings,
};

pub fn init() Explorer {
    return .{
        .open_branches = .init(fizzy.app.allocator),
    };
}

pub fn deinit(self: *Explorer) void {
    // TODO: Free memory
    self.open_branches.deinit();
}

pub fn title(pane: Pane, all_caps: bool) []const u8 {
    return switch (pane) {
        .files => if (all_caps) "FILES" else "Files",
        .tools => if (all_caps) "TOOLS" else "Tools",
        .sprites => if (all_caps) "SPRITES" else "Sprites",
        .animations => if (all_caps) "ANIMATIONS" else "Animations",
        .keyframe_animations => if (all_caps) "KEYFRAME ANIMATIONS" else "Keyframe Animations",
        .project => if (all_caps) "PROJECT" else "Project",
        .settings => if (all_caps) "SETTINGS" else "Settings",
    };
}

pub fn close(explorer: *Explorer) void {
    explorer.paned.animateSplit(0.0, dvui.easing.outQuint);
    explorer.closed = true;
}

pub fn open(explorer: *Explorer) void {
    if (explorer.paned.collapsed()) {
        // Re-pressing the sidebar while peeking just refreshes the timer.
        if (explorer.peek_open) {
            explorer.peekRefresh();
        } else {
            explorer.peekOpen();
        }
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
    explorer.peek_deadline_ns = dvui.currentWindow().frame_time_ns + peek_duration_ns;
    explorer.closed = false;
}

pub fn peekRefresh(explorer: *Explorer) void {
    explorer.peek_deadline_ns = dvui.currentWindow().frame_time_ns + peek_duration_ns;
}

pub fn peekClose(explorer: *Explorer) void {
    explorer.peek_open = false;
    explorer.paned.animateSplit(0.0, dvui.easing.outQuint);
    explorer.closed = true;
    explorer.collapse_btn_anim_started = false;
}

/// Called once per frame after `draw`. While peeking, a press inside the explorer's first
/// pane refreshes the deadline; once the deadline expires the peek closes. Position/hover
/// events are deliberately ignored — otherwise the per-frame synthetic position event over
/// the explorer rect would refresh the deadline forever and the peek would never close.
pub fn updatePeek(explorer: *Explorer) void {
    if (!explorer.peek_open) return;

    for (dvui.events()) |*e| {
        switch (e.evt) {
            .mouse => |me| {
                if (me.action != .press) continue;
                if (!explorer.rect_screen.contains(me.p)) continue;
                explorer.peekRefresh();
                break;
            },
            else => {},
        }
    }

    const now = dvui.currentWindow().frame_time_ns;
    if (now >= explorer.peek_deadline_ns) {
        explorer.peekClose();
    } else {
        // Keep the frame loop ticking so the deadline fires even without input.
        dvui.refresh(null, @src(), null);
    }
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

    if (explorer.pane != .files) {
        fizzy.editor.file_tree_data_id = null;
        if (fizzy.editor.tab_drag_from_tree_path) |p| {
            fizzy.app.allocator.free(p);
            fizzy.editor.tab_drag_from_tree_path = null;
        }
    }

    switch (explorer.pane) {
        .files => try files.draw(),
        .settings => try settings.draw(),
        .project => try project.draw(),
        .tools => try explorer.tools.draw(),
        .sprites => try explorer.sprites.draw(),
        else => {},
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
    const button_size: f32 = 44;
    const margin: f32 = 16;
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
        .corner_radius = .all(button_size / 2),
        .background = true,
        .color_fill = dvui.themeGet().color(.highlight, .fill),
        .color_fill_hover = dvui.themeGet().color(.highlight, .fill).lighten(if (dvui.themeGet().dark) 6 else -6),
        .color_border = .transparent,
        .min_size_content = .{ .w = button_size, .h = button_size },
    });
    defer bw.deinit();
    bw.processEvents();
    bw.drawBackground();

    dvui.icon(
        @src(),
        "collapse_explorer",
        icons.tvg.lucide.@"panel-left-close",
        .{ .stroke_color = dvui.themeGet().color(.highlight, .text), .fill_color = dvui.themeGet().color(.highlight, .text) },
        .{
            .expand = .ratio,
            .padding = .all(2),
            .gravity_x = 0.5,
            .gravity_y = 0.5,
        },
    );

    if (bw.clicked()) {
        explorer.peekClose();
    }
}

pub fn hovered(explorer: *Explorer) bool {
    return fizzy.dvui.hovered(explorer.paned.data());
}

pub fn drawHeader(explorer: *Explorer) !void {
    const header_title = title(explorer.pane, true);

    dvui.labelNoFmt(@src(), header_title, .{}, .{ .font = dvui.Font.theme(.heading) });
}
