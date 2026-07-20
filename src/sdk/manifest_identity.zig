//! Plugin identity read from `plugin.zig.zon` at `std.Build` configure time, plus the raw
//! manifest source — embedded verbatim into the dylib (`fizzy_plugin_manifest_zon`) so a
//! disabled/unloaded plugin's identity can still be probed without a full `register`.
//!
//! `std`-free (see `sdk_version.zig`'s doc comment for why this matters): both `plugin_sdk.zig`
//! (third-party build path) and `src/plugins/shared/build/helpers.zig` (built-in path) `@import`
//! this file directly for the type, while keeping their own `readManifestAt`/`pluginOptions`
//! implementations separate — those genuinely can't share code without pulling one build graph
//! into the other (see `helpers.zig`'s doc comment).
pub const IdentityManifest = struct {
    id: []const u8,
    name: []const u8,
    version: []const u8,
    /// "" = built against whatever SDK the plugin's build pinned; no floor enforced.
    min_sdk_version: []const u8 = "",
    /// Raw `plugin.zig.zon` source, no trailing NUL.
    raw: []const u8 = "",
};
