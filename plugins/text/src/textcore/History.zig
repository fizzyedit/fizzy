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

/// VSCode's `EditOperationType`: the grouping rule is defined entirely in terms of these
/// categories. Their values are the text plugin's step format (`Transaction.encodeStep`): a
/// recorded step names its kind by number, so a value never changes; a new kind takes the next.
pub const EditKind = enum(u8) {
    /// Anything that isn't simple typing or deleting: paste, Enter, replace-selection,
    /// a command-driven edit. Always breaks the group.
    other = 0,
    deleting_left = 1,
    deleting_right = 2,
    typing_other = 3,
    typing_first_space = 4,
    typing_consecutive_space = 5,

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
    /// The step's own id, given when it is pushed and kept through merges (unlike `id`): what a
    /// timeline names it by (`line`, `stepsTo`).
    step: u64,
    /// A step that takes another back, appended when an edit landed after going back
    /// (`keepGoneBack`): the step the jump went back to, 0 before the first.
    back_to: ?u64 = null,

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
/// Moves whenever the history does: a step pushed or merged into, undone or redone.
version: u64 = 0,

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

/// What a commit did to the history, for whoever records it (`sdk.Step`).
pub const Committed = struct {
    step: u64,
    /// It joined the step on top (a run of typing) rather than starting one.
    joined: bool,
    /// What this commit did: the whole step when it starts one, only the new part when it joins.
    /// Valid until the history next changes.
    edits: []const Transaction.Edit,
    sel_after: Range,
    /// How many steps had been gone back over (undone) when it landed: they are on the line
    /// again, followed by their reverses, just below it (`keepGoneBack`, `goneBack`).
    back: usize = 0,
};

/// A step as the history holds it: its id, its edits, and the selection either side. Valid until
/// the history next changes.
pub const StepRef = struct {
    step: u64,
    edits: []const Transaction.Edit,
    sel_before: Range,
    sel_after: Range,
    label: Transaction.Label,

    fn of(e: *const Entry) StepRef {
        return .{ .step = e.step, .edits = e.txn.edits.items, .sel_before = e.txn.sel_before, .sel_after = e.txn.sel_after, .label = .{ .kind = e.kind, .back_to = e.back_to } };
    }
};

/// The step `applyRedo` just put back: the last applied. Null when none is.
pub fn lastApplied(self: *const History) ?StepRef {
    const items = self.undo_stack.items;
    return if (items.len == 0) null else .of(&items[items.len - 1]);
}

/// The step `applyUndo` just took back: the next to redo. Null when there is none.
pub fn lastUndone(self: *const History) ?StepRef {
    const items = self.redo_stack.items;
    return if (items.len == 0) null else .of(&items[items.len - 1]);
}

/// Commit the pending edit, merging it into the current group when VSCode's rule says to and
/// `may_join` allows: false when the step on top is another hand's (`sdk.Host.mayMerge`), so one
/// hand's typing never joins another's run. Returns what it did, or null when there was nothing to
/// commit.
pub fn end(self: *History, gpa: Allocator, sel_after: Range, may_join: bool) ?Committed {
    var p = self.pending orelse return null;
    self.pending = null;

    if (p.txn.isEmpty()) {
        p.txn.deinit(gpa);
        return null;
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

    const back = self.keepGoneBack(gpa);

    const can_merge = back == 0 and may_join and self.group_open and
        self.undo_stack.items.len > 0 and
        !shouldBreakGroup(prev_kind, kind);

    var committed: Committed = undefined;
    if (can_merge) {
        var top = &self.undo_stack.items[self.undo_stack.items.len - 1];
        const first_new = top.txn.edits.items.len;
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
        committed = .{ .step = top.step, .joined = true, .edits = top.txn.edits.items[first_new..], .sel_after = sel_after };
    } else {
        self.undo_stack.append(gpa, .{
            .txn = p.txn,
            .kind = kind,
            .id = self.next_id,
            .step = self.next_id,
        }) catch |err| {
            std.log.err("History.end: push failed: {s}", .{@errorName(err)});
            p.txn.deinit(gpa);
            return null;
        };
        self.next_id += 1;
        const top = &self.undo_stack.items[self.undo_stack.items.len - 1];
        committed = .{ .step = top.step, .joined = false, .edits = top.txn.edits.items, .sel_after = sel_after, .back = back };
    }
    self.group_open = true;
    self.version += 1;
    return committed;
}

/// Record one complete edit built outside the begin/note/end flow (the paste command). Always
/// its own undo step. Null when it changed nothing.
pub fn pushComplete(
    self: *History,
    gpa: Allocator,
    pos: usize,
    removed: []const u8,
    inserted: []const u8,
    sel_before: Range,
    sel_after: Range,
) !?Committed {
    var txn: Transaction = .{ .sel_before = sel_before, .sel_after = sel_after };
    errdefer txn.deinit(gpa);
    try txn.append(gpa, pos, removed, inserted);
    if (txn.isEmpty()) {
        txn.deinit(gpa);
        return null;
    }
    return try self.push(gpa, txn, .other);
}

/// Take `txn`, already applied, as a step of its own, reading as `kind`: a recorded step played
/// into the document (`Transaction.applyStepTo`).
pub fn push(self: *History, gpa: Allocator, txn: Transaction, kind: EditKind) !Committed {
    const back = self.keepGoneBack(gpa);
    try self.undo_stack.append(gpa, .{ .txn = txn, .kind = kind, .id = self.next_id, .step = self.next_id });
    self.next_id += 1;
    self.group_open = false;
    self.version += 1;
    const top = &self.undo_stack.items[self.undo_stack.items.len - 1];
    return .{ .step = top.step, .joined = false, .edits = top.txn.edits.items, .sel_after = top.txn.sel_after, .back = back };
}

/// Going back is a step (`plans/HISTORY_TIMELINE_PLAN.md`): before an edit lands after going
/// back, the steps gone back over (the redo stack) go back on the line as they were, then each
/// one's reverse, newest first. The text is where it was gone back to, as before, but nothing on
/// the line is lost: dragging to a step gone back over brings it back like any other. Answers how
/// many steps were gone back over; the line grew by twice that. Out of memory, they are dropped,
/// as redo always was.
fn keepGoneBack(self: *History, gpa: Allocator) usize {
    const gone = self.redo_stack.items;
    if (gone.len == 0) return 0;
    const back_to: u64 = if (self.lastApplied()) |s| s.step else 0;
    kept: {
        const reverses = gpa.alloc(Transaction, gone.len) catch break :kept;
        defer gpa.free(reverses);
        // The redo stack holds the furthest step gone back over first: its reverse comes first.
        var made: usize = 0;
        for (gone, reverses) |e, *r| {
            r.* = e.txn.inverted(gpa) catch break;
            made += 1;
        }
        const room = if (made < gone.len) false else if (self.undo_stack.ensureUnusedCapacity(gpa, gone.len * 2)) true else |_| false;
        if (!room) {
            for (reverses[0..made]) |*r| r.deinit(gpa);
            break :kept;
        }
        const n = gone.len;
        // As they were, the nearest first.
        while (self.redo_stack.pop()) |e| self.undo_stack.appendAssumeCapacity(e);
        for (reverses) |r| {
            self.undo_stack.appendAssumeCapacity(.{ .txn = r, .kind = .other, .id = self.next_id, .step = self.next_id, .back_to = back_to });
            self.next_id += 1;
        }
        self.version += 1;
        return n;
    }
    std.log.err("History: the steps gone back over were dropped: out of memory", .{});
    for (self.redo_stack.items) |*e| e.deinit(gpa);
    self.redo_stack.clearRetainingCapacity();
    return 0;
}

/// Keep the line to `limit` steps (0 keeps every one): past it by some slack, the oldest go, down
/// to `limit`, in one move rather than a copy of the stack per step. Going back is a step, so the
/// line grows by the steps gone back over each time (`keepGoneBack`); this is what bounds it, as
/// an undo history's limit does. A step a jump went back to may go: the jump's steps keep naming
/// it (`back_to`), and a caller reads that as an earlier step.
pub fn trim(self: *History, gpa: Allocator, limit: usize) void {
    if (limit == 0) return;
    const items = self.undo_stack.items;
    if (items.len < limit + @max(16, limit / 16)) return;
    const drop = items.len - limit;
    for (items[0..drop]) |*e| e.deinit(gpa);
    std.mem.copyForwards(Entry, items[0..limit], items[drop..]);
    self.undo_stack.shrinkRetainingCapacity(limit);
    self.version += 1;
}

/// An entry put back by `restore`: its step id, what it did, and how it reads on the line.
pub const Restored = struct { step: u64, txn: Transaction, label: Transaction.Label = .{} };

/// Put the history back as `entries` (taken: the history owns their transactions), oldest first,
/// the first `applied` of them applied: a document's history read back from its track
/// (`Document.restoreHistory`), in place of what it held. Each keeps its step id, and steps
/// after it are numbered past the highest. What the text is does not change.
pub fn restore(self: *History, gpa: Allocator, entries: []Restored, applied: usize) !void {
    var undo: std.ArrayList(Entry) = .empty;
    errdefer undo.deinit(gpa);
    var redo: std.ArrayList(Entry) = .empty;
    errdefer redo.deinit(gpa);
    try undo.ensureTotalCapacity(gpa, applied);
    try redo.ensureTotalCapacity(gpa, entries.len - applied);
    var next = self.next_id;
    for (entries) |e| next = @max(next, e.step + 1);
    for (entries[0..applied]) |e| {
        undo.appendAssumeCapacity(.{ .txn = e.txn, .kind = e.label.kind, .id = next, .step = e.step, .back_to = e.label.back_to });
        next += 1;
    }
    // The redo stack's top is the next to redo: the first entry past `applied`.
    var i = entries.len;
    while (i > applied) {
        i -= 1;
        redo.appendAssumeCapacity(.{ .txn = entries[i].txn, .kind = entries[i].label.kind, .id = next, .step = entries[i].step, .back_to = entries[i].label.back_to });
        next += 1;
    }
    for (self.undo_stack.items) |*e| e.deinit(gpa);
    self.undo_stack.deinit(gpa);
    for (self.redo_stack.items) |*e| e.deinit(gpa);
    self.redo_stack.deinit(gpa);
    self.undo_stack = undo;
    self.redo_stack = redo;
    self.next_id = next;
    self.group_open = false;
    self.version += 1;
}

/// The `i`th step below the top of the line (0 is the top), as `lastApplied` gives the top: how
/// a caller reads the steps `keepGoneBack` added below a commit.
pub fn appliedBelowTop(self: *const History, i: usize) ?StepRef {
    const items = self.undo_stack.items;
    return if (i >= items.len) null else .of(&items[items.len - 1 - i]);
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
    self.version += 1;
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
    self.version += 1;
    return sel;
}

// -- the line -------------------------------------------------------------------------------------

/// One step of `line`.
pub const Step = struct { step: u64, kind: EditKind, back_to: ?u64 = null };

/// Every step, oldest first: the undo stack, then the redo stack from the next redo on. The
/// first `undo_stack.items.len` are applied.
pub fn line(self: History, arena: Allocator) ![]Step {
    const out = try arena.alloc(Step, self.undo_stack.items.len + self.redo_stack.items.len);
    for (self.undo_stack.items, 0..) |e, i| out[i] = .{ .step = e.step, .kind = e.kind, .back_to = e.back_to };
    const redo = self.redo_stack.items;
    for (redo, 0..) |e, i| out[out.len - 1 - i] = .{ .step = e.step, .kind = e.kind, .back_to = e.back_to };
    return out;
}

/// How many steps to undo (negative) or redo (positive) for `step` to be the last applied; 0
/// goes back before the first. Null when `step` is not on the line.
pub fn stepsTo(self: History, step: u64) ?isize {
    const applied: isize = @intCast(self.undo_stack.items.len);
    if (step == 0) return -applied;
    for (self.undo_stack.items, 0..) |e, i| if (e.step == step) return @as(isize, @intCast(i + 1)) - applied;
    const redo = self.redo_stack.items;
    for (redo, 0..) |e, i| if (e.step == step) return @intCast(redo.len - i);
    return null;
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
            _ = self.hist.end(self.gpa, .collapsed(self.cursor), true);
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
            _ = self.hist.end(self.gpa, .collapsed(self.cursor), true);
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
    _ = hist.end(a, .collapsed(7), true);

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

test "an edit after going back keeps what was gone back over, then its reverse" {
    var h: Harness = .{ .gpa = t.allocator };
    defer h.deinit();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();

    try h.type_("abc"); // "abc"
    try h.backspace(1); // "ab"
    try h.type_("\n"); // "ab\n"
    const before = try h.hist.line(arena.allocator());
    try t.expectEqual(@as(usize, 3), before.len);

    _ = h.undo();
    _ = h.undo();
    try t.expectEqualStrings("abc", h.text.items);
    h.hist.begin(.collapsed(h.cursor));
    try h.text.insertSlice(h.gpa, h.cursor, "z");
    h.hist.note(h.gpa, h.cursor, "", "z");
    h.cursor += 1;
    const c = h.hist.end(h.gpa, .collapsed(h.cursor), true).?;
    try t.expectEqualStrings("abcz", h.text.items);
    // Nothing to redo, and nothing lost: the two steps gone back over, their reverses, the edit.
    try t.expect(!h.hist.canRedo());
    try t.expectEqual(@as(usize, 2), c.back);
    try t.expect(!c.joined);
    const after = try h.hist.line(arena.allocator());
    try t.expectEqual(@as(usize, 6), after.len);
    for (before, after[0..3]) |a, b| try t.expectEqual(a.step, b.step);
    for (after[3..5]) |r| try t.expectEqual(@as(?u64, before[0].step), r.back_to);
    try t.expectEqual(@as(?u64, null), after[5].back_to);
    // The commit's reverses sit just below it, the step gone back to's reverse nearest.
    try t.expectEqual(after[4].step, h.hist.appliedBelowTop(1).?.step);

    // Every point on the line is still there to go to.
    const goTo = struct {
        fn f(hh: *Harness, step: u64) void {
            const n = hh.hist.stepsTo(step).?;
            for (0..@abs(n)) |_| _ = if (n < 0) hh.undo() else hh.redo();
        }
    }.f;
    goTo(&h, before[2].step);
    try t.expectEqualStrings("ab\n", h.text.items);
    goTo(&h, after[3].step);
    try t.expectEqualStrings("ab", h.text.items);
    goTo(&h, before[0].step);
    try t.expectEqualStrings("abc", h.text.items);
    goTo(&h, after[5].step);
    try t.expectEqualStrings("abcz", h.text.items);
}

test "a history put back from its steps reads as it did: kinds and jumps kept" {
    var h: Harness = .{ .gpa = t.allocator };
    defer h.deinit();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();

    try h.type_("abc");
    try h.backspace(1);
    try h.type_("\n");
    _ = h.undo();
    _ = h.undo();
    try h.type_("z");
    _ = h.undo();
    const was = try h.hist.line(arena.allocator());

    // Each entry as a recorded step (`Transaction.encodeStep`), read back as a track's would be.
    const n_applied = h.hist.undo_stack.items.len;
    var built: std.ArrayList(Restored) = .empty;
    defer built.deinit(t.allocator);
    errdefer for (built.items) |*b| b.txn.deinit(t.allocator);
    for (was, 0..) |st, i| {
        const ref: StepRef = if (i < n_applied) .of(&h.hist.undo_stack.items[i]) else .of(&h.hist.redo_stack.items[was.len - 1 - i]);
        var out: std.Io.Writer.Allocating = .init(t.allocator);
        defer out.deinit();
        try Transaction.encodeStep(&out.writer, ref.edits, ref.sel_after, false, ref.label);
        const view = try Transaction.StepView.init(out.written());
        var txn: Transaction = .{ .sel_after = view.sel };
        var it = view.iterator();
        while (it.next()) |e| try txn.append(t.allocator, e.pos, e.removed, e.inserted);
        try built.append(t.allocator, .{ .step = st.step, .txn = txn, .label = view.label });
    }
    var back: History = .{};
    defer back.deinit(t.allocator);
    try back.restore(t.allocator, built.items, n_applied);
    built.clearRetainingCapacity();
    const got = try back.line(arena.allocator());
    try t.expectEqual(was.len, got.len);
    for (was, got) |a, b| {
        try t.expectEqual(a.step, b.step);
        try t.expectEqual(a.kind, b.kind);
        try t.expectEqual(a.back_to, b.back_to);
    }
    // Not all one kind: typing, deleting, Enter, and the jump's steps.
    try t.expectEqual(EditKind.typing_other, got[0].kind);
    try t.expectEqual(EditKind.deleting_left, got[1].kind);
    try t.expect(got[3].back_to != null);
}

test "the line keeps to its limit, the oldest going first" {
    var h: Harness = .{ .gpa = t.allocator };
    defer h.deinit();
    // Forty steps of their own, then trimmed to twenty: at the slack (16 past), not before.
    for (0..40) |i| {
        h.hist.closeGroup();
        try h.type_(&.{@as(u8, 'a') + @as(u8, @intCast(i % 26))});
        h.hist.trim(t.allocator, 20);
        if (i + 1 < 36) try t.expectEqual(i + 1, h.steps());
    }
    try t.expect(h.steps() <= 36 and h.steps() >= 20);
    const kept = h.steps();
    // What is left still undoes, newest first, to the oldest kept step's start.
    for (0..kept) |_| _ = h.undo();
    try t.expectEqual(@as(usize, 40 - kept), h.text.items.len);
    // No limit keeps every one.
    h.hist.trim(t.allocator, 0);
}

test "an edit with nothing gone back over adds only itself" {
    var h: Harness = .{ .gpa = t.allocator };
    defer h.deinit();
    try h.type_("ab");
    h.hist.closeGroup();
    h.hist.begin(.collapsed(h.cursor));
    try h.text.insertSlice(h.gpa, h.cursor, "\n");
    h.hist.note(h.gpa, h.cursor, "", "\n");
    h.cursor += 1;
    const c = h.hist.end(h.gpa, .collapsed(h.cursor), true).?;
    try t.expectEqual(@as(usize, 0), c.back);
    try t.expectEqual(@as(usize, 2), h.steps());
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
    _ = h.hist.end(h.gpa, .collapsed(6), true);

    try t.expectEqualStrings("hello ", h.text.items);
    _ = h.undo();
    try t.expectEqualStrings("hello world", h.text.items);
}

test "the line: steps keep their ids through merges, undo and redo" {
    var h: Harness = .{ .gpa = t.allocator };
    defer h.deinit();
    try h.type_("abc");
    try h.backspace(1);
    try h.type_("\n");
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const before = try h.hist.line(arena.allocator());
    // A typing run is one step however many keys merged into it.
    try t.expectEqual(@as(usize, 3), before.len);
    try t.expectEqual(EditKind.typing_other, before[0].kind);

    const v = h.hist.version;
    _ = h.undo();
    _ = h.undo();
    try t.expect(h.hist.version != v);
    const after = try h.hist.line(arena.allocator());
    // The same steps in the same order: two of them now redo.
    for (before, after) |a, b| try t.expectEqual(a.step, b.step);
    try t.expectEqual(@as(usize, 1), h.hist.undo_stack.items.len);

    // Going to a step is so many undos or redos.
    try t.expectEqual(@as(?isize, 2), h.hist.stepsTo(before[2].step));
    try t.expectEqual(@as(?isize, 0), h.hist.stepsTo(before[0].step));
    try t.expectEqual(@as(?isize, -1), h.hist.stepsTo(0));
    try t.expectEqual(@as(?isize, null), h.hist.stepsTo(9999));
}

test "a commit says whether it started a step or joined one, and what it added" {
    const a = t.allocator;
    var hist: History = .{};
    defer hist.deinit(a);

    hist.begin(.collapsed(0));
    hist.note(a, 0, "", "a");
    const first = hist.end(a, .collapsed(1), true).?;
    try t.expect(!first.joined);
    try t.expectEqual(@as(usize, 1), first.edits.len);

    hist.begin(.collapsed(1));
    hist.note(a, 1, "", "b");
    const second = hist.end(a, .collapsed(2), true).?;
    // Typing runs on: the same step, and only the new keystroke.
    try t.expect(second.joined);
    try t.expectEqual(first.step, second.step);
    try t.expectEqual(@as(usize, 1), second.edits.len);
    try t.expectEqualStrings("b", second.edits[0].inserted);

    // An empty commit commits nothing.
    hist.begin(.collapsed(2));
    try t.expect(hist.end(a, .collapsed(2), true) == null);

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(a);
    try text.appendSlice(a, "ab");
    _ = hist.applyUndo(a, &text).?;
    try t.expectEqual(first.step, hist.lastUndone().?.step);
    try t.expectEqual(@as(usize, 2), hist.lastUndone().?.edits.len);
    _ = hist.applyRedo(a, &text).?;
    try t.expectEqual(first.step, hist.lastApplied().?.step);
}

test "an edit another hand may not join starts a step of its own" {
    const a = t.allocator;
    var hist: History = .{};
    defer hist.deinit(a);

    hist.begin(.collapsed(0));
    hist.note(a, 0, "", "a");
    const first = hist.end(a, .collapsed(1), true).?;
    hist.begin(.collapsed(1));
    hist.note(a, 1, "", "b");
    // Typing on, which VSCode's rule would join, but the step on top is another hand's.
    const second = hist.end(a, .collapsed(2), false).?;
    try t.expect(!second.joined);
    try t.expect(second.step != first.step);
    try t.expectEqual(@as(usize, 2), hist.undo_stack.items.len);
}
