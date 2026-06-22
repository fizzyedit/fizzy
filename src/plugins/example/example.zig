//! Example plugin root module **and** intra-plugin import hub — the conventional `<name>.zig`.
//!
//! - The shell resolves `@import("example")` to this file when the plugin is compiled into the
//!   app (static embed); `example.plugin` is its entry.
//! - Files under `src/` import it as `../example.zig` for shared deps (`sdk`/`dvui`) and types.
//!
//! A minimal plugin keeps this tiny — it grows into the plugin's shared namespace as `src/`
//! gains files. It must sit at the plugin root (a Zig module can't import above its root file's
//! directory). The build-side static-embed glue lives in `static/`.
pub const sdk = @import("sdk");
pub const dvui = @import("dvui");

pub const plugin = @import("src/plugin.zig");
pub const State = @import("src/State.zig");
