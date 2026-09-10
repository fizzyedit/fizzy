//! Undo/redo history with VSCode-compatible grouping.
//!
//! The old `UndoStack` pushed one entry per widget mutation — i.e. one per keystroke — so undo
//! walked back a character at a time. VSCode instead groups by **operation-type run**: a run of
//! ordinary typing is one undo step, a run of spaces is another, and switching between typing
//! and deleting starts a new one. It is *not* grouped by word, and there is no timer or
//! character-count threshold anywhere in that path.
//!
//! `EditKind` and `shouldBreakGroup` below are a direct port of VSCode's `EditOperationType`,
//! `getTypingOperation` and `shouldPushStackElementBetween`
//! (src/vs/editor/common/cursor/cursorTypeEditOperations.ts). The comments marked "VSCode:" quote
//! that source, including its worked examples.

const std = @import("std");
const Range = @import("Range.zig");
const Transaction = @import("Transaction.zig");

const History = @This();

const Allocator = std.mem.Allocator;

/// VSCode's `EditOperationType`. The numeric values don't matter to us, but the *set* does —
/// the grouping rule is defined entirely in terms of these categories.
pub const EditKind = enum {
    /// Anything that isn't simple typing or deleting: paste, Enter, replace-selection,
    /// a command-driven edit. Always breaks the group.
    other,
    deleting_left,
    deleting_right,
    typing_other,
    typing_first_space,
    typing_consecutive_space,

    fn isTyping(self: EditKind) bool {
        return switch (self) {
            .typing_other, .typing_first_space, .typing_consecutive_space => true,
            else => false,
        };
    }

    /// VSCode's `normalizeOperationType`: both space kinds collapse to one category, so a run
    /// of spaces stays a single group.
    fn normalized(self: EditKind) EditKind {
        return switch (self) {
            .typing_first_space, .typing_consecutive_space => .typing_first_space,
            else => self,
        };
    }
};

/// Classify one captured edit. `cursor_before` is the caret position before the edit, used only
/// to tell a backspace (removes behind the caret) from a forward delete.
pub fn classify(
    removed: []const u8,
    inserted: []const u8,
    pos: usize,
    cursor_before: usize,
    prev: EditKind,
) EditKind {
    // A replacement (typing over a selection) is never plain typing.
    if (removed.len > 0 and inserted.len > 0) return .other;

    if (inserted.len > 0) {
        // Multi-character insertions are pastes, snippet expansions, or Enter-with-indent —
        // all "other", so they bracket cleanly in the undo history.
        const seq_len = std.unicode.utf8ByteSequenceLength(inserted[0]) catch return .other;
        if (seq_len != inserted.len) return .other;
        // VSCode routes Enter through its own operation, which reports `Other` and therefore
        // always opens a new undo step. Matching that means Enter is an undo boundary.
        if (inserted[0] == '\n' or inserted[0] == '\r') return .other;

        if (inserted.len == 1 and inserted[0] == ' ') {
            // VSCode's `getTypingOperation`.
            return switch (prev) {
                .typing_first_space, .typing_consecutive_space => .typing_consecutive_space,
                else => .typing_first_space,
            };
        }
        return .typing_other;
    }

    if (removed.len > 0) {
        return if (pos < cursor_before) .deleting_left else .deleting_right;
    }
    return .other;
}

/// VSCode's `shouldPushStackElementBetween`: true when `cur` must start a NEW undo step rather
/// than joining the group `prev` belongs to.
pub fn shouldBreakGroup(prev: EditKind, cur: EditKind) bool {
    if (prev.isTyping() and !cur.isTyping()) {
        // VSCode: "Always set an undo stop before non-type operations"
        return true;
    }
    if (prev == .typing_first_space) {
        // VSCode: `abc |d`: No undo stop
        //         `abc  |d`: Undo stop
        // One space keeps the run open; a second one closes it. This single rule is what makes
        // undo *feel* word-granular without ever looking at word boundaries.
        return false;
    }
    // VSCode: "Insert undo stop between different operation types"
    return prev.normalized() != cur.normalized();
}

const Entry = struct {
    txn: Transaction,
    kind: EditKind,
    /// Bumped on every mutation, including a merge into an existing entry. Dirty-tracking
    /// compares this against `Document.clean_op_id`, so it must change whenever the buffer
    /// changes — a merge that left the id alone would make a modified document look saved.
    id: u64,

    fn deinit(self: *Entry, gpa: Allocator) void {
        self.txn.deinit(gpa);
    }
};

