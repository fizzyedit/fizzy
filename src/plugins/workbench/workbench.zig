//! Workbench plugin root module **and** intra-plugin import hub.
//!
//! - The shell resolves `@import("workbench")` to this file when compiled into the app (static
//!   embed) and reaches its public surface here.
//! - Files under `src/` import it as `../workbench.zig` for shared deps + types — the
//!   conventional `<package>.zig` namespace.
//!
//! Must sit at the plugin root: a Zig module cannot import files above its root file's
//! directory. The build-side static-embed glue lives in `static/`.
const std = @import("std");

pub const sdk = @import("sdk");
pub const core = @import("core");
pub const dvui = @import("dvui");

pub const math = core.math;
pub const atlas = core.atlas;
pub const platform = core.platform;
pub const perf = core.perf;
pub const Sprite = core.Sprite;

/// Shell's custom dvui widgets/helpers (TreeWidget, paned, labelWithKeybind, …).
pub const wdvui = core.dvui;

pub const plugin = @import("src/plugin.zig");
pub const runtime = @import("src/runtime.zig");
pub const files = @import("src/files.zig");
pub const Workspace = @import("src/Workspace.zig");
pub const Workbench = @import("src/Workbench.zig");
pub const FileLoadJob = @import("src/FileLoadJob.zig");
