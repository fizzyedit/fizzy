//! Event times on the wall clock (`MotionClock`), indexed by dvui event number.
//!
//! A backend stamps each real event as it posts it (`stamp`); a widget that needs the moment a
//! touch moved (a fling's speed) reads it back (`get`). Every time here is wall time, so samples
//! from one stream never mix bases when the motion clock holds a late frame.
const std = @import("std");
const dvui = @import("dvui");
const MotionClock = @import("MotionClock.zig");

/// The wall time of event `num`. An event nobody stamped (a synthetic one, a backend without
/// timestamps) reads the wall time the frame began at.
pub fn get(num: u16) i128 {
    var buf: [32]u8 = undefined;
    return dvui.dataGet(null, dvui.currentWindow().data().id, key(&buf, num), i128) orelse MotionClock.wallFrameNs();
}

/// Store the wall time `time_ns` for event `num` in the given window.
pub fn set(win: *dvui.Window, num: u16, time_ns: i128) void {
    var buf: [32]u8 = undefined;
    dvui.dataSet(win, win.data().id, key(&buf, num), time_ns);
}

/// Stamp every real event dvui added since `before` (the window's `event_num` ahead of the
/// `addEvent*` call) with `time_ns`. dvui keeps a `.position` event last in the list, numbered
/// after the newest real one; an `addEvent*` call replaces it, so the real event takes the
/// position event's number and the new position event is the one beyond it. Stamping what the
/// list gained would stamp that position event and leave the real one to read its predecessor's time.
pub fn stamp(win: *dvui.Window, before: u16, time_ns: i128) void {
    var i = win.events.items.len;
    while (i > 0) {
        i -= 1;
        const e = win.events.items[i];
        if (e.num <= before) break;
        if (e.evt == .mouse and e.evt.mouse.action == .position) continue;
        set(win, e.num, time_ns);
    }
}

fn key(buf: *[32]u8, num: u16) []const u8 {
    // The prefix and a u16 event number fit in 32 bytes.
    return std.mem.print(buf, "_input_time_{d}", .{num}) catch unreachable;
}

test "stamp gives each real event its own time, not its predecessor's" {
    var test_window = try dvui.testing.init(.{});
    defer test_window.deinit();
    const cw = dvui.currentWindow();
    const ms = std.time.ns_per_ms;
    var nums: [3]u16 = undefined;
    for (&nums, 0..) |*n, i| {
        const before = cw.event_num;
        _ = try cw.addEventTouchMotion(.touch0, 0.5, 0.5, 0, 0.01);
        stamp(cw, before, @as(i128, @intCast(i + 1)) * 10 * ms);
        n.* = cw.event_num;
    }
    try std.testing.expectEqual(@as(i128, 10 * ms), get(nums[0]));
    try std.testing.expectEqual(@as(i128, 20 * ms), get(nums[1]));
    try std.testing.expectEqual(@as(i128, 30 * ms), get(nums[2]));
}
