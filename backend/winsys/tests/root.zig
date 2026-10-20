//! Sim's tests, one file per area of `docs/window-notes/`, each a first case from the notes.
//! The helpers here are the ones every area uses.
const std = @import("std");
const Sim = @import("../Sim.zig");
const Platform = @import("../Platform.zig");
const Event = @import("../Event.zig");
const Window = @import("../Window.zig");

test {
    _ = @import("windows.zig");
    _ = @import("events.zig");
    _ = @import("input.zig");
    _ = @import("clipboard.zig");
    _ = @import("dnd.zig");
    _ = @import("ime.zig");
    _ = @import("displays.zig");
    _ = @import("streams.zig");
}

/// Polls everything waiting, so a test then looks only at what happens next.
pub fn drain(p: Platform) void {
    while (p.poll() != null) {}
}

/// The next event, which must be of kind `tag` for `window`.
pub fn expectNext(p: Platform, window: Window, comptime tag: std.meta.Tag(Event.Payload)) !@FieldType(Event.Payload, @tagName(tag)) {
    const e = p.poll() orelse return error.NoEvent;
    try std.testing.expectEqual(window.id, e.window.?.id);
    try std.testing.expectEqual(tag, std.meta.activeTag(e.payload));
    return @field(e.payload, @tagName(tag));
}

pub fn expectIdle(p: Platform) !void {
    try std.testing.expect(p.poll() == null);
}
