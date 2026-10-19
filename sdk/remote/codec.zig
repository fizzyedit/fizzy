//! Framing, and encoding a `Message` to bytes and back.
//!
//! A frame is `len: u32` (the bytes after it, at least the 4-byte header), `type: u16`,
//! `flags: u16` (bit 0: required), then the payload; all integers little-endian. The payload is
//! the message struct's fields in order (see `message.zig` for the rules that let it grow).
const std = @import("std");
const message = @import("message.zig");
const Message = message.Message;
const Type = message.Type;

pub const Error = error{
    /// The bytes end before the value does.
    Truncated,
    /// A bool that is not 0 or 1.
    InvalidValue,
    /// A frame, or a message to encode, longer than the limit.
    FrameTooLarge,
    /// A frame header that cannot be one.
    Malformed,
    /// A type this peer does not know, marked required by its sender.
    UnknownRequired,
    OutOfMemory,
};

/// The bytes of a frame after the length: type and flags.
pub const header_len = 4;
/// The length prefix.
pub const prefix_len = 4;
/// Frames longer than this are refused unless a reader is told otherwise. A frame carries at most
/// a texture update, so this is generous.
pub const default_max_frame = 32 * 1024 * 1024;

pub const flag_required: u16 = 1;

/// One frame as read off a stream: its payload borrows the reader's buffer.
pub const Frame = struct {
    type: Type,
    flags: u16,
    payload: []const u8,
};

/// Append the frame (the whole message is built before the limit is checked, so a huge one costs
/// its memory briefly) for `msg` to `out`. On error `out` is left as it was.
pub fn encode(gpa: std.mem.Allocator, out: *std.ArrayList(u8), msg: Message, max_frame: usize) Error!void {
    const start = out.items.len;
    errdefer out.shrinkRetainingCapacity(start);
    const t = msg.tag();
    try out.appendNTimes(gpa, 0, prefix_len + header_len);
    var sink: Sink = .{ .list = out, .gpa = gpa };
    switch (msg) {
        inline else => |p| try encodeValue(@TypeOf(p), p, &sink),
    }
    const len = out.items.len - start - prefix_len;
    if (len > max_frame or len > std.math.maxInt(u32)) return error.FrameTooLarge;
    const h = out.items[start..][0 .. prefix_len + header_len];
    std.mem.writeInt(u32, h[0..4], @intCast(len), .little);
    std.mem.writeInt(u16, h[4..6], @backingInt(t), .little);
    std.mem.writeInt(u16, h[6..8], if (t.required()) flag_required else 0, .little);
}

/// Decode a frame's payload. Strings and pixels borrow `frame.payload`; lists are allocated from
/// `arena`, which the caller resets. Null when the type is unknown and optional (skipped by its
/// length); `error.UnknownRequired` when it is unknown and required.
pub fn decode(arena: std.mem.Allocator, frame: Frame) Error!?Message {
    var src: Source = .{ .bytes = frame.payload, .arena = arena };
    switch (frame.type) {
        inline else => |t| {
            const Payload = @FieldType(Message, @tagName(t));
            const p = try decodeStruct(Payload, &src, true);
            return @unionInit(Message, @tagName(t), p);
        },
        _ => {
            if (frame.flags & flag_required != 0) return error.UnknownRequired;
            return null;
        },
    }
}

const Sink = struct {
    list: *std.ArrayList(u8),
    gpa: std.mem.Allocator,

    fn bytes(s: *Sink, b: []const u8) Error!void {
        try s.list.appendSlice(s.gpa, b);
    }
};

const Source = struct {
    bytes: []const u8,
    arena: std.mem.Allocator,
    pos: usize = 0,

    fn take(s: *Source, n: usize) Error![]const u8 {
        if (n > s.bytes.len - s.pos) return error.Truncated;
        defer s.pos += n;
        return s.bytes[s.pos..][0..n];
    }

    fn remaining(s: Source) usize {
        return s.bytes.len - s.pos;
    }
};

fn encodeValue(comptime T: type, v: T, sink: *Sink) Error!void {
    switch (@typeInfo(T)) {
        .int => {
            var b: [@sizeOf(T)]u8 = undefined;
            std.mem.writeInt(T, &b, v, .little);
            try sink.bytes(&b);
        },
        .float => |f| {
            const U = @Int(.unsigned, f.bits);
            try encodeValue(U, @bitCast(v), sink);
        },
        .bool => try sink.bytes(&.{@intFromBool(v)}),
        .@"enum" => |e| try encodeValue(e.tag_type, @backingInt(v), sink),
        .optional => |o| {
            try sink.bytes(&.{@intFromBool(v != null)});
            if (v) |x| try encodeValue(o.child, x, sink);
        },
        .pointer => |p| {
            comptime std.debug.assert(p.size == .slice);
            if (v.len > std.math.maxInt(u32)) return error.FrameTooLarge;
            try encodeValue(u32, @intCast(v.len), sink);
            if (p.child == u8) {
                try sink.bytes(v);
            } else for (v) |x| try encodeValue(p.child, x, sink);
        },
        .@"struct" => |s| {
            if (s.layout == .@"packed") return encodeValue(s.backing_integer.?, @bitCast(v), sink);
            inline for (s.field_names, s.field_types) |name, F| try encodeValue(F, @field(v, name), sink);
        },
        else => @compileError("remote codec: cannot encode " ++ @typeName(T)),
    }
}

/// `top` is the message's own struct: the only one whose trailing fields may be missing (a
/// peer older than they are), each taking its default.
fn decodeStruct(comptime T: type, src: *Source, comptime top: bool) Error!T {
    var out: T = undefined;
    const s = @typeInfo(T).@"struct";
    inline for (s.field_names, s.field_types, s.field_attrs) |name, F, attrs| {
        if (top and src.remaining() == 0 and attrs.default_value_ptr != null) {
            @field(out, name) = attrs.defaultValue(F).?;
        } else {
            @field(out, name) = try decodeValue(F, src);
        }
    }
    return out;
}

fn decodeValue(comptime T: type, src: *Source) Error!T {
    switch (@typeInfo(T)) {
        .int => return std.mem.readInt(T, (try src.take(@sizeOf(T)))[0..@sizeOf(T)], .little),
        .float => |f| {
            const U = @Int(.unsigned, f.bits);
            return @bitCast(try decodeValue(U, src));
        },
        .bool => return switch ((try src.take(1))[0]) {
            0 => false,
            1 => true,
            else => error.InvalidValue,
        },
        .@"enum" => |e| return @fromBackingInt(@intCast(try decodeValue(e.tag_type, src))),
        .optional => |o| return switch ((try src.take(1))[0]) {
            0 => null,
            1 => try decodeValue(o.child, src),
            else => error.InvalidValue,
        },
        .pointer => |p| {
            const n = try decodeValue(u32, src);
            if (p.child == u8) return try src.take(n);
            // Every element is at least a byte, so a count past what is left is a lie; refusing it
            // here keeps a hostile count from asking for gigabytes.
            if (n > src.remaining()) return error.Truncated;
            const list = try src.arena.alloc(p.child, n);
            for (list) |*x| x.* = try decodeValue(p.child, src);
            return list;
        },
        .@"struct" => |s| {
            if (s.layout == .@"packed") return @bitCast(try decodeValue(s.backing_integer.?, src));
            return decodeStruct(T, src, false);
        },
        else => @compileError("remote codec: cannot decode " ++ @typeName(T)),
    }
}
