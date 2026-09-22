//! Test root for the files that decide how big a pane is: `widgets/Split.zig` (extents in
//! points, one number per region) and the split tree in `widgets/DockingWidget*.zig`.
//!
//! A root of its own, one directory *above* them, for a build reason worth stating: a test module
//! rooted at `core/widgets/Split.zig` can only import within `core/widgets/`, and both files reach
//! `core/anim.zig` for the slide curves. Rooting here puts the whole of `core/` inside the module
//! and costs nothing — these tests run against dvui's testing backend either way.
//!
//! They are a separate step from the integration tests because they need a real `dvui.Window` and
//! nothing else: every bug this pair has had was a dvui event-routing or layout-settle rule rather
//! than arithmetic, and reading the code caught none of them.
test {
    _ = @import("widgets/Split.zig");
    // The local copies of upstream's docking + blur (see `widgets.zig`): referenced here so they
    // are analysed — and their own tests run — even before anything in the app draws them.
    _ = @import("widgets/DockingWidget.zig");
    _ = @import("widgets/DockingWidget/Layout.zig");
    _ = @import("widgets/DockingWidget/Row.zig");
    _ = @import("widgets/BlurBackdrop.zig");
}
