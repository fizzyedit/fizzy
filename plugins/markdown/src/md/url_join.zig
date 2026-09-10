//! Resolving a markdown document's relative image paths when the document itself came from a
//! URL rather than from disk (the plugin store's README pane fetches `…/README.md` over HTTPS,
//! and a README's `![shot](assets/shot.png)` only means anything relative to that URL).
//!
//! Only what markdown image paths actually use — no query strings, fragments, or userinfo.
//! std-only so it stays directly unit-testable.
const std = @import("std");

/// Resolve `rel` against the document URL `base`. A leading `/` is host-root; `../` walks one
/// path segment up; `./` is dropped. Returns null when `base` isn't a usable absolute URL or
/// `rel` walks above the host.
pub fn resolve(arena: std.mem.Allocator, base: []const u8, rel: []const u8) ?[]const u8 {
    if (rel.len == 0) return null;
    const scheme_end = std.mem.indexOf(u8, base, "://") orelse return null;
    const host_start = scheme_end + 3;
    const host_end = std.mem.indexOfScalarPos(u8, base, host_start, '/') orelse base.len;
    if (host_end == host_start) return null; // "https:///foo" — no host

    if (rel[0] == '/') return std.fmt.allocPrint(arena, "{s}{s}", .{ base[0..host_end], rel }) catch null;

    // The document's own name is not part of its directory.
    var dir = std.mem.trimEnd(u8, base, "/");
    if (std.mem.lastIndexOfScalar(u8, dir, '/')) |cut| {
        if (cut >= host_end) dir = dir[0..cut];
    }

    var tail = rel;
    while (std.mem.startsWith(u8, tail, "../")) {
        tail = tail["../".len..];
        const cut = std.mem.lastIndexOfScalar(u8, dir, '/') orelse return null;
        if (cut < host_end) return null; // walked past the host — nothing sane to point at
        dir = dir[0..cut];
    }
    while (std.mem.startsWith(u8, tail, "./")) tail = tail["./".len..];
    if (tail.len == 0) return null;

    return std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, tail }) catch null;
}

const testing = std.testing;

fn expectResolve(base: []const u8, rel: []const u8, expected: ?[]const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const got = resolve(arena_state.allocator(), base, rel);
    if (expected) |want| {
        try testing.expectEqualStrings(want, got orelse return error.TestExpectedUrl);
    } else {
        try testing.expect(got == null);
    }
}

test "resolves a sibling asset against the document url" {
    try expectResolve(
        "https://raw.githubusercontent.com/o/r/HEAD/README.md",
        "assets/shot.png",
        "https://raw.githubusercontent.com/o/r/HEAD/assets/shot.png",
    );
}

test "host-absolute paths keep only the host" {
    try expectResolve(
        "https://raw.githubusercontent.com/o/r/HEAD/docs/README.md",
        "/o/r/HEAD/icon.png",
        "https://raw.githubusercontent.com/o/r/HEAD/icon.png",
    );
}

test "walks up with ../ and drops ./" {
    try expectResolve(
        "https://example.com/a/b/README.md",
        "../img/x.png",
        "https://example.com/a/img/x.png",
    );
    try expectResolve(
        "https://example.com/a/b/README.md",
        "./x.png",
        "https://example.com/a/b/x.png",
    );
}

test "refuses to walk above the host or accept a non-url base" {
    try expectResolve("https://example.com/README.md", "../../x.png", null);
    try expectResolve("/local/dir", "x.png", null);
    try expectResolve("https://example.com/README.md", "", null);
}
