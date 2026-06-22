//! Built-in plugin build integration — the static-embed + bundled-dylib module graph.
//!
//! Each built-in plugin keeps its fizzy-internal static-embed glue self-contained in
//! `src/plugins/<name>/static/integration.zig`, separate from the canonical third-party files
//! at the plugin-folder root (the shell's `@import("<name>")` resolves to the root
//! `<name>.zig`). Fizzy root aggregates those integration files here.
pub const pixi = @import("../src/plugins/pixi/static/integration.zig");
pub const workbench = @import("../src/plugins/workbench/static/integration.zig");
pub const code = @import("../src/plugins/code/static/integration.zig");
pub const example = @import("../src/plugins/example/static/integration.zig");

pub const ZipPackage = pixi.ZipPackage;
