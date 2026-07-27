//! Cursor motion, as pure functions of `(text, offset) -> offset`.
//!
//! Nothing here touches a widget, a layout, or frame state. That is the entire point: the
//! old path set `TextLayoutWidget.sel_move`, a **single-slot** union resolved later during
//! the render pass, so a second motion arriving in the same frame was silently dropped and
//! vertical motion round-tripped through `dataSet`/`dataGet` across two frames.
//!
//! No `LineIndex` is required. The editor sets `break_lines = false` (one source line is
//! exactly one visual row), so every motion below is a local scan bounded by line length.
//! If wrapping is ever added, vertical motion grows a `VisualLines` seam; nothing else here
//! changes.

const std = @import("std");
const Range = @import("Range.zig");
const LineIndex = @import("LineIndex.zig");

pub const Granularity = enum {
    char,
    subword,
    word,
    /// Home/End — horizontal, within the current line.
    line_boundary,
    /// Up/Down by one line.
    line,
    page,
    document,
};

pub const Dir = enum {
    backward,
    forward,

    pub fn sign(self: Dir) i32 {
        return switch (self) {
            .backward => -1,
            .forward => 1,
        };
    }
};

pub const Opts = struct {
    tab_size: u8 = 4,
    /// Rows per PageUp/PageDown. The caller knows the viewport; default is a sane fallback.
    page_lines: u32 = 20,
};

// -- UTF-8 boundaries ------------------------------------------------------------------------

fn isContinuation(c: u8) bool {
    return c & 0xC0 == 0x80;
}

/// Start of the codepoint immediately before `off`, or 0.
pub fn prevCharStart(text: []const u8, off: usize) usize {
    if (off == 0) return 0;
    var i = @min(off, text.len) - 1;
    while (i > 0 and isContinuation(text[i])) : (i -= 1) {}
    return i;
}

/// Start of the codepoint immediately after `off`, or `text.len`.
pub fn nextCharStart(text: []const u8, off: usize) usize {
    if (off >= text.len) return text.len;
    var i = off + 1;
    while (i < text.len and isContinuation(text[i])) : (i += 1) {}
    return i;
}

/// Snap `off` back to the nearest codepoint boundary.
pub fn alignToChar(text: []const u8, off: usize) usize {
    var i = @min(off, text.len);
    while (i > 0 and i < text.len and isContinuation(text[i])) : (i -= 1) {}
    return i;
}

pub fn charLeft(text: []const u8, off: usize) usize {
    return prevCharStart(text, off);
}

pub fn charRight(text: []const u8, off: usize) usize {
    return nextCharStart(text, off);
}

// -- character classes -----------------------------------------------------------------------

const Class = enum { space, word, punct };

/// `_` is a word character and every non-ASCII byte is too — a code editor must treat
/// `snake_case` and identifiers with non-ASCII letters as single words. (dvui's
/// `word_breaks` list puts `_` in the *separator* set, which is wrong for source code.)
fn classOf(c: u8) Class {
    if (c == ' ' or c == '\t' or c == '\n' or c == '\r') return .space;
    if (c == '_' or c >= 0x80) return .word;
    if (std.ascii.isAlphanumeric(c)) return .word;
    return .punct;
}

fn isUpper(c: u8) bool {
    return c >= 'A' and c <= 'Z';
}

fn isLower(c: u8) bool {
    return c >= 'a' and c <= 'z';
}

fn isWordByte(c: u8) bool {
    return classOf(c) == .word;
}

// -- word motion -----------------------------------------------------------------------------

/// Skip whitespace forward, then consume the run of like-classed characters. `foo| bar` goes
/// to `foo bar|` — the classic "end of word" behaviour, symmetric with `wordLeft`.
pub fn wordRight(text: []const u8, off: usize) usize {
    var i = @min(off, text.len);
    while (i < text.len and classOf(text[i]) == .space) i = nextCharStart(text, i);
    if (i >= text.len) return text.len;
    const cls = classOf(text[i]);
    while (i < text.len and classOf(text[i]) == cls) i = nextCharStart(text, i);
    return i;
}

