//! Workbench plugin compile-time module root.
//!
//! Wired in `build.zig` via `wireWorkbenchModule` (`b.addModule("workbench", …)`) for the
//! native, web, and test roots. Shell code imports this as `@import("workbench")`. Plugin
//! files inside `src/` import `../workbench.zig` for shared sdk/core access.
pub const workbench = @import("workbench.zig");
pub const plugin = @import("src/plugin.zig");
pub const files = @import("src/files.zig");
pub const Workspace = @import("src/Workspace.zig");
pub const Workbench = @import("src/Workbench.zig");
pub const FileLoadJob = @import("src/FileLoadJob.zig");
pub const Globals = @import("src/Globals.zig");
