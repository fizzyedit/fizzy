//! SDK version and ABI fingerprint lock.
//!
//! `sdk_version` is bumped when the plugin ABI boundary changes. `recorded_abi_fingerprint`
//! must be updated in the same commit — CI fails at compile time if the live fingerprint
//! drifts without an intentional version bump.
const std = @import("std");
const builtin = @import("builtin");
const dylib = @import("dylib.zig");

pub const VersionTriplet = dylib.VersionTriplet;

/// ABI contract version. Bump minor (or major for breaking changes) when
/// `recorded_abi_fingerprint` changes.
pub const sdk_version = std.SemanticVersion{
    .major = 0,
    .minor = 4,
    .patch = 0,
};

/// Commit this literal alongside `sdk_version` when the ABI boundary changes.
pub const recorded_abi_fingerprint: u64 = 0x868c117d77f99593;

comptime {
    // The ABI fingerprint guards the *dynamic* plugin-loading boundary, which is native-only
    // (no `dlopen` on wasm; web plugins are statically linked into the app). The fingerprint is
    // target-dependent — pointer width, etc. — so the recorded literal tracks native targets;
    // enforcing it on wasm would fail spuriously. Skip the lock there.
    if (builtin.target.cpu.arch != .wasm32 and dylib.abi_fingerprint != recorded_abi_fingerprint) {
        @compileError(std.fmt.comptimePrint(
            "ABI fingerprint is 0x{x} — bump sdk_version and set recorded_abi_fingerprint in src/sdk/version.zig",
            .{dylib.abi_fingerprint},
        ));
    }
}

pub fn sdkVersionTriplet() VersionTriplet {
    return .{
        .major = sdk_version.major,
        .minor = sdk_version.minor,
        .patch = sdk_version.patch,
    };
}

/// True when `required` (plugin min SDK) is satisfied by `host` (this Fizzy build).
pub fn sdkVersionSatisfies(host: std.SemanticVersion, required: std.SemanticVersion) bool {
    if (host.major != required.major) return host.major > required.major;
    if (host.minor != required.minor) return host.minor > required.minor;
    return host.patch >= required.patch;
}

pub fn formatVersion(v: std.SemanticVersion, writer: *std.Io.Writer) !void {
    try writer.print("{d}.{d}.{d}", .{ v.major, v.minor, v.patch });
}

test "sdk version lock is self-consistent" {
    try std.testing.expect(dylib.abi_fingerprint == recorded_abi_fingerprint);
}