pub fn wordLeft(text: []const u8, off: usize) usize {
    var i = @min(off, text.len);
    while (i > 0 and classOf(text[prevCharStart(text, i)]) == .space) i = prevCharStart(text, i);
    if (i == 0) return 0;
    const cls = classOf(text[prevCharStart(text, i)]);
    while (i > 0 and classOf(text[prevCharStart(text, i)]) == cls) i = prevCharStart(text, i);
    return i;
}

/// Like `wordRight`, but a word is further split into sub-words: `snake_case` breaks as
/// `snake` + `_case`, `camelCase` as `camel` + `Case`, and `HTTPServer` as `HTTP` + `Server`
/// (the acronym rule — a run of capitals belongs together except for the last one, which
/// starts the following word).
pub fn subwordRight(text: []const u8, off: usize) usize {
    var i = @min(off, text.len);
    while (i < text.len and classOf(text[i]) == .space) i = nextCharStart(text, i);
    if (i >= text.len) return text.len;

    if (classOf(text[i]) == .punct) {
        while (i < text.len and classOf(text[i]) == .punct) i = nextCharStart(text, i);
        return i;
    }

    // Leading underscores attach to the sub-word that follows them.
    while (i < text.len and text[i] == '_') i += 1;
    if (i >= text.len or !isWordByte(text[i])) return i;

    const started_upper = isUpper(text[i]);
    i = nextCharStart(text, i);
    if (started_upper) {
        // Acronym run: keep consuming capitals, but stop before the capital that begins the
        // next word (i.e. one immediately followed by a lowercase letter).
        while (i < text.len and isUpper(text[i]) and
            !(i + 1 < text.len and isLower(text[i + 1]))) : (i += 1)
        {}
    }
    while (i < text.len and isWordByte(text[i]) and !isUpper(text[i]) and text[i] != '_') {
        i = nextCharStart(text, i);
    }
    return i;
}

/// The `subwordRight` segmentation walked backwards. Like `wordLeft` vs `wordRight`, the two
/// aren't offset-for-offset inverses across whitespace — forward stops at the *end* of a
/// sub-word, backward at its *start* — but within a word they agree exactly.
pub fn subwordLeft(text: []const u8, off: usize) usize {
    var i = @min(off, text.len);
    while (i > 0 and classOf(text[prevCharStart(text, i)]) == .space) i = prevCharStart(text, i);
    if (i == 0) return 0;

    if (classOf(text[prevCharStart(text, i)]) == .punct) {
        while (i > 0 and classOf(text[prevCharStart(text, i)]) == .punct) i = prevCharStart(text, i);
        return i;
    }

    const before = i;
    while (i > 0) {
        const p = prevCharStart(text, i);
        if (!isWordByte(text[p]) or isUpper(text[p]) or text[p] == '_') break;
        i = p;
    }
    const consumed_lower = i != before;

    if (i > 0 and isUpper(text[i - 1])) {
        if (consumed_lower) {
            // A single leading capital on a CamelWord we just walked back through.
            i -= 1;
        } else {
            // No lowercase tail, so this is an acronym run — take all of it.
            while (i > 0 and isUpper(text[i - 1])) i -= 1;
        }
    }
    // Underscores attach to the sub-word that follows, so absorb them on the way back.
    while (i > 0 and text[i - 1] == '_') i -= 1;
    return i;
}

// -- line geometry (local scans) ---------------------------------------------------------------

pub fn lineStartOf(text: []const u8, off: usize) usize {
    const i = @min(off, text.len);
    return if (std.mem.lastIndexOfScalar(u8, text[0..i], '\n')) |nl| nl + 1 else 0;
}

/// End of the line containing `off`, excluding the newline.
pub fn lineEndOf(text: []const u8, off: usize) usize {
    const i = @min(off, text.len);
    return std.mem.indexOfScalarPos(u8, text, i, '\n') orelse text.len;
}

fn prevLineStart(text: []const u8, line_start: usize) ?usize {
    if (line_start == 0) return null;
    return lineStartOf(text, line_start - 1);
}

fn nextLineStart(text: []const u8, line_start: usize) ?usize {
    const nl = std.mem.indexOfScalarPos(u8, text, line_start, '\n') orelse return null;
    return nl + 1;
}

