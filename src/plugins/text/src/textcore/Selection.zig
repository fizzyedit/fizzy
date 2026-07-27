//! A sorted, non-overlapping set of `Range`s — the document's cursors.
//!
//! Multi-cursor is in the type from day one even though the editor currently only ever holds
//! one range. Every motion goes through `mapRanges`, so adding Ctrl+D later doesn't mean
//! revisiting each motion individually.

const std = @import("std");
const Range = @import("Range.zig");

const Selection = @This();

const Allocator = std.mem.Allocator;

/// INVARIANT (restored by `normalize`): sorted ascending by `Range.start()`, and no two
/// entries overlap or touch.
ranges: std.ArrayList(Range) = .empty,
/// Index into `ranges` of the primary cursor — the one that drives scroll-to-cursor and the
/// single-cursor-only features (completion anchor, hover, signature help).
primary: usize = 0,

pub fn deinit(self: *Selection, gpa: Allocator) void {
    self.ranges.deinit(gpa);
    self.* = .{};
}

pub fn single(gpa: Allocator, r: Range) !Selection {
    var self: Selection = .{};
    try self.ranges.append(gpa, r);
    return self;
}

pub fn collapsedAt(gpa: Allocator, off: usize) !Selection {
    return single(gpa, .collapsed(off));
}

pub fn clone(self: Selection, gpa: Allocator) !Selection {
    return .{
        .ranges = try self.ranges.clone(gpa),
        .primary = self.primary,
    };
}

pub fn count(self: Selection) usize {
    return self.ranges.items.len;
}

/// The primary range, or a collapsed range at 0 for an empty selection (which shouldn't
/// happen, but callers shouldn't have to branch on it).
pub fn primaryRange(self: Selection) Range {
    if (self.ranges.items.len == 0) return .collapsed(0);
    return self.ranges.items[@min(self.primary, self.ranges.items.len - 1)];
}

pub fn setPrimaryRange(self: *Selection, r: Range) void {
    if (self.ranges.items.len == 0) return;
    self.ranges.items[@min(self.primary, self.ranges.items.len - 1)] = r;
}

/// Sort by start, then merge any ranges that overlap or touch, keeping `primary` pointed at
/// whichever entry absorbed the old primary. Called after every motion and every edit —
/// this is what stops two cursors drifting into each other and applying an edit twice.
pub fn normalize(self: *Selection, gpa: Allocator) !void {
    _ = gpa;
    const items = self.ranges.items;
    if (items.len <= 1) {
        self.primary = if (items.len == 0) 0 else 0;
        return;
    }

    // Track the primary by identity through the sort: tag each range with its index, sort,
    // then follow the tag. Insertion sort — cursor counts are small (tens, not thousands)
    // and this keeps the sort stable without an allocation.
    var primary_range = self.primaryRange();
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        const key = items[i];
        var j = i;
        while (j > 0 and items[j - 1].start() > key.start()) : (j -= 1) {
            items[j] = items[j - 1];
        }
        items[j] = key;
    }

    var out: usize = 0;
    var k: usize = 1;
    while (k < items.len) : (k += 1) {
        if (items[out].overlaps(items[k])) {
            const merged = items[out].merged(items[k]);
            // If either side was the primary, the merged range inherits that role.
            if (rangeEql(items[out], primary_range) or rangeEql(items[k], primary_range)) {
                primary_range = merged;
            }
            items[out] = merged;
        } else {
            out += 1;
            items[out] = items[k];
        }
    }
    self.ranges.shrinkRetainingCapacity(out + 1);

    self.primary = 0;
    for (self.ranges.items, 0..) |r, idx| {
        if (rangeEql(r, primary_range)) {
            self.primary = idx;
            break;
        }
    }
}

fn rangeEql(a: Range, b: Range) bool {
    return a.anchor == b.anchor and a.head == b.head;
}

pub fn addCursor(self: *Selection, gpa: Allocator, r: Range) !void {
    try self.ranges.append(gpa, r);
    self.primary = self.ranges.items.len - 1;
    try self.normalize(gpa);
}

pub fn collapseToPrimary(self: *Selection, gpa: Allocator) !void {
    const p = self.primaryRange();
    self.ranges.clearRetainingCapacity();
    try self.ranges.append(gpa, p);
    self.primary = 0;
}

