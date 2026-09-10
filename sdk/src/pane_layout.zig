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
///
/// No top margin, deliberately: a document canvas (`mainCanvasVbox`) starts flush at the top of
/// the center region, directly under the tab bar / titlebar, and a 10pt gap here made the
/// homepage and every other card sit lower than the canvas they replace — a visible step when
/// switching between them, and a mismatch the host cannot compensate for when cross-fading
/// providers (it has no way to know which shape it is fading between).
pub fn emptyStateCard(content_color: dvui.Color, grouping: u64) *dvui.BoxWidget {
    return dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .both,
        .background = true,
        .color_fill = content_color,
        .corners = dvui.CornerRect.all(16),
        .id_extra = @intCast(grouping),
    });
}