/// VSCode's Home: first non-whitespace character of the line, unless already there, in which
/// case column 0. The current `line_start` keybind jumps straight to column 0 unconditionally.
pub fn lineHomeSmart(text: []const u8, off: usize) usize {
    const s = lineStartOf(text, off);
    const e = lineEndOf(text, off);
    var first = s;
    while (first < e and (text[first] == ' ' or text[first] == '\t')) : (first += 1) {}
    return if (off == first) s else first;
}

// -- vertical motion ---------------------------------------------------------------------------

pub const Vertical = struct { off: usize, goal_col: u32 };

/// Move `lines` rows (negative = up), holding `goal_col` if one is already established.
/// Running off either end lands on the document boundary, keeping the goal column — same as
/// VSCode, so Up at the first line goes to offset 0 rather than doing nothing.
pub fn verticalMove(
    text: []const u8,
    off: usize,
    goal_col: ?u32,
    lines: i32,
    opts: Opts,
) Vertical {
    const cur_start = lineStartOf(text, off);
    const col = goal_col orelse LineIndex.colBetween(text, cur_start, off, opts.tab_size);
    if (lines == 0) return .{ .off = off, .goal_col = col };

    var target = cur_start;
    var remaining: u32 = @abs(lines);
    while (remaining > 0) : (remaining -= 1) {
        const next = if (lines < 0) prevLineStart(text, target) else nextLineStart(text, target);
        if (next) |n| {
            target = n;
        } else {
            // Off the end of the document in this direction.
            return .{ .off = if (lines < 0) 0 else text.len, .goal_col = col };
        }
    }

    const target_end = lineEndOf(text, target);
    return .{
        .off = LineIndex.offsetAtColIn(text, target, target_end, col, opts.tab_size),
        .goal_col = col,
    };
}

// -- the single entry point ----------------------------------------------------------------------

/// Resolve a motion immediately. This is what the key handler calls — one function, one
/// frame, no deferral, no dropped repeats.
pub fn move(
    text: []const u8,
    r: Range,
    g: Granularity,
    dir: Dir,
    extend: bool,
    opts: Opts,
) Range {
    const head = @min(r.head, text.len);

    // Collapsing a selection: an unshifted Left/Right with something selected moves to the
    // near edge rather than moving by one character. Matches VSCode and the previous
    // behaviour at TextEntryWidget.zig:1561.
    if (!extend and !r.isEmpty() and (g == .char or g == .word or g == .subword)) {
        return .collapsed(switch (dir) {
            .backward => r.start(),
            .forward => r.end(),
        });
    }

    switch (g) {
        .char => return r.withHead(switch (dir) {
            .backward => charLeft(text, head),
            .forward => charRight(text, head),
        }, extend),

        .word => return r.withHead(switch (dir) {
            .backward => wordLeft(text, head),
            .forward => wordRight(text, head),
        }, extend),

        .subword => return r.withHead(switch (dir) {
            .backward => subwordLeft(text, head),
            .forward => subwordRight(text, head),
        }, extend),

        .line_boundary => return r.withHead(switch (dir) {
            .backward => lineHomeSmart(text, head),
            .forward => lineEndOf(text, head),
        }, extend),

        .document => return r.withHead(switch (dir) {
            .backward => 0,
            .forward => text.len,
        }, extend),

        .line, .page => {
            const rows: i32 = if (g == .line) 1 else @intCast(opts.page_lines);
            const v = verticalMove(text, head, r.goal_col, rows * dir.sign(), opts);
            return r.withHeadKeepGoal(v.off, extend, v.goal_col);
        },
    }
}

// -- tests --------------------------------------------------------------------------------------

const t = std.testing;

test "char motion steps whole codepoints" {
    const text = "aébc";
    try t.expectEqual(@as(usize, 1), charRight(text, 0));
    try t.expectEqual(@as(usize, 3), charRight(text, 1)); // over the 2-byte 'é'
    try t.expectEqual(@as(usize, 1), charLeft(text, 3));
    try t.expectEqual(@as(usize, 0), charLeft(text, 0));
    try t.expectEqual(@as(usize, text.len), charRight(text, text.len));
}

