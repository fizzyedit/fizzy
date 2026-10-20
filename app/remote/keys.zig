//! A remote host's key and modifier codes as dvui's. `Key.code` is the physical key as a USB HID
//! usage (page 0x07), the numbering SDL's scancodes and most hosts' own tables share; a host
//! whose own codes differ maps them before it sends. `host_code` is the host's and not read here.
const std = @import("std");
const dvui = @import("dvui");
const message = @import("remote").message;

/// The dvui key a HID usage names; `.unknown` for one fizzy has no key for.
pub fn fromHid(code: u32) dvui.enums.Key {
    const K = dvui.enums.Key;
    return switch (code) {
        4...29 => @fromBackingInt(@intCast(@backingInt(K.a) + (code - 4))),
        30...38 => @fromBackingInt(@intCast(@backingInt(K.one) + (code - 30))),
        39 => .zero,
        40 => .enter,
        41 => .escape,
        42 => .backspace,
        43 => .tab,
        44 => .space,
        45 => .minus,
        46 => .equal,
        47 => .left_bracket,
        48 => .right_bracket,
        49 => .backslash,
        51 => .semicolon,
        52 => .apostrophe,
        53 => .grave,
        54 => .comma,
        55 => .period,
        56 => .slash,
        57 => .caps_lock,
        58...69 => @fromBackingInt(@intCast(@backingInt(K.f1) + (code - 58))),
        70 => .print,
        71 => .scroll_lock,
        72 => .pause,
        73 => .insert,
        74 => .home,
        75 => .page_up,
        76 => .delete,
        77 => .end,
        78 => .page_down,
        79 => .right,
        80 => .left,
        81 => .down,
        82 => .up,
        83 => .num_lock,
        84 => .kp_divide,
        85 => .kp_multiply,
        86 => .kp_subtract,
        87 => .kp_add,
        88 => .kp_enter,
        89...97 => @fromBackingInt(@intCast(@backingInt(K.kp_1) + (code - 89))),
        98 => .kp_0,
        99 => .kp_decimal,
        101 => .menu,
        103 => .kp_equal,
        104...115 => @fromBackingInt(@intCast(@backingInt(K.f13) + (code - 104))),
        224 => .left_control,
        225 => .left_shift,
        226 => .left_alt,
        227 => .left_command,
        228 => .right_control,
        229 => .right_shift,
        230 => .right_alt,
        231 => .right_command,
        else => .unknown,
    };
}

/// The modifiers a host reports, as dvui's left-hand bits (a host does not say which side).
pub fn toMod(mods: message.Mods) dvui.enums.Mod {
    var bits: u16 = 0;
    if (mods.shift) bits |= @backingInt(dvui.enums.Mod.lshift);
    if (mods.ctrl) bits |= @backingInt(dvui.enums.Mod.lcontrol);
    if (mods.alt) bits |= @backingInt(dvui.enums.Mod.lalt);
    if (mods.super) bits |= @backingInt(dvui.enums.Mod.lcommand);
    return @fromBackingInt(@intCast(bits));
}

/// 0 left, 1 middle, 2 right, then the extras.
pub fn button(n: u8) dvui.enums.Button {
    return switch (n) {
        0 => .left,
        1 => .middle,
        2 => .right,
        3 => .four,
        4 => .five,
        5 => .six,
        6 => .seven,
        else => .eight,
    };
}

test "HID usages land on the keys they name" {
    try std.testing.expectEqual(dvui.enums.Key.a, fromHid(4));
    try std.testing.expectEqual(dvui.enums.Key.z, fromHid(29));
    try std.testing.expectEqual(dvui.enums.Key.one, fromHid(30));
    try std.testing.expectEqual(dvui.enums.Key.nine, fromHid(38));
    try std.testing.expectEqual(dvui.enums.Key.zero, fromHid(39));
    try std.testing.expectEqual(dvui.enums.Key.f1, fromHid(58));
    try std.testing.expectEqual(dvui.enums.Key.f12, fromHid(69));
    try std.testing.expectEqual(dvui.enums.Key.f24, fromHid(115));
    try std.testing.expectEqual(dvui.enums.Key.kp_9, fromHid(97));
    try std.testing.expectEqual(dvui.enums.Key.up, fromHid(82));
    try std.testing.expectEqual(dvui.enums.Key.right_command, fromHid(231));
    try std.testing.expectEqual(dvui.enums.Key.unknown, fromHid(0));
}

test "modifiers become dvui's left-hand bits" {
    const m = toMod(.{ .shift = true, .super = true });
    try std.testing.expect(m.has(.lshift));
    try std.testing.expect(m.has(.lcommand));
    try std.testing.expect(!m.has(.lcontrol));
    try std.testing.expectEqual(dvui.enums.Mod.none, toMod(.{}));
}
