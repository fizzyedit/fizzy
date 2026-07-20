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

/// ABI contract version. `sdkVersionSatisfies` below does a plain lexicographic
/// (major, minor, patch) compare with no semver "0.x is special" carve-out, so each field's
/// meaning is a convention this project enforces by discipline, not by the type system:
///
///   * **patch** — bump on every `recorded_sdk_shape_fingerprint` change. This is the field that
///     moved (as `minor`) for every 0.5.0–0.35.0 entry in the changelog below; from 0.1.35 on,
///     ordinary boundary changes bump patch instead.
///   * **minor** — a manually-bumped compatibility *epoch*, reserved for a deliberate, announced
///     hard break (e.g. "pre-1.0 pins are no longer supported, rebuild against the new epoch").
///     Left untouched otherwise. Bump this, not major, for that.
///   * **major** — stays 0 until there's an actual stable 1.0 contract to commit to.
///
/// The value itself lives in `sdk_version.zig`, not here — that file has no dependency
/// beyond `std`, so `plugin_sdk.zig` / `helpers.zig` (build-script code, which can't import this
/// file — see its own doc comment) can read the current version.
pub const sdk_version = @import("sdk_version.zig").sdk_version;

/// Recorded `dylib.sdk_shape_fingerprint` — see the module doc above for what this hashes and
/// why it is a single target/mode-invariant literal rather than a per-target table. Update this
/// value (from the `@compileError` it triggers) and bump `sdk_version` in the same commit
/// whenever it changes.
pub const recorded_sdk_shape_fingerprint: u64 = 0x6d066fceebfb2b40;

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
