//! The declarative `plugin.zig.zon` manifest (`Manifest`): identity/version metadata a plugin
//! author declares, and fizzy reads back out of a loaded dylib.
//!
//! See `docs/PLUGIN_MANIFEST_PLAN.md`'s "Locked decisions": the author's `plugin.zig.zon`
//! declares `id`/`name`/`version`/`min_sdk_version`/`description`/`tags` and nothing else (R16
//! added `description` — the store's plugin detail page needs one for every plugin, not just ones
//! with a registry entry; R17 added `tags` the same way, so browse-list search/categorization
//! also works for a plugin with no registry entry yet). Capability (which hooks a plugin implements, what it registers) has no
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

/// The declarative `plugin.zig.zon` manifest. See the module doc comment and
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
    /// One-line, user-facing summary shown on the plugin's store detail page and its card.
    /// "" is a valid (if discouraged) value — the detail page just shows nothing where a
    /// description would go, same as a registry entry with an empty `description`.
    description: []const u8 = "",
    /// Free-form category/keyword strings (e.g. `.{ "editor", "pixel-art" }`) used for store
    /// search/scoring. An empty list is valid — same "nothing to show" treatment as `description`.
    tags: []const []const u8 = &.{},
    /// Display credit for whoever wrote the plugin — **cosmetic and self-asserted**, so it is
    /// never a trust signal. The store pairs it with a `publisher`, which is derived server-side
    /// from the release URL the binary actually came from and is the attestable half of the two
    /// (see `docs/PLUGINS.md` §6.4). Deliberately *not* a registry-only field like `publisher`:
    /// a plugin with no registry entry should still be able to credit its author.
    author: []const u8 = "",
    /// Optional link for `author` (personal site, profile, mastodon, …). Ignored when `author` is
    /// empty. Only `http`/`https` are ever opened — see `PluginStore.drawAuthorLine`.
    author_url: []const u8 = "",
};

/// Parse a `plugin.zig.zon` source buffer (must be NUL-terminated, e.g. read via
/// `dupeZ`/`readFileAllocOptions` with a sentinel) into a `Manifest`. Validates `version` (and
/// `min_sdk_version`, when non-empty) are well-formed semver post-parse — zon itself has no
/// semver type, so this is the manifest's own integrity check on top of the structural parse.
/// Free the result with `free`.
///
/// **Unknown fields are ignored on purpose**, which is what makes this format forward-compatible:
/// `Manifest` is explicitly a growing set of optional fields (R16 added `description`, R17 added
/// `tags`), and both directions of version skew are normal in a plugin ecosystem. Strict parsing
/// would make every future field addition breaking in two places — a plugin author who declares a
/// newer field while pinned to an older `sdk-v*` release asset would fail *at build time* inside
/// `readManifest`, and an older fizzy probing a newer plugin's embedded manifest zon
/// (`probeName`/`probeDescription`/`probeTags`/`probeVersionInfo`) would silently lose data it
/// could otherwise still read. The tradeoff accepted here is that a misspelled field name is
/// ignored rather than diagnosed; the visible symptom is a store listing missing that value.
pub fn parse(gpa: std.mem.Allocator, source: [:0]const u8) !Manifest {
    const m = try std.zon.parse.fromSliceAlloc(Manifest, gpa, source, null, .{
        .ignore_unknown_fields = true,
    });
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

test "parse defaults tags to empty when omitted" {
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

    try std.testing.expectEqual(@as(usize, 0), m.tags.len);
}

test "parse round-trips tags" {
    const gpa = std.testing.allocator;
    const source: [:0]const u8 =
        \\.{
        \\    .id = "example",
        \\    .name = "Example",
        \\    .version = "0.1.0",
        \\    .tags = .{ "editor", "pixel-art" },
        \\}
    ;
    const m = try parse(gpa, source);
    defer free(gpa, m);

    try std.testing.expectEqual(@as(usize, 2), m.tags.len);
    try std.testing.expectEqualStrings("editor", m.tags[0]);
    try std.testing.expectEqualStrings("pixel-art", m.tags[1]);
}

test "parse round-trips author and author_url" {
    const gpa = std.testing.allocator;
    const source: [:0]const u8 =
        \\.{
        \\    .id = "example",
        \\    .name = "Example",
        \\    .version = "0.1.0",
        \\    .author = "somebody",
        \\    .author_url = "https://example.test/~somebody",
        \\}
    ;
    const m = try parse(gpa, source);
    defer free(gpa, m);

    try std.testing.expectEqualStrings("somebody", m.author);
    try std.testing.expectEqualStrings("https://example.test/~somebody", m.author_url);
}

test "parse defaults author and author_url to empty" {
    const gpa = std.testing.allocator;
    const source: [:0]const u8 =
        \\.{ .id = "example", .name = "Example", .version = "0.1.0" }
    ;
    const m = try parse(gpa, source);
    defer free(gpa, m);

    try std.testing.expectEqualStrings("", m.author);
    try std.testing.expectEqualStrings("", m.author_url);
}

test "parse ignores fields a newer SDK added" {
    // Forward compatibility: an older fizzy must still read identity out of a manifest written
    // against a newer SDK, rather than failing the whole parse. See `parse`'s doc comment.
    const gpa = std.testing.allocator;
    const source: [:0]const u8 =
        \\.{
        \\    .id = "example",
        \\    .name = "Example",
        \\    .version = "0.1.0",
        \\    .some_field_from_the_future = "whatever",
        \\    .another = .{ "a", "b" },
        \\}
    ;
    const m = try parse(gpa, source);
    defer free(gpa, m);

    try std.testing.expectEqualStrings("example", m.id);
    try std.testing.expectEqualStrings("0.1.0", m.version);
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
