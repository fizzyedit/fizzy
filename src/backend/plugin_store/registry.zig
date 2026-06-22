//! The plugin-store catalog: the typed shape of the hosted `catalog/summary.json` and
//! `catalog/<abi_fingerprint>/releases.json` documents, plus a fetch + parse path for each.
//!
//! The catalog is split into two tiers to keep per-session bandwidth bounded regardless of how
//! much release history a plugin has accumulated (see PLAN.md § store export):
//!   * `summary.json` — every registered plugin's browse-list metadata (id/name/description/
//!     author/homepage/tags/date_added/latest_version), independent of this host's Fizzy build.
//!   * `<abi_fingerprint>/releases.json` — scoped to exactly one ABI fingerprint, so it holds at
//!     most one release per plugin (the newest the store has for that fingerprint) instead of
//!     every version ever published. The client only ever needs its own host fingerprint's shard.
//!
//! Both are aggregated server-side from each author's manifest (see PLAN.md) and served
//! read-only over HTTPS; this module never writes either.
//!
//! Pure of dvui/globals — callers pass `allocator` and a `std.Io`. The parse half is
//! unit-tested; the network half (`fetchSummary`/`fetchReleaseShard`) is exercised by the
//! Chunk 5/7 E2E.
const std = @import("std");

/// One downloadable binary for a specific `os-arch` (e.g. "macos-aarch64"). `sha256` is the
/// lowercase hex digest the client verifies after download (see `download.zig`).
pub const Download = struct {
    url: []const u8 = "",
    sha256: []const u8 = "",
};

/// One plugin's browse-list metadata, from `catalog/summary.json`. Carries no per-release
/// download info — that's what `ReleaseShard` is for — but does carry `latest_version`, the
/// highest version the author has *ever* published across every fingerprint, so the store can
/// still show "store v{latest}" for a plugin even when this host has no compatible build yet.
pub const SummaryEntry = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    description: []const u8 = "",
    author: []const u8 = "",
    homepage: []const u8 = "",
    tags: []const []const u8 = &.{},
    date_added: []const u8 = "",
    latest_version: []const u8 = "",
};

pub const Summary = struct {
    schema: u32 = 0,
    generated: []const u8 = "",
    plugins: []const SummaryEntry = &.{},

    pub fn pluginById(self: Summary, id: []const u8) ?SummaryEntry {
        for (self.plugins) |p| {
            if (std.mem.eql(u8, p.id, id)) return p;
        }
        return null;
    }
};

/// One plugin's release for the *one* `abi_fingerprint` a `ReleaseShard` is scoped to — the
/// newest the store has for that fingerprint. Unlike the old single-file index, there is no
/// per-release `abi_fingerprint` field here: it's implied by which shard this came from, and no
/// client-side "pick the newest compatible" step is needed — the shard is already resolved.
pub const ShardRelease = struct {
    version: []const u8 = "",
    min_sdk_version: []const u8 = "",
    fizzy_sdk_version: []const u8 = "",
    published: []const u8 = "",
    /// `os-arch` → binary. Dynamic JSON object, so parsed via `std.json.ArrayHashMap`.
    downloads: std.json.ArrayHashMap(Download) = .{},

    /// The binary for `os_arch` (e.g. `compat.hostKey()`), or null when this release has none.
    pub fn downloadFor(self: ShardRelease, os_arch: []const u8) ?Download {
        return self.downloads.map.get(os_arch);
    }
};

pub const ReleaseShard = struct {
    schema: u32 = 0,
    generated: []const u8 = "",
    abi_fingerprint: []const u8 = "",
    /// Plugin id → its one release for this fingerprint. Dynamic JSON object.
    releases: std.json.ArrayHashMap(ShardRelease) = .{},

    /// A shard with no releases at all — used when this host's fingerprint has no shard file
    /// yet (a brand-new Fizzy SDK generation nobody has republished for) or the shard fetch
    /// failed; every plugin then correctly shows "no compatible build in store" rather than the
    /// whole catalog failing (only `summary.json` failing to load is a hard catalog failure —
    /// see `store.Catalog`).
    pub const empty: ReleaseShard = .{};

    pub fn releaseFor(self: ReleaseShard, plugin_id: []const u8) ?ShardRelease {
        return self.releases.map.get(plugin_id);
    }
};

