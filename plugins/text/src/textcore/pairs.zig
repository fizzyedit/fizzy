//! Auto-closing bracket/quote decisions — the "what should this keystroke do" half of
//! VSCode's `editor.autoClosingBrackets`/`autoSurround`/`autoClosingDelete`, resolved against
//! the byte buffer alone so it is testable without a window (see `textcore.zig`'s invariant).
//! Applying the result (mutating the buffer and the selection) stays in the widget.

const std = @import("std");

/// One auto-closed pair. Quotes need slightly different rules than brackets — their opener and
/// closer are the same byte, so lookahead alone can't tell "closing the string I'm in" from
/// "starting a new one" — hence `is_quote`.
pub const Pair = struct { open: u8, close: u8, is_quote: bool };

/// Deliberately language-agnostic: the text widget has no notion of which language a document
/// is in, and these six pairs are ones every language it is likely to open agrees on. A
/// per-language table would belong on `sdk.language.LanguageSupport`, not here.
pub const all = [_]Pair{
    .{ .open = '{', .close = '}', .is_quote = false },
    .{ .open = '(', .close = ')', .is_quote = false },
    .{ .open = '[', .close = ']', .is_quote = false },
    .{ .open = '"', .close = '"', .is_quote = true },
    .{ .open = '\'', .close = '\'', .is_quote = true },
    .{ .open = '`', .close = '`', .is_quote = true },
};

pub fn forOpen(c: u8) ?Pair {
    for (all) |p| {
        if (p.open == c) return p;
    }
    return null;
}

pub fn forClose(c: u8) ?Pair {
    for (all) |p| {
        if (p.close == c) return p;
    }
    return null;
}

/// Identifier byte, by the same alphanumeric/underscore convention the LSP client's prefix
/// derivation and the completion list's typed-prefix highlight already use.
pub fn isWordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// What typing one character should do.
pub const Action = union(enum) {
    /// Insert the character normally (including replacing any selection) — the default.
    insert,
    /// Insert `open` and `close` at the cursor, leaving the cursor between them.
    close_pair: Pair,
    /// A closer identical to the one typed already sits at the cursor: move past it instead of
    /// inserting a second one.
    step_over,
    /// Wrap the active selection in the pair rather than replacing it, keeping it selected.
    surround: Pair,
};

/// Decides what typing `ch` does with the caret at `[sel_start, sel_end)` in `text`.
///
/// Step-over is deliberately *untracked*: it fires on any matching closer directly after the
/// cursor, rather than only on closers the editor itself auto-inserted. Tracking would mean
/// persisting byte offsets across frames (the widget struct is rebuilt every frame) and
/// shifting them on every edit, for a difference that only shows up when someone deliberately
/// types a closer immediately before an unrelated one — the same tradeoff Sublime Text makes.
pub fn onTyped(text: []const u8, sel_start: usize, sel_end: usize, ch: u8) Action {
    if (sel_end > text.len or sel_start > sel_end) return .insert;

    if (sel_start != sel_end) {
        const p = forOpen(ch) orelse return .insert;
        // Wrapping several lines in quotes is nearly always a mistake (and leaves an
        // unterminated string in every language this editor highlights); brackets over multiple
        // lines are normal.
        if (p.is_quote and std.mem.indexOfScalar(u8, text[sel_start..sel_end], '\n') != null) return .insert;
        return .{ .surround = p };
    }

    const cursor = sel_start;
    const prev: ?u8 = if (cursor > 0) text[cursor - 1] else null;
    const next: ?u8 = if (cursor < text.len) text[cursor] else null;

    // Checked before the opener path so a quote closes the string it's inside rather than
    // opening a new one.
    if (next != null and next.? == ch and forClose(ch) != null) return .step_over;

    const p = forOpen(ch) orelse return .insert;

    // Don't auto-close directly before a word: `(` typed just before `foo` is far more likely
    // to be wrapping `foo` in parens than opening an empty pair, and an unwanted `)` there is
    // more annoying to clean up than a missing one is to type.
    if (next) |n| {
        if (isWordByte(n)) return .insert;
    }
    if (p.is_quote) {
        // An apostrophe after a word character is punctuation, not a string opener (`don't`),
        // and one after a backslash is escaped.
        if (prev) |pv| {
            if (isWordByte(pv) or pv == '\\') return .insert;
        }
    }
    return .{ .close_pair = p };
}