undo_stack: std.ArrayList(Entry) = .empty,
redo_stack: std.ArrayList(Entry) = .empty,
/// The in-progress edit opened by `begin`.
pending: ?struct {
    txn: Transaction,
    cursor_before: usize,
} = null,
/// False right after undo/redo/save/an out-of-band edit: the next captured edit must start a
/// fresh group rather than merging into whatever is on top.
group_open: bool = false,
next_id: u64 = 1,

pub fn deinit(self: *History, gpa: Allocator) void {
    for (self.undo_stack.items) |*e| e.deinit(gpa);
    self.undo_stack.deinit(gpa);
    for (self.redo_stack.items) |*e| e.deinit(gpa);
    self.redo_stack.deinit(gpa);
    if (self.pending) |*p| p.txn.deinit(gpa);
    self.* = .{};
}

pub fn canUndo(self: History) bool {
    return self.undo_stack.items.len > 0;
}

pub fn canRedo(self: History) bool {
    return self.redo_stack.items.len > 0;
}

/// Id of the entry on top of the undo stack, or 0 when empty. See `Entry.id`.
pub fn topOpId(self: History) u64 {
    const items = self.undo_stack.items;
    return if (items.len == 0) 0 else items[items.len - 1].id;
}

/// Close the current group so the next edit starts a new undo step. Called after undo, redo,
/// and on save — VSCode likewise pushes a stack element when a model is saved, without which a
/// save landing mid-group would make undo jump straight past the saved state.
pub fn closeGroup(self: *History) void {
    self.group_open = false;
}

// -- capture ------------------------------------------------------------------------------------

pub fn begin(self: *History, sel_before: Range) void {
    self.pending = .{
        .txn = .{ .sel_before = sel_before, .sel_after = sel_before },
        .cursor_before = sel_before.head,
    };
}

pub fn note(
    self: *History,
    gpa: Allocator,
    pos: usize,
    removed: []const u8,
    inserted: []const u8,
) void {
    const p = if (self.pending) |*p| p else return;
    p.txn.append(gpa, pos, removed, inserted) catch |err| {
        std.log.err("History.note: dropping {d}+{d} bytes: {s}", .{
            removed.len, inserted.len, @errorName(err),
        });
    };
}

/// Commit the pending edit, merging it into the current group when VSCode's rule says to.
pub fn end(self: *History, gpa: Allocator, sel_after: Range) void {
    var p = self.pending orelse return;
    self.pending = null;

    if (p.txn.isEmpty()) {
        p.txn.deinit(gpa);
        return;
    }
    p.txn.sel_after = sel_after;

    // Classify from the net effect of the pending edit.
    var removed_total: []const u8 = &.{};
    var inserted_total: []const u8 = &.{};
    var pos: usize = 0;
    if (p.txn.edits.items.len > 0) {
        const first = p.txn.edits.items[0];
        pos = first.pos;
        removed_total = first.removed;
        inserted_total = first.inserted;
        // A single widget mutation reports at most one removal + one insertion; if it somehow
        // reported more, that's compound and shouldn't be treated as plain typing.
        if (p.txn.edits.items.len > 1) {
            for (p.txn.edits.items[1..]) |e| {
                if (e.removed.len > 0) removed_total = e.removed;
                if (e.inserted.len > 0) inserted_total = e.inserted;
            }
        }
    }
    const prev_kind: EditKind = if (self.group_open and self.undo_stack.items.len > 0)
        self.undo_stack.items[self.undo_stack.items.len - 1].kind
    else
        .other;
    const kind = classify(removed_total, inserted_total, pos, p.cursor_before, prev_kind);

    self.clearRedo(gpa);

    const can_merge = self.group_open and
        self.undo_stack.items.len > 0 and
        !shouldBreakGroup(prev_kind, kind);

    if (can_merge) {
        var top = &self.undo_stack.items[self.undo_stack.items.len - 1];
        // Move the pending edits onto the existing group; the group keeps its original
        // `sel_before` so undo returns to where the whole run started.
        for (p.txn.edits.items) |e| {
            top.txn.edits.append(gpa, e) catch |err| {
                std.log.err("History.end: merge failed: {s}", .{@errorName(err)});
                var owned = e;
                owned.deinit(gpa);
                continue;
            };
        }
        p.txn.edits.clearRetainingCapacity();
        p.txn.deinit(gpa);
        top.txn.sel_after = sel_after;
        top.kind = kind;
        top.id = self.next_id;
        self.next_id += 1;
    } else {
        self.undo_stack.append(gpa, .{
            .txn = p.txn,
            .kind = kind,
            .id = self.next_id,
        }) catch |err| {
            std.log.err("History.end: push failed: {s}", .{@errorName(err)});
            p.txn.deinit(gpa);
            return;
        };
        self.next_id += 1;
    }
    self.group_open = true;
}

