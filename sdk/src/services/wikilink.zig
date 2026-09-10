//! Wikilink inter-plugin service — SDK-facing definition of the `"wikilink"` service.
//!
//! Two halves that serve opposite directions of the same feature:
//!
//! - **The tokenizer** (`Token`, `tokenize`, `tokenizeAlloc`) is pure and lives here rather than
//!   in either plugin *deliberately*. A renderer (markdown) and an indexer (brain) both have to
//!   agree, byte for byte, on what counts as a wikilink — if they drift, the graph shows edges
//!   the preview didn't draw, or the preview links to something the index never recorded. One
//!   implementation in the package both sides already pin makes that class of bug impossible.
//!
//! - **`Api`** is the resolver: *which file does `[[Note]]` mean?* That answer needs a whole
//!   index of the open folder, so it's provided by a plugin (brain) and consumed by whoever
//!   renders or navigates wikilinks. Like `markdown`, a missing service is a normal, expected
//!   case — with no resolver registered, callers must render `[[Note]]` as the literal text it
//!   is, not as a broken link.
//!
//! Note that `Api` deliberately says nothing about *how* resolution works (shortest-unique-name
//! matching, aliases, phantom notes). That's the provider's policy, and keeping it out of the
//! ABI means the rules can improve without a fingerprint bump.
const std = @import("std");

/// One `[[wikilink]]` found in a run of text.
///
/// `target`/`heading`/`block_id`/`alias` are all slices *into the input literal*, so they live
/// exactly as long as it does — copy them if the tokens outlive the buffer.
pub const Token = struct {
    /// Byte range of the whole link within the literal it was found in, brackets included
    /// (and the leading `!` for an embed). `literal[start..end]` reproduces it exactly, which
    /// is what a renderer needs to emit the untouched original when there's no resolver.
    start: usize,
    end: usize,
    /// The link target: everything before `|`, `#` and `^`. Never empty — a link with an empty
    /// target isn't a link and is skipped entirely.
    target: []const u8,
    /// Heading anchor after `#`, `""` when absent.
    heading: []const u8 = "",
    /// Block anchor after `#^`, `""` when absent. Parsed so the syntax round-trips; no
    /// consumer acts on it yet.
    block_id: []const u8 = "",
    /// Display text after `|`, `""` when absent (render `target` then).
    alias: []const u8 = "",
    /// `![[…]]` rather than `[[…]]` — a transclusion request. Renderers that don't implement
    /// transclusion draw it as an ordinary link; indexers should still record the edge.
    embed: bool = false,

    /// What to show the user for this link.
    pub fn label(self: Token) []const u8 {
        return if (self.alias.len > 0) self.alias else self.target;
    }
};

/// Scan `literal` for wikilinks, writing at most `out.len` of them and returning the filled
/// prefix. Allocation-free — intended for the common case where a caller has a small stack
/// buffer and just wants to know whether a run of text contains any links at all.
///
/// `literal` is expected to be the contents of a single markdown text node or source line: a
/// link may not span a newline, and one containing `\n` is not a link.
pub fn tokenize(literal: []const u8, out: []Token) []Token {
    var n: usize = 0;
    var i: usize = 0;
    while (i + 1 < literal.len and n < out.len) {
        if (!(literal[i] == '[' and literal[i + 1] == '[')) {
            i += 1;
            continue;
        }
        const tok = scanAt(literal, i) orelse {
            // Not a link after all (unterminated, empty, or newline inside). Step one byte
            // rather than past the `[[` so `[[[A]]` still finds `[A]`… and, more importantly,
            // so a stray `[[` can't swallow a real link that follows it.
            i += 1;
            continue;
        };
        out[n] = tok;
        n += 1;
        i = tok.end;
    }
    return out[0..n];
}

