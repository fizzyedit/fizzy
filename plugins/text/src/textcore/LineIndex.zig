//! Cached line-start offsets plus display-column math.
//!
//! Replaces the ad-hoc `std.mem.lastIndexOfScalar(u8, text[0..pos], '\n')` rescans sprinkled
//! through the editor, and the byte-based column arithmetic in `TextEntryWidget.insertIndent`
//! (`column = cursor - line_start`), which is wrong for tabs and for any non-ASCII line.
//!
//! Movement does *not* need this — with `break_lines = false` every motion is a local scan
//! (see `movement.zig`). This exists for the things that genuinely want random access by
//! line: line counts, goto-definition reveal, and the indent logic landing in step 4.

const std = @import("std");

const LineIndex = @This();

const Allocator = std.mem.Allocator;

/// Byte offset of the first character of each line. `starts[0]` is always 0, so this is
/// never empty for a valid index — `lineCount()` == `starts.len`.
starts: std.ArrayList(usize) = .empty,
tab_size: u8 = 4,

pub fn deinit(self: *LineIndex, gpa: Allocator) void {
    self.starts.deinit(gpa);
    self.* = .{};
}

/// Full O(n) rebuild — on load, and after a full-buffer replace.
pub fn rebuild(self: *LineIndex, gpa: Allocator, text: []const u8) !void {
    self.starts.clearRetainingCapacity();
    try self.starts.append(gpa, 0);
    for (text, 0..) |c, i| {
        if (c == '\n') try self.starts.append(gpa, i + 1);
    }
}

/// Incremental fixup after `text[pos..pos+removed_len]` was replaced by `inserted_len` bytes.
/// `text` must already be the post-edit buffer.
///
/// Only lines at or after the one containing `pos` can move, so entries up to and including
/// that line are kept verbatim, the edited span is rescanned, and the untouched tail is
/// shifted by the length delta.
pub fn applyEdit(
    self: *LineIndex,
    gpa: Allocator,
    text: []const u8,
    pos: usize,
    removed_len: usize,
    inserted_len: usize,
) !void {
    if (self.starts.items.len == 0) return self.rebuild(gpa, text);

    const first_line = self.lineOf(pos);
    const keep = first_line + 1;
    const old_removed_end = pos + removed_len;

    // Shifted tail: old line starts that survived the removal, in new coordinates. Collected
    // before truncating because the shift can be negative.
    var tail: std.ArrayList(usize) = .empty;
    defer tail.deinit(gpa);
    for (self.starts.items[keep..]) |s| {
        if (s > old_removed_end) {
            try tail.append(gpa, s + inserted_len - removed_len);
        }
    }

    self.starts.shrinkRetainingCapacity(keep);

    // Rescan from the start of the first affected line through the end of the inserted text.
    // Everything past that is unchanged and already accounted for by `tail`.
    const scan_from = self.starts.items[first_line];
    const scan_to = @min(pos + inserted_len, text.len);
    var i = scan_from;
    while (i < scan_to) : (i += 1) {
        if (text[i] == '\n') try self.starts.append(gpa, i + 1);
    }

    try self.starts.appendSlice(gpa, tail.items);
}

pub fn lineCount(self: LineIndex) usize {
    return @max(1, self.starts.items.len);
}

/// 0-based line containing byte offset `off`.
pub fn lineOf(self: LineIndex, off: usize) usize {
    const items = self.starts.items;
    if (items.len == 0) return 0;
    var lo: usize = 0;
    var hi: usize = items.len; // find greatest i with items[i] <= off
    while (lo + 1 < hi) {
        const mid = lo + (hi - lo) / 2;
        if (items[mid] <= off) lo = mid else hi = mid;
    }
    return lo;
}

pub fn lineStart(self: LineIndex, line: usize) usize {
    const items = self.starts.items;
    if (items.len == 0) return 0;
    return items[@min(line, items.len - 1)];
}

/// End of `line`, *excluding* its trailing newline.
pub fn lineEnd(self: LineIndex, text: []const u8, line: usize) usize {
    const items = self.starts.items;
    if (line + 1 < items.len) {
        const next = items[line + 1];
        return if (next > 0 and next - 1 <= text.len) next - 1 else text.len;
    }
    return text.len;
}

pub fn lineSlice(self: LineIndex, text: []const u8, line: usize) []const u8 {
    const s = self.lineStart(line);
    const e = self.lineEnd(text, line);
    if (s > text.len or e > text.len or s > e) return "";
    return text[s..e];
}

