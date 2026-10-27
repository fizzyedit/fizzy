//! Waiting for a thread at shutdown for only so long. std-only, so its test needs no window.

const std = @import("std");

/// Waits until `done` is set, up to `bound_ms`, then joins `thread`; past the bound, detaches it
/// instead and returns false. The caller owns what the thread still touches: it must outlive
/// the process or the thread must touch nothing torn down meanwhile.
pub fn joinWithin(io: std.Io, thread: std.Thread, done: *const std.atomic.Value(bool), bound_ms: u32) bool {
    var waited_ms: u32 = 0;
    while (!done.load(.acquire)) : (waited_ms += poll_ms) {
        if (waited_ms >= bound_ms) {
            thread.detach();
            return false;
        }
        io.sleep(.fromMilliseconds(poll_ms), .awake) catch {};
    }
    thread.join();
    return true;
}

const poll_ms = 5;

test "a stalled thread is detached once the bound passes" {
    const Stall = struct {
        var release: std.atomic.Value(bool) = .init(false);
        var done: std.atomic.Value(bool) = .init(false);
        fn run(io: std.Io) void {
            while (!release.load(.acquire)) io.sleep(.fromMilliseconds(1), .awake) catch {};
            done.store(true, .release);
        }
    };
    const io = std.testing.io;
    const thread = try std.Thread.spawn(.{}, Stall.run, .{io});
    const start = std.Io.Clock.awake.now(io);
    try std.testing.expect(!joinWithin(io, thread, &Stall.done, 50));
    const elapsed = start.durationTo(std.Io.Clock.awake.now(io));
    try std.testing.expect(elapsed.toMilliseconds() < 1000);
    Stall.release.store(true, .release);
    while (!Stall.done.load(.acquire)) io.sleep(.fromMilliseconds(1), .awake) catch {};
}

test "a finished thread is joined" {
    const Quick = struct {
        var done: std.atomic.Value(bool) = .init(false);
        fn run() void {
            done.store(true, .release);
        }
    };
    const thread = try std.Thread.spawn(.{}, Quick.run, .{});
    try std.testing.expect(joinWithin(std.testing.io, thread, &Quick.done, 1000));
}
