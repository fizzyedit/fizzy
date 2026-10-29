//! Keyed layout motion, independent of drawing and of the track's motion model.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// An item's identity across layouts, chosen by the app.
pub const Key = u64;
/// Container-local coordinates in points; scrolling animates nothing.
pub const Rect = struct { x: f32 = 0, y: f32 = 0, w: f32 = 0, h: f32 = 0 };
/// Track lanes: x, y, w, h, presence (0 gone, 1 fully there).
pub const lanes = 5;
pub const Phase = enum {
    /// First placement: invisible while the layout measures it.
    measuring,
    entering,
    present,
    /// Absent from the layout; retired when presence reaches zero.
    leaving,
};
pub const Shown = struct { rect: Rect, presence: f32, phase: Phase };
pub const EndOptions = struct {
    /// Resizing follows the layout immediately and retires leaving items.
    follow: bool = false,
};

/// Owns each item's track. Track needs pos: [lanes]f32, snap(to), and
/// step(target, now_ns), returning true while moving. Repeated times must move nothing.
/// The owner releases all storage with deinit using the same allocator as place/end.
// lint-allow(fn-length): type factory contains the set declarations; each method is under 150 lines.
pub fn Rearrange(comptime Track: type) type {
    if (!@hasField(Track, "pos")) @compileError("Rearrange Track needs field pos");
    if (@FieldType(Track, "pos") != [lanes]f32) @compileError("Rearrange Track.pos must be [lanes]f32");
    if (!@hasDecl(Track, "snap")) @compileError("Rearrange Track needs snap");
    if (!@hasDecl(Track, "step")) @compileError("Rearrange Track needs step");
    return struct {
        const Self = @This();
        pub const Entry = struct {
            track: Track,
            /// The destination currently chased by the track.
            target: Rect,
            /// This frame's placement, applied unless measurement holds the frame.
            next: Rect,
            phase: Phase,
        };
        items: std.AutoArrayHashMapUnmanaged(Key, Entry) = .empty,
        /// Keys placed since begin, in layout order.
        placed: std.ArrayList(Key) = .empty,
        // Membership stays constant-time without changing the public entry shape.
        placed_set: std.AutoHashMapUnmanaged(Key, void) = .empty,
        // A key joins after its first measuring frame; removed with its entry.
        measured: std.AutoHashMapUnmanaged(Key, void) = .empty,
        moving: bool = false,
        ended: bool = false,
        last_end_ns: i128 = 0,

        pub fn deinit(self: *Self, gpa: Allocator) void {
            self.items.deinit(gpa);
            self.placed.deinit(gpa);
            self.placed_set.deinit(gpa);
            self.measured.deinit(gpa);
            self.* = .{};
        }

        /// Start a frame, forgetting which keys were placed.
        pub fn begin(self: *Self) void {
            self.ended = false;
            self.placed.clearRetainingCapacity();
            self.placed_set.clearRetainingCapacity();
        }

        /// Last placement wins for duplicates; their first position in layout order is kept.
        pub fn place(self: *Self, gpa: Allocator, key: Key, target: Rect) Allocator.Error!void {
            // Reserve before mutation so allocation failure leaves placement consistent.
            try self.items.ensureUnusedCapacity(gpa, 1);
            try self.placed.ensureUnusedCapacity(gpa, 1);
            try self.placed_set.ensureUnusedCapacity(gpa, 1);
            const result = self.items.getOrPutAssumeCapacity(key);
            if (!result.found_existing) {
                var track: Track = .{};
                track.snap(values(target, 0));
                result.value_ptr.* = .{ .track = track, .target = target, .next = target, .phase = .measuring };
            }
            result.value_ptr.next = target;
            const placement = self.placed_set.getOrPutAssumeCapacity(key);
            if (!placement.found_existing) self.placed.appendAssumeCapacity(key);
        }

        /// Diff and step every track. True while anything moves or measures.
        pub fn end(self: *Self, gpa: Allocator, now_ns: i128, opts: EndOptions) Allocator.Error!bool {
            if (self.ended and self.last_end_ns == now_ns and !opts.follow) return !self.settled();
            // A measuring entry created by place has not survived an end yet. Keep that
            // distinction outside Entry so its public shape stays the track/rect/phase seam.
            var hold = false;
            for (self.placed.items) |key| {
                const entry = self.items.getPtr(key).?;
                if (entry.phase == .measuring and !self.measured.contains(key)) hold = true;
            }
            try self.measured.ensureUnusedCapacity(gpa, @intCast(self.placed.items.len));
            self.ended = true;
            self.last_end_ns = now_ns;
            self.moving = false;
            var i = self.items.count();
            // Reverse ordered removal preserves insertion order and unvisited indices.
            while (i > 0) {
                i -= 1;
                const key = self.items.keys()[i];
                const entry = &self.items.values()[i];
                const placed = self.placed_set.contains(key);
                if (!placed) {
                    if (opts.follow or entry.phase == .measuring) {
                        self.items.orderedRemoveAt(i);
                        _ = self.measured.remove(key);
                        continue;
                    }
                    if (entry.phase != .leaving) {
                        // Exit from the pose the person saw, even halfway through a move.
                        entry.target = rectOf(entry.track.pos);
                        entry.phase = .leaving;
                    }
                } else if (opts.follow) {
                    entry.target = entry.next;
                    entry.track.snap(values(entry.next, 1));
                    entry.phase = .present;
                    continue;
                } else if (entry.phase == .measuring) {
                    if (!self.measured.contains(key)) {
                        entry.target = entry.next;
                        entry.track.snap(values(entry.next, 0));
                        self.measured.putAssumeCapacity(key, {});
                        _ = entry.track.step(values(entry.target, 0), now_ns);
                        self.moving = true;
                        continue;
                    }
                    entry.track.snap(values(entry.next, 0));
                    entry.target = entry.next;
                    entry.phase = .entering;
                } else if (entry.phase == .leaving) {
                    entry.phase = .present;
                }
                if (placed and !hold) entry.target = entry.next;
                const moving = entry.track.step(values(entry.target, if (placed) 1 else 0), now_ns);
                if (entry.phase == .leaving and !moving and entry.track.pos[4] <= 0.001) {
                    self.items.orderedRemoveAt(i);
                    _ = self.measured.remove(key);
                    continue;
                }
                if (entry.phase == .entering and !moving) entry.phase = .present;
                self.moving = self.moving or moving;
            }
            return !self.settled();
        }

        /// Draw pose, or null after retirement. The result owns no storage.
        pub fn shown(self: *const Self, key: Key) ?Shown {
            const entry = self.items.get(key) orelse return null;
            return .{ .rect = rectOf(entry.track.pos), .presence = entry.track.pos[4], .phase = entry.phase };
        }

        /// Replaces out with leaving keys in insertion order, then placed keys in layout order.
        /// The caller owns out and frees it with gpa.
        pub fn drawOrder(self: *const Self, gpa: Allocator, out: *std.ArrayList(Key)) Allocator.Error!void {
            out.clearRetainingCapacity();
            try out.ensureTotalCapacity(gpa, self.items.count());
            for (self.items.keys(), self.items.values()) |key, entry| {
                if (entry.phase == .leaving and !self.placed_set.contains(key)) out.appendAssumeCapacity(key);
            }
            for (self.placed.items) |key| {
                if (self.items.contains(key)) out.appendAssumeCapacity(key);
            }
        }

        /// Nothing is measuring, entering, leaving or moving.
        pub fn settled(self: *const Self) bool {
            if (self.moving) return false;
            for (self.items.values()) |entry| {
                if (entry.phase != .present) return false;
            }
            return true;
        }

        /// Give placed, visible tracks this velocity without moving their poses.
        /// Track.kick is required only when this method is used.
        pub fn fling(self: *Self, vel: [lanes]f32) void {
            if (!@hasDecl(Track, "kick")) @compileError("Rearrange Track needs kick for fling");
            for (self.placed.items) |key| {
                const entry = self.items.getPtr(key).?;
                if (entry.phase != .measuring and entry.phase != .leaving) entry.track.kick(vel);
            }
        }
    };
}

