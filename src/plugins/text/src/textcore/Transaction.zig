//! One undoable unit of change: an ordered list of edits plus the selection either side of it.
//!
//! **Coordinate convention: sequential, not pre-transaction.** Each `Edit.pos` is valid at the
//! moment that edit was applied, i.e. after every edit before it in the list. That's the right
//! convention here because these are captured *after the fact* from the editing widget's own
//! mutations, so the offsets we're handed are already sequential — normalizing them to
//! pre-transaction coordinates would mean undoing arithmetic we'd only redo on replay. (A
//! future `Builder` for edits composed *ahead* of application — multi-cursor, refactors —
//! wants the opposite convention and gets its own type; the two must not be confused.)
//!
//! Replay is therefore: forward in order, inverse in reverse order.

const std = @import("std");
const Range = @import("Range.zig");

const Transaction = @This();

const Allocator = std.mem.Allocator;

pub const Edit = struct {
    pos: usize,
    /// Bytes that were at `pos` before this edit (owned).
    removed: []u8 = &.{},
    /// Bytes that replaced them (owned).
    inserted: []u8 = &.{},

    pub fn deinit(self: *Edit, gpa: Allocator) void {
        gpa.free(self.removed);
        gpa.free(self.inserted);
        self.* = .{ .pos = 0 };
    }
};

edits: std.ArrayList(Edit) = .empty,
/// Selection before the first edit — restored on undo. The old `UndoStack` could only return a
/// single guessed offset, so undoing a "type over a selection" lost the selection entirely.
sel_before: Range = .collapsed(0),
/// Selection after the last edit — restored on redo.
sel_after: Range = .collapsed(0),

pub fn deinit(self: *Transaction, gpa: Allocator) void {
    for (self.edits.items) |*e| e.deinit(gpa);
    self.edits.deinit(gpa);
    self.* = .{};
}

pub fn isEmpty(self: Transaction) bool {
    for (self.edits.items) |e| {
        if (e.removed.len != 0 or e.inserted.len != 0) return false;
    }
    return true;
}

/// Append one edit, taking copies of both byte slices.
pub fn append(
    self: *Transaction,
    gpa: Allocator,
    pos: usize,
    removed: []const u8,
    inserted: []const u8,
) !void {
    const removed_copy = try gpa.dupe(u8, removed);
    errdefer gpa.free(removed_copy);
    const inserted_copy = try gpa.dupe(u8, inserted);
    errdefer gpa.free(inserted_copy);
    try self.edits.append(gpa, .{
        .pos = pos,
        .removed = removed_copy,
        .inserted = inserted_copy,
    });
}

/// Re-apply (redo): forward, in order. Either the whole transaction lands or the buffer is
/// left unchanged — a mid-list failure used to leave a half-applied state that made every
/// subsequent undo retry hit `EditOutOfRange`.
pub fn applyForward(self: Transaction, gpa: Allocator, text: *std.ArrayList(u8)) !void {
    var applied: usize = 0;
    errdefer {
        // Roll back the prefix we already applied (inverse, newest-first).
        var j = applied;
        while (j > 0) {
            j -= 1;
            const e = self.edits.items[j];
            text.replaceRange(gpa, e.pos, e.inserted.len, e.removed) catch {};
        }
    }
    for (self.edits.items) |e| {
        if (e.pos > text.items.len) return error.EditOutOfRange;
        if (e.pos + e.removed.len > text.items.len) return error.EditOutOfRange;
        try text.replaceRange(gpa, e.pos, e.removed.len, e.inserted);
        applied += 1;
    }
}

/// Reverse (undo): inverse of each edit, walked backwards so every `pos` is valid again as we
/// reach it. Atomic with respect to the buffer — see `applyForward`.
pub fn applyInverse(self: Transaction, gpa: Allocator, text: *std.ArrayList(u8)) !void {
    var applied: usize = 0;
    errdefer {
        // Re-forward the suffix we already inverted (oldest-of-suffix first).
        const start = self.edits.items.len - applied;
        for (self.edits.items[start..]) |e| {
            text.replaceRange(gpa, e.pos, e.removed.len, e.inserted) catch {};
        }
    }
    var i = self.edits.items.len;
    while (i > 0) {
        i -= 1;
        const e = self.edits.items[i];
        if (e.pos > text.items.len) return error.EditOutOfRange;
        if (e.pos + e.inserted.len > text.items.len) return error.EditOutOfRange;
        try text.replaceRange(gpa, e.pos, e.inserted.len, e.removed);
        applied += 1;
    }
}

// -- tests ------------------------------------------------------------------------------------

const t = std.testing;

fn listOf(gpa: Allocator, s: []const u8) !std.ArrayList(u8) {
    var l: std.ArrayList(u8) = .empty;
    try l.appendSlice(gpa, s);
    return l;
}

