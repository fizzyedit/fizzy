//! A single caret plus its (possibly empty) selection.
//!
//! `anchor` is where the selection began, `head` is where the caret is now. Either may be
//! the smaller offset — selecting backwards is normal and has to round-trip, which is why
//! this is an anchor/head pair rather than dvui's ordered `start`/`end`/`cursor` triple.
//! `Selection.toDvui` does the lowering.

const std = @import("std");

const Range = @This();

anchor: usize,
head: usize,
/// Sticky target column for vertical motion, in **display** columns (tabs expanded, one
/// column per codepoint). Set on the first up/down of a run and preserved across subsequent
/// ones, so travelling down through a short line and back out doesn't lose the column.
/// Cleared by any horizontal motion or edit.
goal_col: ?u32 = null,

pub fn collapsed(off: usize) Range {
    return .{ .anchor = off, .head = off };
}

pub fn init(anchor: usize, head: usize) Range {
    return .{ .anchor = anchor, .head = head };
}

pub fn cursor(self: Range) usize {
    return self.head;
}

pub fn start(self: Range) usize {
    return @min(self.anchor, self.head);
}

pub fn end(self: Range) usize {
    return @max(self.anchor, self.head);
}

pub fn len(self: Range) usize {
    return self.end() - self.start();
}

pub fn isEmpty(self: Range) bool {
    return self.anchor == self.head;
}

pub fn contains(self: Range, off: usize) bool {
    return off >= self.start() and off < self.end();
}

/// Touching counts as overlapping — two carets that meet must merge into one, otherwise a
/// multi-cursor edit applies twice at the same spot.
pub fn overlaps(self: Range, other: Range) bool {
    return self.start() <= other.end() and other.start() <= self.end();
}

/// Move the caret to `head`. `extend` is the Shift modifier: false collapses the anchor
/// onto the new head, true leaves the anchor where it was.
pub fn withHead(self: Range, head: usize, extend: bool) Range {
    return .{
        .anchor = if (extend) self.anchor else head,
        .head = head,
        .goal_col = null,
    };
}

/// `withHead`, but preserving `goal_col` — used only by vertical motion, which is the one
/// caller that wants the sticky column to survive.
pub fn withHeadKeepGoal(self: Range, head: usize, extend: bool, goal_col: ?u32) Range {
    return .{
        .anchor = if (extend) self.anchor else head,
        .head = head,
        .goal_col = goal_col,
    };
}

pub fn merged(self: Range, other: Range) Range {
    const lo = @min(self.start(), other.start());
    const hi = @max(self.end(), other.end());
    // Keep the direction of whichever range's head sits at an extreme, so merging while
    // drag-selecting backwards doesn't silently flip the caret to the other end.
    const backwards = self.head <= self.anchor and other.head <= other.anchor;
    return if (backwards)
        .{ .anchor = hi, .head = lo }
    else
        .{ .anchor = lo, .head = hi };
}

test "start/end round-trip regardless of direction" {
    const fwd: Range = .init(2, 7);
    const back: Range = .init(7, 2);
    try std.testing.expectEqual(@as(usize, 2), fwd.start());
    try std.testing.expectEqual(@as(usize, 7), fwd.end());
    try std.testing.expectEqual(@as(usize, 2), back.start());
    try std.testing.expectEqual(@as(usize, 7), back.end());
    // `init` is (anchor, head) — a backwards selection has its caret at the *low* end.
    try std.testing.expectEqual(@as(usize, 2), back.cursor());
    try std.testing.expectEqual(@as(usize, 7), fwd.cursor());
}

test "withHead collapses unless extending" {
    const r: Range = .init(2, 7);
    try std.testing.expect(r.withHead(9, false).isEmpty());
    try std.testing.expectEqual(@as(usize, 2), r.withHead(9, true).anchor);
    try std.testing.expectEqual(@as(usize, 9), r.withHead(9, true).head);
}

test "withHead clears goal_col but withHeadKeepGoal does not" {
    const r: Range = .{ .anchor = 0, .head = 0, .goal_col = 12 };
    try std.testing.expectEqual(@as(?u32, null), r.withHead(4, false).goal_col);
    try std.testing.expectEqual(@as(?u32, 12), r.withHeadKeepGoal(4, false, 12).goal_col);
}

test "touching ranges overlap" {
    try std.testing.expect((Range.init(0, 3)).overlaps(.init(3, 6)));
    try std.testing.expect(!(Range.init(0, 3)).overlaps(.init(4, 6)));
}

test "merge preserves backwards direction" {
    const m = (Range.init(6, 3)).merged(.init(4, 1));
    try std.testing.expectEqual(@as(usize, 6), m.anchor);
    try std.testing.expectEqual(@as(usize, 1), m.head);
}
