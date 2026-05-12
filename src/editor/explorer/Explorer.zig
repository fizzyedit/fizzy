const std = @import("std");

const dvui = @import("dvui");
const fizzy = @import("../../fizzy.zig");

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
open_branches: std.AutoHashMap(dvui.Id, void) = undefined,
pinned_palettes: bool = false,
layers_ratio: f32 = 0.5,
animations_ratio: f32 = 0.5,
closed: bool = false,

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
    if (explorer.paned.collapsed()) return;

    if (fizzy.editor.settings.explorer_ratio > 0.0) {
        explorer.paned.animateSplit(fizzy.editor.settings.explorer_ratio, dvui.easing.outBack);
    } else {
        explorer.paned.animateSplit(0.2, dvui.easing.outBack);
    }

    explorer.closed = false;
}

pub fn draw(explorer: *Explorer) !dvui.App.Result {
    const vbox = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = false,
    });
    defer vbox.deinit();

    explorer.rect = vbox.data().rect;

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

    return .ok;
}

pub fn hovered(explorer: *Explorer) bool {
    return fizzy.dvui.hovered(explorer.paned.data());
}

pub fn drawHeader(explorer: *Explorer) !void {
    const header_title = title(explorer.pane, true);

    dvui.labelNoFmt(@src(), header_title, .{}, .{ .font = dvui.Font.theme(.heading) });
}