/// Record one complete edit built outside the begin/note/end flow (the paste command). Always
/// its own undo step.
pub fn pushComplete(
    self: *History,
    gpa: Allocator,
    pos: usize,
    removed: []const u8,
    inserted: []const u8,
    sel_before: Range,
    sel_after: Range,
) !void {
    var txn: Transaction = .{ .sel_before = sel_before, .sel_after = sel_after };
    errdefer txn.deinit(gpa);
    try txn.append(gpa, pos, removed, inserted);
    if (txn.isEmpty()) {
        txn.deinit(gpa);
        return;
    }
    self.clearRedo(gpa);
    try self.undo_stack.append(gpa, .{ .txn = txn, .kind = .other, .id = self.next_id });
    self.next_id += 1;
    self.group_open = false;
}

fn clearRedo(self: *History, gpa: Allocator) void {
    for (self.redo_stack.items) |*e| e.deinit(gpa);
    self.redo_stack.clearRetainingCapacity();
}

// -- replay ---------------------------------------------------------------------------------------

/// Undo one group. Returns the selection to restore, or null if there was nothing to undo.
pub fn applyUndo(self: *History, gpa: Allocator, text: *std.ArrayList(u8)) ?Range {
    if (self.undo_stack.items.len == 0) return null;
    var entry = self.undo_stack.pop().?;
    entry.txn.applyInverse(gpa, text) catch |err| {
        // Don't push the entry back: a desynced transaction will never become valid, and
        // `fizzy.undo` accepts key-repeat — re-queueing would spam `EditOutOfRange` forever
        // while the user holds ⌘Z. Drop it and let a later undo try the next group.
        std.log.err("History.applyUndo failed: {s} (dropping corrupt undo entry)", .{@errorName(err)});
        entry.deinit(gpa);
        self.group_open = false;
        return null;
    };
    const sel = entry.txn.sel_before;
    self.redo_stack.append(gpa, entry) catch |err| {
        std.log.err("History.applyUndo: redo push failed: {s}", .{@errorName(err)});
        entry.deinit(gpa);
    };
    self.group_open = false;
    return sel;
}

pub fn applyRedo(self: *History, gpa: Allocator, text: *std.ArrayList(u8)) ?Range {
    if (self.redo_stack.items.len == 0) return null;
    var entry = self.redo_stack.pop().?;
    entry.txn.applyForward(gpa, text) catch |err| {
        std.log.err("History.applyRedo failed: {s} (dropping corrupt redo entry)", .{@errorName(err)});
        entry.deinit(gpa);
        self.group_open = false;
        return null;
    };
    const sel = entry.txn.sel_after;
    self.undo_stack.append(gpa, entry) catch |err| {
        std.log.err("History.applyRedo: undo push failed: {s}", .{@errorName(err)});
        entry.deinit(gpa);
    };
    self.group_open = false;
    return sel;
}

// -- tests ---------------------------------------------------------------------------------------

const t = std.testing;

test "VSCode grouping rule: table" {
    // Typing runs merge.
    try t.expect(!shouldBreakGroup(.typing_other, .typing_other));
    // Typing → deleting breaks ("always an undo stop before non-type operations").
    try t.expect(shouldBreakGroup(.typing_other, .deleting_left));
    // Deleting runs merge, but left/right are different runs.
    try t.expect(!shouldBreakGroup(.deleting_left, .deleting_left));
    try t.expect(shouldBreakGroup(.deleting_left, .deleting_right));
    // `abc |d` — one space keeps the run open.
    try t.expect(!shouldBreakGroup(.typing_first_space, .typing_other));
    // `abc  |d` — a second space closes it.
    try t.expect(shouldBreakGroup(.typing_consecutive_space, .typing_other));
    // Both space kinds are one category.
    try t.expect(!shouldBreakGroup(.typing_first_space, .typing_consecutive_space));
    try t.expect(!shouldBreakGroup(.typing_consecutive_space, .typing_consecutive_space));
    // Anything after an `other` starts fresh.
    try t.expect(shouldBreakGroup(.other, .typing_other));
}

