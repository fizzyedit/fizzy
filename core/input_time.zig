//! Event times in the backend nanosecond clock, indexed by dvui event number.
const std = @import("std");
const dvui = @import("dvui");

/// Events from backends without timestamp support use the current frame time.
pub fn get(num: u16) i128 {
    var buf: [32]u8 = undefined;
    // The prefix and a u16 event number fit in 32 bytes.
    const key = std.fmt.bufPrint(&buf, "_input_time_{d}", .{num}) catch unreachable;
    return dvui.dataGet(null, dvui.currentWindow().data().id, key, i128) orelse dvui.frameTimeNS();
}
