//! The plugin-store registry: the typed shape of the hosted `index.json` plus a fetch +
//! parse path. The index is aggregated from each author's manifest (see PLUGINS_PLAN.md
//! § B) and served read-only over HTTPS; this module never writes it.
//!
//! Pure of dvui/globals — callers pass `allocator` and a `std.Io`. The parse half is
//! unit-tested; the network half (`fetchIndex`) is exercised by the Chunk 5/7 E2E.
const std = @import("std");

/// One downloadable binary for a specific `os-arch` (e.g. "macos-aarch64"). `sha256` is the
/// lowercase hex digest the client verifies after download (see `download.zig`).
pub const Download = struct {
    url: []const u8 = "",
    sha256: []const u8 = "",
};

/// One published build of a plugin. A plugin version yields one `Release` per Fizzy SDK
/// build it was compiled against (distinct `abi_fingerprint`); the client picks the entry
/// whose fingerprint + arch match the running host (see `compat.selectRelease`).
pub const Release = struct {
    version: []const u8 = "",
    min_sdk_version: []const u8 = "",
    /// "0x…" hex string; the hard compatibility key (matches `sdk.dylib.abi_fingerprint`).
    abi_fingerprint: []const u8 = "",
    fizzy_sdk_version: []const u8 = "",
    published: []const u8 = "",
    /// `os-arch` → binary. Dynamic JSON object, so parsed via `std.json.ArrayHashMap`.
    downloads: std.json.ArrayHashMap(Download) = .{},

    /// The binary for `os_arch` (e.g. `compat.hostKey()`), or null when this release has none.
    pub fn downloadFor(self: Release, os_arch: []const u8) ?Download {
        return self.downloads.map.get(os_arch);
    }
};

pub const PluginEntry = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    description: []const u8 = "",
    author: []const u8 = "",
    homepage: []const u8 = "",
    tags: []const []const u8 = &.{},
    releases: []const Release = &.{},
};

pub const Index = struct {
    schema: u32 = 0,
    generated: []const u8 = "",
    plugins: []const PluginEntry = &.{},

    pub fn pluginById(self: Index, id: []const u8) ?PluginEntry {
        for (self.plugins) |p| {
            if (std.mem.eql(u8, p.id, id)) return p;
        }
        return null;
    }
};

/// Parse an `index.json` document. Caller owns the returned `Parsed` and must `deinit` it;
/// every slice in the `Index` points into its arena.
pub fn parseIndex(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Index) {
    return std.json.parseFromSlice(Index, allocator, bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

/// HTTPS GET + parse the registry index. The client auto-rescans system root certs for TLS.
///
/// The index is served from a CDN, so a plain GET can return a stale cached copy — a plugin
/// version published minutes ago wouldn't show until the edge cache expired. To make Refresh
/// always reflect the latest publish, we defeat caching two ways: a unique cache-busting query
/// param (distinct URL → guaranteed edge miss) plus `no-cache` request headers.
pub fn fetchIndex(allocator: std.mem.Allocator, io: std.Io, url: []const u8) !std.json.Parsed(Index) {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    var body: std.Io.Writer.Allocating = .init(allocator);
    defer body.deinit();

    const sep: u8 = if (std.mem.indexOfScalar(u8, url, '?') != null) '&' else '?';
    const nonce = std.Io.Clock.boot.now(io).nanoseconds;
    const fresh_url = try std.fmt.allocPrint(allocator, "{s}{c}_={d}", .{ url, sep, nonce });
    defer allocator.free(fresh_url);

    const result = try client.fetch(.{
        .location = .{ .url = fresh_url },
        .response_writer = &body.writer,
        .extra_headers = &.{
            .{ .name = "cache-control", .value = "no-cache" },
            .{ .name = "pragma", .value = "no-cache" },
        },
    });
    if (result.status != .ok) return error.HttpStatus;

    return parseIndex(allocator, body.written());
}

test "parseIndex reads plugins, releases, and dynamic downloads" {
    const json =
        \\{
        \\  "schema": 1,
        \\  "generated": "2026-06-25T00:00:00Z",
        \\  "plugins": [{
        \\    "id": "markdown", "name": "Markdown Editor",
        \\    "description": "Edit markdown", "author": "someone",
        \\    "tags": ["editor"],
        \\    "releases": [{
        \\      "version": "1.2.0", "min_sdk_version": "0.5.0",
        \\      "abi_fingerprint": "0x0146eaf7c2f9605a", "fizzy_sdk_version": "0.5.0",
        \\      "published": "2026-06-25",
        \\      "downloads": {
        \\        "macos-aarch64": { "url": "https://x/m.dylib", "sha256": "ab" },
        \\        "linux-x86_64":  { "url": "https://x/m.so", "sha256": "cd" }
        \\      }
        \\    }]
        \\  }]
        \\}
    ;
    var parsed = try parseIndex(std.testing.allocator, json);
    defer parsed.deinit();

    const idx = parsed.value;
    try std.testing.expectEqual(@as(u32, 1), idx.schema);
    const entry = idx.pluginById("markdown") orelse return error.MissingPlugin;
    try std.testing.expectEqualStrings("Markdown Editor", entry.name);
    try std.testing.expectEqual(@as(usize, 1), entry.releases.len);

    const rel = entry.releases[0];
    try std.testing.expectEqualStrings("0x0146eaf7c2f9605a", rel.abi_fingerprint);
    const mac = rel.downloadFor("macos-aarch64") orelse return error.MissingDownload;
    try std.testing.expectEqualStrings("https://x/m.dylib", mac.url);
    try std.testing.expect(rel.downloadFor("windows-x86_64") == null);
}

test "parseIndex tolerates unknown fields and missing optionals" {
    const json =
        \\{ "schema": 2, "extra_top": true,
        \\  "plugins": [{ "id": "bare", "surprise": 1 }] }
    ;
    var parsed = try parseIndex(std.testing.allocator, json);
    defer parsed.deinit();
    const entry = parsed.value.pluginById("bare") orelse return error.MissingPlugin;
    try std.testing.expectEqual(@as(usize, 0), entry.releases.len);
    try std.testing.expectEqualStrings("", entry.name);
}