/// Release policy for a row of items.
pub const Snap = struct {
    /// Coast decay in inverse seconds, matching Fling.Tuning.decay.
    decay: f32 = 4.0,
    /// Minimum items/s that guarantees movement in the release direction.
    min_flick: f32 = 0.6,
    /// Maximum distance from the item shown at press; null leaves it uncapped.
    max_step: ?u32 = null,
};

/// Released item index, with pos in items and vel in items/s. Empty rows return zero.
/// Assumes finite pos/vel, positive finite decay and nonnegative finite min_flick.
pub fn snapIndex(from: u32, pos: f32, vel: f32, count: u32, s: Snap) u32 {
    if (count <= 1) return 0;
    // Saturation keeps extreme finite inputs safe before signed arithmetic and clamping.
    const limit: f64 = @floatFromInt(std.math.maxInt(i64) - std.math.maxInt(u32));
    const rest = @as(f64, pos) + @as(f64, vel) / s.decay;
    var index: i64 = @intFromFloat(std.math.clamp(@round(rest), -limit, limit));
    if (@abs(vel) >= s.min_flick) {
        const edge = if (vel > 0) @floor(@as(f64, pos)) + 1 else @ceil(@as(f64, pos)) - 1;
        const flick: i64 = @intFromFloat(std.math.clamp(edge, -limit, limit));
        if (vel > 0) index = @max(index, flick) else if (vel < 0) index = @min(index, flick);
    }
    if (s.max_step) |cap| index = std.math.clamp(index, @as(i64, from) - cap, @as(i64, from) + cap);
    return @intCast(std.math.clamp(index, 0, @as(i64, count) - 1));
}

