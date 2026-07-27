//! Physical key identity, plus the VSCode-compatible spellings used in `keybinds.zon`.
//!
//! Deliberately **not** `dvui.enums.Key`, so the whole `keymap/` tree stays dvui-free and
//! unit-testable from the app build (see `keymap.zig`). The tag names are kept identical to
//! dvui's so the adapter that does import dvui (`keymap_dvui.zig`) can convert by name and
//! `comptime`-assert that no tag has drifted, rather than hand-maintaining a 118-arm switch.

const std = @import("std");

pub const Key = enum {
    a, b, c, d, e, f, g, h, i, j, k, l, m,
    n, o, p, q, r, s, t, u, v, w, x, y, z,

    zero, one, two, three, four, five, six, seven, eight, nine,

    f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12,
    f13, f14, f15, f16, f17, f18, f19, f20, f21, f22, f23, f24, f25,

    kp_divide, kp_multiply, kp_subtract, kp_add,
    kp_0, kp_1, kp_2, kp_3, kp_4, kp_5, kp_6, kp_7, kp_8, kp_9,
    kp_decimal, kp_equal, kp_enter,

    enter, escape, tab,
    left_shift, right_shift, left_control, right_control,
    left_alt, right_alt, left_command, right_command,
    menu, num_lock, caps_lock, print, scroll_lock, pause,
    delete, home, end, page_up, page_down, insert,
    left, right, up, down,
    backspace, space,
    minus, equal, left_bracket, right_bracket, backslash,
    semicolon, apostrophe, comma, period, slash, grave,
};

/// Modifier keys are never bindable on their own — a binding whose key is one of these can only
/// ever fire together with itself, which is never what anyone means.
pub fn isModifier(k: Key) bool {
    return switch (k) {
        .left_shift, .right_shift, .left_control, .right_control,
        .left_alt, .right_alt, .left_command, .right_command => true,
        else => false,
    };
}

/// Accepted spellings → key. Primary spelling first; aliases follow. VSCode's own names are
/// used wherever they exist so its documentation and any pasted `keybindings.json` line reads
/// the same here.
const Spelling = struct { text: []const u8, key: Key };

const spellings = [_]Spelling{
    // Punctuation, by the character itself (how VSCode writes them).
    .{ .text = "`", .key = .grave },      .{ .text = "-", .key = .minus },
    .{ .text = "=", .key = .equal },      .{ .text = "[", .key = .left_bracket },
    .{ .text = "]", .key = .right_bracket }, .{ .text = "\\", .key = .backslash },
    .{ .text = ";", .key = .semicolon },  .{ .text = "'", .key = .apostrophe },
    .{ .text = ",", .key = .comma },      .{ .text = ".", .key = .period },
    .{ .text = "/", .key = .slash },

    // Named keys.
    .{ .text = "left", .key = .left },       .{ .text = "right", .key = .right },
    .{ .text = "up", .key = .up },           .{ .text = "down", .key = .down },
    .{ .text = "pageup", .key = .page_up },  .{ .text = "pagedown", .key = .page_down },
    .{ .text = "page_up", .key = .page_up }, .{ .text = "page_down", .key = .page_down },
    .{ .text = "home", .key = .home },       .{ .text = "end", .key = .end },
    .{ .text = "tab", .key = .tab },         .{ .text = "enter", .key = .enter },
    .{ .text = "return", .key = .enter },    .{ .text = "escape", .key = .escape },
    .{ .text = "esc", .key = .escape },      .{ .text = "space", .key = .space },
    .{ .text = "backspace", .key = .backspace }, .{ .text = "delete", .key = .delete },
    .{ .text = "del", .key = .delete },      .{ .text = "insert", .key = .insert },
    .{ .text = "capslock", .key = .caps_lock }, .{ .text = "numlock", .key = .num_lock },
    .{ .text = "scrolllock", .key = .scroll_lock }, .{ .text = "pausebreak", .key = .pause },
    .{ .text = "pause", .key = .pause },     .{ .text = "printscreen", .key = .print },
    .{ .text = "menu", .key = .menu },

    // Digit row — spelled as digits, not as the tag names.
    .{ .text = "0", .key = .zero },  .{ .text = "1", .key = .one },
    .{ .text = "2", .key = .two },   .{ .text = "3", .key = .three },
    .{ .text = "4", .key = .four },  .{ .text = "5", .key = .five },
    .{ .text = "6", .key = .six },   .{ .text = "7", .key = .seven },
    .{ .text = "8", .key = .eight }, .{ .text = "9", .key = .nine },

    // Numpad, VSCode spelling.
    .{ .text = "numpad0", .key = .kp_0 }, .{ .text = "numpad1", .key = .kp_1 },
    .{ .text = "numpad2", .key = .kp_2 }, .{ .text = "numpad3", .key = .kp_3 },
    .{ .text = "numpad4", .key = .kp_4 }, .{ .text = "numpad5", .key = .kp_5 },
    .{ .text = "numpad6", .key = .kp_6 }, .{ .text = "numpad7", .key = .kp_7 },
    .{ .text = "numpad8", .key = .kp_8 }, .{ .text = "numpad9", .key = .kp_9 },
    .{ .text = "numpad_multiply", .key = .kp_multiply },
    .{ .text = "numpad_add", .key = .kp_add },
    .{ .text = "numpad_subtract", .key = .kp_subtract },
    .{ .text = "numpad_divide", .key = .kp_divide },
    .{ .text = "numpad_decimal", .key = .kp_decimal },
    .{ .text = "numpad_enter", .key = .kp_enter },
    .{ .text = "numpad_equal", .key = .kp_equal },
};

