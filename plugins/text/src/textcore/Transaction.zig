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
const EditKind = @import("History.zig").EditKind;

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

/// This transaction's undo as a transaction of its own (owned): its edits newest first, each
/// with `removed` and `inserted` swapped, and the selections swapped. Applying it forward is
/// `applyInverse`.
pub fn inverted(self: Transaction, gpa: Allocator) !Transaction {
    var out: Transaction = .{ .sel_before = self.sel_after, .sel_after = self.sel_before };
    errdefer out.deinit(gpa);
    try out.edits.ensureTotalCapacity(gpa, self.edits.items.len);
    var i = self.edits.items.len;
    while (i > 0) {
        i -= 1;
        const e = self.edits.items[i];
        try out.append(gpa, e.pos, e.inserted, e.removed);
    }
    return out;
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

// -- as a step --------------------------------------------------------------------------------

/// Edits as a recorded step's effect (`sdk.Step`, the text plugin's step format 2): what fizzy
/// keeps of a change to replay it. Every count and offset LEB128, then the bytes:
///
///   edits · per edit: pos, removed length, removed, inserted length, inserted · selection after:
///   anchor, head · label: kind, back_to + 1 (0: none)
///
/// `removed` is kept although a forward replay only needs its length: it is what makes a step
/// checkable (`applyStepTo` refuses one whose removed bytes are not there), and what lets a step
/// be reversed. `reverse` writes the edits' undo as a forward step: inverses, newest first, the
/// selection the undo restores in `sel`. The label is what the history entry was when the step
/// was reported (`History.EditKind`, and the step a jump went back to), so a history put back from
/// a track reads as it did (`Document.restoreHistory`). Format 1 was the same without it.
pub fn encodeStep(w: *std.Io.Writer, edits: []const Edit, sel: Range, reverse: bool, label: Label) std.Io.Writer.Error!void {
    try w.writeUleb128(edits.len);
    for (0..edits.len) |i| {
        const e = edits[if (reverse) edits.len - 1 - i else i];
        const removed = if (reverse) e.inserted else e.removed;
        const inserted = if (reverse) e.removed else e.inserted;
        try w.writeUleb128(e.pos);
        try w.writeUleb128(removed.len);
        try w.writeAll(removed);
        try w.writeUleb128(inserted.len);
        try w.writeAll(inserted);
    }
    try w.writeUleb128(sel.anchor);
    try w.writeUleb128(sel.head);
    try w.writeUleb128(@backingInt(label.kind));
    try w.writeUleb128(if (label.back_to) |b| b + 1 else 0);
}

/// What a step's history entry was, carried with its edits (`encodeStep`): how it reads on the
/// history line.
pub const Label = struct {
    kind: EditKind = .other,
    /// The step a jump went back to (`History` `back_to`), 0 before the first.
    back_to: ?u64 = null,
};

/// A step `encodeStep` wrote, read back without copying: slices of `bytes`.
pub const StepView = struct {
    bytes: []const u8,
    edits: usize,
    sel: Range,
    label: Label,

    pub const Error = error{BadStep};

    /// Read the step in `bytes`, checking it holds together, or `error.BadStep`.
    pub fn init(bytes: []const u8) Error!StepView {
        var r: std.Io.Reader = .fixed(bytes);
        const n = take(&r) catch return error.BadStep;
        for (0..n) |_| {
            _ = take(&r) catch return error.BadStep;
            for (0..2) |_| {
                const len = take(&r) catch return error.BadStep;
                r.discardAll(len) catch return error.BadStep;
            }
        }
        const anchor = take(&r) catch return error.BadStep;
        const head = take(&r) catch return error.BadStep;
        const kind = std.enums.fromInt(EditKind, take(&r) catch return error.BadStep) orelse return error.BadStep;
        const back = r.takeLeb128(u64) catch return error.BadStep;
        if (r.seek != bytes.len) return error.BadStep;
        return .{ .bytes = bytes, .edits = n, .sel = .init(anchor, head), .label = .{ .kind = kind, .back_to = if (back == 0) null else back - 1 } };
    }

    /// Each edit in order: `{ pos, removed, inserted }`, slices of the step's bytes.
    pub fn iterator(self: StepView) Iterator {
        var r: std.Io.Reader = .fixed(self.bytes);
        _ = take(&r) catch unreachable;
        return .{ .r = r, .left = self.edits };
    }

    pub const Iterator = struct {
        r: std.Io.Reader,
        left: usize,

        pub const Part = struct { pos: usize, removed: []const u8, inserted: []const u8 };

        pub fn next(it: *Iterator) ?Part {
            if (it.left == 0) return null;
            it.left -= 1;
            // `init` checked every length.
            const pos = take(&it.r) catch unreachable;
            const removed = it.r.take(take(&it.r) catch unreachable) catch unreachable;
            const inserted = it.r.take(take(&it.r) catch unreachable) catch unreachable;
            return .{ .pos = pos, .removed = removed, .inserted = inserted };
        }
    };

    fn take(r: *std.Io.Reader) !usize {
        return r.takeLeb128(usize);
    }
};

/// Apply a step to `text` forward as one transaction, which it returns (owned) for the history.
/// Every edit must find at its `pos` the bytes it says it removes, or `error.StepDoesNotApply`,
/// and `text` is left as it was.
pub fn applyStepTo(gpa: Allocator, text: *std.ArrayList(u8), step: StepView) !Transaction {
    var txn: Transaction = .{ .sel_after = step.sel };
    errdefer txn.deinit(gpa);
    var it = step.iterator();
    var first = true;
    while (it.next()) |e| {
        if (first) txn.sel_before = .collapsed(e.pos);
        first = false;
        try txn.append(gpa, e.pos, e.removed, e.inserted);
    }
    // Checked against the text as each edit reaches it, then applied atomically.
    var check: usize = 0;
    errdefer {
        // Undo the edits already applied, newest first.
        var j = check;
        while (j > 0) {
            j -= 1;
            const e = txn.edits.items[j];
            text.replaceRange(gpa, e.pos, e.inserted.len, e.removed) catch {};
        }
    }
    for (txn.edits.items) |e| {
        if (e.pos > text.items.len or e.removed.len > text.items.len - e.pos) return error.StepDoesNotApply;
        if (!std.mem.eql(u8, text.items[e.pos..][0..e.removed.len], e.removed)) return error.StepDoesNotApply;
        try text.replaceRange(gpa, e.pos, e.removed.len, e.inserted);
        check += 1;
    }
    return txn;
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

fn stepBytes(gpa: Allocator, edits: []const Edit, sel: Range, reverse: bool) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try encodeStep(&out.writer, edits, sel, reverse, .{ .kind = .deleting_left, .back_to = 0 });
    return out.toOwnedSlice();
}

test "a step replays its edits forward, and its reverse takes them back" {
    const a = t.allocator;
    var txn: Transaction = .{ .sel_before = .collapsed(5), .sel_after = .collapsed(12) };
    defer txn.deinit(a);
    try txn.append(a, 5, "", ", wide");
    try txn.append(a, 0, "hello", "HELLO");
    try txn.append(a, 12, "world", "wörld");

    var text = try listOf(a, "hello world");
    defer text.deinit(a);
    var original = try listOf(a, "hello world");
    defer original.deinit(a);

    const fwd = try stepBytes(a, txn.edits.items, txn.sel_after, false);
    defer a.free(fwd);
    var applied = try applyStepTo(a, &text, try .init(fwd));
    defer applied.deinit(a);
    try t.expectEqualStrings("HELLO, wide wörld", text.items);
    try t.expectEqual(txn.sel_after, applied.sel_after);
    // What the history keeps is the same edits: it undoes as the original would.
    try applied.applyInverse(a, &text);
    try t.expectEqualStrings("hello world", text.items);

    try txn.applyForward(a, &original);
    const back = try stepBytes(a, txn.edits.items, txn.sel_before, true);
    defer a.free(back);
    var undone = try applyStepTo(a, &original, try .init(back));
    defer undone.deinit(a);
    try t.expectEqualStrings("hello world", original.items);
    try t.expectEqual(txn.sel_before, undone.sel_after);
}

test "a step that does not fit the text is refused, and the text is left as it was" {
    const a = t.allocator;
    var txn: Transaction = .{};
    defer txn.deinit(a);
    try txn.append(a, 0, "ab", "x");
    try txn.append(a, 1, "cd", "y");
    const bytes = try stepBytes(a, txn.edits.items, .collapsed(2), false);
    defer a.free(bytes);

    // The first edit fits; the second finds other bytes. Nothing of either stays.
    var text = try listOf(a, "abXX");
    defer text.deinit(a);
    try t.expectError(error.StepDoesNotApply, applyStepTo(a, &text, try .init(bytes)));
    try t.expectEqualStrings("abXX", text.items);
    var short = try listOf(a, "a");
    defer short.deinit(a);
    try t.expectError(error.StepDoesNotApply, applyStepTo(a, &short, try .init(bytes)));
    try t.expectEqualStrings("a", short.items);
}

test "a damaged step is an error, never a crash" {
    const a = t.allocator;
    var txn: Transaction = .{};
    defer txn.deinit(a);
    try txn.append(a, 3, "abc", "défg");
    const bytes = try stepBytes(a, txn.edits.items, .init(1, 4), false);
    defer a.free(bytes);
    for (0..bytes.len) |n| try t.expectError(error.BadStep, StepView.init(bytes[0..n]));

    var prng: std.Random.DefaultPrng = .init(0x7e47);
    const r = prng.random();
    const copy = try a.dupe(u8, bytes);
    defer a.free(copy);
    for (0..4000) |_| {
        @memcpy(copy, bytes);
        copy[r.uintLessThan(usize, copy.len)] ^= @as(u8, 1) << r.int(u3);
        const view = StepView.init(copy) catch continue;
        var text = try listOf(a, "xyzabcxyz");
        defer text.deinit(a);
        var got = applyStepTo(a, &text, view) catch continue;
        got.deinit(a);
    }
}
