//! Wasm entry point for the fizzy web build.
//!
//! Uses the DVUI App pattern: declaring `dvui_app` + `main` lets DVUI's web
//! backend auto-export `dvui_init` / `dvui_deinit` / `dvui_update`
//! (see `dvui-dev/src/backends/web.zig:890`). This matches graphl and DVUI's
//! own `examples/app.zig` rather than the manual export style.
//!
//! Lifecycle is delegated to `fizzy.Entry` (`AppInit` / `AppFrame` / `AppDeinit`) via
//! `fizzy.Entry.dvui_app`, so the web build runs the same editor tick loop as native.

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
// actually calls into native APIs.
comptime {
    // Pure constants / re-exports
    _ = fizzy.version;

    // Math + graphics helpers
    _ = fizzy.core.math.checker;
    _ = fizzy.core.math.rotate;
    _ = fizzy.core.math.lerp;
    _ = fizzy.core.image.init;
    _ = fizzy.core.image.pixels;
    _ = fizzy.core.perf.record;

    // Custom dvui wrapper + widgets — types compile even though the widget files
    // contain dead `@import("backend")` SDL3 imports at file scope.
    _ = fizzy.core.widgets.CanvasWidget;

    // The big ones: Editor + App. Type-level reference only — passes because Zig
    // doesn't fully analyze function bodies until they're actually wired into a
    // reachable call (e.g. assigned to a runtime fn-pointer field)\
    _ = fizzy.Editor;
    _ = fizzy.Entry;
}

pub const dvui_app: dvui.App = fizzy.Entry.dvui_app;

pub const main = dvui.App.main;
pub const panic = dvui.App.panic;
pub const std_options: std.Options = fizzy.Entry.std_options;

// ---- libm for plugins ---------------------------------------------------------------------
//
// A plugin built as a wasm side module has no compiler-rt of its own, and its optimized build
// calls a few libm entry points by name (`@exp2` lowering, `ldexp`); Debug builds inline them.
// The page resolves a side module's `env` imports from this module's exports, so the host
// provides them here. Exported by `build/web.zig`.
export fn ldexpf(x: f32, n: i32) f32 {
    return std.math.ldexp(x, n);
}
export fn ldexp(x: f64, n: i32) f64 {
    return std.math.ldexp(x, n);
}
