//! The bookkeeping half of a variable-height list: where each row sits, and how far its height
//! can be trusted. Std-only, so every rule is tested headlessly; a list widget draws the rows and hands
//! the measurements back through `record`.
//!
//! The one invariant everything else serves: **a row's height is either a measurement or an
//! admission that it is not one.** An estimate never replaces a measurement taken at the current
//! width. A width change keeps the old measurements as the best guess (they are not trusted at
//! the new width, so the next draw measures them again) and re-estimates only the rows never
//! measured.
//!
//! Cumulative heights live in a Fenwick tree, so `record` is O(log n) and `yAt`, `rowAt` and
//! `visibleRange` are O(log n) however many rows there are. `reconcile` is a key comparison per row
//! while the rows are unchanged (none, given a `revision`) and O(n) with allocation when they are not (a prepend, an append,
//! a deletion, a replaced row).
//!
//! Position is an `Anchor` (a row's key and an offset into it), never a pixel `y`: rows prepended
//! above it, or measured above it, move its `y` and leave what the reader sees alone.

const std = @import("std");

const HeightIndex = @This();

pub const State = enum {
    /// A guess from the caller's `estimate`.
    estimated,
    /// A measurement taken at another width: the best guess, kept until the row is measured again.
    stale,
    /// Laid out and measured at the current width.
    measured,
};

/// A reading position: the row and how far into it the top of the view is.
pub const Anchor = struct {
    key: u64,
    /// Pixels from the row's top to the top of the view; negative when the view starts above it.
    offset: f32,
};

/// The rows to draw: `first` up to but not including `end`.
pub const Range = struct {
    first: usize,
    end: usize,
};

/// What `reconcile` asks of the caller: the stable key of a row, and a guess at its height.
pub const Source = struct {
    ctx: *anyopaque,
    key: *const fn (ctx: *anyopaque, index: usize) u64,
    estimate: *const fn (ctx: *anyopaque, index: usize, width: f32) f32,
};

/// Heights closer than this are the same height.
pub const epsilon: f32 = 0.5;

/// A measurement this close to the height held is not worth moving the tree for.
const unchanged: f32 = 0.001;

keys: std.ArrayList(u64) = .empty,
heights: std.ArrayList(f32) = .empty,
states: std.ArrayList(State) = .empty,
/// Fenwick tree over `heights`, one-based (`tree[0]` unused), in f64 so adding and removing
/// deltas does not drift visibly.
tree: std.ArrayList(f64) = .empty,
by_key: std.AutoHashMapUnmanaged(u64, u32) = .empty,
width: f32 = 0,
/// The caller's `revision` the rows were last reconciled at.
revision: ?u64 = null,

/// Frees the index with the allocator it was reconciled with.
pub fn deinit(self: *HeightIndex, gpa: std.mem.Allocator) void {
    self.keys.deinit(gpa);
    self.heights.deinit(gpa);
    self.states.deinit(gpa);
    self.tree.deinit(gpa);
    self.by_key.deinit(gpa);
    self.* = undefined;
}

/// The number of rows.
pub fn len(self: *const HeightIndex) usize {
    return self.keys.items.len;
}

/// Whether row `index` holds a measurement, a guess or a measurement from another width.
pub fn stateAt(self: *const HeightIndex, index: usize) State {
    return self.states.items[index];
}

/// The height held for row `index`, whatever its state.
pub fn heightAt(self: *const HeightIndex, index: usize) f32 {
    return self.heights.items[index];
}

/// The row with `key`, or null when the rows hold none.
pub fn indexOf(self: *const HeightIndex, key: u64) ?usize {
    const i = self.by_key.get(key) orelse return null;
    return i;
}

/// Top of row `index`; `len()` gives the total.
pub fn yAt(self: *const HeightIndex, index: usize) f32 {
    var sum: f64 = 0;
    var i = index;
    while (i > 0) : (i &= i - 1) sum += self.tree.items[i];
    return @floatCast(sum);
}

pub fn total(self: *const HeightIndex) f32 {
    return self.yAt(self.len());
}

/// The row containing `y`, clamped to the first and last row; null when there are no rows.
pub fn rowAt(self: *const HeightIndex, y: f32) ?usize {
    const n = self.len();
    if (n == 0) return null;
    var pos: usize = 0;
    var rem: f64 = @max(y, 0);
    var step = std.math.floorPowerOfTwo(usize, n);
    while (step > 0) : (step >>= 1) {
        const next = pos + step;
        if (next <= n and self.tree.items[next] <= rem) {
            pos = next;
            rem -= self.tree.items[next];
        }
    }
    return @min(pos, n - 1);
}

