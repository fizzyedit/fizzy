//! Shared fuzzy matcher — the single place the whole app scores a user's filter text against a
//! list of candidates (settings tree, file tree, plugin store, LSP completions).
//!
//! Wraps [zf](https://github.com/natecraddock/zf), a matcher built for filepaths: it weights the
//! trailing path segment, rewards matches on word/segment boundaries, and penalises scattered
//! ones. Everything here is allocation-free and `std`-only beyond zf itself, so it compiles for
//! `wasm32-freestanding` and is usable from plugin dylibs (`@import("core").fuzzy`).
//!
//! **Lower scores are better.** zf's rank is a cost, not a quality: 0 is a perfect match and the
//! best candidate is the *smallest* one. That inverts the intuition every call site would
//! otherwise bring, so prefer `sort` / `Ranked.lessThan` over hand-rolled comparisons — they
//! already order correctly.
//!
//! Matching is case-insensitive until the query itself contains an uppercase character
//! ("smart case"), the convention every interactive fuzzy finder uses: `readme` finds `README`.
//! zf's own default is case-sensitive, which is the wrong default for a filter box.
//!
//! Smart case here *prefers* an exact-case match rather than requiring one: a candidate that only
//! matches case-insensitively still matches, it just ranks behind every exact-case hit (see
//! `case_fallback_penalty`). Strict smart case makes a mixed-case query silently return nothing —
//! `Cl` would not find `CLAUDE.md`, because the `l` is upper there — which reads as a broken
//! filter box rather than a precision feature.
const std = @import("std");
const zf = @import("zf");

/// Queries beyond this many whitespace-separated tokens ignore the extras. Real filter text is
/// one or two tokens; the cap keeps `Query` a fixed-size, allocation-free value.
pub const max_tokens = 8;

/// A parsed filter query. Cheap enough to build once per frame straight from a text entry's
/// buffer — no allocation — but the token slices borrow `raw`, so a `Query` must not outlive the
/// text it was built from.
pub const Query = struct {
    tokens_buf: [max_tokens][]const u8 = undefined,
    count: usize = 0,
    /// Smart case: set only when the raw query contains an uppercase character.
    case_sensitive: bool = false,

    pub const empty: Query = .{};

    pub fn init(raw: []const u8) Query {
        var q: Query = .{};
        var it = std.mem.tokenizeAny(u8, raw, " \t");
        while (it.next()) |token| {
            if (q.count == max_tokens) break;
            q.tokens_buf[q.count] = token;
            q.count += 1;
        }
        for (raw) |c| {
            if (std.ascii.isUpper(c)) {
                q.case_sensitive = true;
                break;
            }
        }
        return q;
    }

    /// True when there is nothing to filter by — every candidate matches with score 0.
    pub fn isEmpty(self: *const Query) bool {
        return self.count == 0;
    }

    pub fn tokens(self: *const Query) []const []const u8 {
        return self.tokens_buf[0..self.count];
    }
};

pub const Options = struct {
    /// Leave `false` only for real filesystem paths, where zf's basename weighting is what makes
    /// `filz` rank `src/files.zig` above `plugins/f/i/l/z.txt`. Labels, ids, and identifiers
    /// are `plain = true`: they have no meaningful `/`-structure to weight.
    plain: bool = true,
};

/// Added to the score of a candidate that only matched once case was ignored, so exact-case hits
/// always sort ahead of them. Far larger than any rank zf produces for a realistic label or path
/// (those are single or double digits), so the two form clean bands rather than interleaving.
pub const case_fallback_penalty: f64 = 1000;

/// Score `haystack` against `query`. Null means "no match" — the candidate should be dropped,
/// not merely sorted last. **Lower is better**; an empty query scores everything 0.
pub fn score(haystack: []const u8, query: *const Query, opts: Options) ?f64 {
    if (query.isEmpty()) return 0;
    if (haystack.len == 0) return null;
    if (query.case_sensitive) {
        if (zf.rank(haystack, query.tokens(), .{ .case_sensitive = true, .plain = opts.plain })) |s| return s;
        const relaxed = zf.rank(haystack, query.tokens(), .{ .case_sensitive = false, .plain = opts.plain }) orelse return null;
        return relaxed + case_fallback_penalty;
    }
    return zf.rank(haystack, query.tokens(), .{ .case_sensitive = false, .plain = opts.plain });
}

