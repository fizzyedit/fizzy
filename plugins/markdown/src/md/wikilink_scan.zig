//! Finding `[[wikilinks]]` in a parsed markdown AST — specifically, the part the SDK's pure
//! tokenizer cannot do alone: telling `[[A]]` apart from `\[\[A]]`.
//!
//! **Why this file exists.** md4c reports a backslash escape as its own text run holding just the
//! escaped character, and `ast.zig` merges adjacent runs into one `.text` node so the renderer
//! sees a paragraph of prose as one node. After that merge `\[\[A]]` and `[[A]]` have **the same
//! literal** — `[[A]]` — so tokenizing the literal turns a deliberately escaped link into a real
//! one, and the AST alone cannot tell them apart.
//!
//! What survives is position: `ast.zig` records the source byte span every node was built from,
//! so the original bytes — backslashes included — can be read straight back out of the document.
//!
//! **The rule.** Re-apply markdown's escape handling to that source span, producing the bytes it
//! would have yielded plus a flag per byte for "this came from an escape". When those bytes match
//! the node's literal exactly, the flags line up with it positionally and a link whose opening
//! brackets are flagged is dropped. When they *don't* match — an HTML entity expanded, say — the
//! mapping is untrustworthy and we **fail open**: the link renders. A link that renders when the
//! author wanted literal text is a visible, correctable annoyance; a link that silently vanishes
//! is a bug someone spends an afternoon on.
const std = @import("std");
const ast = @import("ast.zig");
const wikilink = @import("fizzy_sdk").services.wikilink;

pub const Token = wikilink.Token;

/// Bytes `span` would produce after markdown's backslash-escape handling, and a parallel flag per
/// byte marking the ones that came from an escape.
const Unescaped = struct {
    bytes: []u8,
    escaped: []bool,

    fn deinit(self: *Unescaped, gpa: std.mem.Allocator) void {
        gpa.free(self.bytes);
        gpa.free(self.escaped);
    }
};

/// Mirrors md4c's escape handling: a backslash before ASCII punctuation
/// yields that punctuation literally; anything else keeps the backslash as-is.
fn unescape(gpa: std.mem.Allocator, span: []const u8) !Unescaped {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(gpa);
    var escaped: std.ArrayList(bool) = .empty;
    errdefer escaped.deinit(gpa);

    var i: usize = 0;
    while (i < span.len) {
        if (span[i] == '\\' and i + 1 < span.len and isCmarkPunct(span[i + 1])) {
            try bytes.append(gpa, span[i + 1]);
            try escaped.append(gpa, true);
            i += 2;
        } else {
            try bytes.append(gpa, span[i]);
            try escaped.append(gpa, false);
            i += 1;
        }
    }
    return .{
        .bytes = try bytes.toOwnedSlice(gpa),
        .escaped = try escaped.toOwnedSlice(gpa),
    };
}

/// CommonMark's escapable set — ASCII punctuation only.
fn isCmarkPunct(c: u8) bool {
    return switch (c) {
        '!'...'/', ':'...'@', '['...'`', '{'...'~' => true,
        else => false,
    };
}

/// Wikilinks in one consolidated TEXT node's `literal`, with backslash-escaped ones removed.
///
/// `source_span` is that node's original bytes (`Node.sourceSpan`); pass null when they can't
/// be located, which disables escape detection rather than dropping links. Offsets in the
/// returned tokens index `literal`, so the caller can slice display text straight out of it.
///
/// Returns an owned slice, empty when there are no links.
pub fn tokensFor(
    gpa: std.mem.Allocator,
    literal: []const u8,
    source_span: ?[]const u8,
) ![]Token {
    const tokens = try wikilink.tokenizeAlloc(gpa, literal);
    if (tokens.len == 0) return tokens;
    errdefer gpa.free(tokens);

    const span = source_span orelse return tokens;
    // The overwhelmingly common case: no backslash anywhere in this run of text, so nothing
    // can have been escaped and the literal is the source. Costs one memchr.
    if (std.mem.indexOfScalar(u8, span, '\\') == null) return tokens;

    var un = try unescape(gpa, span);
    defer un.deinit(gpa);

    // Fail open on any drift between what we reconstructed and what the parser actually produced
    // (smart punctuation, entity expansion) — the flags would no longer line up positionally.
    if (!std.mem.eql(u8, un.bytes, literal)) return tokens;

    var kept: usize = 0;
    for (tokens) |tok| {
        // `start` points at `!` for an embed; the brackets follow it.
        const open = if (tok.embed) tok.start + 1 else tok.start;
        if (open + 1 < un.escaped.len and (un.escaped[open] or un.escaped[open + 1])) continue;
        tokens[kept] = tok;
        kept += 1;
    }
    if (kept == tokens.len) return tokens;
    return gpa.realloc(tokens, kept) catch tokens[0..kept];
}