fn values(rect: Rect, presence: f32) [lanes]f32 {
    return .{ rect.x, rect.y, rect.w, rect.h, presence };
}

fn rectOf(pos: [lanes]f32) Rect {
    return .{ .x = pos[0], .y = pos[1], .w = pos[2], .h = pos[3] };
}

const Linear = struct {
    pos: [lanes]f32 = @splat(0),
    time: ?i128 = null,
    kicked: ?[lanes]f32 = null,

    pub fn snap(self: *Linear, to: [lanes]f32) void {
        self.pos = to;
    }

    pub fn step(self: *Linear, target: [lanes]f32, now_ns: i128) bool {
        const elapsed: f32 = @floatFromInt(@max(0, now_ns - (self.time orelse now_ns)));
        self.time = now_ns;
        var moving = false;
        for (&self.pos, target, 0..) |*pos, to, lane| {
            // Rect lanes travel one point/ms; presence travels 0.01/ms.
            const distance = elapsed / std.time.ns_per_ms * (if (lane == 4) @as(f32, 0.01) else 1);
            pos.* += std.math.clamp(to - pos.*, -distance, distance);
            moving = moving or pos.* != to;
        }
        return moving;
    }

    pub fn kick(self: *Linear, vel: [lanes]f32) void {
        self.kicked = vel;
    }
};
const testing = std.testing;
const Set = Rearrange(Linear);
const test_allocator = testing.allocator;
const ms = std.time.ns_per_ms;

fn frame(set: *Set, keys: []const Key, xs: []const f32, time: i128, follow: bool) !void {
    set.begin();
    std.debug.assert(keys.len == xs.len);
    for (keys, xs) |key, x| try set.place(test_allocator, key, .{ .x = x });
    _ = try set.end(test_allocator, time * ms, .{ .follow = follow });
}

test "rearrange: a key placed in both layouts moves from its shown rect to its new target" {
    var set: Set = .{};
    defer set.deinit(test_allocator);
    try frame(&set, &.{1}, &.{0}, 0, false);
    try frame(&set, &.{1}, &.{0}, 100, false);
    try frame(&set, &.{1}, &.{100}, 150, false);
    try testing.expectEqual(@as(f32, 50), set.shown(1).?.rect.x);
    try frame(&set, &.{1}, &.{100}, 200, false);
    try testing.expectEqual(@as(f32, 100), set.shown(1).?.rect.x);
    try testing.expect(set.settled());
}

