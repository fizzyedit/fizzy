//! Intra-plugin import hub for the workbench plugin.
//!
//! Files inside `src/plugins/workbench/src/**` import this as `../workbench.zig` (or
//! `../../workbench.zig` from nested dirs). The compile-time module root is `module.zig`.
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