/// One bracket inside a nesting-colour pass: the byte of the glyph, and the palette index for
/// it (indent + kind offset). See `nestMarks`.
pub const NestMark = struct {
    byte: usize,
    /// Palette index: line indent level plus a per-kind stride so `{`, `(`, and `[` at the
    /// same indent don't share a colour. Matching pairs of the same kind still match.
    depth: u8,
};

/// Leading-whitespace indent level of the line containing `pos`, measured in `tab_size`-wide
/// columns (spaces count 1, tabs jump to the next stop). Trailing content on the line is
/// ignored — `    if (x) {` and a lone `}` at the same indent both report level 1.
pub fn indentLevelAt(text: []const u8, pos: usize, tab_size: u8) u8 {
    const ts: usize = if (tab_size == 0) 4 else tab_size;
    const line_start = if (std.mem.lastIndexOfScalar(u8, text[0..@min(pos, text.len)], '\n')) |nl| nl + 1 else 0;
    var col: usize = 0;
    var i = line_start;
    while (i < text.len) : (i += 1) {
        switch (text[i]) {
            ' ' => col += 1,
            '\t' => col = (col / ts + 1) * ts,
            else => break,
        }
    }
    return @truncate(col / ts);
}

/// Per-kind offset into the palette. Spaced so braces / parens / square brackets at the same
/// indent land on visually distinct slots — `core.palette.bracket_colors` has a comptime check
/// that its length keeps these three offsets from colliding. Open and close of a kind share the
/// offset, so a matching pair still paints the same colour.
fn kindOffset(c: u8) u8 {
    return switch (c) {
        '{', '}' => 0,
        '(', ')' => 3,
        '[', ']' => 5,
        else => 0,
    };
}

/// Rainbow-bracket scan: every non-quote `{`, `(`, `[` and its closer in
/// `[range_start, range_end)` gets a mark whose `depth` is **indent level + kind offset**.
/// Matching pairs of the same kind sit at the same indent in well-formatted code, so they
/// share a colour; different kinds at that indent take different palette slots; one indent
/// deeper advances every kind together.
///
/// Writes ascending by `byte` into `out` and returns how many were written. Stops appending
/// when `out` is full rather than allocating — callers size for a screenful of brackets; a
/// full buffer just leaves later ones uncolored for that frame, never incorrect.
///
/// Quote characters themselves are skipped (which `"` closes which needs a lexer). Brackets
/// *inside* strings still get coloured — same lexical tradeoff as `matchAt`.
pub fn nestMarks(text: []const u8, range_start: usize, range_end: usize, tab_size: u8, out: []NestMark) usize {
    if (range_start >= range_end or range_start > text.len) return 0;
    const end = @min(range_end, text.len);

    var n: usize = 0;
    var i = range_start;
    while (i < end and n < out.len) : (i += 1) {
        const c = text[i];
        const is_bracket = if (forOpen(c)) |p| !p.is_quote else if (forClose(c)) |p| !p.is_quote else false;
        if (!is_bracket) continue;
        out[n] = .{ .byte = i, .depth = indentLevelAt(text, i, tab_size) +% kindOffset(c) };
        n += 1;
    }
    return n;
}

/// How far `matchAt` will scan in each direction before giving up. A match further away than
/// this is off-screen by orders of magnitude, so finding it would change nothing on screen —
/// but scanning for it runs on every frame of every open editor, including 60MB files where an
/// unmatched brace at the top would otherwise walk the whole buffer every frame.
pub const match_scan_budget: usize = 200_000;