test "forward then inverse restores the original text" {
    const a = t.allocator;

    var txn: Transaction = .{};
    defer txn.deinit(a);
    try txn.append(a, 0, "", "hello");
    try txn.append(a, 5, "", " world");

    var text = try listOf(a, "");
    defer text.deinit(a);

    try txn.applyForward(a, &text);
    try t.expectEqualStrings("hello world", text.items);
    try txn.applyInverse(a, &text);
    try t.expectEqualStrings("", text.items);
}

test "inverse walks backwards so later edits unwind first" {
    const a = t.allocator;
    var text = try listOf(a, "abc");
    defer text.deinit(a);

    var txn: Transaction = .{};
    defer txn.deinit(a);
    // Simulate two sequential insertions as the widget would report them.
    try txn.append(a, 3, "", "d");
    try text.replaceRange(a, 3, 0, "d");
    try txn.append(a, 4, "", "e");
    try text.replaceRange(a, 4, 0, "e");
    try t.expectEqualStrings("abcde", text.items);

    try txn.applyInverse(a, &text);
    try t.expectEqualStrings("abc", text.items);
    try txn.applyForward(a, &text);
    try t.expectEqualStrings("abcde", text.items);
}

test "replacement edits round-trip" {
    const a = t.allocator;
    var text = try listOf(a, "the quick fox");
    defer text.deinit(a);

    var txn: Transaction = .{};
    defer txn.deinit(a);
    try txn.append(a, 4, "quick", "slow");
    try txn.applyForward(a, &text);
    try t.expectEqualStrings("the slow fox", text.items);
    try txn.applyInverse(a, &text);
    try t.expectEqualStrings("the quick fox", text.items);
}

test "isEmpty ignores no-op edits" {
    const a = t.allocator;
    var txn: Transaction = .{};
    defer txn.deinit(a);
    try t.expect(txn.isEmpty());
    try txn.append(a, 0, "", "");
    try t.expect(txn.isEmpty());
    try txn.append(a, 0, "", "x");
    try t.expect(!txn.isEmpty());
}

test "out-of-range edits error instead of corrupting the buffer" {
    const a = t.allocator;
    var text = try listOf(a, "ab");
    defer text.deinit(a);

    var txn: Transaction = .{};
    defer txn.deinit(a);
    try txn.append(a, 99, "", "x");
    try t.expectError(error.EditOutOfRange, txn.applyForward(a, &text));
    try t.expectEqualStrings("ab", text.items);
}

test "inverse failure rolls back a partially-applied group" {
    // Simulates the cut-without-history desync: a merged group whose later edits no longer
    // match the buffer. Without atomicity, undoing would strip the matching suffix and leave
    // the buffer half-rewound when the stale prefix fails.
    const a = t.allocator;
    var text = try listOf(a, "hello x");
    defer text.deinit(a);

    var txn: Transaction = .{};
    defer txn.deinit(a);
    // Stale "world" inserts that aren't in the buffer anymore…
    try txn.append(a, 6, "", "w");
    try txn.append(a, 7, "", "o");
    try txn.append(a, 8, "", "r");
    try txn.append(a, 9, "", "l");
    try txn.append(a, 10, "", "d");
    // …followed by a real "x" that is.
    try txn.append(a, 6, "", "x");

    try t.expectError(error.EditOutOfRange, txn.applyInverse(a, &text));
    try t.expectEqualStrings("hello x", text.items);
}

// Property: any sequence of random sequential edits round-trips exactly.
test "random edit sequences round-trip" {
    const a = t.allocator;
    var prng: std.Random.DefaultPrng = .init(0xbeefcafe);
    const rand = prng.random();
    const inserts = [_][]const u8{ "", "x", "\n", "ab", "hello", " " };

    var round: usize = 0;
    while (round < 300) : (round += 1) {
        var text = try listOf(a, "seed text\nsecond line");
        defer text.deinit(a);
        const original = try a.dupe(u8, text.items);
        defer a.free(original);

        var txn: Transaction = .{};
        defer txn.deinit(a);

        for (0..5) |_| {
            const pos = rand.uintAtMost(usize, text.items.len);
            const removed_len = rand.uintAtMost(usize, text.items.len - pos);
            const ins = inserts[rand.uintLessThan(usize, inserts.len)];
            try txn.append(a, pos, text.items[pos .. pos + removed_len], ins);
            try text.replaceRange(a, pos, removed_len, ins);
        }

        const after = try a.dupe(u8, text.items);
        defer a.free(after);

        try txn.applyInverse(a, &text);
        try t.expectEqualStrings(original, text.items);
        try txn.applyForward(a, &text);
        try t.expectEqualStrings(after, text.items);
    }
}