test "word motion is symmetric" {
    const text = "foo bar  baz";
    try t.expectEqual(@as(usize, 3), wordRight(text, 0));
    try t.expectEqual(@as(usize, 7), wordRight(text, 3));
    try t.expectEqual(@as(usize, 12), wordRight(text, 7));
    try t.expectEqual(@as(usize, 12), wordRight(text, 12));

    try t.expectEqual(@as(usize, 9), wordLeft(text, 12));
    try t.expectEqual(@as(usize, 4), wordLeft(text, 9));
    try t.expectEqual(@as(usize, 0), wordLeft(text, 4));
    try t.expectEqual(@as(usize, 0), wordLeft(text, 0));
}

test "underscore is a word character, punctuation is its own class" {
    const text = "snake_case+other";
    try t.expectEqual(@as(usize, 10), wordRight(text, 0)); // whole snake_case
    try t.expectEqual(@as(usize, 11), wordRight(text, 10)); // the '+' alone
    try t.expectEqual(@as(usize, 16), wordRight(text, 11));
}

test "word motion crosses newlines" {
    const text = "ab\n\ncd";
    try t.expectEqual(@as(usize, 2), wordRight(text, 0));
    try t.expectEqual(@as(usize, 6), wordRight(text, 2));
    try t.expectEqual(@as(usize, 0), wordLeft(text, 4));
}

test "subword stops at underscores and camel humps" {
    //             0    5     11   16    21
    const text = "snake_case camelCase HTTPServer";
    try t.expectEqual(@as(usize, 5), subwordRight(text, 0)); // "snake"
    try t.expectEqual(@as(usize, 10), subwordRight(text, 5)); // "_case"
    try t.expectEqual(@as(usize, 16), subwordRight(text, 10)); // "camel"
    try t.expectEqual(@as(usize, 20), subwordRight(text, 16)); // "Case"
    try t.expectEqual(@as(usize, 25), subwordRight(text, 20)); // "HTTP" — acronym rule
    try t.expectEqual(@as(usize, 31), subwordRight(text, 25)); // "Server"

    try t.expectEqual(@as(usize, 25), subwordLeft(text, 31)); // start of "Server"
    try t.expectEqual(@as(usize, 21), subwordLeft(text, 25)); // start of "HTTP"
    try t.expectEqual(@as(usize, 16), subwordLeft(text, 21)); // start of "Case"
    try t.expectEqual(@as(usize, 11), subwordLeft(text, 16)); // start of "camel"
    try t.expectEqual(@as(usize, 5), subwordLeft(text, 11)); // start of "_case"
    try t.expectEqual(@as(usize, 0), subwordLeft(text, 5)); // start of "snake"
}

test "subword never crosses a word boundary that word motion wouldn't" {
    const text = "alpha_beta gammaDelta";
    var i: usize = 0;
    var guard: usize = 0;
    while (i < text.len and guard < 50) : (guard += 1) {
        const next = subwordRight(text, i);
        try t.expect(next > i); // always makes progress
        try t.expect(next <= wordRight(text, i) or classOf(text[i]) == .space);
        i = next;
    }
    try t.expectEqual(@as(usize, text.len), i);
}

test "subword handles punctuation and underscore runs" {
    try t.expectEqual(@as(usize, 2), subwordRight("a+b", 1)); // the '+' alone
    try t.expectEqual(@as(usize, 4), subwordRight("a__b", 1)); // "__b"
    try t.expectEqual(@as(usize, 1), subwordLeft("a__b", 4)); // symmetric within the word
}

test "smart home toggles between first non-blank and column zero" {
    const text = "    indented";
    try t.expectEqual(@as(usize, 4), lineHomeSmart(text, 8)); // from inside → first non-blank
    try t.expectEqual(@as(usize, 0), lineHomeSmart(text, 4)); // already there → column 0
    try t.expectEqual(@as(usize, 4), lineHomeSmart(text, 0)); // and back
}