/// The rows touching `[y, y + h)`, widened by `overscan` pixels each side; null for no rows. dvui
/// forgets the size of a widget that goes undrawn, so a row needs drawing before it is seen.
pub fn visibleRange(self: *const HeightIndex, y: f32, h: f32, overscan: f32) ?Range {
    const first = self.rowAt(y - overscan) orelse return null;
    // A row starting exactly at the bottom edge is not in view.
    const last = self.rowAt(@max(y, y + h + overscan - 0.01)).?;
    return .{ .first = first, .end = last + 1 };
}

/// The anchor for the view whose top is at `y`.
pub fn anchorAt(self: *const HeightIndex, y: f32) ?Anchor {
    const i = self.rowAt(y) orelse return null;
    return .{ .key = self.keys.items[i], .offset = y - self.yAt(i) };
}

/// Where the view's top is for `anchor`, or null when its row is gone.
pub fn resolve(self: *const HeightIndex, anchor: Anchor) ?f32 {
    const i = self.by_key.get(anchor.key) orelse return null;
    return self.yAt(i) + anchor.offset;
}

/// The top of a view `h` tall that shows the end of the rows.
pub fn endY(self: *const HeightIndex, h: f32) f32 {
    return @max(0, self.total() - h);
}

/// Whether a view `[y, y + h)` shows the end of the rows.
pub fn atEnd(self: *const HeightIndex, y: f32, h: f32) bool {
    return y + h >= self.total() - epsilon;
}

/// Whether `index` still needs a measurement, so a caller draws it whatever its estimate says.
pub fn wantsMeasure(self: *const HeightIndex, index: usize) bool {
    return self.states.items[index] != .measured;
}

/// Records what a laid-out row measured. Returns whether the height moved.
pub fn record(self: *HeightIndex, index: usize, h: f32) bool {
    const was = self.heights.items[index];
    self.states.items[index] = .measured;
    if (@abs(was - h) < unchanged) return false;
    self.heights.items[index] = h;
    self.add(index, @as(f64, h) - was);
    return @abs(was - h) >= epsilon;
}

/// Brings the rows in line with the caller's `count` rows laid out `width` wide. A row whose key
/// is still present keeps its height and state wherever it moved to; a new row starts at its
/// estimate. A change of `width` keeps the heights of measured rows as guesses that want measuring
/// again, and re-estimates the rows never measured. Estimates are only asked of rows in `count`.
///
/// Without a `revision` every row's key is compared on each call. A caller that can say when its
/// rows changed passes a number that changes with them, and an unchanged number skips the scan, so
/// a steady frame costs nothing in the number of rows.
pub fn reconcile(self: *HeightIndex, gpa: std.mem.Allocator, source: Source, count: usize, width: f32, revision: ?u64) std.mem.Allocator.Error!void {
    const width_changed = @abs(self.width - width) >= epsilon;
    if (!width_changed and count == self.len()) {
        if (count == 0) return;
        if (revision != null and revision == self.revision) return;
        for (self.keys.items, 0..) |key, i| {
            if (key != source.key(source.ctx, i)) break;
        } else {
            self.revision = revision;
            return;
        }
    }

    const old_heights = self.heights.items;
    const old_states = self.states.items;
    var keys = try std.ArrayList(u64).initCapacity(gpa, count);
    errdefer keys.deinit(gpa);
    var heights = try std.ArrayList(f32).initCapacity(gpa, count);
    errdefer heights.deinit(gpa);
    var states = try std.ArrayList(State).initCapacity(gpa, count);
    errdefer states.deinit(gpa);
    var by_key: std.AutoHashMapUnmanaged(u64, u32) = .empty;
    errdefer by_key.deinit(gpa);
    try by_key.ensureTotalCapacity(gpa, @intCast(count));

    for (0..count) |i| {
        const key = source.key(source.ctx, i);
        keys.appendAssumeCapacity(key);
        by_key.putAssumeCapacity(key, @intCast(i));
        if (self.by_key.get(key)) |was| {
            const state = old_states[was];
            const refresh = width_changed and state == .estimated;
            heights.appendAssumeCapacity(if (refresh) source.estimate(source.ctx, i, width) else old_heights[was]);
            states.appendAssumeCapacity(if (width_changed and state == .measured) .stale else state);
        } else {
            heights.appendAssumeCapacity(source.estimate(source.ctx, i, width));
            states.appendAssumeCapacity(.estimated);
        }
    }

    try self.tree.resize(gpa, count + 1);
    self.keys.deinit(gpa);
    self.heights.deinit(gpa);
    self.states.deinit(gpa);
    self.by_key.deinit(gpa);
    self.keys = keys;
    self.heights = heights;
    self.states = states;
    self.by_key = by_key;
    self.width = width;
    self.revision = revision;
    self.rebuild();
}

