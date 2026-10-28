//! Touch press ownership shared by text fields and selectable text.
const std = @import("std");
const dvui = @import("dvui");

/// The touch presses among the frame's first `max_presses` events that nothing has handled yet.
pub const Presses = std.bit_set.IntegerBitSet(max_presses);
const max_presses = 32;

pub fn unhandledPresses() Presses {
    var set: Presses = .empty;
    for (dvui.events(), 0..) |*e, i| {
        if (i == max_presses) break;
        if (e.evt == .mouse and e.evt.mouse.action == .press and e.evt.mouse.button.touch() and !e.handled) set.set(i);
    }
    return set;
}

/// Whether `dvui.textLayout` took the press `e`, the `i`th event, in a window other than its own:
/// its menu handles the press, and its selection handles keep an `_offset` under their window's id.
pub fn tookPress(unhandled: Presses, i: usize, e: *const dvui.Event) bool {
    if (i < max_presses and unhandled.isSet(i) and e.handled) return true;
    return dvui.dataGet(null, e.evt.mouse.floating_win, "_offset", dvui.Point.Physical) != null;
}