test "rearrange: a new key is measured for one frame and holds the others" {
    var set: Set = .{};
    defer set.deinit(test_allocator);
    try frame(&set, &.{1}, &.{0}, 0, false);
    try frame(&set, &.{1}, &.{0}, 100, false);
    try frame(&set, &.{ 2, 1 }, &.{ 20, 100 }, 150, false);
    try testing.expectEqual(Phase.measuring, set.shown(2).?.phase);
    try testing.expectEqual(@as(f32, 0), set.shown(2).?.presence);
    try testing.expectEqual(@as(f32, 0), set.shown(1).?.rect.x);
    try frame(&set, &.{ 2, 1 }, &.{ 20, 100 }, 200, false);
    try testing.expectEqual(Phase.entering, set.shown(2).?.phase);
    try testing.expectEqual(@as(f32, 50), set.shown(1).?.rect.x);
    // Another measuring key holds the destination, but an existing move keeps stepping.
    try frame(&set, &.{ 3, 2, 1 }, &.{ 30, 20, 500 }, 225, false);
    try testing.expectEqual(@as(f32, 75), set.shown(1).?.rect.x);
    try testing.expectEqual(@as(f32, 100), set.items.get(1).?.target.x);
}

test "rearrange: a key left out leaves from where it was shown and is retired at presence 0" {
    var set: Set = .{};
    defer set.deinit(test_allocator);
    try frame(&set, &.{1}, &.{0}, 0, false);
    try frame(&set, &.{1}, &.{0}, 100, false);
    try frame(&set, &.{1}, &.{100}, 150, false);
    try frame(&set, &.{}, &.{}, 175, false);
    try testing.expectEqual(@as(f32, 50), set.shown(1).?.rect.x);
    try testing.expectEqual(@as(f32, 0.75), set.shown(1).?.presence);
    try frame(&set, &.{}, &.{}, 250, false);
    try testing.expectEqual(null, set.shown(1));
}

test "rearrange: a key placed again while leaving turns around without a jump" {
    var set: Set = .{};
    defer set.deinit(test_allocator);
    try frame(&set, &.{1}, &.{0}, 0, false);
    try frame(&set, &.{1}, &.{0}, 100, false);
    try frame(&set, &.{}, &.{}, 150, false);
    const before = set.shown(1).?;
    try frame(&set, &.{1}, &.{100}, 151, false);
    const after = set.shown(1).?;
    try testing.expect(@abs(after.rect.x - before.rect.x) <= 1);
    try testing.expect(@abs(after.presence - before.presence) <= 0.010001);
    try testing.expectEqual(Phase.present, after.phase);
}

test "rearrange: follow puts every item on its target in one frame" {
    var set: Set = .{};
    defer set.deinit(test_allocator);
    try frame(&set, &.{ 1, 2, 3, 4 }, &.{ 0, 0, 0, 0 }, 0, false);
    try frame(&set, &.{ 1, 2, 3, 4 }, &.{ 100, 200, 300, 400 }, 50, false);
    try frame(&set, &.{ 1, 2, 3, 5 }, &.{ 100, 200, 300, 500 }, 75, true);
    for ([_]Key{ 1, 2, 3, 5 }, [_]f32{ 100, 200, 300, 500 }) |key, x| {
        try testing.expectEqual(Shown{ .rect = .{ .x = x }, .presence = 1, .phase = .present }, set.shown(key).?);
    }
    try testing.expectEqual(null, set.shown(4));
    try testing.expect(set.settled());
}

test "rearrange: draw order is leaving first, then layout order" {
    var set: Set = .{};
    defer set.deinit(test_allocator);
    var order: std.ArrayList(Key) = .empty;
    defer order.deinit(test_allocator);
    try frame(&set, &.{ 3, 1, 2 }, &.{ 0, 0, 0 }, 0, false);
    try frame(&set, &.{ 3, 1, 2 }, &.{ 0, 0, 0 }, 100, false);
    try frame(&set, &.{ 3, 2 }, &.{ 0, 0 }, 150, false);
    try set.drawOrder(test_allocator, &order);
    try testing.expectEqualSlices(Key, &.{ 1, 3, 2 }, order.items);
}

