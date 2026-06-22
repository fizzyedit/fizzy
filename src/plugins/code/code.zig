//! Intra-plugin import hub for the code plugin.
//!
//! Files inside `src/plugins/code/src/**` import this as `../code.zig` (or
//! `../../code.zig` from nested dirs). The compile-time module root is `module.zig`.
const std = @import("std");

pub const sdk = @import("sdk");
pub const core = @import("core");
pub const dvui = @import("dvui");

pub const Globals = @import("src/Globals.zig");
pub const State = @import("src/State.zig");
pub const Document = @import("src/Document.zig");
