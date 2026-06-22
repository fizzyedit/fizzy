//! Code plugin root module **and** intra-plugin import hub.
//!
//! - The shell resolves `@import("code")` to this file when the plugin is compiled into the app
//!   (static embed) and reaches its public surface here (`plugin`, document types).
//! - Files under `src/` import it as `../code.zig` for the shared deps (`sdk`/`core`/`dvui`)
//!   and sibling types — the conventional `<package>.zig` namespace.
//!
//! It must sit at the plugin root: a Zig module cannot import files above its root file's
//! directory, so this has to be beside `src/` to re-export from it. The build-side static-embed
//! glue lives in `static/`. A minimal/third-party plugin only needs this file if it embeds
//! statically or wants a shared import hub.
const std = @import("std");

pub const sdk = @import("sdk");
pub const core = @import("core");
pub const dvui = @import("dvui");

pub const plugin = @import("src/plugin.zig");
pub const State = @import("src/State.zig");
pub const Document = @import("src/Document.zig");
pub const CodeEditor = @import("src/CodeEditor.zig");
pub const SyntaxHighlight = @import("src/SyntaxHighlight.zig");
