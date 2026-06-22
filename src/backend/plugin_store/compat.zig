//! Compatibility matching between the running host and a registry plugin's releases.
//!
//! A prebuilt plugin dylib is valid only for one `(abi_fingerprint, os-arch)` pair (see
//! `docs/PLUGINS.md` § Compatibility), so selection is exact on the fingerprint + arch — not
//! a semver negotiation. Pure logic; fully unit-tested.
const std = @import("std");
const builtin = @import("builtin");
const registry = @import("registry.zig");

/// The host's `os-arch` key, matching the registry `downloads` object keys
/// (e.g. "macos-aarch64"). Comptime-known.
pub fn hostKey() []const u8 {
    const os = switch (builtin.os.tag) {
        .macos => "macos",
        .linux => "linux",
        .windows => "windows",
        else => "unknown",
    };
    const arch = switch (builtin.cpu.arch) {
        .aarch64 => "aarch64",
        .x86_64 => "x86_64",
        else => "unknown",
    };
    return os ++ "-" ++ arch;
}

/// Parse a "0x…" (or bare hex/decimal) fingerprint string into a u64, or null if malformed.
pub fn parseFingerprint(s: []const u8) ?u64 {
    const trimmed = std.mem.trim(u8, s, " \t\r\n");
    return std.fmt.parseInt(u64, trimmed, 0) catch null;
}

/// The newest release of `entry` that is loadable on this host: its `abi_fingerprint` equals
/// `host_fp` **and** it ships a binary for `host_key`. Returns null when none qualifies (the
/// store shows "needs a rebuild for this Fizzy SDK").
pub fn selectRelease(
    entry: registry.PluginEntry,
    host_fp: u64,
    host_key: []const u8,
) ?registry.Release {
    var best: ?registry.Release = null;
    var best_ver: std.SemanticVersion = undefined;
    for (entry.releases) |candidate| {
        const fp = parseFingerprint(candidate.abi_fingerprint) orelse continue;
        if (fp != host_fp) continue;
        if (candidate.downloadFor(host_key) == null) continue;
        const ver = std.SemanticVersion.parse(candidate.version) catch continue;
        if (best == null or ver.order(best_ver) == .gt) {
            best = candidate;
            best_ver = ver;
        }
    }
    return best;
}

const testing = std.testing;

/// Build a release whose `downloads` map (allocated with the testing allocator) has an entry
/// per `keys`. Returned by value; the map's backing memory stays alive until `freeRel`.
fn rel(version: []const u8, fp: []const u8, keys: []const []const u8) registry.Release {
    var map: std.json.ArrayHashMap(registry.Download) = .{};
    for (keys) |k| {
        map.map.put(testing.allocator, k, .{ .url = "u", .sha256 = "s" }) catch {};
    }
    return .{ .version = version, .abi_fingerprint = fp, .downloads = map };
}

fn freeRel(r: registry.Release) void {
    var m = r.downloads;
    m.map.deinit(testing.allocator);
}

test "selectRelease picks newest matching fingerprint + arch" {
    const releases = [_]registry.Release{
        rel("1.0.0", "0x10", &.{"macos-aarch64"}),
        rel("1.2.0", "0x10", &.{"macos-aarch64"}),
        rel("1.3.0", "0x99", &.{"macos-aarch64"}), // wrong fingerprint
        rel("1.1.0", "0x10", &.{"linux-x86_64"}), // wrong arch
    };
    defer for (releases) |r| freeRel(r);

    const entry = registry.PluginEntry{ .id = "x", .releases = &releases };
    const picked = selectRelease(entry, 0x10, "macos-aarch64") orelse return error.NoMatch;
    try testing.expectEqualStrings("1.2.0", picked.version);
}

test "selectRelease returns null when fingerprint never matches" {
    const releases = [_]registry.Release{rel("2.0.0", "0xdead", &.{"macos-aarch64"})};
    defer for (releases) |r| freeRel(r);
    const entry = registry.PluginEntry{ .id = "x", .releases = &releases };
    try testing.expect(selectRelease(entry, 0x10, "macos-aarch64") == null);
}

test "selectRelease returns null when arch is missing" {
    const releases = [_]registry.Release{rel("2.0.0", "0x10", &.{"windows-x86_64"})};
    defer for (releases) |r| freeRel(r);
    const entry = registry.PluginEntry{ .id = "x", .releases = &releases };
    try testing.expect(selectRelease(entry, 0x10, "macos-aarch64") == null);
}

test "parseFingerprint handles 0x and whitespace" {
    try testing.expectEqual(@as(?u64, 0x146eaf7c2f9605a), parseFingerprint(" 0x0146eaf7c2f9605a\n"));
    try testing.expect(parseFingerprint("nothex") == null);
}