fn rebuild(self: *HeightIndex) void {
    const n = self.len();
    self.tree.items[0] = 0;
    for (self.heights.items, 1..) |h, i| self.tree.items[i] = h;
    for (1..n + 1) |i| {
        const parent = i + (i & (0 -% i));
        if (parent <= n) self.tree.items[parent] += self.tree.items[i];
    }
}

fn add(self: *HeightIndex, index: usize, delta: f64) void {
    var i = index + 1;
    while (i < self.tree.items.len) : (i += i & (0 -% i)) self.tree.items[i] += delta;
}

const testing = std.testing;

/// Rows in newest-last order: row `i` is message `first_id + i`, all estimated at 40.
const Rows = struct {
    first_id: u64,
    count: usize,

    /// A row swapped for one with another key, count and endpoints unchanged.
    replaced: ?usize = null,

    fn key(ctx: *anyopaque, i: usize) u64 {
        const self: *Rows = @ptrCast(@alignCast(ctx));
        if (self.replaced == i) return std.math.maxInt(u64);
        return self.first_id + i;
    }

    fn estimate(_: *anyopaque, _: usize, width: f32) f32 {
        return 40 * 100 / width;
    }

    fn source(self: *Rows) Source {
        return .{ .ctx = self, .key = key, .estimate = estimate };
    }
};

fn fresh(rows: *Rows) !HeightIndex {
    var index: HeightIndex = .{};
    errdefer index.deinit(testing.allocator);
    try index.reconcile(testing.allocator, rows.source(), rows.count, 100, null);
    return index;
}

fn naiveY(index: *const HeightIndex, row: usize) f32 {
    var sum: f64 = 0;
    for (index.heights.items[0..row]) |h| sum += h;
    return @floatCast(sum);
}

test "prefix sums match a plain sum, and rowAt inverts yAt" {
    var rows: Rows = .{ .first_id = 0, .count = 1000 };
    var index = try fresh(&rows);
    defer index.deinit(testing.allocator);
    for (0..1000) |i| _ = index.record(i, @floatFromInt(10 + i % 37));
    for ([_]usize{ 0, 1, 7, 64, 500, 999, 1000 }) |i| try testing.expectApproxEqAbs(naiveY(&index, i), index.yAt(i), 0.01);
    for ([_]usize{ 0, 1, 7, 64, 500, 999 }) |i| {
        try testing.expectEqual(i, index.rowAt(index.yAt(i)).?);
        try testing.expectEqual(i, index.rowAt(index.yAt(i) + index.heightAt(i) - 0.01).?);
    }
    try testing.expectEqual(@as(usize, 999), index.rowAt(1e9).?);
    try testing.expectEqual(@as(usize, 0), index.rowAt(-5).?);
}

test "a measurement is never overwritten by an estimate" {
    var rows: Rows = .{ .first_id = 0, .count = 10 };
    var index = try fresh(&rows);
    defer index.deinit(testing.allocator);
    _ = index.record(3, 123);
    // The rows are rebuilt (one appended) and the width is unchanged: row 3 keeps its measurement.
    rows.count = 11;
    try index.reconcile(testing.allocator, rows.source(), rows.count, 100, null);
    try testing.expectEqual(@as(f32, 123), index.heightAt(3));
    try testing.expectEqual(State.measured, index.stateAt(3));
    try testing.expectEqual(State.estimated, index.stateAt(10));
}

test "500 rows prepended above the anchor leave what the reader sees unchanged" {
    var rows: Rows = .{ .first_id = 1000, .count = 2000 };
    var index = try fresh(&rows);
    defer index.deinit(testing.allocator);
    for (0..2000) |i| _ = index.record(i, @floatFromInt(20 + i % 50));
    const view_y: f32 = index.yAt(900) + 7;
    const anchor = index.anchorAt(view_y).?;
    const row_on_screen = index.yAt(index.indexOf(anchor.key).?) - view_y;

    rows.first_id = 500;
    rows.count = 2500;
    try index.reconcile(testing.allocator, rows.source(), rows.count, 100, null);
    const new_y = index.resolve(anchor).?;
    const after = index.yAt(index.indexOf(anchor.key).?) - new_y;
    try testing.expectEqual(row_on_screen, after);
    // The view did travel, by exactly the 500 new rows' estimates.
    try testing.expectApproxEqAbs(view_y + 500 * 40, new_y, 0.01);
    try testing.expectEqual(anchor.key, index.anchorAt(new_y).?.key);
}

