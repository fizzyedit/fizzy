//! What a dvui app was handed, frame by frame, exactly: the black box's stream (`ring.Ring` named
//! `"dvui"`, plans/RECORDER_PLAN.md). Where a `Tape` says what a person did to named things, so it
//! plays in any layout, these say which events reached which frame, in the window's pixels, so a
//! run from the same start replays as it happened.
//!
//! std-only, so it tests alone (`fizzy-tape-tests`); the dvui half that fills it from
//! `dvui.events()` is `replay.BlackBox`.
const std = @import("std");
const ring = @import("ring.zig");

pub const Frame = extern struct {
    /// The frame's time on the app's clock (`dvui.frameTimeNS`), so a replay's clock can say it.
    t_ns: i64,
    /// Its events: `count` of them from sequence `first`.
    first: u64 = 0,
    count: u32 = 0,
    /// The window, in physical pixels, and its scale (physical per natural pixel).
    w: u16,
    h: u16,
    scale: f32,
    _pad: u32 = 0,
};

pub const Kind = enum(u8) {
    motion,
    press,
    release,
    wheel_x,
    wheel_y,
    key_down,
    key_repeat,
    key_up,
    /// Text typed or pasted: the payload.
    text,
    /// A text selection an input method set: the payload is its start and end, two
    /// little-endian u64s (`selection`).
    text_select,
    window_close,
    window_leave,
    app_quit,
};

pub const Event = extern struct {
    kind: Kind,
    /// `dvui.enums.Button` for pointer events.
    button: u8 = 0,
    /// `dvui.enums.Mod`.
    mod: u16 = 0,
    /// `dvui.enums.Key` for key events.
    key: u16 = 0,
    /// A text event's text was selected (`dvui.Event.Text`'s `selected`).
    selected: bool = false,
    _pad0: u8 = 0,
    /// Where the pointer was, in physical pixels; a wheel event's ticks in `x`.
    x: f32 = 0,
    y: f32 = 0,
    /// Its payload, set by the ring.
    bytes_at: u64 = 0,
    bytes_len: u32 = 0,
    _pad1: u32 = 0,

    pub fn valid(self: Event) bool {
        return @backingInt(self.kind) <= @backingInt(Kind.app_quit);
    }
};

comptime {
    std.debug.assert(@sizeOf(Frame) == 32);
    std.debug.assert(@sizeOf(Event) == 32);
}

/// About a minute at 120 frames a second, a minute of steady pointer motion and typing with room
/// to spare: 1.3 MB.
pub const Ring = ring.Ring("dvui", Frame, Event, .{ .frames = 8192, .records = 32 * 1024, .bytes = 64 * 1024 });

/// A `text_select` event's payload.
pub fn selectionBytes(start: u64, end: u64) [16]u8 {
    var out: [16]u8 = undefined;
    std.mem.writeInt(u64, out[0..8], start, .little);
    std.mem.writeInt(u64, out[8..16], end, .little);
    return out;
}

pub fn selection(payload: []const u8) ?struct { start: u64, end: u64 } {
    if (payload.len != 16) return null;
    return .{
        .start = std.mem.readInt(u64, payload[0..8], .little),
        .end = std.mem.readInt(u64, payload[8..16], .little),
    };
}

fn testFrame(t: i64) Frame {
    return .{ .t_ns = t, .w = 800, .h = 600, .scale = 2 };
}

test "frames keep their events and text, and a stretch reads back as written" {
    const r = try std.testing.allocator.create(Ring);
    defer std.testing.allocator.destroy(r);
    r.* = .{};
    r.appendFrame(testFrame(10), &.{}, &.{});
    const sel = selectionBytes(3, 9);
    r.appendFrame(testFrame(20), &.{
        .{ .kind = .motion, .x = 12, .y = 34 },
        .{ .kind = .press, .button = 1 },
        .{ .kind = .text },
        .{ .kind = .text_select },
    }, &.{ "", "", "héllo", &sel });
    r.appendFrame(testFrame(30), &.{.{ .kind = .key_down, .key = 7, .mod = 4 }}, &.{});

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try r.write(&out.writer, 1, r.frames_n);
    const s = try Ring.read(out.written());
    try std.testing.expectEqual(@as(usize, 2), s.frames.len);
    try std.testing.expectEqual(@as(u64, 1), s.header.first_frame);
    try std.testing.expectEqual(@as(i64, 20), s.frames[0].t_ns);
    try std.testing.expectEqual(@as(u16, 600), s.frames[0].h);
    const ev = s.recordsOf(0);
    try std.testing.expectEqual(@as(usize, 4), ev.len);
    try std.testing.expectEqual(Kind.motion, ev[0].kind);
    try std.testing.expectEqual(@as(f32, 34), ev[0].y);
    try std.testing.expectEqualStrings("héllo", s.payload(ev[2]));
    try std.testing.expectEqual(@as(u64, 9), selection(s.payload(ev[3])).?.end);
    try std.testing.expectEqual(@as(u16, 7), s.recordsOf(1)[0].key);
    try std.testing.expectEqual(@as(i64, 20), r.frame(r.frameAt(15)).t_ns);
}

test "an unknown kind is refused" {
    const r = try std.testing.allocator.create(Ring);
    defer std.testing.allocator.destroy(r);
    r.* = .{};
    r.appendFrame(testFrame(1), &.{.{ .kind = .motion }}, &.{});
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try r.write(&out.writer, 0, r.frames_n);
    out.written()[@sizeOf(ring.Header) + @sizeOf(Frame)] = 200;
    try std.testing.expectError(error.BadIndex, Ring.read(out.written()));
}

test "appending a busy frame costs microseconds" {
    // A frame of steady input: pointer motion and a few keys. The budget is the plan's 10 µs,
    // checked loosely here (a Debug build, a shared machine); ReleaseFast measures 5 ns.
    const r = try std.testing.allocator.create(Ring);
    defer std.testing.allocator.destroy(r);
    r.* = .{};
    const busy = [_]Event{ .{ .kind = .motion }, .{ .kind = .motion }, .{ .kind = .key_down }, .{ .kind = .key_up } };
    var io_impl: std.Io.Threaded = .init_single_threaded;
    const io = io_impl.io();
    const start = std.Io.Clock.awake.now(io).nanoseconds;
    const n = 10_000;
    for (0..n) |i| r.appendFrame(testFrame(@intCast(i)), &busy, &.{});
    const per = @divTrunc(std.Io.Clock.awake.now(io).nanoseconds - start, n);
    try std.testing.expect(per < 50_000);
}