/// Byte offsets of the bracket next to `cursor` and the one that closes/opens it, ascending, or
/// null when the caret isn't next to a bracket (or its partner isn't found within
/// `match_scan_budget`). Drives match highlighting.
///
/// Brackets only — quotes are excluded because their two halves are the same byte, so deciding
/// which `"` closes which needs to know whether the caret is inside a string, which needs a
/// lexer. For the same reason this scan is purely lexical: a bracket inside a string or comment
/// (`const s = "{";`) counts toward nesting like any other, so it can pair up with the wrong
/// partner. Fixing that means asking tree-sitter which node each candidate is in — worth doing
/// if it ever grates, but it costs a per-frame tree query and only pays off in code that puts
/// unbalanced brackets in string literals.
pub fn matchAt(text: []const u8, cursor: usize) ?[2]usize {
    if (cursor > text.len) return null;
    // The bracket *before* the caret wins: with the caret at `foo()|`, VSCode highlights the
    // `)` just typed rather than looking past it.
    if (cursor > 0) {
        if (matchFrom(text, cursor - 1)) |m| return m;
    }
    if (cursor < text.len) {
        if (matchFrom(text, cursor)) |m| return m;
    }
    return null;
}

/// The pair for the bracket at `i`, ascending, or null when `i` isn't a bracket or has no
/// partner in budget. Nesting is counted per bracket kind, so a stray `(` inside a `{}` block
/// doesn't throw the brace match off.
fn matchFrom(text: []const u8, i: usize) ?[2]usize {
    const c = text[i];
    if (forOpen(c)) |p| {
        if (p.is_quote) return null;
        var depth: usize = 1;
        var j = i + 1;
        const limit = @min(text.len, i + 1 +| match_scan_budget);
        while (j < limit) : (j += 1) {
            if (text[j] == p.open) {
                depth += 1;
            } else if (text[j] == p.close) {
                depth -= 1;
                if (depth == 0) return .{ i, j };
            }
        }
        return null;
    }
    if (forClose(c)) |p| {
        if (p.is_quote) return null;
        var depth: usize = 1;
        var j = i;
        const limit = i -| match_scan_budget;
        while (j > limit) {
            j -= 1;
            if (text[j] == p.close) {
                depth += 1;
            } else if (text[j] == p.open) {
                depth -= 1;
                if (depth == 0) return .{ j, i };
            }
        }
        return null;
    }
    return null;
}

/// True when `cursor` sits directly between an empty pair (`{|}`), so Backspace should take out
/// both halves — VSCode's `editor.autoClosingDelete`. Deleting the `{` of `{|}` and leaving the
/// orphaned `}` behind is never what was meant.
pub fn deletesPair(text: []const u8, cursor: usize) bool {
    if (cursor == 0 or cursor >= text.len) return false;
    const p = forOpen(text[cursor - 1]) orelse return false;
    return text[cursor] == p.close;
}

// -- tests --------------------------------------------------------------------------------------

const testing = std.testing;

/// `text` with `|` marking the caret (or `[`…`]` a selection) is unreadable next to real
/// brackets, which is exactly what these tests are full of — so positions are passed directly.
fn expectAction(text: []const u8, start: usize, end: usize, ch: u8, want: std.meta.Tag(Action)) !void {
    try testing.expectEqual(want, std.meta.activeTag(onTyped(text, start, end, ch)));
}

test "opener at end of buffer auto-closes" {
    try expectAction("pub const Test = struct ", 24, 24, '{', .close_pair);
}

test "opener before whitespace or a closer auto-closes" {
    try expectAction("f() ", 2, 2, '(', .close_pair); // before ')'
    try expectAction("a  b", 2, 2, '[', .close_pair); // before ' '
    try expectAction("x\ny", 1, 1, '{', .close_pair); // before '\n'
}

test "opener directly before a word does not auto-close" {
    try expectAction("foo", 0, 0, '(', .insert);
    try expectAction("call foo", 5, 5, '[', .insert);
    // Still auto-closes when the word is behind, not ahead.
    try expectAction("foo", 3, 3, '(', .close_pair);
}

