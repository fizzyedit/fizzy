//! The two byte queues between a connection the server upgraded (`GET /remote`) and the app: what
//! the peer sent, and what the app wants sent. The connection's tasks fill the first and empty the
//! second; the UI thread does the opposite, once a frame, so a connection costs the frame no
//! blocking read or write (`Server.serveLink`).
//!
//! std-only, like the server that carries it.
const std = @import("std");
const Io = std.Io;

const Link = @This();

/// The most that may wait on either side: a peer that reads slower than the app writes, or sends
/// faster than the app takes, is cut off rather than buffered without end. It must hold a whole
/// frame of the remote-view protocol (32 MiB) with room for the traffic behind it; this file is
/// std-only, so `remote/Session.zig` asserts that at comptime.
pub const max_backlog = 64 * 1024 * 1024;

/// How long a closing link may take to write what is queued before `reapStuck` cuts it off.
pub const close_grace_ms = 2000;

gpa: std.mem.Allocator,
io: Io,
/// Wakes the app so its next frame reads what arrived. Safe from any thread.
wake: *const fn () void,
lock: Io.Mutex = .init,
/// From the peer, under `lock`.
inbox: std.ArrayList(u8) = .empty,
/// To the peer, under `lock`.
outbox: std.ArrayList(u8) = .empty,
out_ready: Io.Event = .unset,
/// When `close` was first called (awake-clock ns + 1), 0 before: `reapStuck` measures from it.
closed_at: std.atomic.Value(u64) = .init(0),
/// The app is done with the link: its tasks end, and the socket with them. Set by `close`.
closing: std.atomic.Value(bool) = .init(false),
/// The connection's tasks are done with the link: the peer left, or `close` was answered. Only
/// then may the app `deinit` it; the tasks touch nothing after setting this.
gone: std.atomic.Value(bool) = .init(false),
/// Set when either of the connection's tasks ends, or by `abort`: the supervising task then cancels
/// both, which frees one blocked in the socket.
ended: Io.Event = .unset,
/// The connection's socket, once its task has one, under `lock`: `abort` shuts it down.
stream: ?Io.net.Stream = null,

pub fn init(gpa: std.mem.Allocator, io: Io, wake: *const fn () void) Link {
    return .{ .gpa = gpa, .io = io, .wake = wake };
}

/// Free the queues. Only once `isGone`, or if the server never served it.
pub fn deinit(self: *Link) void {
    self.inbox.deinit(self.gpa);
    self.outbox.deinit(self.gpa);
}

/// Move what the peer has sent so far onto the end of `out`. UI thread.
pub fn take(self: *Link, out: *std.ArrayList(u8)) error{OutOfMemory}!void {
    self.lock.lockUncancelable(self.io);
    defer self.lock.unlock(self.io);
    try out.appendSlice(self.gpa, self.inbox.items);
    self.inbox.clearRetainingCapacity();
}

/// Queue `bytes` for the peer. A peer too far behind is closed instead. UI thread.
pub fn send(self: *Link, bytes: []const u8) error{OutOfMemory}!void {
    if (self.closing.load(.acquire) or self.gone.load(.acquire)) return;
    {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        if (self.outbox.items.len + bytes.len <= max_backlog) {
            try self.outbox.appendSlice(self.gpa, bytes);
            self.out_ready.set(self.io);
            return;
        }
    }
    self.abort();
}

/// End the connection once what is queued is written. UI thread.
pub fn close(self: *Link) void {
    const now: u64 = @intCast(Io.Clock.awake.now(self.io).nanoseconds + 1);
    _ = self.closed_at.cmpxchgStrong(0, now, .acq_rel, .acquire);
    self.closing.store(true, .release);
    self.out_ready.set(self.io);
}

/// End the connection now, dropping what is queued: a peer that does not read would otherwise
/// leave the writer blocked and `close` unheard. UI thread.
pub fn abort(self: *Link) void {
    self.close();
    self.lock.lockUncancelable(self.io);
    defer self.lock.unlock(self.io);
    if (self.stream) |s| s.shutdown(self.io, .both) catch {};
    self.ended.set(self.io);
}

/// A `close` that nobody heard (the writer is blocked on a peer that does not read) is made an
/// `abort` once it has waited `close_grace_ms`. True when it did. UI thread, once a frame.
pub fn reapStuck(self: *Link) bool {
    const at = self.closed_at.load(.acquire);
    if (at == 0 or self.gone.load(.acquire)) return false;
    const now: u64 = @intCast(Io.Clock.awake.now(self.io).nanoseconds + 1);
    if (now -| at < close_grace_ms * std.time.ns_per_ms) return false;
    self.abort();
    return true;
}

pub fn isGone(self: *const Link) bool {
    return self.gone.load(.acquire);
}

/// From the connection's reader task: bytes arrived. A peer that sends more than the app takes
/// is refused the rest (`error.OutOfMemory`, which ends the connection).
pub fn push(self: *Link, bytes: []const u8) error{OutOfMemory}!void {
    {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        if (self.inbox.items.len + bytes.len > max_backlog) return error.OutOfMemory;
        try self.inbox.appendSlice(self.gpa, bytes);
    }
    self.wake();
}

/// From the connection's writer task: everything queued so far, which the caller frees; null when
/// there is nothing and the link is not closing.
pub fn drain(self: *Link) error{OutOfMemory}!?[]u8 {
    self.lock.lockUncancelable(self.io);
    defer self.lock.unlock(self.io);
    self.out_ready.reset();
    // A `close` that came after the caller read `closing` set the event before this reset.
    if (self.closing.load(.acquire)) self.out_ready.set(self.io);
    if (self.outbox.items.len == 0) return null;
    return try self.outbox.toOwnedSlice(self.gpa);
}

/// From the connection's task, last: it will not touch the link again.
pub fn finish(self: *Link) void {
    // Read first: the app frees the link once it sees `gone`.
    const wake = self.wake;
    self.gone.store(true, .release);
    wake();
}

fn noWake() void {}

test "bytes cross in both directions, and a link too far behind is closed" {
    const gpa = std.testing.allocator;
    var link: Link = .init(gpa, std.testing.io, noWake);
    defer link.deinit();
    try link.push("ab");
    try link.push("cd");
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(gpa);
    try link.take(&got);
    try std.testing.expectEqualStrings("abcd", got.items);

    try std.testing.expect((try link.drain()) == null);
    try link.send("xy");
    const out = (try link.drain()).?;
    defer gpa.free(out);
    try std.testing.expectEqualStrings("xy", out);

    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(gpa);
    try big.appendNTimes(gpa, 0, max_backlog);
    try link.send(big.items);
    try link.send("z");
    try std.testing.expect(link.closing.load(.acquire));
    link.outbox.clearRetainingCapacity();
}

test "a frame between 8 and 32 MiB crosses in both directions" {
    const gpa = std.testing.allocator;
    var link: Link = .init(gpa, std.testing.io, noWake);
    defer link.deinit();
    const frame = try gpa.alloc(u8, 20 * 1024 * 1024);
    defer gpa.free(frame);
    @memset(frame, 7);
    try link.push(frame);
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(gpa);
    try link.take(&got);
    try std.testing.expectEqual(frame.len, got.items.len);

    try link.send(frame);
    try std.testing.expect(!link.closing.load(.acquire));
    const out = (try link.drain()).?;
    defer gpa.free(out);
    try std.testing.expectEqual(frame.len, out.len);
}
