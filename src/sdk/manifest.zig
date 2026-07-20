//! The declarative `plugin.zig.zon` manifest (`Manifest`): identity/version metadata a plugin
//! author declares, and the shell reads back out of a loaded dylib.
//!
//! `Manifest` is identity-only — see `docs/PLUGIN_MANIFEST_PLAN.md`'s "Locked decisions": the
//! author's `plugin.zig.zon` declares `id`/`name`/`version`/`min_sdk_version` and nothing else.
//! Capability (which hooks a plugin implements, what it registers) has no
//! declare-and-audit list — `plugin.zig`'s `register()` + vtable is the single source of truth,
//! enforced by nothing beyond normal Zig compilation.
//!
//! The typed, `std.SemanticVersion`-based shape actually baked into a dylib's C-ABI exports is
//! `dylib.Identity` — build-injected from this same `plugin.zig.zon`, never parsed from it at
//! runtime (see `dylib.exportEntry`).
const std = @import("std");

/// `[major, minor, patch]` for C exports.
pub fn versionTriplet(v: std.SemanticVersion) [3]u32 {
    return .{ v.major, v.minor, v.patch };
}

/// The declarative `plugin.zig.zon` manifest: identity only. See the module doc comment and
/// `docs/PLUGIN_MANIFEST_PLAN.md`.
pub const Manifest = struct {
    id: []const u8,
    name: []const u8,
    /// Semver string, validated post-parse (see `parse`) rather than typed `std.SemanticVersion`
    /// so zon parsing stays a plain string round-trip; the build helper forwards this from
    /// `build.zig.zon`.
    version: []const u8,
    /// "" = built against whatever SDK the plugin's build pinned; no floor enforced.
    min_sdk_version: []const u8 = "",
};

/// Parse a `plugin.zig.zon` source buffer (must be NUL-terminated, e.g. read via
/// `dupeZ`/`readFileAllocOptions` with a sentinel) into a `Manifest`. Validates `version` (and
/// `min_sdk_version`, when non-empty) are well-formed semver post-parse — zon itself has no
/// semver type, so this is the manifest's own integrity check on top of the structural parse.
/// Free the result with `free`.
pub fn parse(gpa: std.mem.Allocator, source: [:0]const u8) !Manifest {
    const m = try std.zon.parse.fromSliceAlloc(Manifest, gpa, source, null, .{});
    errdefer free(gpa, m);
    _ = std.SemanticVersion.parse(m.version) catch return error.InvalidVersion;
    if (m.min_sdk_version.len > 0) {
        _ = std.SemanticVersion.parse(m.min_sdk_version) catch return error.InvalidMinSdkVersion;
    }
    return m;
}

/// Free a `Manifest` returned by `parse`.
pub fn free(gpa: std.mem.Allocator, m: Manifest) void {
    std.zon.parse.free(gpa, m);
}

test "Manifest parse round-trips identity" {
    const gpa = std.testing.allocator;
    const source: [:0]const u8 =
        \\.{
        \\    .id = "example",
        \\    .name = "Example",
        \\    .version = "1.2.3",
        \\    .min_sdk_version = "0.32.0",
        \\}
    ;

    const m = try parse(gpa, source);
    defer free(gpa, m);

    try std.testing.expectEqualStrings("example", m.id);
    try std.testing.expectEqualStrings("Example", m.name);
    try std.testing.expectEqualStrings("1.2.3", m.version);
    try std.testing.expectEqualStrings("0.32.0", m.min_sdk_version);
}

test "parse defaults min_sdk_version when omitted" {
    const gpa = std.testing.allocator;
    const source: [:0]const u8 =
        \\.{
        \\    .id = "example",
        \\    .name = "Example",
        \\    .version = "0.1.0",
        \\}
    ;
    const m = try parse(gpa, source);
    defer free(gpa, m);

    try std.testing.expectEqualStrings("", m.min_sdk_version);
}

test "parse rejects a non-semver version" {
    const gpa = std.testing.allocator;
    const source: [:0]const u8 =
        \\.{
        \\    .id = "example",
        \\    .name = "Example",
        \\    .version = "not-a-version",
        \\}
    ;
    try std.testing.expectError(error.InvalidVersion, parse(gpa, source));
}
