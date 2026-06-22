//! Image plugin root module **and** intra-plugin import hub.
//!
//! - The shell resolves `@import("image")` to this file when the plugin is compiled into the app
//!   (static embed) and reaches its public surface here (`plugin`, document types).
//! - Files under `src/` import it as `../image.zig` for the shared deps (`sdk`/`core`/`dvui`)
//!   and sibling types — the conventional `<package>.zig` namespace.
const std = @import("std");

pub const sdk = @import("sdk");
pub const core = @import("core");
pub const dvui = @import("dvui");

pub const plugin = @import("src/plugin.zig");
pub const State = @import("src/State.zig");
pub const Document = @import("src/Document.zig");
pub const ImageView = @import("src/ImageView.zig");
