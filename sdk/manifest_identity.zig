//! Mirror of `sdk/src/manifest_identity.zig` for the plugin-facing package's build scripts.
//! Keep the struct identical.
pub const IdentityManifest = struct {
    id: []const u8,
    name: []const u8,
    version: []const u8,
    /// "" = built against whatever SDK the plugin's build pinned; no floor enforced.
    min_sdk_version: []const u8 = "",
    /// Raw `plugin.zig.zon` source, no trailing NUL.
    raw: []const u8 = "",
};
