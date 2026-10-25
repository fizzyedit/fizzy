//! The recorded stream: what crossed a `Platform` while someone used it, in a compact versioned
//! byte form that replays on any machine. `Recorder` writes it, `Replayer` plays it into a `Sim`.
//!
//! **Layout.** The magic `FZWS`, the version as a little-endian `u16`, then records until the
//! bytes end. A record is a tag byte, the time as a varint delta from the record before, and the
//! tag's body. Integers are LEB128 (signed ones zigzagged), floats are four bytes little-endian,
//! a slice is its length then its elements, an enum is its number, a union its tag then its
//! payload, and a packed struct its backing integer. The bodies are the types in `Body`, written
//! by one reflection over them, so a field added to `Event` moves the format, and the golden
//! streams (`tests/streams/`) fail until `version` moves with it.
//!
//! **What is in it.** Everything the app *observed* of the platform (the events it polled, the
//! displays it saw, the clock it read, the clipboard text behind a clipboard event) and every
//! *request* it made (windows opened, closed, titled, sized, …). Queries (`windowSize`, …) are
//! not: a replay answers those itself.
//!
//! **Privacy.** Unredacted, a stream holds what the person typed (`text`, `key`, `ime`), copied
//! (`clipboard_text`, `set_clipboard_text`), dragged in (`drop`) and named their windows. `Recorder` redacts those by
//! default (lengths still leak) and says what it keeps (its doc); a stream made with `redact = false` is as sensitive
//! as a keylogger's output and is not for sharing.
//!
//! **No platform identity.** A window is a number the platform picked, a display, a finger and a
//! touch screen the same, and on one machine they are pointers or counters that mean nothing on
//! another. The recorder renames each, in order of first sight, to 1, 2, 3 …, so a stream a
//! person records on a Mac replays on Linux CI (`Ids`). Times are nanoseconds from the moment
//! the recorder was made, so the platform's clock origin is not in it either.
//!
//! **Joining `sdk/tape`.** A tape says what a person did to named things, in demo milliseconds;
//! this says what the platform did and was asked, in clock nanoseconds. They are separate
//! formats on purpose and stay so. They share the one idea of time (a monotonic clock from a
//! start), so a join is two files whose origins are the same instant: the seam is a `start`
//! stamp in each header, which neither has yet. Playing both is then a `Sequencer` step that
//! feeds a `Replayer` its `advance`, not a merged format.
const std = @import("std");
const Platform = @import("Platform.zig");
const Window = @import("Window.zig");
const Display = @import("Display.zig");
const Event = @import("Event.zig");
const Ime = @import("Ime.zig");
const geometry = @import("geometry.zig");

const Allocator = std.mem.Allocator;

pub const magic = "FZWS".*;
pub const version: u16 = 1;

pub const Error = error{
    /// Not a stream, or one of a version this reader does not know.
    BadHeader,
    /// The bytes ended inside a record.
    Truncated,
    /// A record that cannot be what a writer made: an unknown tag, a number out of range.
    Corrupt,
};

/// One thing that crossed the platform, in the order the app saw it.
pub const Body = union(enum) {
    /// The app read the clock (`now`) or came back from `wait`: the record's time is what it saw.
    clock,
    /// A polled event; `window` and the touch ids are stream-local names (`Ids`).
    event: Event,
    /// The displays now, written when they differ from the last record of this kind.
    displays: []const Display,
    /// What the clipboard held when a `clipboard` event arrived, which the event does not carry.
    clipboard_text: []const u8,
    request: Request,
};

