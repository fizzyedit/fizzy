//! Shared dvui layout helpers for workbench content panes. Used by the workbench when
//! drawing document canvases and by plugins that take over a pane via `draw_workspace`
//! (e.g. pixel art's Project atlas preview). Stable `@src()` + `grouping` ids avoid
//! widget churn when switching between document and project views.
const dvui = @import("dvui");

/// Main vertical canvas region inside a workspace pane.
pub fn mainCanvasVbox(content_color: dvui.Color, background: bool, grouping: u64) *dvui.BoxWidget {
    return dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = background,
        .color_fill = content_color,
        .id_extra = @intCast(grouping),
    });
}

/// Rounded card behind empty states (homepage, project hint, etc.).
pub fn emptyStateCard(content_color: dvui.Color, grouping: u64) *dvui.BoxWidget {
    return dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .both,
        .background = true,
        .color_fill = content_color,
        .corner_radius = dvui.Rect.all(16),
        .margin = .{ .y = 10 },
        .id_extra = @intCast(grouping),
    });
}
