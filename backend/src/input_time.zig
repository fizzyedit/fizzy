//! Backend event timestamps shared by native and web input delivery.
const std = @import("std");
const dvui = @import("dvui");

/// Stamp input added since `before`, the window's event count before delivery.
/// dvui keeps a trailing position event which input replaces; position is not a sample.
pub fn stamp(win: *dvui.Window, before: usize, time_ns: i128) void {
    for (win.events.items[before -| 1..]) |event| {
        if (event.evt == .mouse and event.evt.mouse.action == .position) continue;
        var buf: [32]u8 = undefined;
        // The prefix and a u16 event number fit in 32 bytes. Match core/input_time.zig.
        const key = std.mem.print(&buf, "_input_time_{d}", .{event.num}) catch unreachable;
        dvui.dataSet(win, win.data().id, key, time_ns);
    }
}