/// A call that changes the platform, with the window as its stream-local name.
pub const Request = union(enum) {
    open_window: struct { options: Window.Options, result: ?Window },
    close_window: Window,
    set_title: struct { window: Window, title: []const u8 },
    set_window_size: struct { window: Window, size: geometry.DesktopSize },
    set_window_position: struct { window: Window, at: geometry.DesktopPoint },
    set_window_state: struct { window: Window, state: Window.State },
    show_window: struct { window: Window, visible: bool },
    raise_window: Window,
    set_cursor: struct { window: Window, cursor: Window.Cursor },
    set_hints: struct { window: Window, hints: Window.Hints },
    set_material: struct { window: Window, material: Window.MaterialSpec },
    set_text_input: struct { window: Window, on: bool },
    set_ime_area: struct { window: Window, area: Ime.Area },
    set_clipboard_text: []const u8,
    drop_respond: struct { window: Window, response: @import("Drop.zig").Response },
};

/// A record: `t_ns` since the recording began, and what happened.
pub const Record = struct {
    t_ns: u64,
    body: Body,
};

/// Renames the platform's identities to the order they were first seen in: 1, 2, 3 …
pub const Ids = struct {
    gpa: Allocator,
    windows: std.AutoHashMapUnmanaged(u64, u64) = .empty,
    displays: std.AutoHashMapUnmanaged(u64, u64) = .empty,
    devices: std.AutoHashMapUnmanaged(u64, u64) = .empty,
    fingers: std.AutoHashMapUnmanaged(Finger, u64) = .empty,

    const Finger = struct { device: u64, finger: u64 };

    pub fn init(gpa: Allocator) Ids {
        return .{ .gpa = gpa };
    }

    pub fn deinit(ids: *Ids) void {
        ids.windows.deinit(ids.gpa);
        ids.displays.deinit(ids.gpa);
        ids.devices.deinit(ids.gpa);
        ids.fingers.deinit(ids.gpa);
    }

    pub fn window(ids: *Ids, w: Window) Allocator.Error!Window {
        return .{ .id = try name(ids.gpa, &ids.windows, w.id) };
    }

    pub fn display(ids: *Ids, id: u64) Allocator.Error!u64 {
        return try name(ids.gpa, &ids.displays, id);
    }

    /// The event as the stream names it: window, touch device and finger renamed.
    pub fn event(ids: *Ids, e: Event) Allocator.Error!Event {
        var out = e;
        if (e.window) |w| out.window = try ids.window(w);
        switch (out.payload) {
            .touch => |*t| {
                const finger = try name(ids.gpa, &ids.fingers, Finger{ .device = t.device, .finger = t.finger });
                t.device = try name(ids.gpa, &ids.devices, t.device);
                t.finger = finger;
            },
            else => {},
        }
        return out;
    }

    // anytype: The four identity maps have different key types but share lookup and numbering.
    fn name(gpa: Allocator, map: anytype, key: anytype) Allocator.Error!u64 {
        const slot = try map.getOrPut(gpa, key);
        if (!slot.found_existing) slot.value_ptr.* = @intCast(map.count());
        return slot.value_ptr.*;
    }
};

