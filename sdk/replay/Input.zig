//! Tape input as dvui events: what a glide, a press, a key or typed text becomes, added to dvui's
//! event list exactly where a backend adds the real ones, so every widget, keybind and plugin
//! handles it as it handles a person's.
//!
//! The half of a `Sequencer.Sink` that is dvui's and nothing else's. Whoever plays a tape owns one
//! and adds what is its own around it: the `Player` (a demo) its stage's commands, keyframes and
//! idleness, its transport and its interruptions; a live driver (`plans/AGENTS_PLAN.md`, "Driving a
//! live tape") the same few calls with rules of its own. Each owns one, so a button one of them
//! holds is that one's to let go of.
const Input = @This();

const std = @import("std");
const dvui = @import("dvui");
const Tape = @import("tape").Tape;
const Sequencer = @import("tape").Sequencer;
const chord = @import("tape").chord;

/// The buttons this input has pressed and not let go of.
held: std.EnumSet(Tape.Button) = .initEmpty(),

/// A target's point in physical pixels: a fraction of the tagged rect (or the window), nudged by
/// natural pixels. Only a visible tag has a point.
pub fn targetPoint(target: Tape.Target) ?Sequencer.Point {
    const r: dvui.Rect.Physical = if (target.tag.len == 0) dvui.windowRectPixels() else blk: {
        const td = dvui.tagGet(target.tag) orelse return null;
        if (!td.visible) return null;
        break :blk td.rect;
    };
    const scale = dvui.windowNaturalScale();
    return .{ .x = r.x + r.w * target.x + target.dx * scale, .y = r.y + r.h * target.y + target.dy * scale };
}

pub fn moveTo(pt: Sequencer.Point) void {
    _ = dvui.currentWindow().addEventMouseMotion(.{ .pt = .{ .x = pt.x, .y = pt.y } }) catch {};
}

/// Put dvui's pointer back at `pt`, where the tape has it, if anything real moved it.
pub fn holdPointer(pt: Sequencer.Point) void {
    const cw = dvui.currentWindow();
    if (cw.mouse_pt.x == pt.x and cw.mouse_pt.y == pt.y) return;
    _ = cw.addEventMouseMotion(.{ .pt = .{ .x = pt.x, .y = pt.y } }) catch {};
}

pub fn button(self: *Input, b: Tape.Button, down: bool) void {
    _ = dvui.currentWindow().addEventMouseButton(dvuiButton(b), if (down) .press else .release) catch {};
    if (down) self.held.insert(b) else self.held.remove(b);
}

/// Let go of every button this input holds.
pub fn releaseHeld(self: *Input) void {
    // At teardown (quitting while a tape holds a button) there is no window to send them to, and
    // nothing left to release them in.
    if (dvui.current_window) |cw| {
        var it = self.held.iterator();
        while (it.next()) |b| {
            _ = cw.addEventMouseButton(dvuiButton(b), .release) catch {};
        }
    }
    self.held = .initEmpty();
}

pub fn scroll(by: Tape.Scroll) void {
    const cw = dvui.currentWindow();
    if (by.y != 0) _ = cw.addEventMouseWheel(by.y, .vertical, .mouse) catch {};
    if (by.x != 0) _ = cw.addEventMouseWheel(by.x, .horizontal, .mouse) catch {};
}

/// The tape's spelling of a chord is the keymap's (`check`): `mod` is ⌘ on a Mac and Ctrl
/// elsewhere, and a two-stroke chord is pressed a stroke at a time.
pub fn key(spelled: []const u8) void {
    // `check` passed it at load; a tape that skipped that loses the key.
    const stroke = chord.parseKeys(spelled, platform()) catch return;
    pressChord(stroke.first);
    if (stroke.second) |second| pressChord(second);
}

/// Text typed; never contains `\n` or `\t` (the sequencer sends those as `key`).
pub fn text(bytes: []const u8) void {
    _ = dvui.currentWindow().addEventText(.{ .text = bytes }) catch {};
}

/// Whether a wait on a widget holds: drawn and visible, or gone. Null for `.idle`, which is the
/// app's to answer, not dvui's.
pub fn tagHolds(until: Tape.Until) ?bool {
    return switch (until) {
        .idle => null,
        .shown => |tag| if (dvui.tagGet(tag)) |td| td.visible else false,
        .gone => |tag| if (dvui.tagGet(tag)) |td| !td.visible else true,
    };
}

/// What a tape is checked against (`Tape.Check`): its key chords in the keymap's spelling.
pub const check: Tape.Check = .{ .key = struct {
    fn ok(spelled: []const u8) bool {
        _ = chord.parseKeys(spelled, .other) catch return false;
        return true;
    }
}.ok };

/// Which key `mod` is: dvui's own answer (its `ctrl/cmd` keybind), right on the web too, where the
/// browser says which platform it runs on.
fn platform() chord.Platform {
    const kb = dvui.currentWindow().keybinds.get("ctrl/cmd") orelse return .other;
    return if (kb.command orelse false) .mac else .other;
}

fn dvuiButton(b: Tape.Button) dvui.enums.Button {
    return switch (b) {
        .left => .left,
        .right => .right,
        .middle => .middle,
    };
}

fn dvuiMod(m: chord.Mods) dvui.enums.Mod {
    var bits: u16 = 0;
    if (m.ctrl) bits |= @intFromEnum(dvui.enums.Mod.lcontrol);
    if (m.shift) bits |= @intFromEnum(dvui.enums.Mod.lshift);
    if (m.alt) bits |= @intFromEnum(dvui.enums.Mod.lalt);
    if (m.command) bits |= @intFromEnum(dvui.enums.Mod.lcommand);
    return @enumFromInt(bits);
}

fn pressChord(c: chord.Chord) void {
    const cw = dvui.currentWindow();
    // `chord.Key`'s tags are spelled as `dvui.enums.Key`'s.
    const code = switch (c.key) {
        inline else => |tag| @field(dvui.enums.Key, @tagName(tag)),
    };
    const mod = dvuiMod(c.mods);
    _ = cw.addEventKey(.{ .code = code, .mod = mod, .action = .down }) catch {};
    _ = cw.addEventKey(.{ .code = code, .mod = mod, .action = .up }) catch {};
    // dvui keeps the last key event's modifiers as the window's, and every pointer event after
    // carries them: let go of the modifier, as a hand does, or the next click is a Ctrl-click.
    if (mod != .none) {
        const modifier: dvui.enums.Key = if (c.mods.command) .left_command else if (c.mods.ctrl) .left_control else if (c.mods.alt) .left_alt else .left_shift;
        _ = cw.addEventKey(.{ .code = modifier, .mod = .none, .action = .up }) catch {};
    }
}