/// Display column of `off`: tabs advance to the next multiple of `tab_size`, and each
/// codepoint counts as one column (continuation bytes count as zero).
pub fn displayCol(self: LineIndex, text: []const u8, off: usize) u32 {
    return colBetween(text, self.lineStart(self.lineOf(off)), off, self.tab_size);
}

/// Nearest byte offset on `line` at or before display column `col`. Lands on a codepoint
/// boundary, and never past the line's end.
pub fn offsetAtCol(self: LineIndex, text: []const u8, line: usize, col: u32) usize {
    const s = self.lineStart(line);
    const e = self.lineEnd(text, line);
    return offsetAtColIn(text, s, e, col, self.tab_size);
}

/// Leading whitespace of the line containing `off`, as a slice *into `text`* — no fixed-size
/// buffer, so no silent truncation at depth (the current code caps at `[128]u8`).
pub fn indentOf(self: LineIndex, text: []const u8, off: usize) []const u8 {
    const line = self.lineOf(off);
    const s = self.lineStart(line);
    const e = self.lineEnd(text, line);
    var i = s;
    while (i < e and (text[i] == ' ' or text[i] == '\t')) : (i += 1) {}
    return text[s..i];
}

/// Width of that indent in display columns.
pub fn indentWidthOf(self: LineIndex, text: []const u8, off: usize) u32 {
    const ind = self.indentOf(text, off);
    return colBetween(ind, 0, ind.len, self.tab_size);
}

// -- shared column math, also used by movement.zig ------------------------------------------

/// Display columns spanned by `text[from..to]`, starting from column 0 at `from`.
pub fn colBetween(text: []const u8, from: usize, to: usize, tab_size: u8) u32 {
    const ts: u32 = if (tab_size == 0) 4 else tab_size;
    var col: u32 = 0;
    var i = from;
    const stop = @min(to, text.len);
    while (i < stop) : (i += 1) {
        const c = text[i];
        if (c == '\t') {
            col += ts - (col % ts);
        } else if (c & 0xC0 != 0x80) {
            col += 1; // codepoint start; continuation bytes add nothing
        }
    }
    return col;
}

/// Byte offset within `text[from..to]` at or before display column `col`.
pub fn offsetAtColIn(text: []const u8, from: usize, to: usize, col: u32, tab_size: u8) usize {
    const ts: u32 = if (tab_size == 0) 4 else tab_size;
    var cur: u32 = 0;
    var i = from;
    const stop = @min(to, text.len);
    while (i < stop) {
        if (cur >= col) return i;
        const c = text[i];
        if (c == '\t') {
            cur += ts - (cur % ts);
            i += 1;
        } else {
            cur += 1;
            i += 1;
            while (i < stop and text[i] & 0xC0 == 0x80) : (i += 1) {}
        }
    }
    return stop;
}

// -- tests ----------------------------------------------------------------------------------

test "rebuild records every line start" {
    const gpa = std.testing.allocator;
    var idx: LineIndex = .{};
    defer idx.deinit(gpa);
    try idx.rebuild(gpa, "abc\ndef\n\nghi");
    try std.testing.expectEqualSlices(usize, &.{ 0, 4, 8, 9 }, idx.starts.items);
    try std.testing.expectEqual(@as(usize, 4), idx.lineCount());
}

test "lineOf / lineStart / lineEnd" {
    const gpa = std.testing.allocator;
    const text = "abc\ndef\n\nghi";
    var idx: LineIndex = .{};
    defer idx.deinit(gpa);
    try idx.rebuild(gpa, text);

    try std.testing.expectEqual(@as(usize, 0), idx.lineOf(0));
    try std.testing.expectEqual(@as(usize, 0), idx.lineOf(3)); // the '\n' belongs to line 0
    try std.testing.expectEqual(@as(usize, 1), idx.lineOf(4));
    try std.testing.expectEqual(@as(usize, 3), idx.lineOf(11));

    try std.testing.expectEqual(@as(usize, 3), idx.lineEnd(text, 0));
    try std.testing.expectEqual(@as(usize, 8), idx.lineEnd(text, 2)); // empty line
    try std.testing.expectEqual(@as(usize, 12), idx.lineEnd(text, 3));
    try std.testing.expectEqualStrings("def", idx.lineSlice(text, 1));
    try std.testing.expectEqualStrings("", idx.lineSlice(text, 2));
}

