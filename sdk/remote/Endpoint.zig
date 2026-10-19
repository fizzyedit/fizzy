//! One end of a socket-style transport: a `Connection` with the bytes around it. Write what
//! `pending` holds to the stream and `consume` what was written; `feed` what the stream gave, and
//! `poll` for messages. It never reads or writes a stream itself, so any event loop can drive it
//! and no thread is needed per view.
const std = @import("std");
const message = @import("message.zig");
const codec = @import("codec.zig");
const Connection = @import("Connection.zig");
const FrameReader = @import("FrameReader.zig");

const Endpoint = @This();

pub const Error = Connection.Error || codec.Error;

gpa: std.mem.Allocator,
conn: Connection,
reader: FrameReader,
out: std.ArrayList(u8) = .empty,

pub fn init(gpa: std.mem.Allocator, role: Connection.Role, local: message.Hello) Endpoint {
    return .{ .gpa = gpa, .conn = Connection.init(gpa, role, local), .reader = FrameReader.init(gpa) };
}

pub fn deinit(self: *Endpoint) void {
    self.conn.deinit();
    self.reader.deinit();
    self.out.deinit(self.gpa);
}

/// Queue our hello. Each side does this first.
pub fn start(self: *Endpoint) Error!void {
    try self.send(.{ .hello = self.conn.local });
}

/// Check `msg` against the conversation's rules and queue its frame.
pub fn send(self: *Endpoint, msg: message.Message) Error!void {
    const mark = self.out.items.len;
    try codec.encode(self.gpa, &self.out, msg, self.reader.max_frame);
    errdefer self.out.shrinkRetainingCapacity(mark);
    try self.conn.sending(msg);
}

/// Bytes waiting to be written to the stream.
pub fn pending(self: *const Endpoint) []const u8 {
    return self.out.items;
}

/// `n` bytes of `pending` were written.
pub fn consume(self: *Endpoint, n: usize) void {
    std.debug.assert(n <= self.out.items.len);
    const rest = self.out.items.len - n;
    std.mem.copyForwards(u8, self.out.items[0..rest], self.out.items[n..]);
    self.out.shrinkRetainingCapacity(rest);
}

/// Bytes read from the stream.
pub fn feed(self: *Endpoint, bytes: []const u8) error{OutOfMemory}!void {
    try self.reader.push(bytes);
}

/// The next message the peer sent, or null when more bytes are needed. Lists are allocated from
/// `arena`; strings and pixels borrow the reader, so a message is valid until the next `feed`.
/// Unknown optional types are skipped. A version mismatch queues a `bye` that says who must
/// update and returns `error.VersionSkew`; a protocol violation queues one and returns its error.
/// After any error the stream is dead: write `pending` out and close it.
pub fn poll(self: *Endpoint, arena: std.mem.Allocator) Error!?message.Message {
    while (true) {
        if (self.conn.state == .closed) return null;
        const frame = (self.reader.next() catch |e| return self.violation(e)) orelse return null;
        const msg = (codec.decode(arena, frame) catch |e| return self.violation(e)) orelse continue;
        self.conn.received(msg) catch |e| {
            if (e == error.VersionSkew) {
                const who = self.conn.skew.?;
                self.queueBye(.{ .reason = self.conn.close_reason.?, .text = message.updateAdvice(who) });
            } else self.queueBye(.{ .reason = .protocol_error, .text = @errorName(e) });
            return e;
        };
        return msg;
    }
}

fn violation(self: *Endpoint, e: Error) Error {
    self.queueBye(.{ .reason = .protocol_error, .text = @errorName(e) });
    return e;
}

/// The stream is dead either way; the bye is best effort.
fn queueBye(self: *Endpoint, bye: message.Bye) void {
    self.conn.state = .closed;
    codec.encode(self.gpa, &self.out, .{ .bye = bye }, codec.default_max_frame) catch return;
}

/// Move everything `from` has queued into `to`, `chunk` bytes at a time (a stream may split
/// anywhere). For tests and in-process loopback.
pub fn pump(from: *Endpoint, to: *Endpoint, chunk: usize) error{OutOfMemory}!void {
    while (from.pending().len > 0) {
        const n = @min(chunk, from.pending().len);
        try to.feed(from.pending()[0..n]);
        from.consume(n);
    }
}

const t = std.testing;

test "two endpoints talk over a loopback, however the bytes are cut" {
    for ([_]usize{ 1, 3, 7, 4096 }) |chunk| {
        var host = Endpoint.init(t.allocator, .host, .{ .app_id = "blender" });
        defer host.deinit();
        var editor = Endpoint.init(t.allocator, .editor, .{ .app_id = "fizzy", .mode = .shared });
        defer editor.deinit();
        var arena_state = std.heap.ArenaAllocator.init(t.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        try host.start();
        try editor.start();
        try t.expectError(error.NotOpen, host.send(.{ .create_view = .{ .view = 1, .width = 640, .height = 480 } }));
        try pump(&host, &editor, chunk);
        try pump(&editor, &host, chunk);
        try t.expectEqualStrings("blender", (try editor.poll(arena)).?.hello.app_id);
        try t.expectEqual(message.Mode.shared, (try host.poll(arena)).?.hello.mode);

        try host.send(.{ .create_view = .{ .view = 1, .width = 640, .height = 480, .target = "region" } });
        try pump(&host, &editor, chunk);
        const cv = (try editor.poll(arena)).?.create_view;
        try t.expectEqualStrings("region", cv.target);
        try editor.send(.{ .view_created = .{ .view = 1, .tier = .draw_list, .width = 640, .height = 480 } });
        try pump(&editor, &host, chunk);
        try t.expectEqual(@as(u32, 640), (try host.poll(arena)).?.view_created.width);
        try t.expect(try host.poll(arena) == null);
    }
}

test "a skewed hello gets a bye saying who updates" {
    var host = Endpoint.init(t.allocator, .host, .{ .version_min = 9, .version_max = 9 });
    defer host.deinit();
    var editor = Endpoint.init(t.allocator, .editor, .{});
    defer editor.deinit();
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    try host.start();
    try pump(&host, &editor, 64);
    try t.expectError(error.VersionSkew, editor.poll(arena_state.allocator()));
    try pump(&editor, &host, 64);
    const bye = (try host.poll(arena_state.allocator())).?.bye;
    try t.expectEqual(message.CloseReason.your_side_too_new, bye.reason);
    try t.expectEqualStrings("update fizzy", bye.text);
}

test "garbage closes with a protocol error" {
    var editor = Endpoint.init(t.allocator, .editor, .{});
    defer editor.deinit();
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    try editor.feed(&.{ 1, 0, 0, 0 });
    try t.expectError(error.Malformed, editor.poll(arena_state.allocator()));
    try t.expect(editor.pending().len > 0);
}