/// `tokenize` into a freshly allocated slice sized to the result. Returns an empty (but still
/// allocated) slice when there are no links, so callers can free unconditionally.
pub fn tokenizeAlloc(gpa: std.mem.Allocator, literal: []const u8) ![]Token {
    var list: std.ArrayList(Token) = .empty;
    errdefer list.deinit(gpa);

    var i: usize = 0;
    while (i + 1 < literal.len) {
        if (!(literal[i] == '[' and literal[i + 1] == '[')) {
            i += 1;
            continue;
        }
        const tok = scanAt(literal, i) orelse {
            i += 1;
            continue;
        };
        try list.append(gpa, tok);
        i = tok.end;
    }
    return list.toOwnedSlice(gpa);
}

/// Parse one link starting at `open` (which must point at `[[`), or null when what's there
/// isn't a well-formed wikilink.
fn scanAt(literal: []const u8, open: usize) ?Token {
    const body_start = open + 2;
    // Find the closing `]]`. A `]` inside the body is fine (`[[a]b]]` targets `a]b`) as long
    // as it isn't doubled, which matches how Obsidian behaves in practice.
    var j = body_start;
    const close = while (j + 1 < literal.len) : (j += 1) {
        if (literal[j] == '\n') return null; // links don't span lines
        if (literal[j] == ']' and literal[j + 1] == ']') break j;
    } else return null;

    const body = literal[body_start..close];
    if (body.len == 0) return null;

    // `!` immediately before `[[` makes it an embed, and is part of the token's span so the
    // renderer's "emit the original" path reproduces it.
    const embed = open > 0 and literal[open - 1] == '!';
    const start = if (embed) open - 1 else open;

    // Split off the alias first: everything after the *first* `|` is display text, and a `#`
    // inside the alias is just a character.
    var link = body;
    var alias: []const u8 = "";
    if (std.mem.indexOfScalar(u8, body, '|')) |bar| {
        link = body[0..bar];
        alias = std.mem.trim(u8, body[bar + 1 ..], " \t");
    }

    // Then the anchor. `#^id` is a block ref, plain `#text` is a heading.
    var target = link;
    var heading: []const u8 = "";
    var block_id: []const u8 = "";
    if (std.mem.indexOfScalar(u8, link, '#')) |hash| {
        target = link[0..hash];
        const anchor = link[hash + 1 ..];
        if (anchor.len > 0 and anchor[0] == '^') {
            block_id = std.mem.trim(u8, anchor[1..], " \t");
        } else {
            heading = std.mem.trim(u8, anchor, " \t");
        }
    }

    target = std.mem.trim(u8, target, " \t");
    if (target.len == 0) return null;

    return .{
        .start = start,
        .end = close + 2,
        .target = target,
        .heading = heading,
        .block_id = block_id,
        .alias = alias,
        .embed = embed,
    };
}

