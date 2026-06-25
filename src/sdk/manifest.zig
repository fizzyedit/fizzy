//! Plugin identity and version metadata embedded in dylibs and optional sidecar JSON.
const std = @import("std");
const version = @import("version.zig");

pub const PluginManifest = struct {
    /// Stable plugin id (snake_case). Must match the dylib basename (`{id}.dylib`).
    id: []const u8,
    /// User-facing name shown in UI / store listings.
    name: []const u8,
    /// Plugin release version (author bumps on publish).
    version: std.SemanticVersion,
    /// Minimum host SDK version required to load this plugin.
    min_sdk_version: std.SemanticVersion = version.sdk_version,
};

/// `[major, minor, patch]` for C exports.
pub fn versionTriplet(v: std.SemanticVersion) [3]u32 {
    return .{ v.major, v.minor, v.patch };
}

test "manifest defaults min sdk to current" {
    const m = PluginManifest{
        .id = "test",
        .name = "Test",
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
    };
    try std.testing.expectEqual(version.sdk_version, m.min_sdk_version);
}
