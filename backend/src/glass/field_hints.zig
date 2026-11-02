//! Keyboard policy for the focused field, shared through the window across plugin images.
const std = @import("std");
const dvui = @import("dvui");

pub const Kind = enum(u3) { text, code, url, email, number, search };
pub const Enter = enum(u3) { newline, send, done, next, search };
pub const Hints = struct {
    kind: Kind = .text,
    autocorrect: ?bool = null,
    capitalize: ?bool = null,
    enter: Enter = .newline,
};

const Published = struct { hints: Hints, frame: i128 };

/// Publish the focused field's hints for this frame only. The last publisher wins.
pub fn publish(h: Hints) void {
    const win = dvui.currentWindow();
    dvui.dataSet(win, win.data().id, "_field_hints", Published{ .hints = h, .frame = dvui.frameTimeNS() });
}

/// Return this frame's hints, or null if no field published any.
pub fn current() ?Hints {
    const win = dvui.currentWindow();
    const p = dvui.dataGet(null, win.data().id, "_field_hints", Published) orelse return null;
    return if (p.frame == dvui.frameTimeNS()) p.hints else null;
}

/// Pack kind, enter action, and resolved correction/capitalization into bits 0 through 7.
pub fn bits(h: Hints) u32 {
    const prose = h.kind == .text or h.kind == .search;
    return @as(u32, @backingInt(h.kind)) |
        (@as(u32, @backingInt(h.enter)) << 3) |
        (@as(u32, @intFromBool(h.autocorrect orelse prose)) << 6) |
        (@as(u32, @intFromBool(h.capitalize orelse prose)) << 7);
}

test "resolved by kind" {
    try std.testing.expectEqual(@as(u32, 1), bits(.{ .kind = .code }));
    try std.testing.expectEqual(@as(u32, 192), bits(.{ .kind = .text }));
    try std.testing.expectEqual(@as(u32, 197), bits(.{ .kind = .search }));
}

test "published hints last one frame" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    try std.testing.expectEqual(@as(?Hints, null), current());
    publish(.{ .kind = .code });
    try std.testing.expectEqual(Kind.code, current().?.kind);
    publish(.{ .enter = .send });
    try std.testing.expectEqual(Enter.send, current().?.enter);
    const next = dvui.frameTimeNS() + std.time.ns_per_ms;
    _ = try t.window.end(.{});
    try t.window.begin(next);
    try std.testing.expectEqual(@as(?Hints, null), current());
}

test "bits round-trips" {
    inline for (std.meta.tags(Kind)) |kind| {
        inline for (std.meta.tags(Enter)) |enter| {
            for ([_]bool{ false, true }) |correct| {
                for ([_]bool{ false, true }) |capitals| {
                    const encoded = bits(.{ .kind = kind, .enter = enter, .autocorrect = correct, .capitalize = capitals });
                    try std.testing.expectEqual(@backingInt(kind), encoded & 7);
                    try std.testing.expectEqual(@backingInt(enter), (encoded >> 3) & 7);
                    try std.testing.expectEqual(correct, encoded & 64 != 0);
                    try std.testing.expectEqual(capitals, encoded & 128 != 0);
                    try std.testing.expectEqual(@as(u32, 0), encoded >> 8);
                }
            }
        }
    }
}