test "line end stops before the newline" {
    const text = "abc\ndef";
    try t.expectEqual(@as(usize, 3), lineEndOf(text, 1));
    try t.expectEqual(@as(usize, 7), lineEndOf(text, 5));
}

test "vertical motion keeps the goal column across a short line" {
    // Columns:      0123456789
    const text = "long line\nab\nanother long\n";
    const opts: Opts = .{};

    // Start at column 8 on line 0.
    const d1 = verticalMove(text, 8, null, 1, opts);
    try t.expectEqual(@as(u32, 8), d1.goal_col);
    try t.expectEqual(@as(usize, 12), d1.off); // clamped to end of "ab"

    // Down again, carrying the goal column — must land back at column 8, not column 2.
    const d2 = verticalMove(text, d1.off, d1.goal_col, 1, opts);
    try t.expectEqual(@as(usize, 13 + 8), d2.off);
    try t.expectEqual(@as(u32, 8), d2.goal_col);
}

test "vertical motion past the ends clamps to the document" {
    const text = "abc\ndef";
    try t.expectEqual(@as(usize, 0), verticalMove(text, 1, null, -1, .{}).off);
    try t.expectEqual(@as(usize, text.len), verticalMove(text, 5, null, 1, .{}).off);
}

test "vertical motion respects tab stops" {
    const text = "\t\tx\nabcdefghi";
    const v = verticalMove(text, 2, null, 1, .{ .tab_size = 4 });
    try t.expectEqual(@as(u32, 8), v.goal_col);
    try t.expectEqual(@as(usize, 4 + 8), v.off);
}

test "move collapses a selection instead of stepping" {
    const text = "hello world";
    const sel: Range = .init(2, 7);
    try t.expectEqual(@as(usize, 2), move(text, sel, .char, .backward, false, .{}).head);
    try t.expectEqual(@as(usize, 7), move(text, sel, .char, .forward, false, .{}).head);
    // ...but shift-extends normally.
    try t.expectEqual(@as(usize, 8), move(text, sel, .char, .forward, true, .{}).head);
    try t.expectEqual(@as(usize, 2), move(text, sel, .char, .forward, true, .{}).anchor);
}

test "move clears goal_col on horizontal motion and keeps it on vertical" {
    const text = "abcdef\nghijkl";
    const r: Range = .{ .anchor = 3, .head = 3, .goal_col = 3 };
    try t.expectEqual(@as(?u32, null), move(text, r, .char, .forward, false, .{}).goal_col);
    try t.expectEqual(@as(?u32, 3), move(text, r, .line, .forward, false, .{}).goal_col);
}

// Repeated motion must be exactly N single motions — the property the old single-slot
// `sel_move` union broke when two key events landed in one frame.
test "repeated motions compose" {
    const text = "one two three four";
    var r: Range = .collapsed(0);
    for (0..3) |_| r = move(text, r, .word, .forward, false, .{});
    try t.expectEqual(@as(usize, 13), r.head);

    var back: Range = .collapsed(text.len);
    for (0..3) |_| back = move(text, back, .word, .backward, false, .{});
    try t.expectEqual(@as(usize, 4), back.head);
}

test "motion never lands mid-codepoint" {
    const text = "aéb→c\nxé\n→→";
    var prng: std.Random.DefaultPrng = .init(0xc0ffee);
    const rand = prng.random();

    const grans = [_]Granularity{ .char, .word, .subword, .line_boundary, .line, .page, .document };
    var iter: usize = 0;
    while (iter < 2000) : (iter += 1) {
        var r: Range = .collapsed(rand.uintAtMost(usize, text.len));
        r.head = alignToChar(text, r.head);
        r.anchor = r.head;
        for (0..4) |_| {
            const g = grans[rand.uintLessThan(usize, grans.len)];
            const dir: Dir = if (rand.boolean()) .forward else .backward;
            r = move(text, r, g, dir, rand.boolean(), .{});
            try t.expect(r.head <= text.len);
            try t.expect(r.anchor <= text.len);
            if (r.head < text.len) try t.expect(!isContinuation(text[r.head]));
            if (r.anchor < text.len) try t.expect(!isContinuation(text[r.anchor]));
        }
    }
}