test "rearrange: a measuring key not placed again is dropped, never drawn" {
    var set: Set = .{};
    defer set.deinit(test_allocator);
    var order: std.ArrayList(Key) = .empty;
    defer order.deinit(test_allocator);
    try frame(&set, &.{1}, &.{0}, 0, false);
    try frame(&set, &.{}, &.{}, 1, false);
    try testing.expectEqual(null, set.shown(1));
    try set.drawOrder(test_allocator, &order);
    try testing.expectEqual(@as(usize, 0), order.items.len);
}

test "rearrange: the same frame time twice moves nothing" {
    var set: Set = .{};
    defer set.deinit(test_allocator);
    try frame(&set, &.{ 1, 2 }, &.{ 0, 0 }, 0, false);
    const measuring = set.shown(1).?;
    _ = try set.end(test_allocator, 0, .{});
    try testing.expectEqual(measuring, set.shown(1).?);
    try frame(&set, &.{ 1, 2 }, &.{ 0, 0 }, 100, false);
    try frame(&set, &.{ 1, 2 }, &.{ 100, 200 }, 150, false);
    const before = [_]Shown{ set.shown(1).?, set.shown(2).? };
    _ = try set.end(test_allocator, 150 * ms, .{});
    try testing.expectEqual(before, [_]Shown{ set.shown(1).?, set.shown(2).? });
}

test "rearrange: fling gives placed tracks the speed, not leaving or measuring ones" {
    var set: Set = .{};
    defer set.deinit(test_allocator);
    try frame(&set, &.{ 1, 2 }, &.{ 0, 0 }, 0, false);
    try frame(&set, &.{ 1, 2 }, &.{ 0, 0 }, 100, false);
    try frame(&set, &.{1}, &.{0}, 125, false);
    set.begin();
    try set.place(test_allocator, 1, .{});
    try set.place(test_allocator, 2, .{});
    try set.place(test_allocator, 3, .{});
    const velocity: [lanes]f32 = .{ 300, 0, 0, 0, 0 };
    set.fling(velocity);
    try testing.expectEqual(velocity, set.items.get(1).?.track.kicked.?);
    try testing.expectEqual(null, set.items.get(2).?.track.kicked);
    try testing.expectEqual(null, set.items.get(3).?.track.kicked);
}

test "rearrange: snapIndex" {
    const Case = struct { pos: f32, vel: f32 = 0, from: u32 = 2, count: u32 = 5, cap: ?u32 = null, want: u32 };
    const cases = [_]Case{
        .{ .pos = 2.4, .want = 2 }, // Slow release below half.
        .{ .pos = 2.6, .want = 3 }, // Slow release above half.
        .{ .pos = 2.1, .vel = 0.7, .want = 3 }, // Positive flick beats rounding.
        .{ .pos = 2.9, .vel = -0.7, .want = 2 }, // Negative flick beats rounding.
        .{ .pos = 2, .vel = 40, .cap = 1, .want = 3 }, // Pager caps a hard flick.
        .{ .pos = 2, .vel = 40, .want = 4 }, // Uncapped flick reaches the end.
        .{ .pos = 0.2, .vel = -40, .want = 0 }, // Lower bound.
        .{ .pos = 2, .count = 0, .want = 0 }, // Empty row.
        .{ .pos = 100, .vel = 40, .count = 1, .want = 0 }, // Singleton row.
    };
    for (cases) |case| try testing.expectEqual(case.want, snapIndex(case.from, case.pos, case.vel, case.count, .{ .max_step = case.cap }));
}

test "rearrange: a press on a moving row keeps every shown rect" {
    var set: Set = .{};
    defer set.deinit(test_allocator);
    const keys = [_]Key{ 1, 2, 3 };
    try frame(&set, &keys, &.{ 0, 0, 0 }, 0, false);
    try frame(&set, &keys, &.{ 0, 0, 0 }, 100, false);
    try frame(&set, &keys, &.{ 100, 200, 300 }, 150, false);
    const poses = [_]Rect{ set.shown(1).?.rect, set.shown(2).?.rect, set.shown(3).?.rect };
    set.begin();
    for (keys, poses) |key, pose| try set.place(test_allocator, key, pose);
    set.fling(@splat(0));
    try testing.expect(!try set.end(test_allocator, 151 * ms, .{ .follow = true }));
    for (keys, poses) |key, pose| try testing.expectEqual(pose, set.shown(key).?.rect);
    try testing.expect(set.settled());
}