test "classify" {
    try t.expectEqual(EditKind.typing_other, classify("", "a", 0, 0, .other));
    try t.expectEqual(EditKind.typing_first_space, classify("", " ", 0, 0, .typing_other));
    try t.expectEqual(EditKind.typing_consecutive_space, classify("", " ", 0, 0, .typing_first_space));
    // Enter is always a boundary.
    try t.expectEqual(EditKind.other, classify("", "\n", 0, 0, .typing_other));
    // Multi-char insert = paste.
    try t.expectEqual(EditKind.other, classify("", "hello", 0, 0, .typing_other));
    // A multi-byte codepoint is still one typed character.
    try t.expectEqual(EditKind.typing_other, classify("", "é", 0, 0, .typing_other));
    // Deletion direction from the caret.
    try t.expectEqual(EditKind.deleting_left, classify("a", "", 4, 5, .other));
    try t.expectEqual(EditKind.deleting_right, classify("a", "", 5, 5, .other));
    // Typing over a selection is a replacement.
    try t.expectEqual(EditKind.other, classify("sel", "x", 0, 3, .typing_other));
}

/// Drives the history the way the widget does, so the tests read like real editing sessions.
const Harness = struct {
    gpa: Allocator,
    text: std.ArrayList(u8) = .empty,
    hist: History = .{},
    cursor: usize = 0,

    fn deinit(self: *Harness) void {
        self.text.deinit(self.gpa);
        self.hist.deinit(self.gpa);
    }

    fn type_(self: *Harness, s: []const u8) !void {
        var it = (try std.unicode.Utf8View.init(s)).iterator();
        while (it.nextCodepointSlice()) |ch| {
            self.hist.begin(.collapsed(self.cursor));
            try self.text.insertSlice(self.gpa, self.cursor, ch);
            self.hist.note(self.gpa, self.cursor, "", ch);
            self.cursor += ch.len;
            self.hist.end(self.gpa, .collapsed(self.cursor));
        }
    }

    fn backspace(self: *Harness, n: usize) !void {
        for (0..n) |_| {
            if (self.cursor == 0) return;
            self.hist.begin(.collapsed(self.cursor));
            const removed = self.text.items[self.cursor - 1 .. self.cursor];
            self.hist.note(self.gpa, self.cursor - 1, removed, "");
            try self.text.replaceRange(self.gpa, self.cursor - 1, 1, "");
            self.cursor -= 1;
            self.hist.end(self.gpa, .collapsed(self.cursor));
        }
    }

    fn undo(self: *Harness) ?Range {
        const sel = self.hist.applyUndo(self.gpa, &self.text) orelse return null;
        self.cursor = @min(sel.head, self.text.items.len);
        return sel;
    }
    fn redo(self: *Harness) ?Range {
        const sel = self.hist.applyRedo(self.gpa, &self.text) orelse return null;
        self.cursor = @min(sel.head, self.text.items.len);
        return sel;
    }
    fn steps(self: Harness) usize {
        return self.hist.undo_stack.items.len;
    }
};

test "a run of typing is one undo step" {
    var h: Harness = .{ .gpa = t.allocator };
    defer h.deinit();

    try h.type_("hello");
    try t.expectEqual(@as(usize, 1), h.steps());
    _ = h.undo();
    try t.expectEqualStrings("", h.text.items);
}

// This is the rule that produces word-granular undo. A space *opens* a new group, and the
// character after a single space *joins* it — so each group is "leading space + word", and one
// undo takes back exactly one word.
test "typing groups as space-plus-word" {
    var h: Harness = .{ .gpa = t.allocator };
    defer h.deinit();

    try h.type_("the quick brown");
    try t.expectEqual(@as(usize, 3), h.steps()); // "the" / " quick" / " brown"

    _ = h.undo();
    try t.expectEqualStrings("the quick", h.text.items);
    _ = h.undo();
    try t.expectEqualStrings("the", h.text.items);
    _ = h.undo();
    try t.expectEqualStrings("", h.text.items);
}

test "a second consecutive space closes the run" {
    var h: Harness = .{ .gpa = t.allocator };
    defer h.deinit();

    // VSCode: `abc |d` no undo stop, `abc  |d` undo stop. So the double space is its own
    // group and "def" starts another.
    try h.type_("abc  def");
    try t.expectEqual(@as(usize, 3), h.steps()); // "abc" / "  " / "def"
    _ = h.undo();
    try t.expectEqualStrings("abc  ", h.text.items);
    _ = h.undo();
    try t.expectEqualStrings("abc", h.text.items);
}

