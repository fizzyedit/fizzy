//! One replica of a text as a sequence CRDT: the same characters in the same order on every
//! replica that has seen the same operations, in whatever order they arrived.
//!
//! Every character ever typed stays as an item, flat and append-only in creation order, linked
//! into document order through `next`/`prev`. A delete only sets a flag (a tombstone), so a
//! concurrent insert next to it still finds its neighbour. Item 0 is a hidden sentinel standing
//! for the start of the text.
//!
//! Placement is YATA's rule (Yjs `Item.integrate`): an insert carries the two neighbours it was
//! typed between (its origins), and a receiver scans only the items between them, breaking ties
//! on `Id`. Fugue was prototyped beside it and dropped (its subtree test walks the tree, as deep
//! as a typed run is long).
//!
//! Operations from one replica are applied in the order it made them, and an insert only once its
//! two origins are present; anything earlier waits in `pending` (so any delivery order converges,
//! and a duplicate is a no-op). std-only, so it builds for wasm.

const Replica = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const op_mod = @import("op.zig");

pub const Id = op_mod.Id;
pub const Insert = op_mod.Insert;
pub const Op = op_mod.Op;

const none: u32 = std.math.maxInt(u32);
const head: u32 = 0;

const Item = struct {
    id: Id,
    ch: u32,
    /// Origins as item indexes (`none` at the end of the text).
    left: u32,
    right: u32,
    next: u32,
    prev: u32,
    deleted: bool,
};

gpa: Allocator,
replica: u32,
items: std.MultiArrayList(Item) = .empty,
/// replica -> the item index of each of its characters, by counter.
by_replica: std.AutoHashMapUnmanaged(u32, std.ArrayList(u32)) = .empty,
tail: u32 = head,
/// Operations whose origins have not arrived.
pending: std.ArrayList(Op) = .empty,
visible_len: usize = 0,
/// A visible-position cache for typing: `cursor_item` is the item after which `cursor_pos`
/// visible characters have gone by. Typing and backspacing hit it; anything else walks from
/// the nearer of it and the start.
cursor_item: u32 = head,
cursor_pos: usize = 0,
/// Scratch sets, kept to avoid allocating per insert.
scan_before: std.AutoHashMapUnmanaged(u32, void) = .empty,
scan_conflicting: std.AutoHashMapUnmanaged(u32, void) = .empty,

/// `replica` must be unique among the replicas of one text and not `maxInt(u32)`.
pub fn init(gpa: Allocator, replica: u32) Allocator.Error!Replica {
    std.debug.assert(replica != Id.root.replica);
    var self: Replica = .{ .gpa = gpa, .replica = replica };
    errdefer self.deinit();
    try self.items.append(gpa, .{
        .id = Id.root,
        .ch = 0,
        .left = none,
        .right = none,
        .next = none,
        .prev = none,
        .deleted = true,
    });
    return self;
}

pub fn deinit(self: *Replica) void {
    self.items.deinit(self.gpa);
    var it = self.by_replica.valueIterator();
    while (it.next()) |list| list.deinit(self.gpa);
    self.by_replica.deinit(self.gpa);
    self.pending.deinit(self.gpa);
    self.scan_before.deinit(self.gpa);
    self.scan_conflicting.deinit(self.gpa);
    self.* = undefined;
}

/// Visible characters.
pub fn len(self: *const Replica) usize {
    return self.visible_len;
}

/// Inserts `ch` so it becomes the character at visible index `pos` (`pos <= len()`), and returns
/// the op to send to the other replicas.
pub fn insert(self: *Replica, pos: usize, ch: u21) Allocator.Error!Op {
    std.debug.assert(pos <= self.visible_len);
    const l = self.nthVisible(pos);
    const r = self.items.items(.next)[l];
    const counter: u32 = if (self.by_replica.get(self.replica)) |list| @intCast(list.items.len) else 0;
    const ids = self.items.items(.id);
    const ins: Insert = .{
        .id = .{ .replica = self.replica, .counter = counter },
        .ch = ch,
        .left = ids[l],
        .right = if (r == none) null else ids[r],
    };
    const item = try self.integrate(ins, l, r);
    self.cursor_item = item;
    self.cursor_pos = pos + 1;
    return .{ .insert = ins };
}

/// Tombstones the character at visible index `pos` and returns the op to send, or null when
/// `pos` is past the end.
pub fn delete(self: *Replica, pos: usize) ?Op {
    if (pos >= self.visible_len) return null;
    const item = self.nthVisible(pos + 1);
    self.items.items(.deleted)[item] = true;
    self.visible_len -= 1;
    self.cursor_item = self.items.items(.prev)[item];
    self.cursor_pos = pos;
    return .{ .delete = self.items.items(.id)[item] };
}

/// Applies an op from any replica, this one's own included. An op whose origins have not
/// arrived waits; one already applied changes nothing.
pub fn apply(self: *Replica, op: Op) Allocator.Error!void {
    if (!try self.tryApply(op)) {
        try self.pending.append(self.gpa, op);
        return;
    }
    var progress = true;
    while (progress) {
        progress = false;
        var i: usize = 0;
        while (i < self.pending.items.len) {
            if (try self.tryApply(self.pending.items[i])) {
                _ = self.pending.orderedRemove(i);
                progress = true;
            } else i += 1;
        }
    }
}

