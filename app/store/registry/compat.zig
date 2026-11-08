//! Host identity for the plugin store: the `os-arch` key used both as a `downloads` map key and
//! as a path segment when building a plugin's download URL.
//!
//! Fingerprint compatibility is no longer matched here - a `registry.ReleaseShard` is already
//! scoped to exactly one `abi_fingerprint` (see `store.Catalog`, which fetches the shard for the
//! running host's own `dylib.abi_fingerprint`), so the only thing left to check client-side is
//! whether that shard's release has a binary for this `os-arch` (see
//! `registry.ShardRelease.downloadFor`).
const std = @import("std");
const builtin = @import("builtin");

/// The host's `os-arch` key, matching the registry `downloads` object keys
/// (e.g. "macos-aarch64"). Comptime-known.
pub fn hostKey() []const u8 {
    return comptime hostKeyFor(builtin.target);
}

/// The `os-arch` registry key for a given comptime `target`, as `hostKey` gives it
/// for the host (e.g. "android-aarch64", "web-wasm32").
pub fn hostKeyFor(comptime target: std.Target) []const u8 {
    // The web: one key for the wasm side module a plugin publishes for the browser.
    if (target.cpu.arch == .wasm32) return "web-wasm32";
    const arch = switch (target.cpu.arch) {
        .aarch64 => "aarch64",
        .x86_64 => "x86_64",
        else => "unknown",
    };
    if (target.abi.isAndroid()) return "android-" ++ arch;
    const os = switch (target.os.tag) {
        .macos => "macos",
        .linux => "linux",
        .windows => "windows",
        else => "unknown",
    };
    return os ++ "-" ++ arch;
}

test {
    _ = @import("compat_tests.zig");
}