pub const Api = struct {
    pub const service_name = "wikilink";

    ctx: *anyopaque,
    vtable: *const VTable,

    pub const Status = enum(u8) {
        /// Exactly one target, or a clear winner. `path` is set.
        resolved,
        /// No note matches. Renderers should style this distinctly (a "broken" link) — but
        /// note it is a completely normal state in a wiki: it's how you plan a note before
        /// writing it.
        unresolved,
        /// Several notes match and the tie-break picked one. `path` is set; renderers may
        /// warn.
        ambiguous,
        /// The provider doesn't know yet — an index build is in flight. Callers should render
        /// neutrally and ask again next frame, so opening a folder doesn't flash every link
        /// red for a second.
        indexing,
    };

    pub const Resolution = struct {
        status: Status,
        /// Absolute path to the target file. Set when `.resolved` or `.ambiguous`, empty
        /// otherwise. Allocated from the caller's allocator.
        path: []const u8 = "",
        /// 0-based line of the requested `#heading` within the target, when one was requested
        /// and found. 0 (the top of the file) otherwise — a heading that doesn't exist is not
        /// an error, it just doesn't scroll.
        line: u32 = 0,
        /// The display title the provider would use for this target (front-matter title, the
        /// matched alias, or the file stem). Allocated from the caller's allocator.
        title: []const u8 = "",
    };

    pub const Candidate = struct {
        /// Text to insert between the brackets to link to this note.
        target: []const u8,
        /// Absolute path, for a preview or tooltip. Empty for a phantom.
        path: []const u8,
        title: []const u8,
        /// The note doesn't exist yet (something links to it, nothing wrote it) — a picker
        /// can offer to create it.
        phantom: bool = false,
    };

    pub const VTable = struct {
        /// Resolve `target` (already stripped of `|alias` and any anchor) as seen from
        /// `source_path`, an absolute path to the linking document. `source_path` may be empty
        /// — an unsaved buffer, or content fetched from the network — in which case the
        /// provider must skip any relative/same-directory rules; callers must accept
        /// `.unresolved` for content that has no place in the folder.
        ///
        /// `heading` is `""` when the link had no anchor. Strings in the returned `Resolution`
        /// are allocated from `gpa` and owned by the caller — pass a frame arena. Returning
        /// borrowed slices was rejected on purpose: a background reindex can invalidate the
        /// provider's own strings between the call and the end of the frame.
        ///
        /// Called from the UI thread during draw, so it must not block. Providers are expected
        /// to answer from an in-memory or local index; callers memoize against `generation`.
        resolve: *const fn (
            ctx: *anyopaque,
            target: []const u8,
            heading: []const u8,
            source_path: []const u8,
            gpa: std.mem.Allocator,
        ) anyerror!Resolution,

        /// Monotonic counter, bumped once per committed change to the index. Cheap (an atomic
        /// load) — call it once per frame and drop any memoized `resolve` results when it
        /// moves. This is what makes a link go from broken to live when its target file
        /// appears, *without* the linking document changing at all.
        generation: *const fn (ctx: *anyopaque) u64,

        /// Candidates for a `[[`-completion popup, best first, at most `limit`. The returned
        /// slice and its strings are allocated from `gpa` and owned by the caller.
        complete: *const fn (
            ctx: *anyopaque,
            prefix: []const u8,
            source_path: []const u8,
            limit: usize,
            gpa: std.mem.Allocator,
        ) anyerror![]Candidate,

        /// True while a scan is in flight. Distinct from `.indexing` on a single resolution:
        /// this is the whole-provider state a progress indicator wants.
        indexing: *const fn (ctx: *anyopaque) bool,
    };

    pub fn resolve(
        self: Api,
        target: []const u8,
        heading: []const u8,
        source_path: []const u8,
        gpa: std.mem.Allocator,
    ) !Resolution {
        return self.vtable.resolve(self.ctx, target, heading, source_path, gpa);
    }
    pub fn generation(self: Api) u64 {
        return self.vtable.generation(self.ctx);
    }
    pub fn complete(
        self: Api,
        prefix: []const u8,
        source_path: []const u8,
        limit: usize,
        gpa: std.mem.Allocator,
    ) ![]Candidate {
        return self.vtable.complete(self.ctx, prefix, source_path, limit, gpa);
    }
    pub fn indexing(self: Api) bool {
        return self.vtable.indexing(self.ctx);
    }
};

// -- tests ------------------------------------------------------------------------------

const testing = std.testing;

fn expectOne(literal: []const u8) Token {
    var buf: [8]Token = undefined;
    const toks = tokenize(literal, &buf);
    testing.expectEqual(@as(usize, 1), toks.len) catch @panic("expected exactly one token");
    return toks[0];
}

fn expectNone(literal: []const u8) !void {
    var buf: [8]Token = undefined;
    try testing.expectEqual(@as(usize, 0), tokenize(literal, &buf).len);
}

test "plain target" {
    const t = expectOne("[[A]]");
    try testing.expectEqualStrings("A", t.target);
    try testing.expectEqualStrings("", t.alias);
    try testing.expect(!t.embed);
    try testing.expectEqual(@as(usize, 0), t.start);
    try testing.expectEqual(@as(usize, 5), t.end);
}

test "alias" {
    const t = expectOne("[[A|B]]");
    try testing.expectEqualStrings("A", t.target);
    try testing.expectEqualStrings("B", t.alias);
    try testing.expectEqualStrings("B", t.label());
}

