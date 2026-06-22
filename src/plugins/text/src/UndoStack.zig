//! Per-document undo/redo history for the text editor.
//!
//! Each edit is captured as `(pos, removed, inserted)` — the smallest slice of bytes that
//! changed and where — never a full-buffer snapshot, so history stays O(edit size) per
//! entry regardless of file size ("efficient"), and the stack itself is unbounded ("endless":
//! nothing pops off the bottom until the document closes).
//!
//! Two ways an edit gets recorded:
//! - `begin`/`noteRemoved`/`noteInserted`/`end`: used by `TextEntryWidget`'s `edit_notify`
//!   hook, which fires once per widget mutation call (typing, paste-into-focused-widget,
//!   backspace, delete) — `begin` opens a slot, 0-1 `noteRemoved` + 0-1 `noteInserted` fill
//!   it in (both can fire in one call, e.g. typing over a selection replaces it), `end`
//!   commits it as a single undo step.
//! - `pushComplete`: used by the `text.paste` command, which builds one full edit outside
//!   the widget's own frame and has nothing to coalesce.
const std = @import("std");

const UndoStack = @This();

pub const EditOp = struct {
    pos: usize = 0,
    removed: []u8 = &.{},
    inserted: []u8 = &.{},
    id: u64 = 0,

    fn deinit(self: *EditOp, gpa: std.mem.Allocator) void {
        gpa.free(self.removed);
        gpa.free(self.inserted);
    }
};

undo: std.ArrayListUnmanaged(EditOp) = .empty,
redo: std.ArrayListUnmanaged(EditOp) = .empty,
pending: ?EditOp = null,
next_id: u64 = 1,

pub fn deinit(self: *UndoStack, gpa: std.mem.Allocator) void {
    for (self.undo.items) |*op| op.deinit(gpa);
    self.undo.deinit(gpa);
    for (self.redo.items) |*op| op.deinit(gpa);
    self.redo.deinit(gpa);
    if (self.pending) |*op| op.deinit(gpa);
}

pub fn canUndo(self: *const UndoStack) bool {
    return self.undo.items.len > 0;
}

pub fn canRedo(self: *const UndoStack) bool {
    return self.redo.items.len > 0;
}

/// The id of the entry currently at the top of `undo`, or 0 if empty. See `EditOp.id`.
pub fn topOpId(self: *const UndoStack) u64 {
    return if (self.undo.items.len == 0) 0 else self.undo.items[self.undo.items.len - 1].id;
}

pub fn begin(self: *UndoStack) void {
    self.pending = .{};
}

pub fn noteRemoved(self: *UndoStack, gpa: std.mem.Allocator, pos: usize, bytes: []const u8) void {
    const op = if (self.pending) |*p| p else return;
    op.pos = pos;
    if (op.removed.len != 0) gpa.free(op.removed);
    op.removed = gpa.dupe(u8, bytes) catch blk: {
        std.log.err("UndoStack.noteRemoved: dupe failed, dropping {d} bytes", .{bytes.len});
        break :blk &.{};
    };
}

pub fn noteInserted(self: *UndoStack, gpa: std.mem.Allocator, pos: usize, bytes: []const u8) void {
    const op = if (self.pending) |*p| p else return;
    if (op.removed.len == 0) op.pos = pos;
    if (op.inserted.len != 0) gpa.free(op.inserted);
    op.inserted = gpa.dupe(u8, bytes) catch blk: {
        std.log.err("UndoStack.noteInserted: dupe failed, dropping {d} bytes", .{bytes.len});
        break :blk &.{};
    };
}

/// Commits the pending edit opened by `begin`. A no-op edit (nothing removed or inserted,
/// e.g. backspace at the start of the document) is discarded rather than pushed.
pub fn end(self: *UndoStack, gpa: std.mem.Allocator) void {
    const op = self.pending orelse return;
    self.pending = null;
    self.commit(gpa, op);
}

/// Records one complete edit built outside the begin/note/end flow (the `text.paste` command).
pub fn pushComplete(self: *UndoStack, gpa: std.mem.Allocator, pos: usize, removed: []const u8, inserted: []const u8) !void {
    var op: EditOp = .{ .pos = pos, .removed = try gpa.dupe(u8, removed) };
    errdefer gpa.free(op.removed);
    op.inserted = try gpa.dupe(u8, inserted);
    self.commit(gpa, op);
}

fn commit(self: *UndoStack, gpa: std.mem.Allocator, op_in: EditOp) void {
    var op = op_in;
    if (op.removed.len == 0 and op.inserted.len == 0) {
        op.deinit(gpa);
        return;
    }
    for (self.redo.items) |*r| r.deinit(gpa);
    self.redo.clearRetainingCapacity();
    op.id = self.next_id;
    self.next_id += 1;
    self.undo.append(gpa, op) catch |err| {
        std.log.err("UndoStack.commit: undo.append failed: {s}", .{@errorName(err)});
        op.deinit(gpa);
    };
}

/// Reverses the most recent undo entry against `text`, moving it onto the redo stack.
/// Returns the byte offset to place the cursor at afterward, or `null` if there was nothing
/// to undo.
pub fn applyUndo(self: *UndoStack, gpa: std.mem.Allocator, text: *std.ArrayList(u8)) ?usize {
    var op = self.undo.pop() orelse return null;
    text.replaceRange(gpa, op.pos, op.inserted.len, op.removed) catch {};
    const cursor = op.pos + op.removed.len;
    self.redo.append(gpa, op) catch |err| {
        std.log.err("UndoStack.applyUndo: redo.append failed: {s}", .{@errorName(err)});
        op.deinit(gpa);
    };
    return cursor;
}

/// Re-applies the most recent redo entry against `text`, moving it back onto the undo stack.
/// Returns the byte offset to place the cursor at afterward, or `null` if there was nothing
/// to redo.
pub fn applyRedo(self: *UndoStack, gpa: std.mem.Allocator, text: *std.ArrayList(u8)) ?usize {
    var op = self.redo.pop() orelse return null;
    text.replaceRange(gpa, op.pos, op.removed.len, op.inserted) catch {};
    const cursor = op.pos + op.inserted.len;
    self.undo.append(gpa, op) catch |err| {
        std.log.err("UndoStack.applyRedo: undo.append failed: {s}", .{@errorName(err)});
        op.deinit(gpa);
    };
    return cursor;
}
