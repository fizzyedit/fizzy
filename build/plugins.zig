//! Built-in plugin build integration — the static-embed + bundled-dylib module graph.
//!
//! Each built-in plugin keeps its fizzy-internal static-embed glue self-contained in
//! `plugins/<name>/static/integration.zig`, separate from the canonical third-party files
//! at the plugin-folder root (fizzy's `@import("<name>")` resolves to the root
//! `<name>.zig`). Fizzy root aggregates those integration files here.
pub const workbench = @import("../plugins/workbench/static/integration.zig");
pub const text = @import("../plugins/text/static/integration.zig");
pub const markdown = @import("../plugins/markdown/static/integration.zig");
pub const image = @import("../plugins/image/static/integration.zig");
pub const archive = @import("../plugins/archive/static/integration.zig");