test "heading" {
    const t = expectOne("[[A#H]]");
    try testing.expectEqualStrings("A", t.target);
    try testing.expectEqualStrings("H", t.heading);
    try testing.expectEqualStrings("", t.block_id);
}

test "heading and alias" {
    const t = expectOne("[[A#H|B]]");
    try testing.expectEqualStrings("A", t.target);
    try testing.expectEqualStrings("H", t.heading);
    try testing.expectEqualStrings("B", t.alias);
}

test "block id" {
    const t = expectOne("[[A#^abc123]]");
    try testing.expectEqualStrings("A", t.target);
    try testing.expectEqualStrings("abc123", t.block_id);
    try testing.expectEqualStrings("", t.heading);
}

test "embed spans the bang" {
    const t = expectOne("![[A]]");
    try testing.expect(t.embed);
    try testing.expectEqualStrings("A", t.target);
    try testing.expectEqual(@as(usize, 0), t.start);
    try testing.expectEqual(@as(usize, 6), t.end);
}

test "relative path target" {
    const t = expectOne("[[../rel/A]]");
    try testing.expectEqualStrings("../rel/A", t.target);
}

test "surrounding text is excluded from the span" {
    const src = "see [[A]] now";
    const t = expectOne(src);
    try testing.expectEqualStrings("[[A]]", src[t.start..t.end]);
}

test "two links" {
    var buf: [8]Token = undefined;
    const toks = tokenize("[[A]] and [[B]]", &buf);
    try testing.expectEqual(@as(usize, 2), toks.len);
    try testing.expectEqualStrings("A", toks[0].target);
    try testing.expectEqualStrings("B", toks[1].target);
}

test "nested brackets keep the inner link" {
    // `[[[A]]]` — the first `[[` opens, `]]` closes, so the target is `[A`. What matters is
    // that exactly one link is found and the untouched original is recoverable.
    var buf: [8]Token = undefined;
    const toks = tokenize("[[[A]]]", &buf);
    try testing.expectEqual(@as(usize, 1), toks.len);
}

test "whitespace around target and alias is trimmed" {
    const t = expectOne("[[  A  |  B  ]]");
    try testing.expectEqualStrings("A", t.target);
    try testing.expectEqualStrings("B", t.alias);
}

test "empty target is not a link" {
    try expectNone("[[]]");
    try expectNone("[[   ]]");
    try expectNone("[[|B]]");
    try expectNone("[[#H]]");
}

test "unterminated is not a link" {
    try expectNone("[[A");
    try expectNone("A]]");
    try expectNone("[[A]");
    try expectNone("");
    try expectNone("[");
}

test "a link may not span a newline" {
    try expectNone("[[A\nB]]");
}

test "a stray open bracket does not swallow the next link" {
    var buf: [8]Token = undefined;
    const toks = tokenize("[[ oops \n [[A]]", &buf);
    try testing.expectEqual(@as(usize, 1), toks.len);
    try testing.expectEqualStrings("A", toks[0].target);
}

test "out buffer bounds are respected" {
    var buf: [2]Token = undefined;
    const toks = tokenize("[[A]] [[B]] [[C]]", &buf);
    try testing.expectEqual(@as(usize, 2), toks.len);
}

test "tokenizeAlloc matches tokenize" {
    const src = "[[A]] x ![[B|b]] y [[C#H]]";
    const toks = try tokenizeAlloc(testing.allocator, src);
    defer testing.allocator.free(toks);

    var buf: [8]Token = undefined;
    const stack = tokenize(src, &buf);

    try testing.expectEqual(stack.len, toks.len);
    for (stack, toks) |a, b| {
        try testing.expectEqual(a.start, b.start);
        try testing.expectEqual(a.end, b.end);
        try testing.expectEqualStrings(a.target, b.target);
    }
}

test "tokenizeAlloc returns a freeable empty slice" {
    const toks = try tokenizeAlloc(testing.allocator, "no links here");
    defer testing.allocator.free(toks);
    try testing.expectEqual(@as(usize, 0), toks.len);
}