test "a measurement replacing an estimate above the view moves nothing" {
    var rows: Rows = .{ .first_id = 0, .count = 300 };
    var index = try fresh(&rows);
    defer index.deinit(testing.allocator);
    const y_before = index.yAt(200) + 11;
    const anchor = index.anchorAt(y_before).?;
    const before = index.yAt(index.indexOf(anchor.key).?) - index.resolve(anchor).?;
    for (0..100) |i| try testing.expect(index.record(i, 90));
    const after = index.yAt(index.indexOf(anchor.key).?) - index.resolve(anchor).?;
    try testing.expectEqual(before, after);
    try testing.expectApproxEqAbs(@as(f32, 100 * 50), index.resolve(anchor).? - y_before, 0.01);
}

test "follow_end holds the last row at the bottom as rows are appended" {
    var rows: Rows = .{ .first_id = 0, .count = 50 };
    var index = try fresh(&rows);
    defer index.deinit(testing.allocator);
    const view_h: f32 = 300;
    var y = index.endY(view_h);
    try testing.expect(index.atEnd(y, view_h));
    for (0..20) |_| {
        rows.count += 1;
        try index.reconcile(testing.allocator, rows.source(), rows.count, 100, null);
        y = index.endY(view_h);
        const last = index.len() - 1;
        try testing.expectApproxEqAbs(y + view_h, index.yAt(last) + index.heightAt(last), 0.01);
    }
    // A reader who scrolled up is not at the end, and so is not followed.
    try testing.expect(!index.atEnd(y - 100, view_h));
}

test "a width change re-estimates without moving the anchor" {
    var rows: Rows = .{ .first_id = 0, .count = 400 };
    var index = try fresh(&rows);
    defer index.deinit(testing.allocator);
    for (0..100) |i| _ = index.record(i, 77);
    const anchor = index.anchorAt(index.yAt(250) + 5).?;
    const before = index.yAt(index.indexOf(anchor.key).?) - index.resolve(anchor).?;

    try index.reconcile(testing.allocator, rows.source(), rows.count, 50, null);
    // Never-measured rows follow the estimate at the new width; measured ones keep their height
    // as a guess and ask to be measured again.
    try testing.expectEqual(@as(f32, 80), index.heightAt(250));
    try testing.expectEqual(@as(f32, 77), index.heightAt(5));
    try testing.expect(index.wantsMeasure(5));
    try testing.expectEqual(before, index.yAt(index.indexOf(anchor.key).?) - index.resolve(anchor).?);
    try testing.expectApproxEqAbs(naiveY(&index, 400), index.total(), 0.01);

    // The same width again is not a change: the estimates stay put.
    rows.count = 400;
    try index.reconcile(testing.allocator, rows.source(), rows.count, 50.2, null);
    try testing.expectEqual(@as(f32, 80), index.heightAt(250));
}

test "an anchor whose row is gone resolves to null" {
    var rows: Rows = .{ .first_id = 0, .count = 10 };
    var index = try fresh(&rows);
    defer index.deinit(testing.allocator);
    const anchor = index.anchorAt(index.yAt(2)).?;
    rows.first_id = 5;
    try index.reconcile(testing.allocator, rows.source(), rows.count, 100, null);
    try testing.expectEqual(@as(?f32, null), index.resolve(anchor));
}

test "visibleRange covers the view plus overscan and is null only without rows" {
    var rows: Rows = .{ .first_id = 0, .count = 100 };
    var index = try fresh(&rows);
    defer index.deinit(testing.allocator);
    const r = index.visibleRange(400, 200, 0).?;
    try testing.expectEqual(@as(usize, 10), r.first);
    try testing.expectEqual(@as(usize, 15), r.end);
    const wide = index.visibleRange(400, 200, 80).?;
    try testing.expectEqual(@as(usize, 8), wide.first);
    try testing.expectEqual(@as(usize, 17), wide.end);
    const past = index.visibleRange(1e7, 200, 0).?;
    try testing.expectEqual(@as(usize, 99), past.first);

    rows.count = 0;
    try index.reconcile(testing.allocator, rows.source(), 0, 100, null);
    try testing.expectEqual(@as(?Range, null), index.visibleRange(0, 100, 0));
}

