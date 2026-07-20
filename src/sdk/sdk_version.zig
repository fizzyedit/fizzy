//! Just the `sdk_version` triplet, with no dependency beyond `std` — split out of `version.zig`
//! (which pulls in `dylib.zig`, and through it `dvui`/`proxy_bridge`, named modules only
//! resolvable inside a real build graph) so build-script code (`plugin_sdk.zig`,
//! `src/plugins/shared/build/helpers.zig`) can read the current SDK version as a plain relative
//! `@import` without dragging in — or being able to trigger — the runtime ABI fingerprint check.
//! `version.zig` re-exports `sdk_version` from here; this file is the single source of truth.
const std = @import("std");

/// See `version.zig`'s doc comment on `sdk_version` for what each field means and when to bump
/// it — this is purely the value, moved here so it has exactly one home.
pub const sdk_version = std.SemanticVersion{
    .major = 0,
    .minor = 1,
    .patch = 39,
};
