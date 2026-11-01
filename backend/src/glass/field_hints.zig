//! Keyboard policy for the focused field, shared through the current window for one frame.
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

/// Publish the focused field's hints for this frame; the last publisher wins.
pub fn publish(h: Hints) void {
    const win = dvui.currentWindow();
    dvui.dataSet(null, win.data().id, "_field_hints", Published{ .hints = h, .frame = dvui.frameTimeNS() });
}

/// Read this frame's hints, or null if no field published them.
pub fn current() ?Hints {
    const stored = dvui.dataGet(null, dvui.currentWindow().data().id, "_field_hints", Published) orelse return null;
    return if (stored.frame == dvui.frameTimeNS()) stored.hints else null;
}

/// Pack kind (0–2), enter (3–5), autocorrect (6), and capitalization (7).
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
    var test_window = try dvui.testing.init(.{});
    defer test_window.deinit();
    try std.testing.expectEqual(@as(?Hints, null), current());
    publish(.{ .kind = .code });
    try std.testing.expectEqual(Kind.code, current().?.kind);
    publish(.{ .kind = .text });
    try std.testing.expectEqual(Kind.text, current().?.kind);
    const win = dvui.currentWindow();
    _ = try win.end(.{});
    try win.begin(win.frame_time_ns + std.time.ns_per_ms);
    try std.testing.expectEqual(@as(?Hints, null), current());
}

test "bits round-trips" {
    for (std.enums.values(Kind)) |kind| {
        for (std.enums.values(Enter)) |enter| {
            for ([_]bool{ false, true }) |autocorrect| {
                for ([_]bool{ false, true }) |capitalize| {
                    const encoded = bits(.{ .kind = kind, .enter = enter, .autocorrect = autocorrect, .capitalize = capitalize });
                    try std.testing.expectEqual(@as(u32, @backingInt(kind)), encoded & 7);
                    try std.testing.expectEqual(@as(u32, @backingInt(enter)), (encoded >> 3) & 7);
                    try std.testing.expectEqual(autocorrect, encoded & 64 != 0);
                    try std.testing.expectEqual(capitalize, encoded & 128 != 0);
                }
            }
        }
    }
}