pub const Writer = struct {
    gpa: Allocator,
    bytes: std.ArrayList(u8) = .empty,
    last_ns: u64 = 0,

    /// Starts a stream: the header is written.
    pub fn init(gpa: Allocator) Allocator.Error!Writer {
        var w: Writer = .{ .gpa = gpa };
        errdefer w.deinit();
        try w.bytes.appendSlice(gpa, &magic);
        try w.bytes.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u16, version)));
        return w;
    }

    pub fn deinit(w: *Writer) void {
        w.bytes.deinit(w.gpa);
    }

    /// Appends a record. Records are written in time order: `record.t_ns` is clamped up to the
    /// one before.
    pub fn write(w: *Writer, record: Record) Allocator.Error!void {
        const t = @max(record.t_ns, w.last_ns);
        try w.bytes.append(w.gpa, @backingInt(std.meta.activeTag(record.body)));
        try w.putInt(u64, t - w.last_ns);
        w.last_ns = t;
        switch (record.body) {
            .event => |e| {
                // An event is stamped before it is polled, so the lag is small and non-negative.
                try w.putInt(i64, @as(i64, @intCast(t)) - @as(i64, @intCast(e.time_ns)));
                try w.put(?Window, e.window);
                try w.put(Event.Payload, e.payload);
            },
            inline else => |body, tag| try w.put(@FieldType(Body, @tagName(tag)), body),
        }
    }

    fn putInt(w: *Writer, comptime T: type, value: T) Allocator.Error!void {
        // Widened first, so one loop writes every width.
        var rest: u64 = if (@typeInfo(T).int.signedness == .signed) blk: {
            const v: i64 = value;
            break :blk @bitCast((v << 1) ^ (v >> 63));
        } else value;
        while (rest >= 0x80) : (rest >>= 7) try w.bytes.append(w.gpa, @as(u8, @truncate(rest)) | 0x80);
        try w.bytes.append(w.gpa, @truncate(rest));
    }

    fn put(w: *Writer, comptime T: type, value: T) Allocator.Error!void {
        switch (@typeInfo(T)) {
            .void => {},
            .bool => try w.bytes.append(w.gpa, @intFromBool(value)),
            .int => try w.putInt(T, value),
            .float => {
                const bits: u32 = @bitCast(@as(f32, value));
                try w.bytes.appendSlice(w.gpa, &std.mem.toBytes(std.mem.nativeToLittle(u32, bits)));
            },
            .@"enum" => try w.putInt(u64, @backingInt(value)),
            .optional => |o| {
                try w.put(bool, value != null);
                if (value) |v| try w.put(o.child, v);
            },
            .pointer => |p| {
                comptime std.debug.assert(p.size == .slice);
                try w.putInt(u64, value.len);
                if (p.child == u8) return try w.bytes.appendSlice(w.gpa, value);
                for (value) |item| try w.put(p.child, item);
            },
            .array => |a| for (value) |item| try w.put(a.child, item),
            .@"struct" => |s| {
                if (s.layout == .@"packed") return try w.putInt(s.backing_integer.?, @bitCast(value));
                inline for (s.field_names, s.field_types) |fname, ftype| try w.put(ftype, @field(value, fname));
            },
            .@"union" => {
                try w.putInt(u64, @backingInt(std.meta.activeTag(value)));
                switch (value) {
                    inline else => |payload| try w.put(@TypeOf(payload), payload),
                }
            },
            else => @compileError("stream: cannot write " ++ @typeName(T)),
        }
    }
};

