//! Intra-plugin import hub for the workbench plugin.
//!
//! Files inside `src/plugins/workbench/src/**` import this as `../workbench.zig` (or
//! `../../workbench.zig` from nested dirs). The compile-time module root is `module.zig`.
const std = @import("std");

pub const sdk = @import("sdk");
pub const core = @import("core");
pub const dvui = @import("dvui");
