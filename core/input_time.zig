//! Event times in the backend nanosecond clock, indexed by dvui event number.
const std = @import("std");
const dvui = @import("dvui");

/// Events from backends without timestamp support use the current frame time.
pub fn get(num: u16) i128 {
    var buf: [32]u8 = undefined;
    return dvui.dataGet(null, dvui.currentWindow().data().id, key(&buf, num), i128) orelse dvui.frameTimeNS();
}

/// Store a backend-clock timestamp for an event in the given window.
pub fn set(win: *dvui.Window, num: u16, time_ns: i128) void {
    var buf: [32]u8 = undefined;
    dvui.dataSet(win, win.data().id, key(&buf, num), time_ns);
}

fn key(buf: *[32]u8, num: u16) []const u8 {
    // The prefix and a u16 event number fit in 32 bytes.
    return std.mem.print(buf, "_input_time_{d}", .{num}) catch unreachable;
}
