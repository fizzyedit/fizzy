//! Android's Back button, delivered as Escape: whether this frame's press of it went unhandled,
//! so Back goes on to leave the app (`SDLBackend.end`). std-only.

/// True when the event numbered `back_num` (Back's press, given as Escape) is a key press
/// nothing handled. `events` is a slice of dvui's `Event`, or anything shaped like it.
// anytype: dvui's `Event` in the backend, a stand-in of its shape in the test, which has no dvui.
pub fn leaves(events: anytype, back_num: ?u16) bool {
    const num = back_num orelse return false;
    for (events) |e| {
        if (e.num != num) continue;
        return switch (e.evt) {
            .key => |k| k.action == .down and !e.handled,
            else => false,
        };
    }
    return false;
}

const TestEvent = struct {
    num: u16,
    handled: bool = false,
    evt: union(enum) {
        key: struct { action: enum { down, repeat, up } },
        text: void,
    },
};

test "Back leaves only when its Escape went unhandled" {
    const std = @import("std");
    const press: TestEvent = .{ .num = 3, .evt = .{ .key = .{ .action = .down } } };
    var handled = press;
    handled.handled = true;
    try std.testing.expect(leaves(&[_]TestEvent{press}, 3));
    try std.testing.expect(!leaves(&[_]TestEvent{handled}, 3));
    try std.testing.expect(!leaves(&[_]TestEvent{press}, null));
    try std.testing.expect(!leaves(&[_]TestEvent{press}, 4));
}
