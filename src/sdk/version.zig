//! SDK version and ABI fingerprint lock.
//!
//! `sdk_version` is bumped when the plugin ABI boundary changes. `recorded_sdk_shape_fingerprint`
//! must be updated in the same commit — CI fails at compile time if the live shape fingerprint
//! drifts from the recorded literal without an intentional version bump.
//!
//! **Two fingerprints, one shape.** Both derive from the same target/mode-invariant declared
//! shape (`fingerprint.hashAllShape`: field names/order, integer bit-width, enum tags, pointer
//! kind, fn signatures — never a byte offset or size) of the Fizzy-owned boundary:
//!
//!   * `dylib.sdk_shape_fingerprint` — the bare shape hash, checked below against a single
//!     recorded literal. The "did you forget to bump `sdk_version`" guard. Invariant, so it needs
//!     no per-(arch, os, mode) table and no cross-compiling: `zig build test-sdk-version` on any
//!     target reports the value to record.
//!   * `dylib.abi_fingerprint` — the runtime dlopen-time load key: the shape hash folded with the
//!     optimize-mode *safety class* (`Debug`/`ReleaseSafe` vs `ReleaseFast`/`ReleaseSmall`, which
//!     lay out hash-map safety fields differently). Host and plugin compute it live and compare
//!     (`dylib.fingerprintMatches`). Also target-invariant — cross-target `dlopen` is impossible
//!     regardless, so the key deliberately excludes per-target byte offsets, which lets the plugin
//!     store match one fingerprint per release across every `os-arch` binary.
//!
//! Because the load key is shape-based, a plugin breaks *only* when the boundary shape actually
//! changes (→ you bump `sdk_version`) or the optimize-mode class differs (a genuinely unloadable
//! combination). A cosmetic dvui/toolchain update that leaves the boundary shape untouched keeps
//! every installed plugin loading. The one thing this no longer catches — pure codegen/padding
//! drift within a single `sdk_version` — only happens on a deliberate, pinned zig/dvui bump that
//! is a coordinated re-release anyway. See `fingerprint.hashAllShape` for the full rationale.
//!
//! **Cadence policy (decoupled from the app version).** The app version (`VERSION` /
//! `build.zig.zon`) ships often and is *not* an input to either fingerprint or to `sdk_version`.
//! The shape fingerprint is a pure function of the plugin-boundary types Fizzy declares (dvui
//! types included, reached transitively where they cross the boundary) — it only moves when one of
//! those *shapes* changes. `dvui` and the Zig toolchain are pinned (see the `dvui` dependency in
//! `build.zig.zon` and `ZIG_VERSION` in CI) and bumped deliberately/batched; a bump that
//! restructures a boundary-reachable dvui type moves the shape fingerprint (→ bump `sdk_version`),
//! while a cosmetic one does not. A Fizzy release that leaves the boundary shape untouched keeps
//! the same fingerprint, so the store's installed plugins keep loading. The store matches plugin
//! binaries on `abi_fingerprint` (see `docs/PLUGINS.md` § Compatibility).
const std = @import("std");
const builtin = @import("builtin");
const dylib = @import("dylib.zig");

pub const VersionTriplet = dylib.VersionTriplet;

/// ABI contract version. Bump minor (or major for breaking changes) when
/// `recorded_sdk_shape_fingerprint` changes.
pub const sdk_version = std.SemanticVersion{
    .major = 0,
    .minor = 8,
    .patch = 0,
};

/// Recorded `dylib.sdk_shape_fingerprint` — see the module doc above for what this hashes and
/// why it is a single target/mode-invariant literal rather than a per-target table. Update this
/// value (from the `@compileError` it triggers) and bump `sdk_version` in the same commit
/// whenever it changes.
///
/// 0.5.0: added `Host.FileRowFillColor.owner` + service-owner tracking for runtime unload.
/// 0.6.0: added `Host.registerFileIcon`/`FileIcon` (plugins draw their own file-tree icons).
/// 0.7.0: removed `host.uiAtlas`/`UiAtlasView`/`UiSprite` (plugins own their own sprite atlases).
/// 0.8.0: boundary layout shifted (custom TextEntryWidget / workbench tabs work); also replaced
/// the old per-(arch, os) `recorded_abi_fingerprints` table — which could not actually hold one
/// value per platform once optimize mode is accounted for (see `fingerprint.hashAllShape`) — with
/// this single shape fingerprint.
///   ↳ Value re-recorded (no `sdk_version` bump, no boundary change) after fixing a
///     target-*variance* bug in `hashAllShape`: it folded in the concrete bit-width of pointer-
///     sized ints, so any `usize`/`isize` reached in the walk (every `std` container's len/
///     capacity) hashed as 64-bit on native but 32-bit on wasm32. The old literal
///     (`0xd8304e87baf922b2`) was a 64-bit-host value that no wasm32 build could ever match, which
///     broke `zig build check-web`/`serve-web`. `hashTypeShape` now canonicalizes `usize`/`isize`
///     to width-free tokens, so this literal is identical on every target. The runtime gate
///     (`abi_fingerprint`) is unchanged, so already-installed plugins keep loading.
pub const recorded_sdk_shape_fingerprint: u64 = 0xa62dd86a1dca36e3;

comptime {
    if (dylib.sdk_shape_fingerprint != recorded_sdk_shape_fingerprint) {
        @compileError(std.fmt.comptimePrint(
            "SDK boundary shape fingerprint is 0x{x} — bump sdk_version and update " ++
                "recorded_sdk_shape_fingerprint in src/sdk/version.zig",
            .{dylib.sdk_shape_fingerprint},
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

test "sdk shape fingerprint lock is self-consistent" {
    // If this were out of sync, the module-level comptime block above would already have
    // failed to compile, so asserting it here just guards against future refactors.
    try std.testing.expectEqual(recorded_sdk_shape_fingerprint, dylib.sdk_shape_fingerprint);
}

test "shape fingerprint is decoupled from the app version" {
    // The shape fingerprint is a pure function of the Fizzy-owned SDK boundary types. The app
    // version is not in that set, so a routine app-version bump must leave it — and therefore
    // plugin compatibility — unchanged. This guards the cadence policy in the module doc comment:
    // if someone ever wires an app-version-dependent value into a boundary type's declared shape,
    // the live value drifts from the recorded literal and both this lock and the comptime check
    // above fail, forcing a deliberate `sdk_version` bump rather than a silent one.
    try std.testing.expectEqual(recorded_sdk_shape_fingerprint, dylib.sdk_shape_fingerprint);
}