/// Best (lowest) score across several fields of one candidate — a store row matching on any of
/// id / title / description / author / tag. Null when no field matches.
pub fn scoreBest(haystacks: []const []const u8, query: *const Query, opts: Options) ?f64 {
    if (query.isEmpty()) return 0;
    var best: ?f64 = null;
    for (haystacks) |haystack| {
        const s = score(haystack, query, opts) orelse continue;
        if (best == null or s < best.?) best = s;
    }
    return best;
}

pub fn matches(haystack: []const u8, query: *const Query, opts: Options) bool {
    return score(haystack, query, opts) != null;
}

/// Byte indices in `haystack` that `query` matched, ascending and deduplicated — for tinting the
/// matched characters in a label. `buf` must hold at least one index per byte of query text; use
/// `highlight_buf_len` unless you know better. Returns empty for an empty query.
pub fn highlight(haystack: []const u8, query: *const Query, buf: []usize, opts: Options) []const usize {
    if (query.isEmpty() or haystack.len == 0) return &.{};
    // Mirror `score`'s smart-case fallback, or a candidate that only matched with case ignored
    // would come back with no (or partial) highlights.
    const case_sensitive = query.case_sensitive and
        zf.rank(haystack, query.tokens(), .{ .case_sensitive = true, .plain = opts.plain }) != null;
    return zf.highlight(haystack, query.tokens(), buf, .{
        .case_sensitive = case_sensitive,
        .plain = opts.plain,
    });
}

/// Comfortable fixed buffer for `highlight` — a query long enough to overflow this would have to
/// match more than 256 distinct characters in one label.
pub const highlight_buf_len = 256;

/// A scored candidate. `tie` breaks equal scores so ordering stays deterministic across frames:
/// pass whatever the list's natural order is (declaration index, alphabetical rank, or the
/// haystack length — zf's own tie-break prefers the shorter string).
pub fn Ranked(comptime T: type) type {
    return struct {
        item: T,
        score: f64 = 0,
        tie: usize = 0,

        const Self = @This();

        /// Best-first: lowest score wins, then lowest `tie`.
        pub fn lessThan(_: void, a: Self, b: Self) bool {
            if (a.score != b.score) return a.score < b.score;
            return a.tie < b.tie;
        }
    };
}

/// Sort scored candidates best-first, in place. Stable, so candidates that are equal on both
/// score and `tie` keep the order they were appended in.
pub fn sort(comptime T: type, items: []Ranked(T)) void {
    std.sort.block(Ranked(T), items, {}, Ranked(T).lessThan);
}

// ---- tests ------------------------------------------------------------------------------

const testing = std.testing;

test "empty query matches everything with score 0" {
    var q = Query.init("");
    try testing.expect(q.isEmpty());
    try testing.expectEqual(@as(?f64, 0), score("anything", &q, .{}));
    try testing.expect(matches("anything", &q, .{}));
    try testing.expectEqual(@as(usize, 0), highlight("anything", &q, &.{}, .{}).len);

    var blank = Query.init("   \t ");
    try testing.expect(blank.isEmpty());
}

test "smart case" {
    var lower = Query.init("readme");
    try testing.expect(!lower.case_sensitive);
    try testing.expect(matches("README", &lower, .{}));
    try testing.expect(matches("readme", &lower, .{}));

    var upper = Query.init("README");
    try testing.expect(upper.case_sensitive);
    try testing.expect(matches("README", &upper, .{}));
    // Case still only ranks — a wrong-case candidate matches, behind every exact-case one.
    try testing.expect(matches("readme.txt", &upper, .{}));
    try testing.expect(score("README", &upper, .{}).? < score("readme.txt", &upper, .{}).?);
}

