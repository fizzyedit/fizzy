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

/// A floating thing drawn across every screen this frame — a view drag's layer, whose drops and
/// carried glass are wherever the places and the pointer are: the app copies its drawing into
/// every screen's window, not just the main one. Each frame it is drawn (`isEverywhere`).
pub fn markEverywhere(id: dvui.Id) void {
    const now = dvui.currentWindow().frame_time_ns;
    const e = dvui.dataGetPtrDefault(null, key_id, "_everywhere", Everywhere, .{});
    if (e.frame != now) e.* = .{ .frame = now };
    if (e.n < e.ids.len) {
        e.ids[e.n] = id;
        e.n += 1;
    }
}

/// Whether `id` was marked as drawn across every screen this frame (`markEverywhere`).
pub fn isEverywhere(id: dvui.Id) bool {
    const e = dvui.dataGetPtr(null, key_id, "_everywhere", Everywhere) orelse return false;
    if (e.frame != dvui.currentWindow().frame_time_ns) return false;
    for (e.ids[0..e.n]) |i| if (i == id) return true;
    return false;
}

const Everywhere = struct {
    frame: i128 = 0,
    n: u8 = 0,
    ids: [8]dvui.Id = undefined,
};

/// What is carried, in a layer of its own this frame, where the app shows it in a window of its
/// own over every other (fizzy's carry window): that window takes the layer's drawing whole, and
/// the app's own windows draw none of it. A copy left in them, under the carry window, was drawn
/// at a different moment from it — the window server moves the carry window, the app presents its
/// windows — and trailed behind it as it moved.
/// Several a frame: the carried view, and what goes over the OS's glass with it (a drop's icons).
pub fn markCarried(id: dvui.Id) void {
    const now = dvui.currentWindow().frame_time_ns;
    const c = dvui.dataGetPtrDefault(null, key_id, "_carried", Carried, .{});
    if (c.frame != now) c.* = .{ .frame = now };
    if (c.n < c.ids.len) {
        c.ids[c.n] = id;
        c.n += 1;
    }
}

/// Whether `id` is carried this frame (`markCarried`).
pub fn isCarried(id: dvui.Id) bool {
    const c = dvui.dataGetPtr(null, key_id, "_carried", Carried) orelse return false;
    if (c.frame != dvui.currentWindow().frame_time_ns) return false;
    for (c.ids[0..c.n]) |i| if (i == id) return true;
    return false;
}

const Carried = struct {
    frame: i128 = 0,
    n: u8 = 0,
    ids: [4]dvui.Id = undefined,
};

/// While something drawn across every screen may be carried past every window of the app's — a
/// view drag where floats are OS windows of their own, and a window carries the view over the
/// desktop — it reaches across the whole desktop (`allPixels`). The app's, each frame.
pub fn publishBeyond(on: bool) void {
    if (on) dvui.dataSet(null, key_id, "_beyond", true) else dvui.dataRemove(null, key_id, "_beyond");
}

/// How far past the main window the whole desktop reaches, natural units each way: further than
/// any desktop.
const beyond: f32 = 16384;

/// Every screen at once, physical: what a floating thing drawn across all of them clips to.
pub fn allPixels() dvui.Rect.Physical {
    var r = dvui.windowRectPixels();
    if (dvui.dataGet(null, key_id, "_beyond", bool) orelse false) r = r.outsetAll(beyond * dvui.windowNaturalScale());
    const p = dvui.dataGetPtr(null, key_id, key, Published) orelse return r;
    const m = dvui.windowNaturalScale();
    for (p.rects[0..p.n]) |s| r = r.unionWith(.{ .x = s.x * m, .y = s.y * m, .w = s.w * m, .h = s.h * m });
    return r;
}

/// `screenFor`, physical: what a floating thing on that screen clips its drawing to.
pub fn pixelsFor(r: dvui.Rect.Natural) dvui.Rect.Physical {
    const s = screenFor(r);
    const m = dvui.windowNaturalScale();
    return .{ .x = s.x * m, .y = s.y * m, .w = s.w * m, .h = s.h * m };
}