test "typing then deleting are separate steps" {
    var h: Harness = .{ .gpa = t.allocator };
    defer h.deinit();

    try h.type_("hello");
    try h.backspace(2);
    try t.expectEqual(@as(usize, 2), h.steps());

    _ = h.undo();
    try t.expectEqualStrings("hello", h.text.items); // the deletions unwind together
    _ = h.undo();
    try t.expectEqualStrings("", h.text.items);
}

test "Enter is an undo boundary" {
    var h: Harness = .{ .gpa = t.allocator };
    defer h.deinit();

    try h.type_("abc");
    try h.type_("\n");
    try h.type_("def");
    try t.expectEqual(@as(usize, 3), h.steps());
    _ = h.undo();
    try t.expectEqualStrings("abc\n", h.text.items);
}

test "undo restores the selection, not just an offset" {
    const a = t.allocator;
    var hist: History = .{};
    defer hist.deinit(a);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(a);
    try text.appendSlice(a, "hello world");

    // Type "X" over the selected "world".
    hist.begin(.init(6, 11));
    hist.note(a, 6, "world", "X");
    try text.replaceRange(a, 6, 5, "X");
    hist.end(a, .collapsed(7));

    const sel = hist.applyUndo(a, &text).?;
    try t.expectEqualStrings("hello world", text.items);
    try t.expectEqual(@as(usize, 6), sel.start());
    try t.expectEqual(@as(usize, 11), sel.end());
}

test "redo replays the group and restores the after-selection" {
    var h: Harness = .{ .gpa = t.allocator };
    defer h.deinit();

    try h.type_("hello");
    _ = h.undo();
    try t.expectEqualStrings("", h.text.items);
    const sel = h.redo().?;
    try t.expectEqualStrings("hello", h.text.items);
    try t.expectEqual(@as(usize, 5), sel.head);
}

test "closeGroup makes the next edit start a new step (the save case)" {
    var h: Harness = .{ .gpa = t.allocator };
    defer h.deinit();

    try h.type_("abc");
    try t.expectEqual(@as(usize, 1), h.steps());
    const saved_id = h.hist.topOpId();

    h.hist.closeGroup(); // as Document.save() will do
    try h.type_("def");
    try t.expectEqual(@as(usize, 2), h.steps());
    // The saved state is still reachable by exactly one undo.
    _ = h.undo();
    try t.expectEqualStrings("abc", h.text.items);
    try t.expectEqual(saved_id, h.hist.topOpId());
}

test "merging still bumps the id so dirty tracking stays correct" {
    var h: Harness = .{ .gpa = t.allocator };
    defer h.deinit();

    try h.type_("ab");
    const id_after_save = h.hist.topOpId();
    try h.type_("c"); // merges into the same group
    try t.expectEqual(@as(usize, 1), h.steps());
    try t.expect(h.hist.topOpId() != id_after_save);
}

test "a new edit after undo clears the redo stack" {
    var h: Harness = .{ .gpa = t.allocator };
    defer h.deinit();

    try h.type_("abc");
    _ = h.undo();
    try t.expect(h.hist.canRedo());
    try h.type_("z");
    try t.expect(!h.hist.canRedo());
}

test "undo/redo round-trips a long mixed session" {
    var h: Harness = .{ .gpa = t.allocator };
    defer h.deinit();

    try h.type_("the quick");
    try h.backspace(3);
    try h.type_("ck brown fox");
    try h.type_("\n");
    try h.type_("second line");
    const final = try t.allocator.dupe(u8, h.text.items);
    defer t.allocator.free(final);

    const depth = h.steps();
    for (0..depth) |_| _ = h.undo();
    try t.expectEqualStrings("", h.text.items);
    for (0..depth) |_| _ = h.redo();
    try t.expectEqualStrings(final, h.text.items);
}

test "cut-shaped deletion is one undoable step" {
    // Widget cut now goes through begin/noteRemoved/end — same capture shape as this.
    var h: Harness = .{ .gpa = t.allocator };
    defer h.deinit();

    try h.type_("hello world");
    // Cut "world": delete [6, 11).
    h.hist.begin(.init(6, 11));
    h.hist.note(h.gpa, 6, "world", "");
    try h.text.replaceRange(h.gpa, 6, 5, "");
    h.cursor = 6;
    h.hist.end(h.gpa, .collapsed(6));

    try t.expectEqualStrings("hello ", h.text.items);
    _ = h.undo();
    try t.expectEqualStrings("hello world", h.text.items);
}