test "typing a closer steps over the one already there" {
    try expectAction("()", 1, 1, ')', .step_over);
    try expectAction("{}", 1, 1, '}', .step_over);
    // Only for closers — an opener sitting ahead is not stepped over, it auto-closes as usual.
    try expectAction("((", 1, 1, '(', .close_pair);
}

test "quote closes the string it is in rather than opening a new one" {
    try expectAction("\"\"", 1, 1, '"', .step_over);
    try expectAction("x = ", 4, 4, '"', .close_pair);
}

test "apostrophe after a word or a backslash is not a string opener" {
    try expectAction("don", 3, 3, '\'', .insert);
    try expectAction("'\\", 2, 2, '\'', .insert);
}

test "opener with a selection surrounds it" {
    try expectAction("wrap me", 0, 4, '(', .surround);
    // A closer never surrounds — it replaces, like any other character.
    try expectAction("wrap me", 0, 4, ')', .insert);
    // Quotes decline to wrap across lines; brackets don't.
    try expectAction("a\nb", 0, 3, '"', .insert);
    try expectAction("a\nb", 0, 3, '{', .surround);
}

test "out of range selection falls through to a plain insert" {
    try expectAction("ab", 1, 9, '(', .insert);
    try expectAction("ab", 2, 1, '(', .insert);
}

test "matchAt pairs the bracket the caret is next to" {
    const text = "fn f() {}";
    // Caret after the `(`: matches forward to `)`.
    try testing.expectEqual([2]usize{ 4, 5 }, matchAt(text, 5).?);
    // Caret after the `)`: the bracket *before* the caret wins.
    try testing.expectEqual([2]usize{ 4, 5 }, matchAt(text, 6).?);
    // Caret before the `{` with a non-bracket behind it: matches the one ahead.
    try testing.expectEqual([2]usize{ 7, 8 }, matchAt(text, 7).?);
}

test "matchAt counts nesting" {
    const text = "{ a { b } c }";
    try testing.expectEqual([2]usize{ 0, 12 }, matchAt(text, 1).?);
    try testing.expectEqual([2]usize{ 4, 8 }, matchAt(text, 5).?);
    // Backward from the outer closer.
    try testing.expectEqual([2]usize{ 0, 12 }, matchAt(text, 13).?);
}

test "matchAt counts each bracket kind independently" {
    // The stray `(` must not throw off the brace match.
    const text = "{ ( }";
    try testing.expectEqual([2]usize{ 0, 4 }, matchAt(text, 1).?);
}

test "matchAt finds nothing when there is nothing to match" {
    try testing.expectEqual(@as(?[2]usize, null), matchAt("plain text", 3));
    try testing.expectEqual(@as(?[2]usize, null), matchAt("{ unclosed", 1));
    try testing.expectEqual(@as(?[2]usize, null), matchAt("unopened }", 10));
    try testing.expectEqual(@as(?[2]usize, null), matchAt("", 0));
    try testing.expectEqual(@as(?[2]usize, null), matchAt("{}", 99));
    // Quotes are excluded — which `"` closes which needs a lexer, not a scan.
    try testing.expectEqual(@as(?[2]usize, null), matchAt("\"\"", 1));
}

test "matchAt gives up past the scan budget" {
    const gpa = testing.allocator;
    const far = match_scan_budget + 16;
    const text = try gpa.alloc(u8, far + 2);
    defer gpa.free(text);
    @memset(text, ' ');
    text[0] = '{';
    text[far + 1] = '}';
    try testing.expectEqual(@as(?[2]usize, null), matchAt(text, 1));

    // The same brace pair just inside the budget is still found.
    text[far + 1] = ' ';
    text[match_scan_budget] = '}';
    try testing.expectEqual([2]usize{ 0, match_scan_budget }, matchAt(text, 1).?);
}

test "indentLevelAt counts spaces and tabs in tab_size units" {
    try testing.expectEqual(@as(u8, 0), indentLevelAt("foo", 0, 4));
    try testing.expectEqual(@as(u8, 1), indentLevelAt("    foo", 4, 4));
    try testing.expectEqual(@as(u8, 2), indentLevelAt("        foo", 8, 4));
    try testing.expectEqual(@as(u8, 1), indentLevelAt("\tfoo", 1, 4));
    try testing.expectEqual(@as(u8, 2), indentLevelAt("\t\tfoo", 2, 4));
    // Position mid-line still reads that line's leading whitespace.
    try testing.expectEqual(@as(u8, 1), indentLevelAt("    if (x) {\n", 10, 4));
}

