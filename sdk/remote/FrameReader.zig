//! Cuts a byte stream into frames. Feed it whatever a transport read, in any chunk sizes; ask for
//! frames until it says there are no more. No sockets, no blocking: the transport is the caller's.
const std = @import("std");
const codec = @import("codec.zig");
const message = @import("message.zig");

const FrameReader = @This();

gpa: std.mem.Allocator,
buf: std.ArrayList(u8) = .empty,
/// Start of the unread bytes in `buf`.
pos: usize = 0,
max_frame: usize = codec.default_max_frame,

pub fn init(gpa: std.mem.Allocator) FrameReader {
    return .{ .gpa = gpa };
}

pub fn deinit(self: *FrameReader) void {
    self.buf.deinit(self.gpa);
}

/// Add bytes read from the stream. Invalidates frames handed out before.
pub fn push(self: *FrameReader, bytes: []const u8) error{OutOfMemory}!void {
    if (self.pos > 0 and self.pos >= self.buf.items.len / 2) {
        const rest = self.buf.items.len - self.pos;
        std.mem.copyForwards(u8, self.buf.items[0..rest], self.buf.items[self.pos..]);
        self.buf.shrinkRetainingCapacity(rest);
        self.pos = 0;
    }
    try self.buf.appendSlice(self.gpa, bytes);
}

/// The next whole frame, or null when more bytes are needed. The oversize and short-header errors
/// are decided from the header alone, before the body is waited for; after one the stream cannot
/// be resynchronised and should be closed. The payload is valid until the next `push`.
pub fn next(self: *FrameReader) codec.Error!?codec.Frame {
    const avail = self.buf.items[self.pos..];
    if (avail.len < codec.prefix_len) return null;
    const len = std.mem.readInt(u32, avail[0..4], .little);
    if (len < codec.header_len) return error.Malformed;
    if (len > self.max_frame) return error.FrameTooLarge;
    if (avail.len - codec.prefix_len < len) return null;
    const body = avail[codec.prefix_len..][0..len];
    self.pos += codec.prefix_len + len;
    return .{
        .type = @fromBackingInt(@intCast(std.mem.readInt(u16, body[0..2], .little))),
        .flags = std.mem.readInt(u16, body[2..4], .little),
        .payload = body[codec.header_len..],
    };
}

test "frames split across any chunking" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try codec.encode(gpa, &out, .{ .focus = .{ .view = 1, .focused = true } }, codec.default_max_frame);
    try codec.encode(gpa, &out, .{ .wants_keys = .{ .view = 1, .wants = false } }, codec.default_max_frame);

    var chunk: usize = 1;
    while (chunk <= out.items.len) : (chunk += 1) {
        var r = FrameReader.init(gpa);
        defer r.deinit();
        var seen: usize = 0;
        var i: usize = 0;
        while (i < out.items.len) : (i += chunk) {
            try r.push(out.items[i..@min(i + chunk, out.items.len)]);
            while (try r.next()) |f| {
                try std.testing.expectEqual(if (seen == 0) message.Type.focus else .wants_keys, f.type);
                seen += 1;
            }
        }
        try std.testing.expectEqual(@as(usize, 2), seen);
    }
}

test "oversize and short headers are refused from the header alone" {
    var r = FrameReader.init(std.testing.allocator);
    defer r.deinit();
    r.max_frame = 100;
    try r.push(&.{ 200, 0, 0, 0 });
    try std.testing.expectError(error.FrameTooLarge, r.next());

    var s = FrameReader.init(std.testing.allocator);
    defer s.deinit();
    try s.push(&.{ 3, 0, 0, 0 });
    try std.testing.expectError(error.Malformed, s.next());
}