/// Apply `f` to every range, then re-normalize. Every motion routes through here, so a
/// motion written once works for one cursor or fifty.
pub fn mapRanges(
    self: *Selection,
    gpa: Allocator,
    ctx: anytype,
    comptime f: fn (@TypeOf(ctx), Range) Range,
) !void {
    for (self.ranges.items) |*r| r.* = f(ctx, r.*);
    try self.normalize(gpa);
}

/// Lowering to dvui's ordered `{cursor, start, end}` triple. dvui's `Selection` is a
/// projection written *into* the layout each frame — never read back as truth. That's the
/// whole point: layout resolves motion a frame late, so it can't be the source of record.
pub const Dvui = struct { cursor: usize, start: usize, end: usize };

pub fn toDvui(self: Selection) Dvui {
    const p = self.primaryRange();
    return .{ .cursor = p.head, .start = p.start(), .end = p.end() };
}

/// Lifting from dvui — used at the one boundary where the layout legitimately owns the
/// change: mouse click/drag hit-testing, which genuinely needs glyph positions.
pub fn fromDvui(gpa: Allocator, d: Dvui) !Selection {
    // Reconstruct direction from which end the cursor sits at.
    const r: Range = if (d.cursor == d.start and d.start != d.end)
        .init(d.end, d.start)
    else
        .init(d.start, d.end);
    return single(gpa, r);
}

test "normalize sorts and merges touching ranges" {
    const gpa = std.testing.allocator;
    var sel: Selection = .{};
    defer sel.deinit(gpa);
    try sel.ranges.append(gpa, .init(10, 14));
    try sel.ranges.append(gpa, .init(0, 3));
    try sel.ranges.append(gpa, .init(3, 6));
    try sel.normalize(gpa);

    try std.testing.expectEqual(@as(usize, 2), sel.count());
    try std.testing.expectEqual(@as(usize, 0), sel.ranges.items[0].start());
    try std.testing.expectEqual(@as(usize, 6), sel.ranges.items[0].end());
    try std.testing.expectEqual(@as(usize, 10), sel.ranges.items[1].start());
}

test "normalize keeps primary pointed at the surviving range" {
    const gpa = std.testing.allocator;
    var sel: Selection = .{};
    defer sel.deinit(gpa);
    try sel.ranges.append(gpa, .init(10, 14));
    try sel.ranges.append(gpa, .init(0, 3));
    sel.primary = 0; // the (10,14) one
    try sel.normalize(gpa);

    try std.testing.expectEqual(@as(usize, 10), sel.primaryRange().start());
}

test "disjoint ranges are left alone" {
    const gpa = std.testing.allocator;
    var sel: Selection = .{};
    defer sel.deinit(gpa);
    try sel.ranges.append(gpa, .init(0, 2));
    try sel.ranges.append(gpa, .init(4, 6));
    try sel.ranges.append(gpa, .init(8, 10));
    try sel.normalize(gpa);
    try std.testing.expectEqual(@as(usize, 3), sel.count());
}

test "dvui round-trip preserves backwards selection" {
    const gpa = std.testing.allocator;
    var sel = try Selection.single(gpa, .init(9, 4));
    defer sel.deinit(gpa);

    const d = sel.toDvui();
    try std.testing.expectEqual(@as(usize, 4), d.cursor);
    try std.testing.expectEqual(@as(usize, 4), d.start);
    try std.testing.expectEqual(@as(usize, 9), d.end);

    var back = try Selection.fromDvui(gpa, d);
    defer back.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 9), back.primaryRange().anchor);
    try std.testing.expectEqual(@as(usize, 4), back.primaryRange().head);
}

test "mapRanges applies to every cursor" {
    const gpa = std.testing.allocator;
    var sel: Selection = .{};
    defer sel.deinit(gpa);
    try sel.ranges.append(gpa, .collapsed(0));
    try sel.ranges.append(gpa, .collapsed(10));

    const shift = struct {
        fn f(by: usize, r: Range) Range {
            return .collapsed(r.head + by);
        }
    }.f;
    try sel.mapRanges(gpa, @as(usize, 5), shift);

    try std.testing.expectEqual(@as(usize, 5), sel.ranges.items[0].head);
    try std.testing.expectEqual(@as(usize, 15), sel.ranges.items[1].head);
}
