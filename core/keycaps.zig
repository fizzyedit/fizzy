//! How a keybind is drawn — the one place that decides it.
//!
//! Every key has one face — a glyph where there is a good one, a short label where there is
//! not — and modifiers come in the order each platform's own menus use.
//!
//! This draws; it does not spell. `Keymap.formatKeys` is still the text form, because that is also
//! what `keybindings.zon` round-trips through, and a display change must never change what a
//! file on disk means.
//!
//! Keys are named by their tag (`a`, `f1`, `enter`, `page_up`): `dvui.enums.Key` and fizzy's
//! `keymap.Key` share them, so both the menus and the keymap can come here without core knowing
//! either type.
const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const platform = @import("platform.zig");
const icon_tex = @import("gfx/icon.zig");

pub const Mods = struct {
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
    /// ⌘ on macOS, the Windows/Super key elsewhere.
    command: bool = false,

    pub fn fromKeybind(kb: dvui.enums.Keybind) Mods {
        return .{
            .ctrl = kb.control orelse false,
            .shift = kb.shift orelse false,
            .alt = kb.alt orelse false,
            .command = kb.command orelse false,
        };
    }
};

/// One press: modifiers and a key, by tag name.
pub const Chord = struct {
    mods: Mods = .{},
    key: []const u8,
};

/// A binding: one chord, or two in sequence (`⌘K ⌘C`).
pub const Stroke = struct {
    first: Chord,
    second: ?Chord = null,

    /// A dvui keybind as a stroke. Null when it names no key — a keybind that is only modifiers
    /// is not something a menu row can show.
    pub fn fromKeybind(kb: dvui.enums.Keybind) ?Stroke {
        const key = kb.key orelse return null;
        return .{ .first = .{ .mods = .fromKeybind(kb), .key = @tagName(key) } };
    }
};

/// What one keycap shows.
pub const Face = union(enum) {
    glyph: []const u8,
    text: []const u8,
};

/// How a stroke is laid out.
pub const Style = enum {
    /// Bare faces in a row, the way an OS menu shows a shortcut: `⇧⌘P` on macOS, `Ctrl+Shift+P`
    /// elsewhere. For menu rows, where the shortcut is a hint beside the thing you want.
    plain,
    /// Each face in its own keycap. For where the chord *is* the thing being read: the keybind
    /// settings, the command palette.
    caps,
};

/// The glyphs, by meaning. Callers never name an icon set: when a glyph changes, it changes here.
pub const glyph = struct {
    const m = icons.tvg.material;
    pub const command = m.keyboard_command_key;
    pub const option = m.keyboard_option_key;
    pub const control = m.keyboard_control_key;
    pub const shift = m.shift;
    pub const caps_lock = m.keyboard_capslock;
    pub const tab = m.keyboard_tab;
    pub const enter = m.keyboard_return;
    pub const backspace = m.backspace;
    pub const space = m.space_bar;
    pub const up = m.arrow_upward;
    pub const down = m.arrow_downward;
    pub const left = m.arrow_back;
    pub const right = m.arrow_forward;
};

/// A key's face. Glyphs on every platform for the keys whose glyph *is* their name everywhere —
/// ↩ ⇥ ⌫ and the arrows are printed on keyboards — and a short label for the rest.
pub fn keyFace(name: []const u8) Face {
    if (glyphFor(name)) |g| return .{ .glyph = g };
    if (name.len == 1 and name[0] >= 'a' and name[0] <= 'z') return .{ .text = upper[name[0] - 'a'] };
    inline for (named) |pair| {
        if (std.mem.eql(u8, name, pair[0])) return .{ .text = pair[1] };
    }
    if (functionKey(name)) |label| return .{ .text = label };
    return .{ .text = name };
}

fn glyphFor(name: []const u8) ?[]const u8 {
    const pairs = .{
        .{ "enter", glyph.enter },         .{ "kp_enter", glyph.enter }, .{ "tab", glyph.tab },
        .{ "backspace", glyph.backspace }, .{ "space", glyph.space },    .{ "up", glyph.up },
        .{ "down", glyph.down },           .{ "left", glyph.left },      .{ "right", glyph.right },
        .{ "caps_lock", glyph.caps_lock },
    };
    inline for (pairs) |p| {
        if (std.mem.eql(u8, name, p[0])) return p[1];
    }
    return null;
}

const upper = blk: {
    var out: [26][]const u8 = undefined;
    for (0..26) |i| out[i] = &[_]u8{'A' + @as(u8, @intCast(i))};
    break :blk out;
};

