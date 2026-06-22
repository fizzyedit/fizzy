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
const pixi = @import("pixi");
const Internal = pixi.internal;

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
    _ = fizzy.atlas;

    // Algorithms — pure Zig + dvui
    _ = pixi.algorithms.brezenham;
    _ = pixi.algorithms.reduce;

    // Top-level data types (.pixi format on-disk shapes)
    _ = pixi.Animation;
    _ = pixi.Atlas;
    _ = pixi.File;
    _ = pixi.Layer;
    _ = pixi.Sprite;

    // Internal editor-side data types
    _ = Internal.Animation;
    _ = Internal.Atlas;
    _ = Internal.Buffers;
    _ = Internal.File.init;
    _ = Internal.History;
    _ = Internal.Layer;
    _ = Internal.Palette;
    _ = Internal.Sprite;

    // Math + graphics helpers
    _ = fizzy.math.checker;
    _ = fizzy.math.rotate;
    _ = fizzy.math.lerp;
    _ = fizzy.image.init;
    _ = fizzy.image.pixels;
    _ = fizzy.perf.record;
    _ = pixi.render;

    // Custom dvui wrapper + widgets — types compile even though the widget files
    // contain dead `@import("backend")` SDL3 imports at file scope.
    _ = pixi.widgets.FileWidget;
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
