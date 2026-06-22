//! Built-in plugin build integration — the static-embed + bundled-dylib module graph.
//!
//! Each built-in plugin keeps its fizzy-internal static-embed glue self-contained in
//! `src/plugins/<name>/static/integration.zig`, separate from the canonical third-party files
//! at the plugin-folder root (the shell's `@import("<name>")` resolves to the root
//! `<name>.zig`). Fizzy root aggregates those integration files here.
pub const workbench = @import("../src/plugins/workbench/static/integration.zig");
pub const text = @import("../src/plugins/text/static/integration.zig");
pub const markdown = @import("../src/plugins/markdown/static/integration.zig");
pub const image = @import("../src/plugins/image/static/integration.zig");
