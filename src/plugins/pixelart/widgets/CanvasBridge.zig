//! Bridges the decoupled `CanvasWidget` back to editor/app globals. The canvas takes the
//! pan/zoom scheme as config and input-suppression as a hook so it stays a reusable
//! viewport; these helpers supply the pixel-art editor's wiring at the install sites.
const fizzy = @import("../../../fizzy.zig");
const CanvasWidget = fizzy.dvui.CanvasWidget;

/// Map the user's resolved pan/zoom preference onto the canvas's own scheme enum.
pub fn scheme() CanvasWidget.PanZoomScheme {
    return switch (fizzy.PixelArt.Settings.resolvedPanZoomScheme(&fizzy.pixelart.settings)) {
        .mouse => .mouse,
        .trackpad => .trackpad,
    };
}

/// Suppression hook for a main-scope canvas (the document editing surface, image previews).
pub fn mainSuppressed(_: ?*anyopaque) bool {
    return fizzy.dvui.canvasPointerInputSuppressed();
}

/// Suppression hook for a dialog-scope canvas (embedded previews like Grid Layout).
pub fn dialogSuppressed(_: ?*anyopaque) bool {
    return fizzy.dvui.dialogCanvasPointerInputSuppressed();
}
