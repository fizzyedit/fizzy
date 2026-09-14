//! The endless shape, owned by this app — not a shipped fizzy preset.
//!
//! A real consumer copies a shape into its own source (or writes one). This file is that copy:
//! fizzy compiles it in through `-Dapp-layout=` and calls `layout` instead of a shipped preset.
//!
//! One leftover place. The corner menu splits it horizontally or vertically; each
//! new side is an empty slot the picker fills. Remove slides a created pane shut
//! and forgets it. There are no edge sentinels — those handles fought the ones
//! that resize a split.
const dvui = @import("dvui");

const Layout = @import("app").layout.Layout;

/// A user-created place. Nothing a plugin ships matches this word, so a new
/// region stays empty until the picker fills it.
pub const slot: []const []const u8 = &.{"slot"};

pub fn layout(_: ?*anyopaque, f: *Layout) !dvui.App.Result {
    var margin = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .margin = .all(10) });
    defer margin.deinit();

    var center = try f.region(@src(), .{
        .name = "Center",
        .keywords = slot,
        .by_name = true,
    }, .{
        .expand = .both,
        .background = true,
        .color_fill = .{ .color = dvui.themeGet().color(.content, .fill) },
        .corners = dvui.CornerRect.round(12),
    });
    defer center.deinit();

    return .ok;
}