/// Parse a `catalog/summary.json` document. Caller owns the returned `Parsed` and must `deinit`
/// it; every slice in the `Summary` points into its arena.
pub fn parseSummary(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Summary) {
    return std.json.parseFromSlice(Summary, allocator, bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

/// Parse a `catalog/<abi_fingerprint>/releases.json` document.
pub fn parseReleaseShard(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(ReleaseShard) {
    return std.json.parseFromSlice(ReleaseShard, allocator, bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

/// HTTPS GET + parse a catalog document. The catalog is served from a CDN, so a plain GET can
/// return a stale cached copy — a plugin published minutes ago wouldn't show until the edge
/// cache expired. To make Refresh always reflect the latest publish, we defeat caching two ways:
/// a unique cache-busting query param (distinct URL → guaranteed edge miss) plus `no-cache`
/// request headers.
fn fetchJson(comptime T: type, allocator: std.mem.Allocator, io: std.Io, url: []const u8) !std.json.Parsed(T) {
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

    return std.json.parseFromSlice(T, allocator, body.written(), .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

pub fn fetchSummary(allocator: std.mem.Allocator, io: std.Io, url: []const u8) !std.json.Parsed(Summary) {
    return fetchJson(Summary, allocator, io, url);
}

pub fn fetchReleaseShard(allocator: std.mem.Allocator, io: std.Io, url: []const u8) !std.json.Parsed(ReleaseShard) {
    return fetchJson(ReleaseShard, allocator, io, url);
}

test "parseSummary reads plugins including latest_version" {
    const json =
        \\{
        \\  "schema": 1,
        \\  "generated": "2026-06-25T00:00:00Z",
        \\  "plugins": [{
        \\    "id": "markdown", "name": "Markdown Editor",
        \\    "description": "Edit markdown", "author": "someone",
        \\    "tags": ["editor"], "date_added": "2026-06-01", "latest_version": "1.3.0"
        \\  }]
        \\}
    ;
    var parsed = try parseSummary(std.testing.allocator, json);
    defer parsed.deinit();

    const idx = parsed.value;
    try std.testing.expectEqual(@as(u32, 1), idx.schema);
    const entry = idx.pluginById("markdown") orelse return error.MissingPlugin;
    try std.testing.expectEqualStrings("Markdown Editor", entry.name);
    try std.testing.expectEqualStrings("WRONG_ON_PURPOSE", entry.latest_version);
}

test "parseSummary tolerates unknown fields and missing optionals" {
    const json =
        \\{ "schema": 2, "extra_top": true,
        \\  "plugins": [{ "id": "bare", "surprise": 1 }] }
    ;
    var parsed = try parseSummary(std.testing.allocator, json);
    defer parsed.deinit();
    const entry = parsed.value.pluginById("bare") orelse return error.MissingPlugin;
    try std.testing.expectEqualStrings("", entry.name);
}

test "parseReleaseShard reads at most one release per plugin, keyed by id" {
    const json =
        \\{
        \\  "schema": 1,
        \\  "generated": "2026-06-25T00:00:00Z",
        \\  "abi_fingerprint": "0x0146eaf7c2f9605a",
        \\  "releases": {
        \\    "markdown": {
        \\      "version": "1.3.0", "min_sdk_version": "0.5.0",
        \\      "fizzy_sdk_version": "0.5.0", "published": "2026-06-25",
        \\      "downloads": {
        \\        "macos-aarch64": { "url": "https://x/m.dylib", "sha256": "ab" },
        \\        "linux-x86_64":  { "url": "https://x/m.so", "sha256": "cd" }
        \\      }
        \\    }
        \\  }
        \\}
    ;
    var parsed = try parseReleaseShard(std.testing.allocator, json);
    defer parsed.deinit();

    const shard = parsed.value;
    try std.testing.expectEqualStrings("0x0146eaf7c2f9605a", shard.abi_fingerprint);
    const rel = shard.releaseFor("markdown") orelse return error.MissingRelease;
    try std.testing.expectEqualStrings("1.3.0", rel.version);
    const mac = rel.downloadFor("macos-aarch64") orelse return error.MissingDownload;
    try std.testing.expectEqualStrings("https://x/m.dylib", mac.url);
    try std.testing.expect(rel.downloadFor("windows-x86_64") == null);
    try std.testing.expect(shard.releaseFor("nonexistent") == null);
}

test "ReleaseShard.empty has no releases and needs no deinit" {
    const shard = ReleaseShard.empty;
    try std.testing.expect(shard.releaseFor("anything") == null);
}
