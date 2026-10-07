//! Glass the OS draws in place of the app's: Liquid Glass on macOS 26, where a view drag's glass —
//! the carried view and the drop zones' bubbles — is one overlay of the OS's glass over every window
//! (fizzy's `Popout`), merging and refracting as the OS's glass does. Where it is on this frame, the
//! glass that would be drawn is declared here instead (`add`), in the main window's frame, and the
//! app reconciles the OS's glass with it at the end of the frame; nothing of it is drawn by the app.
//!
//! In dvui's data, as `screens` is, so whatever draws the glass — fizzy, a plugin's drop zones —
//! declares it the same way, with no SDK between them.
const std = @import("std");
const dvui = @import("dvui");

/// A piece of the OS's glass: a rounded rect in the main window's frame (a float's window's band
/// past it, where its places are drawn), physical pixels.
pub const Shape = struct {
    rect: dvui.Rect.Physical,
    /// Physical pixels.
    radius: f32,
    /// How lit it is (0…1): the bubble a carried view is aimed at, as a hovered bubble lights.
    lit: f32 = 0,
    /// How much of it there is (0…1): coming in, going.
    alpha: f32 = 1,
    /// How much of the frost's blur it takes in its middle (0…1): whole for a bubble carrying an
    /// icon, which reads through a blur of what is under it, as the app's own glass blurs; none
    /// for the carried view, a clear lens over its picture beneath (`publishUnder`).
    frost: f32 = 1,
};

/// The most pieces of glass in a frame: a carried drop's head and tail, and the bubbles of the
/// drops showing (a wheel's six each).
pub const max_shapes = 48;

const key_id = dvui.Id.update(.zero, "core.native_glass");

const Frame = struct {
    frame: i128 = 0,
    on: bool = false,
    n: u8 = 0,
    shapes: [max_shapes]Shape = undefined,
    /// Physical pixels; 0 while nothing has said.
    merge_px: f32 = 0,
};

fn current() *Frame {
    const now = dvui.currentWindow().frame_time_ns;
    const f = dvui.dataGetPtrDefault(null, key_id, "_frame", Frame, .{});
    if (f.frame != now) f.* = .{ .frame = now, .on = f.on };
    return f;
}

/// Whether the OS draws a view drag's glass this frame, set by the app before anything draws.
pub fn publishOn(on_: bool) void {
    current().on = on_;
}

/// Whether the carried view's picture goes under the OS's glass this frame, in a window of its own
/// beneath the drag's (the app's, each frame): the glass then bends it, a lens over what is carried.
/// The drag hands it over rather than drawing it over the glass.
pub fn publishUnder(on_: bool) void {
    dvui.dataSet(null, key_id, "_under", on_);
}

/// Whether the carried view's picture goes under the OS's glass this frame (`publishUnder`).
pub fn under() bool {
    return dvui.dataGet(null, key_id, "_under", bool) orelse false;
}

/// Whether the OS draws a view drag's glass this frame (`publishOn`): declare it (`add`), draw none.
pub fn on() bool {
    const f = dvui.dataGetPtr(null, key_id, "_frame", Frame) orelse return false;
    return f.on;
}

/// A piece of glass for the OS to draw this frame.
pub fn add(s: Shape) void {
    const f = current();
    if (f.n >= max_shapes) return;
    f.shapes[f.n] = s;
    f.n += 1;
}

/// How far apart the pieces declared with it still run together, physical pixels: the merge the
/// app's own glass would have drawn them at — a drop's, which shrinks with its bubbles where a
/// small place fits them smaller (`DropZones`). The OS runs every piece together at one distance;
/// the smallest said this frame is it.
pub fn mergeWithin(px: f32) void {
    const f = current();
    if (px > 0 and (f.merge_px == 0 or px < f.merge_px)) f.merge_px = px;
}

/// This frame's merge distance (`mergeWithin`), physical pixels; null while nothing has said.
pub fn merge() ?f32 {
    const f = dvui.dataGetPtr(null, key_id, "_frame", Frame) orelse return null;
    if (f.frame != dvui.currentWindow().frame_time_ns or f.merge_px <= 0) return null;
    return f.merge_px;
}

/// This frame's glass, as declared so far (`add`).
pub fn shapes() []const Shape {
    const f = dvui.dataGetPtr(null, key_id, "_frame", Frame) orelse return &.{};
    if (f.frame != dvui.currentWindow().frame_time_ns) return &.{};
    return f.shapes[0..f.n];
}
