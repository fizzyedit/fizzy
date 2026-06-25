//! Bridges the decoupled `CanvasWidget` back to editor/app globals. The canvas takes the
//! pan/zoom scheme as config and input-suppression as a hook so it stays a reusable
//! viewport; these helpers supply the pixel-art editor's wiring at the install sites.
const pixi_mod = @import("../../pixi.zig");
const runtime = @import("../runtime.zig");
const CanvasWidget = pixi_mod.core.dvui.CanvasWidget;

/// Map the user's resolved pan/zoom preference onto the canvas's own scheme enum.
pub fn scheme() CanvasWidget.PanZoomScheme {
    return switch (pixi_mod.Settings.resolvedPanZoomScheme(&runtime.state().settings, runtime.state().host)) {
        .mouse => .mouse,
        .trackpad => .trackpad,
    };
}

/// Suppression hook for a main-scope canvas (the document editing surface, image previews).
pub fn mainSuppressed(_: ?*anyopaque) bool {
    return pixi_mod.core.dvui.canvasPointerInputSuppressed();
}

/// Suppression hook for a dialog-scope canvas (embedded previews like Grid Layout).
pub fn dialogSuppressed(_: ?*anyopaque) bool {
    return pixi_mod.core.dvui.dialogCanvasPointerInputSuppressed();
}