/// Ops still waiting on an origin.
pub fn pendingCount(self: *const Replica) usize {
    return self.pending.items.len;
}

/// The visible text as UTF-8. Caller frees with `gpa`.
pub fn toOwnedText(self: *const Replica, gpa: Allocator) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const next = self.items.items(.next);
    const deleted = self.items.items(.deleted);
    const ch = self.items.items(.ch);
    var i = next[head];
    while (i != none) : (i = next[i]) {
        if (deleted[i]) continue;
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(@intCast(ch[i]), &buf) catch unreachable; // every `ch` came from a `u21` the typist produced as a scalar value
        try out.appendSlice(gpa, buf[0..n]);
    }
    return out.toOwnedSlice(gpa);
}

/// Bytes held by items and the per-replica index (not the capacity slack, not `pending`).
pub fn memoryUsed(self: *const Replica) usize {
    const per_item = @sizeOf(Id) + 5 * @sizeOf(u32) + @sizeOf(bool) + @sizeOf(u32);
    return self.items.len * per_item;
}

fn tryApply(self: *Replica, op: Op) Allocator.Error!bool {
    switch (op) {
        .delete => |id| {
            const item = self.find(id) orelse return false;
            const deleted = self.items.items(.deleted);
            if (!deleted[item]) {
                deleted[item] = true;
                self.visible_len -= 1;
                self.cursor_item = head;
                self.cursor_pos = 0;
            }
            return true;
        },
        .insert => |ins| {
            const expected: u32 = if (self.by_replica.get(ins.id.replica)) |list| @intCast(list.items.len) else 0;
            if (ins.id.counter < expected) return true;
            if (ins.id.counter > expected) return false;
            const l = self.find(ins.left) orelse return false;
            const r: u32 = if (ins.right) |id| self.find(id) orelse return false else none;
            _ = try self.integrate(ins, l, r);
            self.cursor_item = head;
            self.cursor_pos = 0;
            return true;
        },
    }
}

fn find(self: *const Replica, id: Id) ?u32 {
    if (id.eql(Id.root)) return head;
    const list = self.by_replica.get(id.replica) orelse return null;
    if (id.counter >= list.items.len) return null;
    return list.items[id.counter];
}

/// Places `ins` in document order and appends its item. `l`/`r` are its origins' indexes.
fn integrate(self: *Replica, ins: Insert, l: u32, r: u32) Allocator.Error!u32 {
    const gop = try self.by_replica.getOrPut(self.gpa, ins.id.replica);
    if (!gop.found_existing) gop.value_ptr.* = .empty;
    try gop.value_ptr.ensureUnusedCapacity(self.gpa, 1);
    try self.items.ensureUnusedCapacity(self.gpa, 1);

    const new: u32 = @intCast(self.items.len);
    const after = try self.place(ins, l, r);

    const next = self.items.items(.next);
    const nx = next[after];
    self.items.appendAssumeCapacity(.{
        .id = ins.id,
        .ch = ins.ch,
        .left = l,
        .right = r,
        .next = nx,
        .prev = after,
        .deleted = false,
    });
    gop.value_ptr.appendAssumeCapacity(new);
    // `appendAssumeCapacity` never moves the arrays, so these slices are still valid.
    self.items.items(.next)[after] = new;
    if (nx == none) self.tail = new else self.items.items(.prev)[nx] = new;
    self.visible_len += 1;
    return new;
}

/// The item the new one goes right after.
fn place(self: *Replica, ins: Insert, l: u32, r: u32) Allocator.Error!u32 {
    const next = self.items.items(.next);
    const ids = self.items.items(.id);
    const lefts = self.items.items(.left);
    const rights = self.items.items(.right);
    self.scan_before.clearRetainingCapacity();
    self.scan_conflicting.clearRetainingCapacity();
    var after = l;
    var o = next[l];
    while (o != none and o != r) : (o = next[o]) {
        try self.scan_before.put(self.gpa, o, {});
        try self.scan_conflicting.put(self.gpa, o, {});
        if (lefts[o] == l) {
            if (ids[o].order(ins.id) == .lt) {
                after = o;
                self.scan_conflicting.clearRetainingCapacity();
            } else if (rights[o] == r) break;
        } else if (self.scan_before.contains(lefts[o])) {
            if (!self.scan_conflicting.contains(lefts[o])) {
                after = o;
                self.scan_conflicting.clearRetainingCapacity();
            }
        } else break;
    }
    return after;
}

/// The item holding the `n`th visible character (1-based), or the sentinel for `n == 0`.
fn nthVisible(self: *Replica, n: usize) u32 {
    const next = self.items.items(.next);
    const prev = self.items.items(.prev);
    const deleted = self.items.items(.deleted);
    var c = head;
    var count: usize = 0;
    if (self.cursor_pos <= n or self.cursor_pos - n < n) {
        c = self.cursor_item;
        count = self.cursor_pos;
    }
    while (count > n) {
        if (!deleted[c]) count -= 1;
        c = prev[c];
    }
    while (count < n) {
        c = next[c];
        if (!deleted[c]) count += 1;
    }
    while (c != head and deleted[c]) c = prev[c];
    return c;
}
