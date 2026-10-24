//! Merge time and memory of `Replica` on a large text. `zig run -O ReleaseFast bench.zig`
//! prints the numbers for 1 MB; the test below runs the same code small, so it stays working.

const std = @import("std");
const Replica = @import("Replica.zig");
const Op = @import("op.zig").Op;

/// Two replicas each type `n` characters and make `edits` random edits, concurrently; then each
/// applies the other's ops. Returns nanoseconds to merge and the bytes one replica holds.
fn run(gpa: std.mem.Allocator, n: usize, edits: usize, io: std.Io) !struct { type_ns: i96, merge_ns: i96, bytes: usize, items: usize } {
    var base = try Replica.init(gpa, 1);
    defer base.deinit();
    var a = try Replica.init(gpa, 2);
    defer a.deinit();
    var b = try Replica.init(gpa, 3);
    defer b.deinit();

    var prng: std.Random.DefaultPrng = .init(7);
    const rand = prng.random();
    var shared: std.ArrayList(Op) = .empty;
    defer shared.deinit(gpa);
    // The shared start: typed at the end, one character after another.
    const typed = std.Io.Timestamp.now(io, .awake);
    for (0..n) |i| try shared.append(gpa, try base.insert(i, 'a' + @as(u21, @intCast(i % 26))));
    const type_ns = typed.untilNow(io, .awake).toNanoseconds();
    for (shared.items) |o| {
        try a.apply(o);
        try b.apply(o);
    }

    var from_a: std.ArrayList(Op) = .empty;
    defer from_a.deinit(gpa);
    var from_b: std.ArrayList(Op) = .empty;
    defer from_b.deinit(gpa);
    for ([_]struct { *Replica, *std.ArrayList(Op) }{ .{ &a, &from_a }, .{ &b, &from_b } }) |side| {
        const r, const log = side;
        for (0..edits) |_| {
            if (rand.uintLessThan(u8, 4) == 0) {
                if (r.delete(rand.uintLessThan(usize, r.len()))) |o| try log.append(gpa, o);
            } else try log.append(gpa, try r.insert(rand.uintAtMost(usize, r.len()), 'A' + rand.uintLessThan(u21, 26)));
        }
    }

    const start = std.Io.Timestamp.now(io, .awake);
    for (from_b.items) |o| try a.apply(o);
    for (from_a.items) |o| try b.apply(o);
    const merge_ns = start.untilNow(io, .awake).toNanoseconds();

    const ta = try a.toOwnedText(gpa);
    defer gpa.free(ta);
    const tb = try b.toOwnedText(gpa);
    defer gpa.free(tb);
    if (!std.mem.eql(u8, ta, tb)) return error.Diverged;
    return .{ .type_ns = type_ns, .merge_ns = merge_ns, .bytes = a.memoryUsed(), .items = a.items.len };
}

pub fn main(init: std.process.Init) !void {
    const res = try run(init.gpa, 1_000_000, 5_000, init.io);
    std.debug.print("1M chars shared + 2x5000 concurrent edits: type {d} ms, merge {d} ms, {d} bytes ({d:.1} per char)\n", .{
        @divTrunc(res.type_ns, std.time.ns_per_ms),
        @divTrunc(res.merge_ns, std.time.ns_per_ms),
        res.bytes,
        @as(f64, @floatFromInt(res.bytes)) / @as(f64, @floatFromInt(res.items)),
    });
}

test "the benchmark's scenario converges" {
    const res = try run(std.testing.allocator, 2000, 200, std.testing.io);
    try std.testing.expect(res.items > 2000);
}
