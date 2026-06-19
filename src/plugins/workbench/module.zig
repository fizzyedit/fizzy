//! Workbench plugin compile-time module root.
//!
//! Wired in `build.zig` as `b.addModule("workbench", …)` (future). Shell code can
//! import this as `@import("workbench")`. Plugin files inside `src/` import
//! `../workbench.zig` for shared sdk/core access.
pub const workbench = @import("workbench.zig");
pub const plugin = @import("src/plugin.zig");
pub const files = @import("src/files.zig");
pub const Workspace = @import("src/Workspace.zig");
pub const Workbench = @import("src/Workbench.zig");
pub const FileLoadJob = @import("src/FileLoadJob.zig");
pub const Globals = @import("src/Globals.zig");