/// Keys whose label is not their tag.
const named = .{
    .{ "zero", "0" },           .{ "one", "1" },             .{ "two", "2" },             .{ "three", "3" },
    .{ "four", "4" },           .{ "five", "5" },            .{ "six", "6" },             .{ "seven", "7" },
    .{ "eight", "8" },          .{ "nine", "9" },            .{ "escape", "Esc" },        .{ "delete", "Del" },
    .{ "insert", "Ins" },       .{ "home", "Home" },         .{ "end", "End" },           .{ "page_up", "PgUp" },
    .{ "page_down", "PgDn" },   .{ "minus", "-" },           .{ "equal", "=" },           .{ "left_bracket", "[" },
    .{ "right_bracket", "]" },  .{ "backslash", "\\" },      .{ "semicolon", ";" },       .{ "apostrophe", "'" },
    .{ "comma", "," },          .{ "period", "." },          .{ "slash", "/" },           .{ "grave", "`" },
    .{ "kp_add", "Num +" },     .{ "kp_subtract", "Num -" }, .{ "kp_multiply", "Num *" }, .{ "kp_divide", "Num /" },
    .{ "kp_decimal", "Num ." }, .{ "kp_equal", "Num =" },    .{ "kp_0", "Num 0" },        .{ "kp_1", "Num 1" },
    .{ "kp_2", "Num 2" },       .{ "kp_3", "Num 3" },        .{ "kp_4", "Num 4" },        .{ "kp_5", "Num 5" },
    .{ "kp_6", "Num 6" },       .{ "kp_7", "Num 7" },        .{ "kp_8", "Num 8" },        .{ "kp_9", "Num 9" },
    .{ "print", "PrtSc" },      .{ "pause", "Pause" },       .{ "menu", "Menu" },
};

const function_keys = blk: {
    var out: [25][]const u8 = undefined;
    for (0..25) |i| out[i] = std.fmt.comptimePrint("F{d}", .{i + 1});
    break :blk out;
};

fn functionKey(name: []const u8) ?[]const u8 {
    if (name.len < 2 or name[0] != 'f') return null;
    const n = std.fmt.parseInt(usize, name[1..], 10) catch return null;
    if (n < 1 or n > function_keys.len) return null;
    return function_keys[n - 1];
}

/// The modifier faces for `mods`, in the platform's own order: ⌃⌥⇧⌘ on macOS (Apple's menus),
/// Ctrl, Shift, Alt, Win elsewhere (what Windows and GNOME write). On macOS they are glyphs, which
/// is what those keys are called there; elsewhere they are words, because ⌥ and ⌘ mean nothing on
/// a PC keyboard and ⇧ alone reads as an arrow.
pub fn modifierFaces(mods: Mods, mac: bool, out: *[4]Face) []const Face {
    var n: usize = 0;
    if (mac) {
        if (mods.ctrl) out[inc(&n)] = .{ .glyph = glyph.control };
        if (mods.alt) out[inc(&n)] = .{ .glyph = glyph.option };
        if (mods.shift) out[inc(&n)] = .{ .glyph = glyph.shift };
        if (mods.command) out[inc(&n)] = .{ .glyph = glyph.command };
    } else {
        if (mods.ctrl) out[inc(&n)] = .{ .text = "Ctrl" };
        if (mods.shift) out[inc(&n)] = .{ .text = "Shift" };
        if (mods.alt) out[inc(&n)] = .{ .text = "Alt" };
        if (mods.command) out[inc(&n)] = .{ .text = "Win" };
    }
    return out[0..n];
}

fn inc(n: *usize) usize {
    defer n.* += 1;
    return n.*;
}

pub const DrawOptions = struct {
    style: Style = .plain,
    /// The face colour. Defaults to the dimmed control text menus use for shortcuts.
    color: ?dvui.Color = null,
    enabled: bool = true,
    id_extra: usize = 0,
    gravity_x: f32 = 1.0,
    gravity_y: f32 = 0.5,
    /// Force a platform, for tests and for a keymap editor showing another platform's bindings.
    mac: ?bool = null,
    /// What a `.caps` keycap is filled with; the control fill when null. Something translucent
    /// for caps drawn on glass.
    cap_fill: ?dvui.Color = null,
};

/// Draw `stroke`. A two-part chord draws both halves with a gap between them.
pub fn draw(src: std.builtin.SourceLocation, stroke: Stroke, opts: DrawOptions) void {
    const theme = dvui.themeGet();
    const base = opts.color orelse theme.color(.control, .text).opacity(0.55);
    const color = if (opts.enabled) base else base.opacity(0.5);
    const mac = opts.mac orelse platform.isMacOS();
    const cap_fill = opts.cap_fill orelse theme.color(.control, .fill);

    var row = dvui.box(src, .{ .dir = .horizontal }, .{
        .id_extra = opts.id_extra,
        .gravity_x = opts.gravity_x,
        .gravity_y = opts.gravity_y,
    });
    defer row.deinit();

    drawChord(stroke.first, 0, color, mac, opts.style, cap_fill);
    if (stroke.second) |second| {
        _ = dvui.spacer(@src(), .{ .min_size_content = .width(6) });
        drawChord(second, 1, color, mac, opts.style, cap_fill);
    }
}

