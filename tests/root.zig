//! Aggregator for `zig build test`.
//!
//! The Zig test runner discovers `test "..."` blocks reachable from this
//! file at compile time. We deliberately import only modules that are
//! pure logic — no dvui, no SDL, no globals — so the unit-test target
//! compiles fast and never needs a window or GPU.

comptime {
    // Phase 1: pure-logic unit tests.
    _ = @import("fizzy-direction");
    _ = @import("fizzy-easing");
    _ = @import("fizzy-layer-order");
    _ = @import("fizzy-palette-parse");
    _ = @import("fizzy-layout-anchor");
    _ = @import("fizzy-reduce");
    _ = @import("fizzy-grid-validate");
    _ = @import("fizzy-animation");
    _ = @import("fizzy-window-layout");
    _ = @import("fizzy-plugin-dylib");
}
