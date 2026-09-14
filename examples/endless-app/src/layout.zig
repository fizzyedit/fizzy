//! The endless shape, owned by this app — not a shipped fizzy preset.
//!
//! A real consumer copies a shape into its own source (or writes one). This file is that copy:
//! fizzy compiles it in through `-Dapp-layout=` and calls `layout` instead of a shipped preset.
//!
//! One leftover place, declared as a seed tree. The corner menu splits it horizontally or
//! vertically; each new side is an empty slot the picker fills. Remove slides a created pane
//! shut (`DockLayout.closeLeaf`) and forgets it.
const dvui = @import("dvui");

const Layout = @import("app").layout.Layout;

/// A user-created place. Nothing a plugin ships matches this word, so a new
/// region stays empty until the picker fills it.
pub const slot: []const []const u8 = &.{"slot"};

const seed: Layout.Seed = .{ .leaf = .{
    .name = "Center",
    .keywords = slot,
    .pinned = true,
} };

pub fn layout(_: ?*anyopaque, f: *Layout) !dvui.App.Result {
    var margin = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .margin = .all(10),
        .background = true,
        .color_fill = .{ .color = dvui.themeGet().color(.content, .fill) },
        .corners = dvui.CornerRect.round(12),
    });
    defer margin.deinit();

    var tree = try f.tree(@src(), &seed, .{ .expand = .both });
    defer tree.deinit();
    while (tree.leaf()) |l| {
        defer l.end();
        try f.regionIn(l, .{});
    }
    return .ok;
}