test "twenty thousand rows keep the prefix sums right" {
    var rows: Rows = .{ .first_id = 0, .count = 20_000 };
    var index = try fresh(&rows);
    defer index.deinit(testing.allocator);
    for (0..20_000) |i| _ = index.record(i, @floatFromInt(10 + i % 90));
    for ([_]usize{ 1, 4096, 12_345, 19_999, 20_000 }) |i| try testing.expectApproxEqAbs(naiveY(&index, i), index.yAt(i), 0.5);
    try testing.expectEqual(@as(usize, 12_345), index.rowAt(index.yAt(12_345) + 1).?);
}

test "a replaced or reordered interior row is noticed even when count and endpoints match" {
    var rows: Rows = .{ .first_id = 0, .count = 10 };
    var index = try fresh(&rows);
    defer index.deinit(testing.allocator);
    _ = index.record(4, 123);

    rows.replaced = 4;
    try index.reconcile(testing.allocator, rows.source(), rows.count, 100, null);
    try testing.expectEqual(@as(?usize, null), index.indexOf(4));
    try testing.expectEqual(@as(?usize, 4), index.indexOf(std.math.maxInt(u64)));
    try testing.expectEqual(State.estimated, index.stateAt(4));
    try testing.expectEqual(@as(f32, 40), index.heightAt(4));
}

test "a second width change keeps the first one's measurements as guesses" {
    var rows: Rows = .{ .first_id = 0, .count = 20 };
    var index = try fresh(&rows);
    defer index.deinit(testing.allocator);
    _ = index.record(2, 77);

    try index.reconcile(testing.allocator, rows.source(), rows.count, 50, null);
    try testing.expectEqual(State.stale, index.stateAt(2));
    try index.reconcile(testing.allocator, rows.source(), rows.count, 25, null);
    try testing.expectEqual(@as(f32, 77), index.heightAt(2));
    try testing.expect(index.wantsMeasure(2));
    try testing.expectEqual(@as(f32, 160), index.heightAt(3));
    try testing.expectApproxEqAbs(naiveY(&index, 20), index.total(), 0.01);
}

test "an empty list reconciles without allocating" {
    var rows: Rows = .{ .first_id = 0, .count = 0 };
    var index = try fresh(&rows);
    defer index.deinit(testing.allocator);
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try index.reconcile(failing.allocator(), rows.source(), 0, 100, null);
}

test "a width change estimates only the rows the caller still has" {
    var rows: Rows = .{ .first_id = 0, .count = 20 };
    var index = try fresh(&rows);
    defer index.deinit(testing.allocator);
    rows.count = 5;
    // `Rows.key` and `estimate` do not bound-check, so count the asks instead.
    var asked = Asked{ .limit = rows.count };
    try index.reconcile(testing.allocator, asked.source(), rows.count, 50, null);
    try testing.expectEqual(@as(usize, 0), asked.beyond);
    try testing.expectEqual(@as(usize, 5), index.len());
}

const Asked = struct {
    limit: usize,
    beyond: usize = 0,

    fn key(ctx: *anyopaque, i: usize) u64 {
        const self: *Asked = @ptrCast(@alignCast(ctx));
        if (i >= self.limit) self.beyond += 1;
        return i;
    }

    fn estimate(ctx: *anyopaque, i: usize, _: f32) f32 {
        const self: *Asked = @ptrCast(@alignCast(ctx));
        if (i >= self.limit) self.beyond += 1;
        return 40;
    }

    fn source(self: *Asked) Source {
        return .{ .ctx = self, .key = key, .estimate = estimate };
    }
};

test "a new list is estimated at the width it is laid out at" {
    var index: HeightIndex = .{};
    defer index.deinit(testing.allocator);
    var rows: Rows = .{ .first_id = 0, .count = 3 };
    try index.reconcile(testing.allocator, rows.source(), rows.count, 200, null);
    try testing.expectEqual(@as(f32, 20), index.heightAt(0));
}

test "an unchanged revision skips the key scan, a new one does not" {
    var rows: Rows = .{ .first_id = 0, .count = 10 };
    var index: HeightIndex = .{};
    defer index.deinit(testing.allocator);
    try index.reconcile(testing.allocator, rows.source(), rows.count, 100, 1);
    // The interior row changes with no new revision: trusted, so not noticed.
    rows.replaced = 4;
    try index.reconcile(testing.allocator, rows.source(), rows.count, 100, 1);
    try testing.expectEqual(@as(?usize, 4), index.indexOf(4));
    try index.reconcile(testing.allocator, rows.source(), rows.count, 100, 2);
    try testing.expectEqual(@as(?usize, null), index.indexOf(4));
}