test "nestMarks colours by indent level so matching pairs share a colour" {
    const text =
        \\{
        \\    {
        \\        {
        \\        }
        \\    }
        \\}
    ;
    var out: [16]NestMark = undefined;
    const n = nestMarks(text, 0, text.len, 4, &out);
    try testing.expectEqual(@as(usize, 6), n);
    // Braces use kind offset 0 — openers at indent 0, 1, 2; closers reverse at 2, 1, 0.
    try testing.expectEqual(@as(usize, 0), out[0].byte);
    try testing.expectEqual(@as(u8, 0), out[0].depth);
    try testing.expectEqual(@as(u8, 1), out[1].depth);
    try testing.expectEqual(@as(u8, 2), out[2].depth);
    try testing.expectEqual(@as(u8, 2), out[3].depth);
    try testing.expectEqual(@as(u8, 1), out[4].depth);
    try testing.expectEqual(@as(u8, 0), out[5].depth);
}

test "nestMarks different kinds at the same indent get different colours" {
    const text = "{ ( [ ] ) }";
    var out: [8]NestMark = undefined;
    const n = nestMarks(text, 0, text.len, 4, &out);
    try testing.expectEqual(@as(usize, 6), n);
    // Same indent, three kind offsets — openers disagree, each closer matches its opener.
    try testing.expect(out[0].depth != out[1].depth); // { vs (
    try testing.expect(out[1].depth != out[2].depth); // ( vs [
    try testing.expect(out[0].depth != out[2].depth); // { vs [
    try testing.expectEqual(out[0].depth, out[5].depth); // { }
    try testing.expectEqual(out[1].depth, out[4].depth); // ( )
    try testing.expectEqual(out[2].depth, out[3].depth); // [ ]
}

test "nestMarks paren and brace at the same indent disagree" {
    const text =
        \\fn f(
        \\    x: u32,
        \\) void {
        \\    _ = x;
        \\}
    ;
    var out: [8]NestMark = undefined;
    const n = nestMarks(text, 0, text.len, 4, &out);
    try testing.expectEqual(@as(usize, 4), n); // ( ) { }
    try testing.expectEqual(out[0].depth, out[1].depth); // ( )
    try testing.expectEqual(out[2].depth, out[3].depth); // { }
    try testing.expect(out[0].depth != out[2].depth); // ( vs {
}

test "nestMarks mid-range uses each line's own indent" {
    const text =
        \\{
        \\    { }
        \\}
    ;
    // Inner `{ }` sit on the indented middle line — range covering only that line.
    const mid = std.mem.indexOf(u8, text, "{ }").?;
    var out: [4]NestMark = undefined;
    const n = nestMarks(text, mid, mid + 3, 4, &out);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(u8, 1), out[0].depth);
    try testing.expectEqual(@as(u8, 1), out[1].depth);
}

test "nestMarks skips quote characters themselves" {
    var out: [8]NestMark = undefined;
    const n = nestMarks("\"{}\"", 0, 4, 4, &out);
    // The braces inside the string are still lexical brackets (same tradeoff as `matchAt`);
    // the quote characters themselves are not coloured.
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(usize, 1), out[0].byte);
    try testing.expectEqual(@as(usize, 2), out[1].byte);
}

test "deletesPair only between an empty pair" {
    try testing.expect(deletesPair("{}", 1));
    try testing.expect(deletesPair("f('')", 3));
    try testing.expect(!deletesPair("{a}", 1)); // not empty
    try testing.expect(!deletesPair("{}", 0)); // not between
    try testing.expect(!deletesPair("{}", 2)); // past the closer
    try testing.expect(!deletesPair("{)", 1)); // mismatched
    try testing.expect(!deletesPair("", 0));
}