fn drawChord(chord: Chord, which: usize, color: dvui.Color, mac: bool, style: Style, cap_fill: dvui.Color) void {
    var mod_buf: [4]Face = undefined;
    const mods = modifierFaces(chord.mods, mac, &mod_buf);
    var faces: [5]Face = undefined;
    @memcpy(faces[0..mods.len], mods);
    faces[mods.len] = keyFace(chord.key);
    const all = faces[0 .. mods.len + 1];

    for (all, 0..) |face, i| {
        const id = which * 8 + i;
        // Plain on a PC is `Ctrl+Shift+P`: words need the `+` that glyphs run together without.
        if (style == .plain and !mac and i > 0) plainText("+", id * 2, color);
        switch (style) {
            .plain => if (i + 1 == all.len) drawKeyColumn(face, id, color) else drawFace(face, id, color),
            .caps => {
                var cap = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .id_extra = id,
                    .gravity_y = 0.5,
                    .margin = .{ .x = if (i == 0) 0 else 3 },
                    .padding = .{ .x = 5, .y = 1, .w = 5, .h = 1 },
                    .corners = @import("corners.zig").all(4),
                    .background = true,
                    .color_fill = .{ .color = cap_fill },
                    .min_size_content = .{ .w = 12 },
                });
                defer cap.deinit();
                drawFace(face, id, color);
            },
        }
    }
}

/// The key in a plain chord, in a column one wide letter wide and drawn from its left edge — the
/// way macOS lays out a menu's shortcuts. Shortcuts sit against a row's right edge, so without
/// the column a narrow key (`F`, `I`) would pull the modifiers in front of it out of line with
/// the rows above and below.
fn drawKeyColumn(face: Face, id: usize, color: dvui.Color) void {
    const font = dvui.Font.theme(.body);
    const w = @max(font.textSize("W").w, font.lineHeight() * 0.85);
    var col = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = id,
        .gravity_y = 0.5,
        .min_size_content = .{ .w = w },
        .padding = .all(0),
        .margin = .all(0),
    });
    defer col.deinit();
    drawFace(face, id, color);
}

fn drawFace(face: Face, id: usize, color: dvui.Color) void {
    switch (face) {
        .text => |label| plainText(label, id * 2 + 1, color),
        .glyph => |g| {
            // Sized to the text beside it, so a glyph and a letter in the same chord line up.
            const h = dvui.Font.theme(.body).lineHeight();
            icon_tex.icon(@src(), "keycap", g, .{ .fill_color = .{ .color = color }, .stroke_color = .{ .color = color } }, .{
                .id_extra = id,
                .gravity_y = 0.5,
                .min_size_content = .{ .w = h * 0.85, .h = h * 0.85 },
                .max_size_content = .{ .w = h * 0.85, .h = h * 0.85 },
            });
        },
    }
}

fn plainText(text: []const u8, id: usize, color: dvui.Color) void {
    dvui.labelNoFmt(@src(), text, .{}, .{
        .id_extra = id,
        .gravity_y = 0.5,
        .color_text = .{ .color = color },
        .padding = .all(0),
    });
}

// ---- tests --------------------------------------------------------------------------------------

const t = std.testing;

test "every key has a face, and the obvious ones are glyphs" {
    try t.expect(keyFace("enter") == .glyph);
    try t.expect(keyFace("left") == .glyph);
    try t.expectEqualStrings("A", keyFace("a").text);
    try t.expectEqualStrings("0", keyFace("zero").text);
    try t.expectEqualStrings("F12", keyFace("f12").text);
    try t.expectEqualStrings("PgUp", keyFace("page_up").text);
    try t.expectEqualStrings("`", keyFace("grave").text);
    // Something with no entry falls back to its name rather than vanishing.
    try t.expectEqualStrings("scroll_lock", keyFace("scroll_lock").text);
}

test "modifiers come in each platform's own order" {
    var buf: [4]Face = undefined;
    const all: Mods = .{ .ctrl = true, .shift = true, .alt = true, .command = true };

    const mac = modifierFaces(all, true, &buf);
    try t.expectEqual(@as(usize, 4), mac.len);
    try t.expectEqual(glyph.control.ptr, mac[0].glyph.ptr);
    try t.expectEqual(glyph.option.ptr, mac[1].glyph.ptr);
    try t.expectEqual(glyph.shift.ptr, mac[2].glyph.ptr);
    try t.expectEqual(glyph.command.ptr, mac[3].glyph.ptr);

    const pc = modifierFaces(all, false, &buf);
    try t.expectEqualStrings("Ctrl", pc[0].text);
    try t.expectEqualStrings("Shift", pc[1].text);
    try t.expectEqualStrings("Alt", pc[2].text);
    try t.expectEqualStrings("Win", pc[3].text);
}
