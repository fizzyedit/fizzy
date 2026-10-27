const fizzy = @import("../../fizzy.zig");
const workbench = @import("workbench");
const dvui = @import("dvui");
const Layout = @import("app").layout.Layout;
const SidePane = @import("app").layout.SidePane;

pub const Explorer = @This();

pub const files = workbench.files;
// pub const animations = @import("animations.zig");
// pub const keyframe_animations = @import("keyframe_animations.zig");
// The pixel-art project view is contributed by the plugin via `Host.registerSurface`,
// not re-exported here.
pub const settings = @import("settings.zig");

/// Drawn by the layout's side pane; the explorer owns whether it was closed, and opens and
/// closes the region.
pane: SidePane = .{},
animations_ratio: f32 = 0.5,
closed: bool = false,

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
    explorer.pane.collapse_btn_anim_started = false;
    if (editor.regionFor(fizzy.sdk.keywords.ide.sidebar)) |r| r.close();
}

/// Draws the side pane in the sidebar region, and shuts the explorer when its collapse button is pressed.
pub fn draw(
    explorer: *Explorer,
    editor: *fizzy.Editor,
    f: *Layout,
    keywords: []const []const u8,
) Layout.Region.Error!dvui.App.Result {
    const result = try explorer.pane.draw(f, keywords, editor.regionFor(fizzy.sdk.keywords.ide.sidebar));
    if (explorer.pane.collapse_requested) {
        explorer.peekClose(editor);
    }
    return result;
}

pub fn hovered(_: *Explorer, editor: *fizzy.Editor) bool {
    _ = editor;
    // The sidebar is a region now, and a region is a plain box — there is no widget handle to ask
    // about hover. Nothing reads this today; it returns false rather than pretending.
    return false;
}