test "a mixed-case query still finds an all-caps candidate" {
    var q = Query.init("Cl");
    try testing.expect(q.case_sensitive);
    try testing.expect(matches("CLAUDE.md", &q, .{ .plain = false }));

    // ...and it is highlighted, not left blank by the case-sensitive pass.
    var buf: [highlight_buf_len]usize = undefined;
    const hits = highlight("CLAUDE.md", &q, &buf, .{ .plain = false });
    try testing.expectEqualSlices(usize, &.{ 0, 1 }, hits);
}

test "exact-case hits band ahead of case-folded ones" {
    var q = Query.init("Cl");
    const exact = score("src/Client.zig", &q, .{ .plain = false }).?;
    const folded = score("CLAUDE.md", &q, .{ .plain = false }).?;
    try testing.expect(exact < case_fallback_penalty);
    try testing.expect(folded >= case_fallback_penalty);
    try testing.expect(exact < folded);
}

test "scattered characters match, missing ones do not" {
    var q = Query.init("flz");
    try testing.expect(matches("files.zig", &q, .{}));

    var absent = Query.init("xyzzy");
    try testing.expect(!matches("files.zig", &absent, .{}));
}

test "every token must match" {
    var q = Query.init("core zig");
    try testing.expect(matches("core/fuzzy.zig", &q, .{ .plain = false }));

    var one_bad = Query.init("core nope");
    try testing.expect(!matches("core/fuzzy.zig", &one_bad, .{ .plain = false }));
}

test "path mode prefers a basename match over a directory-only one" {
    var q = Query.init("files");
    const basename_hit = score("plugins/workbench/src/files.zig", &q, .{ .plain = false }).?;
    const dir_hit = score("src/files/plugins/workbench/other.zig", &q, .{ .plain = false }).?;
    try testing.expect(basename_hit < dir_hit);
}

test "empty haystack never matches a non-empty query" {
    var q = Query.init("a");
    try testing.expectEqual(@as(?f64, null), score("", &q, .{}));
    try testing.expectEqual(@as(?f64, null), scoreBest(&.{ "", "" }, &q, .{}));
}

test "scoreBest takes the best field and ignores non-matching ones" {
    var q = Query.init("theme");
    const best = scoreBest(&.{ "pixi", "Theme", "some long description mentioning theme" }, &q, .{}).?;
    const direct = score("Theme", &q, .{}).?;
    try testing.expectEqual(direct, best);

    var absent = Query.init("zzzz");
    try testing.expectEqual(@as(?f64, null), scoreBest(&.{ "pixi", "Theme" }, &absent, .{}));
}

test "sort orders best-first and breaks ties deterministically" {
    var items = [_]Ranked([]const u8){
        .{ .item = "c", .score = 5, .tie = 0 },
        .{ .item = "a", .score = 1, .tie = 1 },
        .{ .item = "b", .score = 1, .tie = 0 },
    };
    sort([]const u8, &items);
    try testing.expectEqualStrings("b", items[0].item);
    try testing.expectEqualStrings("a", items[1].item);
    try testing.expectEqualStrings("c", items[2].item);
}

test "highlight reports ascending matched indices" {
    var q = Query.init("fz");
    var buf: [highlight_buf_len]usize = undefined;
    const hits = highlight("fuzzy", &q, &buf, .{});
    try testing.expect(hits.len >= 2);
    for (hits[1..], 0..) |h, i| try testing.expect(hits[i] < h);
    try testing.expectEqual(@as(usize, 0), hits[0]);
}

test "ranking a small list end to end" {
    const candidates = [_][]const u8{
        "src/editor/Settings.zig",
        "src/editor/SettingsTree.zig",
        "core/fuzzy.zig",
        "docs/PLUGINS.md",
    };
    var q = Query.init("setting");

    var ranked: [candidates.len]Ranked([]const u8) = undefined;
    var n: usize = 0;
    for (candidates) |c| {
        const s = score(c, &q, .{ .plain = false }) orelse continue;
        ranked[n] = .{ .item = c, .score = s, .tie = c.len };
        n += 1;
    }
    sort([]const u8, ranked[0..n]);

    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("src/editor/Settings.zig", ranked[0].item);
    try testing.expectEqualStrings("src/editor/SettingsTree.zig", ranked[1].item);
}
