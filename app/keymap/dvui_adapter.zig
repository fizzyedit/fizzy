//! The one file in `keymap/` that imports dvui.
//!
//! Everything else in this tree is deliberately dvui-free so it can be unit-tested from the app
//! build (see `keymap.zig`). This file is the boundary: it converts dvui key events *in*, and
//! projects single-stroke bindings back *out* into `dvui.Window.keybinds`.
//!
//! That projection is not optional. `TextEntryWidget` calls `ke.matchBind("char_left")` and
//! `Menu.zig` calls `cw.keybinds.get("save")` to render accelerators — both read the dvui map
//! directly. Chords have no representation there at all (`dvui.enums.Keybind` is one key plus
//! modifier flags), so they exist only in the resolver.

const std = @import("std");
const dvui = @import("dvui");
const keymap = @import("keymap.zig");

const Key = keymap.Key;
const Chord = keymap.Chord;
const Mods = keymap.Mods;

// `keymap.Key`'s tags are intentionally spelled exactly like `dvui.enums.Key`'s so conversion is
// by name. This catches drift at compile time instead of silently dropping a key at runtime.
comptime {
    for (std.enums.values(Key)) |k| {
        if (!@hasField(dvui.enums.Key, @tagName(k))) {
            @compileError("keymap.Key." ++ @tagName(k) ++
                " has no dvui.enums.Key counterpart — dvui's key enum has changed");
        }
    }
}

pub fn toDvuiKey(k: Key) dvui.enums.Key {
    return switch (k) {
        inline else => |tag| @field(dvui.enums.Key, @tagName(tag)),
    };
}

/// Null for a dvui key we don't model (nothing today, but dvui may add keys before we do).
pub fn fromDvuiKey(k: dvui.enums.Key) ?Key {
    return switch (k) {
        inline else => |tag| if (@hasField(Key, @tagName(tag)))
            @field(Key, @tagName(tag))
        else
            null,
    };
}

pub fn modsFrom(mod: dvui.enums.Mod) Mods {
    return .{
        .ctrl = mod.control(),
        .shift = mod.shift(),
        .alt = mod.alt(),
        .command = mod.command(),
    };
}

/// Chord for a key event, or null if the key isn't one we model.
pub fn chordFrom(ke: dvui.Event.Key) ?Chord {
    const key = fromDvuiKey(ke.code) orelse return null;
    return .{ .key = key, .mods = modsFrom(ke.mod) };
}

/// Lower a chord to a dvui keybind. Every modifier is stated explicitly (rather than left null)
/// so a projected bind matches only the exact combination — `matchKeyBind` treats a null field
/// as "don't care", which would make `ctrl+s` also fire on `ctrl+shift+s`.
pub fn toKeybind(c: Chord) dvui.enums.Keybind {
    return .{
        .key = toDvuiKey(c.key),
        .control = c.mods.ctrl,
        .shift = c.mods.shift,
        .alt = c.mods.alt,
        .command = c.mods.command,
    };
}

/// Lift a dvui keybind into a chord. Null for modifier-only binds (`"ctrl/cmd"`, `"shift"`,
/// `"zoom"`), which have no key and exist purely to be tested with `mod.matchBind`.
pub fn fromKeybind(kb: dvui.enums.Keybind) ?Chord {
    const key = fromDvuiKey(kb.key orelse return null) orelse return null;
    return .{
        .key = key,
        .mods = .{
            .ctrl = kb.control orelse false,
            .shift = kb.shift orelse false,
            .alt = kb.alt orelse false,
            .command = kb.command orelse false,
        },
    };
}