test "displayCol expands tabs to the next tab stop" {
    const gpa = std.testing.allocator;
    const text = "\tab\tc";
    var idx: LineIndex = .{ .tab_size = 4 };
    defer idx.deinit(gpa);
    try idx.rebuild(gpa, text);

    try std.testing.expectEqual(@as(u32, 0), idx.displayCol(text, 0));
    try std.testing.expectEqual(@as(u32, 4), idx.displayCol(text, 1)); // past the tab
    try std.testing.expectEqual(@as(u32, 6), idx.displayCol(text, 3)); // past "ab"
    try std.testing.expectEqual(@as(u32, 8), idx.displayCol(text, 4)); // past the 2nd tab
}

test "displayCol counts codepoints, not bytes" {
    const gpa = std.testing.allocator;
    const text = "héllo"; // 'é' is two bytes
    var idx: LineIndex = .{};
    defer idx.deinit(gpa);
    try idx.rebuild(gpa, text);
    try std.testing.expectEqual(@as(u32, 5), idx.displayCol(text, text.len));
}

test "offsetAtCol lands on codepoint boundaries" {
    const gpa = std.testing.allocator;
    const text = "héllo";
    var idx: LineIndex = .{};
    defer idx.deinit(gpa);
    try idx.rebuild(gpa, text);

    try std.testing.expectEqual(@as(usize, 0), idx.offsetAtCol(text, 0, 0));
    try std.testing.expectEqual(@as(usize, 1), idx.offsetAtCol(text, 0, 1));
    try std.testing.expectEqual(@as(usize, 3), idx.offsetAtCol(text, 0, 2)); // skipped 'é'
    try std.testing.expectEqual(@as(usize, 6), idx.offsetAtCol(text, 0, 99)); // clamps
}

test "offsetAtCol clamps to line end, not document end" {
    const gpa = std.testing.allocator;
    const text = "ab\nlonger line";
    var idx: LineIndex = .{};
    defer idx.deinit(gpa);
    try idx.rebuild(gpa, text);
    try std.testing.expectEqual(@as(usize, 2), idx.offsetAtCol(text, 0, 40));
}

test "indentOf returns full indent without truncation" {
    const gpa = std.testing.allocator;
    var buf: [400]u8 = undefined;
    @memset(buf[0..300], ' ');
    @memcpy(buf[300..303], "abc");
    const text = buf[0..303];

    var idx: LineIndex = .{};
    defer idx.deinit(gpa);
    try idx.rebuild(gpa, text);
    try std.testing.expectEqual(@as(usize, 300), idx.indentOf(text, 302).len);
    try std.testing.expectEqual(@as(u32, 300), idx.indentWidthOf(text, 302));
}

// The important one: `applyEdit` must be indistinguishable from a full `rebuild` for any
// edit. Randomised so it covers newline insertion/removal at every position class.
test "applyEdit matches rebuild across random edits" {
    const gpa = std.testing.allocator;
    var prng: std.Random.DefaultPrng = .init(0x7e47c0de);
    const rand = prng.random();

    const inserts = [_][]const u8{ "", "x", "\n", "ab\ncd", "\n\n\n", "hello", "\nq" };

    var round: usize = 0;
    while (round < 400) : (round += 1) {
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(gpa);
        const seed_len = rand.uintLessThan(usize, 40);
        for (0..seed_len) |_| {
            try text.append(gpa, if (rand.uintLessThan(u8, 4) == 0) '\n' else 'a');
        }

        var incremental: LineIndex = .{};
        defer incremental.deinit(gpa);
        try incremental.rebuild(gpa, text.items);

        for (0..6) |_| {
            const pos = if (text.items.len == 0) 0 else rand.uintAtMost(usize, text.items.len);
            const max_rm = text.items.len - pos;
            const removed_len = if (max_rm == 0) 0 else rand.uintAtMost(usize, max_rm);
            const ins = inserts[rand.uintLessThan(usize, inserts.len)];

            try text.replaceRange(gpa, pos, removed_len, ins);
            try incremental.applyEdit(gpa, text.items, pos, removed_len, ins.len);

            var fresh: LineIndex = .{};
            defer fresh.deinit(gpa);
            try fresh.rebuild(gpa, text.items);

            std.testing.expectEqualSlices(usize, fresh.starts.items, incremental.starts.items) catch |err| {
                std.debug.print(
                    "round {d}: pos={d} removed={d} ins=\"{f}\" text=\"{f}\"\n",
                    .{ round, pos, removed_len, std.zig.fmtString(ins), std.zig.fmtString(text.items) },
                );
                return err;
            };
        }
    }
}