// -- tests ------------------------------------------------------------------------------
//
// These run the **real vendored md4c**, not a stand-in. The whole point of this file is a
// claim about what the parser does to escapes and source spans, and only md4c can confirm it.

const testing = std.testing;

/// Parse `src`, walk every TEXT node, and collect the wikilinks `tokensFor` finds in it.
fn linksIn(gpa: std.mem.Allocator, src: []const u8, out: *std.ArrayList([]const u8)) !void {
    const tree = ast.parse(gpa, src) orelse return error.ParseFailed;
    defer ast.destroy(gpa, tree);
    try walk(gpa, tree.node(), src, out);
}

fn walk(
    gpa: std.mem.Allocator,
    node: ast.Node,
    src: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    if (node.nodeType() == .text) {
        if (node.literal()) |lit| {
            const toks = try tokensFor(gpa, lit, node.sourceSpan(src));
            defer gpa.free(toks);
            for (toks) |t| try out.append(gpa, try gpa.dupe(u8, t.target));
        }
    }
    var child = node.firstChild();
    while (child) |c| : (child = c.nextSibling()) try walk(gpa, c, src, out);
}

fn expectTargets(src: []const u8, expected: []const []const u8) !void {
    const gpa = testing.allocator;
    var found: std.ArrayList([]const u8) = .empty;
    defer {
        for (found.items) |s| gpa.free(s);
        found.deinit(gpa);
    }
    try linksIn(gpa, src, &found);

    testing.expectEqual(expected.len, found.items.len) catch |err| {
        std.debug.print("source: {s}\nfound:", .{src});
        for (found.items) |s| std.debug.print(" [[{s}]]", .{s});
        std.debug.print("\n", .{});
        return err;
    };
    for (expected, found.items) |want, got| try testing.expectEqualStrings(want, got);
}

test "a plain wikilink is found" {
    try expectTargets("See [[Note]] here.\n", &.{"Note"});
}

test "several wikilinks in one paragraph" {
    try expectTargets("[[A]] and [[B]] and [[C]]\n", &.{ "A", "B", "C" });
}

test "escaped brackets are not a wikilink" {
    // The regression this whole file exists for. `ast.zig` merges the escape into the
    // surrounding text, so the literal here is indistinguishable from a real link.
    try expectTargets("\\[\\[Note]] is how you write a link.\n", &.{});
}

test "escaping only the first bracket is enough" {
    try expectTargets("\\[[Note]]\n", &.{});
}

test "an escape elsewhere in the line does not suppress a real link" {
    try expectTargets("\\*not emphasis\\* but [[Note]] is a link\n", &.{"Note"});
}

test "inline code is never a wikilink" {
    // Not handled here at all — inline code gets its own `.code` node, so it
    // never reaches a TEXT node. This test pins that assumption.
    try expectTargets("Write `[[Note]]` to link.\n", &.{});
}

test "fenced code is never a wikilink" {
    try expectTargets("```\n[[Note]]\n```\n", &.{});
}

test "indented code is never a wikilink" {
    try expectTargets("    [[Note]]\n", &.{});
}

test "a wikilink inside emphasis is still found" {
    try expectTargets("*see [[Note]]*\n", &.{"Note"});
}

test "wikilinks survive inside a list item and a blockquote" {
    try expectTargets("- [[A]]\n\n> [[B]]\n", &.{ "A", "B" });
}

test "alias and heading forms round-trip through the parser" {
    try expectTargets("[[A|shown]] and [[B#Heading]]\n", &.{ "A", "B" });
}

test "an embed is found" {
    try expectTargets("![[Note]]\n", &.{"Note"});
}

test "an escaped embed is not" {
    try expectTargets("!\\[\\[Note]]\n", &.{});
}

test "smart punctuation next to an escape fails open rather than dropping the link" {
    // CMARK_OPT_SMART rewrites the quotes, so the reconstructed bytes can't match the literal
    // and escape detection is skipped. The documented, deliberate outcome is that the link
    // renders — not that it disappears.
    try expectTargets("\"quoted\" \\* [[Note]]\n", &.{"Note"});
}

test "a wikilink spanning a line break is not a link" {
    try expectTargets("[[A\nB]]\n", &.{});
}

test "unclosed brackets are not a link" {
    try expectTargets("[[A and then nothing\n", &.{});
}
