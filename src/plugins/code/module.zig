//! Code plugin compile-time module root.
//!
//! Wired in `build.zig` via `wireCodeModule` (`b.addModule("code", …)`) for the native,
//! web, and test roots. Shell code imports this as `@import("code")`. Plugin files inside
//! `src/` import `../code.zig` for shared sdk/core access.
pub const code = @import("code.zig");
pub const plugin = @import("src/plugin.zig");
pub const State = @import("src/State.zig");
pub const Document = @import("src/Document.zig");
pub const Globals = @import("src/Globals.zig");
