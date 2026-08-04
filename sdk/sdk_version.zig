//! **The one place `sdk_version` is edited.** Nothing mirrors this file — bump it here and every
//! consumer follows.
//!
//! It lives in the `sdk/` package (rather than beside `src/sdk/version.zig`, where the rest of
//! the runtime surface lives) because its two build-script readers cannot reach anywhere else:
//! `sdk/plugin_sdk.zig` and `src/plugins/shared/build/helpers.zig` need the value at
//! build-script comptime, and a build script can only `@import` paths inside its own package
//! root — `sdk/` is a standalone package third-party plugins depend on directly, so `../src/…`
//! is off-limits to it. The runtime side reaches *in* instead: `src/sdk/version.zig` re-exports
//! from here, and `scripts/pack-sdk.sh` keeps that relative path resolvable inside the release
//! tarball, where `src/` is vendored into this package.
//!
//! Deliberately `std`-only: `version.zig` pulls in `dylib.zig`, and through it `dvui` /
//! `proxy_bridge` — named modules that only resolve inside a real build graph — so build-script
//! code can't import it. Keeping the triplet here means reading the version can never trigger,
//! or depend on, the runtime ABI fingerprint check.
//!
//! See `src/sdk/version.zig`'s doc comment for what each field means and when to bump it;
//! `zig build test-sdk-version` is the CI lock tying a fingerprint change to a bump here.
const std = @import("std");

pub const sdk_version = std.SemanticVersion{
    .major = 0,
    .minor = 1,
    .patch = 49,
};