/// Reads records back. Everything a record borrows (strings, lists) is allocated from the arena
/// given to `next` and lives as long as it.
pub const Reader = struct {
    bytes: []const u8,
    at: usize = 0,
    last_ns: u64 = 0,

    /// Checks the header; a stream of another version is `error.BadHeader`.
    pub fn init(bytes: []const u8) Error!Reader {
        if (bytes.len < magic.len + 2 or !std.mem.eql(u8, bytes[0..magic.len], &magic)) return error.BadHeader;
        if (std.mem.readInt(u16, bytes[magic.len..][0..2], .little) != version) return error.BadHeader;
        return .{ .bytes = bytes, .at = magic.len + 2 };
    }

    /// The next record, or null at the end of the bytes.
    pub fn next(r: *Reader, arena: Allocator) (Error || Allocator.Error)!?Record {
        if (r.at == r.bytes.len) return null;
        const tag_byte = r.bytes[r.at];
        r.at += 1;
        const Tag = std.meta.Tag(Body);
        const tag = std.enums.fromInt(Tag, tag_byte) orelse return error.Corrupt;
        r.last_ns +|= try r.getInt(u64);
        const t = r.last_ns;
        const body: Body = switch (tag) {
            .event => blk: {
                const lag = try r.getInt(i64);
                const stamp = @as(i128, t) - lag;
                if (stamp < 0 or stamp > std.math.maxInt(u64)) return error.Corrupt;
                break :blk .{ .event = .{
                    .time_ns = @intCast(stamp),
                    .window = try r.get(?Window, arena),
                    .payload = try r.get(Event.Payload, arena),
                } };
            },
            inline else => |tag_| @unionInit(Body, @tagName(tag_), try r.get(@FieldType(Body, @tagName(tag_)), arena)),
        };
        return .{ .t_ns = t, .body = body };
    }

    fn getInt(r: *Reader, comptime T: type) Error!T {
        var out: u64 = 0;
        var shift: u32 = 0;
        while (true) {
            if (r.at == r.bytes.len) return error.Truncated;
            const b = r.bytes[r.at];
            r.at += 1;
            const part: u64 = b & 0x7f;
            // The tenth byte holds the 64th bit and nothing more.
            if (shift > 63 or (shift == 63 and part > 1)) return error.Corrupt;
            out |= part << @intCast(shift);
            if (b & 0x80 == 0) break;
            shift += 7;
        }
        if (@typeInfo(T).int.signedness == .unsigned) {
            return std.math.cast(T, out) orelse error.Corrupt;
        }
        const v: i64 = @bitCast((out >> 1) ^ (0 -% (out & 1)));
        return std.math.cast(T, v) orelse error.Corrupt;
    }

    fn get(r: *Reader, comptime T: type, arena: Allocator) (Error || Allocator.Error)!T {
        switch (@typeInfo(T)) {
            .void => return {},
            .bool => {
                const b = try r.getInt(u8);
                if (b > 1) return error.Corrupt;
                return b == 1;
            },
            .int => return try r.getInt(T),
            .float => {
                if (r.bytes.len - r.at < 4) return error.Truncated;
                const bits = std.mem.readInt(u32, r.bytes[r.at..][0..4], .little);
                r.at += 4;
                return @as(f32, @bitCast(bits));
            },
            .@"enum" => |e| {
                const n = try r.getInt(u64);
                const Backing = e.tag_type;
                if (n > std.math.maxInt(Backing)) return error.Corrupt;
                const value: T = @fromBackingInt(@intCast(n));
                if (e.mode == .nonexhaustive) return value;
                return std.enums.fromInt(T, @as(Backing, @intCast(n))) orelse error.Corrupt;
            },
            .optional => |o| return if (try r.get(bool, arena)) try r.get(o.child, arena) else null,
            .pointer => |p| {
                const len = try r.getInt(u64);
                // Every element takes at least a byte, so a length past the rest is a lie.
                if (len > r.bytes.len - r.at) return error.Truncated;
                const out = try arena.alloc(p.child, @intCast(len));
                if (p.child == u8) {
                    @memcpy(out, r.bytes[r.at..][0..out.len]);
                    r.at += out.len;
                } else for (out) |*item| {
                    item.* = try r.get(p.child, arena);
                }
                return out;
            },
            .array => |a| {
                var out: T = undefined;
                for (&out) |*item| item.* = try r.get(a.child, arena);
                return out;
            },
            .@"struct" => |s| {
                if (s.layout == .@"packed") return @bitCast(try r.getInt(s.backing_integer.?));
                var out: T = undefined;
                inline for (s.field_names, s.field_types) |fname, ftype| @field(out, fname) = try r.get(ftype, arena);
                return out;
            },
            .@"union" => {
                const Tag = std.meta.Tag(T);
                const n = try r.getInt(u64);
                if (n > std.math.maxInt(std.meta.Tag(Tag))) return error.Corrupt;
                const tag = std.enums.fromInt(Tag, @as(std.meta.Tag(Tag), @intCast(n))) orelse return error.Corrupt;
                switch (tag) {
                    inline else => |t| return @unionInit(T, @tagName(t), try r.get(@FieldType(T, @tagName(t)), arena)),
                }
            },
            else => @compileError("stream: cannot read " ++ @typeName(T)),
        }
    }
};

/// A record as one line of text, for a person reading a diff.
pub fn format(record: Record, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.print("{d: >12}ns ", .{record.t_ns});
    switch (record.body) {
        .clock => try w.writeAll("clock"),
        inline else => |body, tag| try w.print("{s} {any}", .{ @tagName(tag), body }),
    }
}

