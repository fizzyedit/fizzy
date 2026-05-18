//! Wasm entry point for the fizzy web build.
//!
//! Uses the DVUI App pattern: declaring `dvui_app` + `main` lets DVUI's web
//! backend auto-export `dvui_init` / `dvui_deinit` / `dvui_update`
//! (see `dvui-dev/src/backends/web.zig:890`). This matches graphl and DVUI's
//! own `examples/app.zig` rather than the manual export style.
//!
//! Lifecycle is delegated to `fizzy.App` (`AppInit` / `AppFrame` / `AppDeinit`) via
//! `fizzy.App.dvui_app`, so the web build runs the same editor tick loop as native.

const std = @import("std");
const dvui = @import("dvui");
const fizzy = @import("fizzy.zig");

// Wasm-cleanliness probes. Referencing each symbol forces semantic analysis of its
// module graph; any compile error pinpoints what to gate next. Zero-cost at runtime.
//
// Major finding: every entry below compiles for `wasm32-freestanding`, including
// symbols whose files import `@import("backend")` (SDL3) at file scope. Zig's
// lazy analysis means a dead/unused file-scope `const` never triggers its
// `@import`. We only pay the wasm-incompatibility cost when a reachable function
// actually calls into native APIs. See WEB_PORT_PLAN.md.
comptime {
    // Pure constants / re-exports
    _ = fizzy.version;
    _ = fizzy.fa.adjust;
    _ = fizzy.atlas;

    // Algorithms — pure Zig + dvui
    _ = fizzy.algorithms.brezenham;
    _ = fizzy.algorithms.reduce;

    // Top-level data types (.pixi format on-disk shapes)
    _ = fizzy.Animation;
    _ = fizzy.Atlas;
    _ = fizzy.File;
    _ = fizzy.Layer;
    _ = fizzy.Sprite;

    // Internal editor-side data types
    _ = fizzy.Internal.Animation;
    _ = fizzy.Internal.Atlas;
    _ = fizzy.Internal.Buffers;
    _ = fizzy.Internal.File.init;
    _ = fizzy.Internal.History;
    _ = fizzy.Internal.Layer;
    _ = fizzy.Internal.Palette;
    _ = fizzy.Internal.Sprite;

    // Math + graphics helpers
    _ = fizzy.math.checker;
    _ = fizzy.math.rotate;
    _ = fizzy.math.lerp;
    _ = fizzy.image.init;
    _ = fizzy.image.pixels;
    _ = fizzy.perf.record;
    _ = fizzy.render;

    // Custom dvui wrapper + widgets — types compile even though the widget files
    // contain dead `@import("backend")` SDL3 imports at file scope.
    _ = fizzy.dvui.FileWidget;
    _ = fizzy.dvui.CanvasWidget;

    // The big ones: Editor + App. Type-level reference only — passes because Zig
    // doesn't fully analyze function bodies until they're actually wired into a
    // reachable call (e.g. assigned to a runtime fn-pointer field). A probe
    // wiring these as `dvui_app.initFn/frameFn/deinitFn` surfaced 10 concrete
    // errors — see WEB_PORT_PLAN.md "next session inventory".
    _ = fizzy.Editor;
    _ = fizzy.App;
}

pub const dvui_app: dvui.App = fizzy.App.dvui_app;

pub const main = dvui.App.main;
pub const panic = dvui.App.panic;
pub const std_options: std.Options = fizzy.App.std_options;
