//! Shared dvui layout helpers for workbench content panes. Used by the workbench when
//! drawing document canvases and by plugins that take over the main area (`Surface.takeover_when`)
//! (e.g. pixel art's Project atlas preview). Stable `@src()` + `grouping` ids avoid
//! widget churn when switching between document and project views.
const dvui = @import("dvui");

/// Main vertical canvas region inside a workspace pane.
pub fn mainCanvasVbox(content_color: dvui.Color, background: bool, grouping: u64) *dvui.BoxWidget {
    return dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = background,
        .color_fill = .{ .color = content_color },
        .id_extra = @intCast(grouping),
    });
}

/// Layout box behind empty states (homepage, project hint, etc.). Transparent:
/// a fill is the shape's to set on the region, not a second card inside it.
pub fn emptyStateCard(content_color: dvui.Color, grouping: u64) *dvui.BoxWidget {
    _ = content_color;
    return dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .both,
        .background = false,
        .id_extra = @intCast(grouping),
    });
}