test "integers round trip across their range" {
    var w = try Writer.init(std.testing.allocator);
    defer w.deinit();
    const ints = [_]i64{ 0, 1, -1, 63, -64, 64, std.math.maxInt(i64), std.math.minInt(i64) };
    for (ints) |n| try w.putInt(i64, n);
    try w.putInt(u64, std.math.maxInt(u64));

    var r: Reader = .{ .bytes = w.bytes.items, .at = magic.len + 2 };
    for (ints) |n| try std.testing.expectEqual(n, try r.getInt(i64));
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), try r.getInt(u64));
}

test "a record of every kind reads back as written" {
    var w = try Writer.init(std.testing.allocator);
    defer w.deinit();
    const files = [_][]const u8{ "/a", "/b" };
    const records = [_]Record{
        .{ .t_ns = 5, .body = .clock },
        .{ .t_ns = 9, .body = .{ .event = .{ .time_ns = 7, .window = .{ .id = 1 }, .payload = .{ .drop = .{ .phase = .drop, .data = .{ .files = &files } } } } } },
        .{ .t_ns = 9, .body = .{ .event = .{ .time_ns = 9, .window = null, .payload = .quit } } },
        .{ .t_ns = 12, .body = .{ .displays = &.{.{ .id = 1, .name = "d", .bounds = .{ .x = -5, .w = 10, .h = 10 }, .usable = .{}, .scale = 1.5, .primary = true }} } },
        .{ .t_ns = 20, .body = .{ .clipboard_text = "héllo" } },
        .{ .t_ns = 21, .body = .{ .request = .{ .open_window = .{ .options = .{ .title = "t", .parent = .{ .id = 1 }, .position = .{ .x = -3, .y = 4 } }, .result = .{ .id = 2 } } } } },
    };
    for (records) |rec| try w.write(rec);

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var r = try Reader.init(w.bytes.items);
    for (records) |want| {
        const got = (try r.next(arena.allocator())).?;
        try std.testing.expectEqual(want.t_ns, got.t_ns);
        var want_text: [512]u8 = undefined;
        var got_text: [512]u8 = undefined;
        var a: std.Io.Writer = .fixed(&want_text);
        var b: std.Io.Writer = .fixed(&got_text);
        try format(want, &a);
        try format(got, &b);
        try std.testing.expectEqualStrings(a.buffered(), b.buffered());
    }
    try std.testing.expect(try r.next(arena.allocator()) == null);
}

test "a stream of another version, or cut short, is refused" {
    try std.testing.expectError(error.BadHeader, Reader.init("nope"));
    try std.testing.expectError(error.BadHeader, Reader.init("FZWS\xff\x00"));

    var w = try Writer.init(std.testing.allocator);
    defer w.deinit();
    try w.write(.{ .t_ns = 1, .body = .{ .request = .{ .set_title = .{ .window = .{ .id = 1 }, .title = "hello" } } } });
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var r = try Reader.init(w.bytes.items[0 .. w.bytes.items.len - 2]);
    try std.testing.expectError(error.Truncated, r.next(arena.allocator()));
}

test "identities are renamed in order of first sight" {
    var ids = Ids.init(std.testing.allocator);
    defer ids.deinit();
    try std.testing.expectEqual(@as(u64, 1), (try ids.window(.{ .id = 0xdead_beef })).id);
    try std.testing.expectEqual(@as(u64, 2), (try ids.window(.{ .id = 7 })).id);
    try std.testing.expectEqual(@as(u64, 1), (try ids.window(.{ .id = 0xdead_beef })).id);
    const e = try ids.event(.{ .time_ns = 0, .window = .{ .id = 7 }, .payload = .{ .touch = .{ .kind = .down, .device = 99, .finger = 12345, .at = .{} } } });
    try std.testing.expectEqual(@as(u64, 2), e.window.?.id);
    try std.testing.expectEqual(@as(u64, 1), e.payload.touch.device);
    try std.testing.expectEqual(@as(u64, 1), e.payload.touch.finger);
}
