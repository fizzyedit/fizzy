//! Trackpad axis choice preserves intended travel across sampling rates and gesture gaps.
const std = @import("std");
const AxisLock = @import("AxisLock.zig");

fn samples(lock: *AxisLock, n: usize, dx: f32, dy: f32, ms: i128) [2]f32 {
    var total: [2]f32 = .{ 0, 0 };
    var now = lock.last_ns orelse 0;
    for (0..n) |_| {
        now += ms * std.time.ns_per_ms;
        if (dx != 0) total[0] += lock.filter(.horizontal, dx, now);
        if (dy != 0) total[1] += lock.filter(.vertical, dy, now);
    }
    return total;
}

test "a sideways swipe keeps all horizontal travel and no vertical travel" {
    var lock: AxisLock = .{};
    const total = samples(&lock, 30, 8, 2, 16);
    try std.testing.expectEqual(@as(f32, 240), total[0]);
    try std.testing.expectEqual(@as(f32, 0), total[1]);
}

test "a vertical swipe suppresses horizontal travel" {
    var lock: AxisLock = .{};
    const total = samples(&lock, 40, 0.8, 10, 16);
    try std.testing.expectEqual(@as(f32, 0), total[0]);
    try std.testing.expectEqual(@as(f32, 400), total[1]);
}

test "a diagonal stays free" {
    var lock: AxisLock = .{};
    const total = samples(&lock, 20, 5, 5, 16);
    try std.testing.expect(total[0] >= 95);
    try std.testing.expect(total[1] >= 95);
}

test "cross travel breaks out only past twenty one points" {
    var lock: AxisLock = .{};
    _ = samples(&lock, 2, 0, 10, 16);
    try std.testing.expectEqual(@as(f32, 0), lock.filter(.horizontal, 20, lock.last_ns.?));
    try std.testing.expectEqual(@as(f32, 2), lock.filter(.horizontal, 2, lock.last_ns.?));
}

test "steady jitter never breaks the lock" {
    var lock: AxisLock = .{};
    const total = samples(&lock, 100, 0.3, 3, 16);
    try std.testing.expectEqual(@as(f32, 0), total[0]);
}

test "a long gap decides again but a hundred milliseconds keeps the lock" {
    var lock: AxisLock = .{};
    _ = samples(&lock, 2, 0, 10, 16);
    try std.testing.expectEqual(@as(f32, 0), lock.filter(.horizontal, 8, lock.last_ns.? + 100 * std.time.ns_per_ms));
    try std.testing.expectEqual(@as(f32, 0), lock.filter(.horizontal, 2, lock.last_ns.?));
    try std.testing.expectEqual(@as(f32, 0), lock.filter(.horizontal, 10, lock.last_ns.? + 121 * std.time.ns_per_ms));
    try std.testing.expectEqual(@as(f32, 20), lock.filter(.horizontal, 10, lock.last_ns.?));
}

test "equal distance at sixty and one hundred twenty hertz gives equal travel" {
    var slow: AxisLock = .{};
    var fast: AxisLock = .{};
    try std.testing.expectEqual(samples(&slow, 30, 10, 1, 16), samples(&fast, 60, 5, 0.5, 8));
}