test "rearrange: duplicate placement keeps the last rect and draws once" {
    var set: Set = .{};
    defer set.deinit(test_allocator);
    var order: std.ArrayList(Key) = .empty;
    defer order.deinit(test_allocator);
    set.begin();
    try set.place(test_allocator, 1, .{ .x = 10 });
    try set.place(test_allocator, 1, .{ .x = 20 });
    _ = try set.end(test_allocator, 0, .{});
    try testing.expectEqual(@as(f32, 20), set.shown(1).?.rect.x);
    try set.drawOrder(test_allocator, &order);
    try testing.expectEqualSlices(Key, &.{1}, order.items);
}

test "rearrange: a track without kick can run a set" {
    const NoKick = struct {
        pos: [lanes]f32 = @splat(0),
        pub fn snap(self: *@This(), to: [lanes]f32) void {
            self.pos = to;
        }
        pub fn step(self: *@This(), target: [lanes]f32, _: i128) bool {
            self.pos = target;
            return false;
        }
    };
    var set: Rearrange(NoKick) = .{};
    defer set.deinit(test_allocator);
    set.begin();
    try set.place(test_allocator, 1, .{});
    try testing.expect(!try set.end(test_allocator, 0, .{ .follow = true }));
}

test "rearrange: allocation failures release all owned storage" {
    try testing.checkAllAllocationFailures(test_allocator, allocationFailure, .{});
}

fn allocationFailure(allocator: Allocator) !void {
    var set: Set = .{};
    defer set.deinit(allocator);
    var order: std.ArrayList(Key) = .empty;
    defer order.deinit(allocator);
    set.begin();
    try set.place(allocator, 1, .{ .x = 10 });
    _ = try set.end(allocator, 0, .{});
    try set.drawOrder(allocator, &order);
}

test "rearrange: measurement uses the second layout's complete rect" {
    var set: Set = .{};
    defer set.deinit(test_allocator);
    set.begin();
    try set.place(test_allocator, 1, .{ .x = 10, .y = 20, .w = 30, .h = 40 });
    _ = try set.end(test_allocator, 0, .{});
    const measured: Rect = .{ .x = 100, .y = 200, .w = 300, .h = 400 };
    set.begin();
    try set.place(test_allocator, 1, measured);
    try testing.expect(try set.end(test_allocator, 50 * ms, .{}));
    const shown = set.shown(1).?;
    try testing.expectEqual(measured, shown.rect);
    try testing.expectEqual(@as(f32, 0.5), shown.presence);
    try testing.expectEqual(Phase.entering, shown.phase);
}

test "rearrange: follow retires leaving items and reveals measuring items" {
    var set: Set = .{};
    defer set.deinit(test_allocator);
    try frame(&set, &.{ 1, 2 }, &.{ 0, 0 }, 0, false);
    try frame(&set, &.{ 1, 2 }, &.{ 0, 0 }, 100, false);
    try frame(&set, &.{ 2, 3 }, &.{ 100, 200 }, 125, false);
    try testing.expectEqual(Phase.leaving, set.shown(1).?.phase);
    try testing.expectEqual(Phase.measuring, set.shown(3).?.phase);
    set.begin();
    const target: Rect = .{ .x = 20, .y = 30, .w = 40, .h = 50 };
    try set.place(test_allocator, 2, target);
    try set.place(test_allocator, 3, target);
    try testing.expect(!try set.end(test_allocator, 126 * ms, .{ .follow = true }));
    try testing.expectEqual(null, set.shown(1));
    for ([_]Key{ 2, 3 }) |key| {
        try testing.expectEqual(Shown{ .rect = target, .presence = 1, .phase = .present }, set.shown(key).?);
    }
    try testing.expect(set.settled());
}
