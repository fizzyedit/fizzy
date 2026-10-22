//! What kind of device the window is on, decided from numbers alone so it tests without a Window.
//!
//! The layout choice (a phone gets one full-screen place, a tablet and a desktop the studio
//! shape) is the form factor; whether a widget is sized for a finger is `dvui.pointerKind()`
//! per frame, since a 2-in-1's pointer changes at runtime. `core.platform` holds the live value.
const std = @import("std");

pub const FormFactor = enum { desktop, tablet, phone };

/// A touch device whose short side is under this many CSS px is a phone.
pub const phone_short_side: f32 = 600;

/// `coarse` is a primary pointer that is a finger with no hover (the page's
/// `(pointer: coarse) and (hover: none)`); `w` and `h` are the screen in CSS px (not the viewport, which the soft keyboard shrinks). A desktop
/// browser narrowed to a phone's width stays `.desktop`: it has a mouse, and the user chose the
/// size.
pub fn classify(coarse: bool, w: f32, h: f32) FormFactor {
    // An unmeasured page (a hidden frame reports 0 x 0) is not a phone.
    if (!coarse or !(w > 0) or !(h > 0)) return .desktop;
    return if (@min(w, h) < phone_short_side) .phone else .tablet;
}

test "a fine pointer is a desktop at any size" {
    try std.testing.expectEqual(FormFactor.desktop, classify(false, 1440, 900));
    try std.testing.expectEqual(FormFactor.desktop, classify(false, 375, 812));
}

test "an unmeasured viewport is a desktop" {
    try std.testing.expectEqual(FormFactor.desktop, classify(true, 0, 0));
    try std.testing.expectEqual(FormFactor.desktop, classify(true, 375, 0));
}

test "a coarse pointer under 600 CSS px on its short side is a phone, either way up" {
    try std.testing.expectEqual(FormFactor.phone, classify(true, 375, 812));
    try std.testing.expectEqual(FormFactor.phone, classify(true, 812, 375));
    try std.testing.expectEqual(FormFactor.phone, classify(true, 599, 1200));
}

test "a coarse pointer at 600 or more on its short side is a tablet" {
    try std.testing.expectEqual(FormFactor.tablet, classify(true, 600, 900));
    try std.testing.expectEqual(FormFactor.tablet, classify(true, 1024, 768));
}
