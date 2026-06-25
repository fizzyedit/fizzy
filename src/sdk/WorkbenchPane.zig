//! Opaque workbench pane handle passed to a sidebar view's `draw_workspace` hook.
//! Plugins use this instead of casting back to the workbench's internal `Workspace` type.
const dvui = @import("dvui");

pub const WorkbenchPaneView = struct {
    grouping: u64,
    /// Workbench-owned slot; the plugin writes the physical content rect each frame so
    /// shell toasts can center over the pane the user is looking at.
    canvas_rect_physical: *?dvui.Rect.Physical,
};
