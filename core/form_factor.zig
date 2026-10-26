//! What kind of device the window is on, decided from numbers alone so it tests without a Window.
//!
//! The layout choice (a mobile device gets one full-screen place, a tablet and a desktop the studio
//! shape) is the form factor; whether a widget is sized for a finger is `dvui.pointerKind()`
//! per frame, since a 2-in-1's pointer changes at runtime. `core.platform` holds the live value.
const std = @import("std");

pub const FormFactor = enum { desktop, tablet, mobile };

/// The person's Layout setting (`settings.zon`'s `layout_mode`): `auto` follows what was detected,
/// the others force a shape on any device.
pub const LayoutMode = enum { auto, mobile, desktop };

/// A touch device whose short side is under this many CSS px is mobile.
pub const mobile_short_side: f32 = 600;

/// `coarse` is a primary pointer that is a finger with no hover (the page's
/// `(pointer: coarse) and (hover: none)`); `w` and `h` are the screen in CSS px (not the viewport, which the soft keyboard shrinks). A desktop
/// browser narrowed to a mobile device's width stays `.desktop`: it has a mouse, and the user chose the
/// size.
pub fn classify(coarse: bool, w: f32, h: f32) FormFactor {
    // An unmeasured page (a hidden frame reports 0 x 0) is not mobile.
    if (!coarse or !(w > 0) or !(h > 0)) return .desktop;
    return if (@min(w, h) < mobile_short_side) .mobile else .tablet;
}

/// The page's `?form=` override as a number (`FormFactor`'s order: desktop 0, tablet 1, mobile 2);
/// anything else, the page sends -1 for "none", and a value this build does not know is ignored.
pub fn overrideFromCode(code: i32) ?FormFactor {
    return switch (code) {
        0 => .desktop,
        1 => .tablet,
        2 => .mobile,
        else => null,
    };
}

/// The form factor for this visit: `override` (`?form=`, per visit, never stored) when there is
/// one, else the measured rule.
pub fn resolve(coarse: bool, w: f32, h: f32, override: ?FormFactor) FormFactor {
    return override orelse classify(coarse, w, h);
}

/// The form factor the layout is drawn for: this visit's `override` (`?form=`) beats the setting,
/// `mobile` and `desktop` force theirs, and `auto` is what was `detected`.
pub fn effective(detected: FormFactor, mode: LayoutMode, override: ?FormFactor) FormFactor {
    if (override) |o| return o;
    return switch (mode) {
        .auto => detected,
        .mobile => .mobile,
        .desktop => .desktop,
    };
}

test "effective covers every detected form, mode and override" {
    const overrides = [_]?FormFactor{ null, .desktop, .tablet, .mobile };
    for (std.enums.values(FormFactor)) |detected| {
        for (std.enums.values(LayoutMode)) |mode| {
            for (overrides) |override| {
                const want: FormFactor = if (override) |o| o else switch (mode) {
                    .auto => detected,
                    .mobile => .mobile,
                    .desktop => .desktop,
                };
                try std.testing.expectEqual(want, effective(detected, mode, override));
            }
        }
    }
}

test "a mode forces mobile or desktop on any device, and auto keeps a tablet a tablet" {
    try std.testing.expectEqual(FormFactor.mobile, effective(.desktop, .mobile, null));
    try std.testing.expectEqual(FormFactor.desktop, effective(.mobile, .desktop, null));
    try std.testing.expectEqual(FormFactor.tablet, effective(.tablet, .auto, null));
    try std.testing.expectEqual(FormFactor.desktop, effective(.tablet, .desktop, null));
}

test "a fine pointer is a desktop at any size" {
    try std.testing.expectEqual(FormFactor.desktop, classify(false, 1440, 900));
    try std.testing.expectEqual(FormFactor.desktop, classify(false, 375, 812));
}

test "an unmeasured viewport is a desktop" {
    try std.testing.expectEqual(FormFactor.desktop, classify(true, 0, 0));
    try std.testing.expectEqual(FormFactor.desktop, classify(true, 375, 0));
}

test "a coarse pointer under 600 CSS px on its short side is mobile, either way up" {
    try std.testing.expectEqual(FormFactor.mobile, classify(true, 375, 812));
    try std.testing.expectEqual(FormFactor.mobile, classify(true, 812, 375));
    try std.testing.expectEqual(FormFactor.mobile, classify(true, 599, 1200));
}

test "a coarse pointer at 600 or more on its short side is a tablet" {
    try std.testing.expectEqual(FormFactor.tablet, classify(true, 600, 900));
    try std.testing.expectEqual(FormFactor.tablet, classify(true, 1024, 768));
}

test "an override wins over what was measured, either way" {
    try std.testing.expectEqual(FormFactor.mobile, resolve(false, 1440, 900, .mobile));
    try std.testing.expectEqual(FormFactor.tablet, resolve(false, 1440, 900, .tablet));
    try std.testing.expectEqual(FormFactor.desktop, resolve(true, 375, 812, .desktop));
    try std.testing.expectEqual(FormFactor.mobile, resolve(false, 0, 0, .mobile));
}

test "no override leaves the measured rule unchanged" {
    try std.testing.expectEqual(classify(true, 375, 812), resolve(true, 375, 812, null));
    try std.testing.expectEqual(classify(false, 375, 812), resolve(false, 375, 812, null));
    try std.testing.expectEqual(classify(true, 1024, 768), resolve(true, 1024, 768, null));
}

test "an override code names a form factor; an unknown one is ignored" {
    try std.testing.expectEqual(@as(?FormFactor, .desktop), overrideFromCode(0));
    try std.testing.expectEqual(@as(?FormFactor, .tablet), overrideFromCode(1));
    try std.testing.expectEqual(@as(?FormFactor, .mobile), overrideFromCode(2));
    try std.testing.expectEqual(@as(?FormFactor, null), overrideFromCode(-1));
    try std.testing.expectEqual(@as(?FormFactor, null), overrideFromCode(3));
    for (std.enums.values(FormFactor)) |f| try std.testing.expectEqual(@as(?FormFactor, f), overrideFromCode(@backingInt(f)));
}