/// Parse a key token (already lowercased and trimmed). Letters `a`-`z` and `f1`-`f25` fall
/// through to the tag names, so they need no table entry.
pub fn fromSpelling(token: []const u8) ?Key {
    if (token.len == 0) return null;
    for (spellings) |s| {
        if (std.mem.eql(u8, s.text, token)) return s.key;
    }
    // `a`..`z` and `f1`..`f25` are spelled exactly like their tags.
    if (std.meta.stringToEnum(Key, token)) |k| {
        // Guard against a config binding a bare modifier, or reaching a tag name that has a
        // different canonical spelling above (e.g. "grave" rather than "`").
        if (isModifier(k)) return null;
        return k;
    }
    return null;
}

/// Canonical spelling, for writing `keybinds.zon` back out and for rendering shortcut hints.
pub fn toSpelling(k: Key) []const u8 {
    for (spellings) |s| {
        if (s.key == k) return s.text;
    }
    return @tagName(k);
}

const t = std.testing;

test "letters and function keys parse from their tag names" {
    try t.expectEqual(Key.a, fromSpelling("a").?);
    try t.expectEqual(Key.z, fromSpelling("z").?);
    try t.expectEqual(Key.f12, fromSpelling("f12").?);
}

test "VSCode punctuation and named-key spellings" {
    try t.expectEqual(Key.grave, fromSpelling("`").?);
    try t.expectEqual(Key.slash, fromSpelling("/").?);
    try t.expectEqual(Key.page_up, fromSpelling("pageup").?);
    try t.expectEqual(Key.escape, fromSpelling("esc").?);
    try t.expectEqual(Key.enter, fromSpelling("enter").?);
    try t.expectEqual(Key.kp_5, fromSpelling("numpad5").?);
    try t.expectEqual(Key.zero, fromSpelling("0").?);
}

test "bare modifiers and junk are rejected" {
    try t.expectEqual(@as(?Key, null), fromSpelling("left_shift"));
    try t.expectEqual(@as(?Key, null), fromSpelling("ctrl"));
    try t.expectEqual(@as(?Key, null), fromSpelling(""));
    try t.expectEqual(@as(?Key, null), fromSpelling("nonsense"));
}

test "every spelling round-trips through its canonical form" {
    for (std.enums.values(Key)) |k| {
        if (isModifier(k)) continue;
        const canonical = toSpelling(k);
        try t.expectEqual(k, fromSpelling(canonical).?);
    }
}
