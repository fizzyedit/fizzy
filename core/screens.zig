//! The screens a floating thing — a menu, a tooltip, a popover, a dialog — is placed on and kept
//! within. The main window's, and, while a float is out of it in an OS window of its own, that
//! window's part of the frame (`docs/POPOUT_WINDOWS_PLAN.md`): far past the main window's edge,
//! where anything opened from the float is drawn and from where it is copied into that window.
//! Placed against the main window there, a menu opened in a float that is out was pulled all the
//! way back onto the main window, and drawn there.
//!
//! The app publishes them each frame, before anything is placed (`publish`). In the shared dvui
//! window's data rather than this module's own state: a plugin built as a library carries its own
//! copy of `core`, and its menus and tooltips must read the same list as the app's.
const std = @import("std");
const dvui = @import("dvui");

/// The most screens besides the main window's.
pub const max = 8;

const Published = struct {
    n: u8 = 0,
    rects: [max]dvui.Rect.Natural = undefined,
};

const key_id: dvui.Id = @enumFromInt(0x6669_7a7a_7363_726e); // "fizzscrn"
const key = "_screens";

/// The screens there are this frame besides the main window's, natural. The app's, each frame
/// before anything is placed; not published, or empty, there is the main window's alone.
pub fn publish(rects: []const dvui.Rect.Natural) void {
    if (rects.len == 0) return clear();
    var p: Published = .{};
    for (rects[0..@min(rects.len, max)]) |r| {
        p.rects[p.n] = r;
        p.n += 1;
    }
    dvui.dataSet(null, key_id, key, p);
}

/// No screens but the main window's, from now.
pub fn clear() void {
    dvui.dataRemove(null, key_id, key);
}

/// The screen `r` (natural) is on: the published one its middle is in, else the main window's.
pub fn screenFor(r: dvui.Rect.Natural) dvui.Rect.Natural {
    const p = dvui.dataGetPtr(null, key_id, key, Published) orelse return dvui.windowRect();
    const c = r.center();
    for (p.rects[0..p.n]) |s| if (s.contains(c)) return s;
    return dvui.windowRect();
}

/// `screenFor`, physical: what a floating thing on that screen clips its drawing to.
pub fn pixelsFor(r: dvui.Rect.Natural) dvui.Rect.Physical {
    const s = screenFor(r);
    const m = dvui.windowNaturalScale();
    return .{ .x = s.x * m, .y = s.y * m, .w = s.w * m, .h = s.h * m };
}
