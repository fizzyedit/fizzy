//! The queue between a platform's callbacks and `Platform.poll`: a bounded ring that normalises
//! what the OS sends into the stream `Event` promises, whichever platform it came from.
//!
//! A platform `push`es what it hears, in the order it hears it, and `pop`s from `poll`. What comes
//! out obeys these, each pinned by a test (the fuzz test holds them over random streams):
//!
//! - **Time never goes backward.** An event stamped before its predecessor takes the
//!   predecessor's time.
//! - **Nothing sticks.** A key, button or finger that goes down comes up exactly once. A release
//!   of something not held is dropped, a second press is a repeat or nothing, and `focus(false)`
//!   (for that window) or `background` (for all) releases what is still held, ahead of the event
//!   that says why: the OS will not send those releases (`Event.Payload.focus`).
//! - **Fast streams are thinned, not reordered.** Pointer moves, wheel travel, window moves and
//!   sizes, a finger's moves and the clipboard merge into the event just before them when it is
//!   the same kind for the same window: the latest position, the summed travel. Nothing merges
//!   across another event, so a press still lands where the pointer was when it happened.
//! - **Text follows its key.** A `text` that a platform delivers ahead of the key down at the same
//!   instant is put behind it. Text is delivered in pieces of at most `text_max` bytes, cut
//!   between code points.
//! - **Modifiers are the OS's,** carried by each event and remembered (`mods`); a modifier key's
//!   own down and up are corrected to show its own bit, which some platforms report one event late.
//! - **A finger has a slot** (`Event.Touch.slot`, `TouchSlots`): held from down to up, reused
//!   after, and an eleventh finger is not seen.
//!
//! **Bounds.** `capacity` events. An event that can only add work (a press, a move, text) is
//! refused while `reserve` slots are free, so the releases of everything held always fit; when
//! even those run out, the oldest event that can be lost (a move, text, a size) is dropped to fit
//! a release. `dropped` counts every loss and `stray` every release of nothing held.
//!
//! The queue keeps `text` itself. Other borrowed payloads (`ime`, `drop`) are queued by value,
//! so the platform keeps their memory alive until the `pop` that hands them out.
const std = @import("std");
const geometry = @import("geometry.zig");
const Window = @import("Window.zig");
const Event = @import("Event.zig");
const TouchSlots = @import("TouchSlots.zig");

const EventQueue = @This();

pub const capacity = 256;
/// The most keys and buttons held at once; a press past it is refused.
pub const max_held = 48;
/// Slots only a release or a focus change may take: every held key, button and finger, and a few
/// events that say why they were let go.
pub const reserve = max_held + TouchSlots.count + 8;
/// The longest `text` event; a longer string arrives as several.
pub const text_max = 32;

const Slot = struct {
    event: Event,
    text_len: u8 = 0,
    text: [text_max]u8 = undefined,
};

const Held = struct {
    window: u64,
    what: union(enum) { key: Event.Key, button: Event.Button },
};

const FingerAt = struct { window: u64 = 0, at: geometry.Norm = .{} };

slots: [capacity]Slot = undefined,
head: usize = 0,
count: usize = 0,
/// What `pop` last returned lives here, so its text outlives the slot it came from.
current: Slot = undefined,

held: [max_held]Held = undefined,
held_count: usize = 0,
touches: TouchSlots = .{},
finger_at: [TouchSlots.count]FingerAt = @splat(.{}),

/// The modifiers the last event that carried them reported.
mods: Event.Mods = .{},
last_time_ns: u64 = 0,
last_at: geometry.Point = .{},
dropped: u64 = 0,
stray: u64 = 0,

pub fn len(self: *const EventQueue) usize {
    return self.count;
}

/// Keys and buttons held, and fingers down: what a focus loss would release.
pub fn heldCount(self: *const EventQueue) usize {
    var n = self.held_count;
    for (self.touches.fingers) |f| n += @intFromBool(f != null);
    return n;
}

/// The next event, or null. A `text` it carries is valid until the next `pop`.
pub fn pop(self: *EventQueue) ?Event {
    if (self.count == 0) return null;
    self.current = self.slots[self.head];
    self.head = (self.head + 1) % capacity;
    self.count -= 1;
    if (self.current.event.payload == .text) {
        self.current.event.payload = .{ .text = self.current.text[0..self.current.text_len] };
    }
    return self.current.event;
}

pub fn push(self: *EventQueue, event: Event) void {
    var ev = event;
    if (ev.time_ns < self.last_time_ns) ev.time_ns = self.last_time_ns else self.last_time_ns = ev.time_ns;
    switch (ev.payload) {
        .key => |k| self.pushKey(ev, k),
        .text => |t| self.pushText(ev, t),
        .pointer => |p| self.pushPointer(ev, p),
        .touch => |t| self.pushTouch(ev, t),
        .wheel => |w| {
            self.mods = w.mods;
            self.last_at = w.at;
            if (self.tailIs(ev)) |tail| {
                const prev = &tail.event.payload.wheel;
                if (prev.precise == w.precise and prev.phase == w.phase and @as(u8, @bitCast(prev.mods)) == @as(u8, @bitCast(w.mods))) {
                    prev.dx += w.dx;
                    prev.dy += w.dy;
                    prev.at = w.at;
                    tail.event.time_ns = ev.time_ns;
                    return;
                }
            }
            _ = self.add(ev, false);
        },
        .focus => |gained| {
            if (!gained) self.releaseWhere(ev.time_ns, windowId(ev));
            self.addOrReplace(ev, true);
        },
        .background => {
            self.releaseWhere(ev.time_ns, null);
            _ = self.add(ev, true);
        },
        .resized, .moved, .clipboard, .occluded => self.addOrReplace(ev, false),
        .close_requested => {
            if (self.tailIs(ev) != null) return;
            _ = self.add(ev, true);
        },
        .quit, .foreground, .state => _ = self.add(ev, true),
        .ime, .drop => _ = self.add(ev, false),
    }
}

fn windowId(ev: Event) u64 {
    return if (ev.window) |w| w.id else 0;
}

fn windowOf(id: u64) ?Window {
    return if (id == 0) null else .{ .id = id };
}

fn at(self: *EventQueue, i: usize) *Slot {
    return &self.slots[(self.head + i) % capacity];
}

/// The newest queued event, if it has the payload kind and window of `ev`.
fn tailIs(self: *EventQueue, ev: Event) ?*Slot {
    if (self.count == 0) return null;
    const tail = self.at(self.count - 1);
    if (std.meta.activeTag(tail.event.payload) != std.meta.activeTag(ev.payload)) return null;
    if (windowId(tail.event) != windowId(ev)) return null;
    return tail;
}

/// Room for one event: any of the free slots for a `critical` one (a release, a focus change),
/// all but `reserve` for the rest.
fn makeSpace(self: *EventQueue, critical: bool) bool {
    if (!critical) return self.count < capacity - reserve;
    if (self.count < capacity) return true;
    return self.evictOne();
}

/// Drops the oldest event that is only ever a picture of "now", for one that cannot be lost.
fn evictOne(self: *EventQueue) bool {
    for (0..self.count) |i| {
        const lossy = switch (self.at(i).event.payload) {
            .pointer => |p| p.kind == .move,
            .touch => |t| t.kind == .move,
            .wheel, .resized, .moved, .text, .ime, .clipboard => true,
            else => false,
        };
        if (!lossy) continue;
        for (i + 1..self.count) |j| self.at(j - 1).* = self.at(j).*;
        self.count -= 1;
        self.dropped += 1;
        return true;
    }
    return false;
}

fn add(self: *EventQueue, ev: Event, critical: bool) ?*Slot {
    if (!self.makeSpace(critical)) {
        self.dropped += 1;
        return null;
    }
    const slot = self.at(self.count);
    slot.* = .{ .event = ev };
    self.count += 1;
    return slot;
}

/// The same kind from the same window right behind it is replaced: only the latest is true.
fn addOrReplace(self: *EventQueue, ev: Event, critical: bool) void {
    if (self.tailIs(ev)) |tail| {
        tail.event = ev;
        return;
    }
    _ = self.add(ev, critical);
}

fn findKey(self: *const EventQueue, window: u64, code: Event.Code) ?usize {
    for (self.held[0..self.held_count], 0..) |h, i| switch (h.what) {
        .key => |k| if (h.window == window and k.physical == code) return i,
        .button => {},
    };
    return null;
}

fn findButton(self: *const EventQueue, window: u64, button: Event.Button) ?usize {
    for (self.held[0..self.held_count], 0..) |h, i| switch (h.what) {
        .button => |b| if (h.window == window and b == button) return i,
        .key => {},
    };
    return null;
}

/// In order, so a focus loss releases in the order things were pressed.
fn unhold(self: *EventQueue, i: usize) void {
    self.held_count -= 1;
    for (i..self.held_count) |j| self.held[j] = self.held[j + 1];
}

fn hold(self: *EventQueue, h: Held) bool {
    if (self.held_count == max_held) {
        self.dropped += 1;
        return false;
    }
    self.held[self.held_count] = h;
    self.held_count += 1;
    return true;
}

/// A modifier key's own bit, set while it or its pair is held and clear otherwise.
fn withModifierKey(self: *const EventQueue, mods: Event.Mods, window: u64, code: Event.Code, held: bool) Event.Mods {
    var m = mods;
    const pair: ?Event.Code = switch (code) {
        .left_shift => .right_shift,
        .right_shift => .left_shift,
        .left_ctrl => .right_ctrl,
        .right_ctrl => .left_ctrl,
        .left_gui => .right_gui,
        .right_gui => .left_gui,
        else => null,
    };
    const on = held or (pair != null and self.findKey(window, pair.?) != null);
    switch (code) {
        .left_shift, .right_shift => m.shift = on,
        .left_ctrl, .right_ctrl => m.ctrl = on,
        .left_gui, .right_gui => m.gui = on,
        // Right Alt may be AltGr, which the OS reports as its own bit.
        .left_alt => m.alt = on,
        else => {},
    }
    return m;
}

fn pushKey(self: *EventQueue, ev0: Event, key0: Event.Key) void {
    var ev = ev0;
    var key = key0;
    const window = windowId(ev);
    const idx = self.findKey(window, key.physical);
    switch (key.action) {
        .down, .repeat => {
            if (idx != null) {
                key.action = .repeat;
            } else {
                if (!self.makeSpace(false) or self.held_count == max_held) {
                    self.dropped += 1;
                    return;
                }
                key.action = .down;
                _ = self.hold(.{ .window = window, .what = .{ .key = key } });
            }
            key.mods = self.withModifierKey(key.mods, window, key.physical, true);
            ev.payload = .{ .key = key };
            self.mods = key.mods;
            self.addBeforeText(ev);
        },
        .up => {
            const i = idx orelse {
                self.stray += 1;
                return;
            };
            self.unhold(i);
            key.mods = self.withModifierKey(key.mods, window, key.physical, false);
            ev.payload = .{ .key = key };
            self.mods = key.mods;
            _ = self.add(ev, true);
        },
    }
}

/// Adds a key behind which text for it may already be queued: same window, same instant.
fn addBeforeText(self: *EventQueue, ev: Event) void {
    var moved: [4]Slot = undefined;
    var n: usize = 0;
    while (n < moved.len and n < self.count) {
        const s = self.at(self.count - 1 - n);
        if (s.event.payload != .text or windowId(s.event) != windowId(ev) or s.event.time_ns != ev.time_ns) break;
        n += 1;
    }
    for (0..n) |i| moved[n - 1 - i] = self.at(self.count - 1 - i).*;
    self.count -= n;
    _ = self.add(ev, false);
    for (moved[0..n]) |s| {
        self.at(self.count).* = s;
        self.count += 1;
    }
}

fn pushText(self: *EventQueue, ev: Event, text: []const u8) void {
    var rest = text;
    while (rest.len > 0) {
        var n = @min(rest.len, text_max);
        // Back off a continuation byte so a code point is never cut; a string that is not UTF-8
        // is cut where it must be.
        if (n < rest.len) {
            var k = n;
            while (k > 0 and rest[k] & 0xC0 == 0x80) k -= 1;
            if (k > 0) n = k;
        }
        const slot = self.add(ev, false) orelse return;
        @memcpy(slot.text[0..n], rest[0..n]);
        slot.text_len = @intCast(n);
        slot.event.payload = .{ .text = &.{} };
        rest = rest[n..];
    }
}

fn pushPointer(self: *EventQueue, ev: Event, p: Event.Pointer) void {
    const window = windowId(ev);
    self.mods = p.mods;
    switch (p.kind) {
        .move => {
            self.last_at = p.at;
            if (self.tailIs(ev)) |tail| if (tail.event.payload.pointer.kind == .move) {
                tail.event = ev;
                return;
            };
            _ = self.add(ev, false);
        },
        .press => {
            self.last_at = p.at;
            if (self.findButton(window, p.button) != null) return;
            if (!self.makeSpace(false) or self.held_count == max_held) {
                self.dropped += 1;
                return;
            }
            _ = self.hold(.{ .window = window, .what = .{ .button = p.button } });
            _ = self.add(ev, false);
        },
        .release => {
            self.last_at = p.at;
            const i = self.findButton(window, p.button) orelse {
                self.stray += 1;
                return;
            };
            self.unhold(i);
            _ = self.add(ev, true);
        },
        .leave => _ = self.add(ev, false),
    }
}

fn pushTouch(self: *EventQueue, ev0: Event, t0: Event.Touch) void {
    var ev = ev0;
    var t = t0;
    const window = windowId(ev);
    switch (t.kind) {
        .down, .move => {
            var slot = self.touches.find(t.device, t.finger);
            if (slot == null) {
                // A move of a finger never seen down is nothing; a down is its press.
                if (t.kind == .move) {
                    self.stray += 1;
                    return;
                }
                if (!self.makeSpace(false)) {
                    self.dropped += 1;
                    return;
                }
                slot = self.touches.down(t.device, t.finger) orelse {
                    self.dropped += 1;
                    return;
                };
            } else {
                t.kind = .move;
            }
            const s = slot.?;
            self.finger_at[s] = .{ .window = window, .at = t.at };
            t.slot = s;
            ev.payload = .{ .touch = t };
            if (t.kind == .move) {
                if (self.tailIs(ev)) |tail| {
                    const prev = &tail.event.payload.touch;
                    if (prev.kind == .move and prev.device == t.device and prev.finger == t.finger) {
                        t.delta = .{ .x = prev.delta.x + t.delta.x, .y = prev.delta.y + t.delta.y };
                        tail.event = ev;
                        tail.event.payload.touch.delta = t.delta;
                        return;
                    }
                }
            }
            _ = self.add(ev, false);
        },
        .up, .cancel => {
            const s = self.touches.up(t.device, t.finger) orelse {
                self.stray += 1;
                return;
            };
            t.slot = s;
            ev.payload = .{ .touch = t };
            _ = self.add(ev, true);
        },
    }
}

/// Releases what `window` holds (everything, for null), then forgets the modifiers: the OS will
/// not send these, and a modifier released in another app must not stay down.
fn releaseWhere(self: *EventQueue, time_ns: u64, window: ?u64) void {
    self.mods = .{ .caps_lock = self.mods.caps_lock, .num_lock = self.mods.num_lock };
    var i: usize = 0;
    while (i < self.held_count) {
        const h = self.held[i];
        if (window != null and h.window != window.?) {
            i += 1;
            continue;
        }
        self.unhold(i);
        const payload: Event.Payload = switch (h.what) {
            .key => |k| .{ .key = .{ .physical = k.physical, .logical = k.logical, .action = .up, .mods = self.mods } },
            .button => |b| .{ .pointer = .{ .kind = .release, .at = self.last_at, .button = b, .mods = self.mods } },
        };
        _ = self.add(.{ .time_ns = time_ns, .window = windowOf(h.window), .payload = payload }, true);
    }
    for (&self.touches.fingers, 0..) |*f, slot| {
        const finger = f.* orelse continue;
        const info = self.finger_at[slot];
        if (window != null and info.window != window.?) continue;
        f.* = null;
        _ = self.add(.{ .time_ns = time_ns, .window = windowOf(info.window), .payload = .{ .touch = .{
            .kind = .cancel,
            .device = finger.device,
            .finger = finger.finger,
            .slot = @intCast(slot),
            .at = info.at,
        } } }, true);
    }
}

// ---- tests ------------------------------------------------------------------------------------

const w1: Window = .{ .id = 1 };
const w2: Window = .{ .id = 2 };

fn evAt(t: u64, window: ?Window, payload: Event.Payload) Event {
    return .{ .time_ns = t, .window = window, .payload = payload };
}

fn keyPayload(code: Event.Code, action: @FieldType(Event.Key, "action")) Event.Payload {
    return .{ .key = .{ .physical = code, .logical = .{ .named = code }, .action = action, .mods = .{} } };
}

fn move(x: f32, y: f32) Event.Payload {
    return .{ .pointer = .{ .kind = .move, .at = .{ .x = x, .y = y } } };
}

fn buttonPayload(kind: Event.Pointer.Kind, b: Event.Button) Event.Payload {
    return .{ .pointer = .{ .kind = kind, .at = .{}, .button = b } };
}

fn fingerPayload(kind: @FieldType(Event.Touch, "kind"), id: u64, x: f32) Event.Payload {
    return .{ .touch = .{ .kind = kind, .device = 1, .finger = id, .at = .{ .x = x } } };
}

fn expectDrained(q: *EventQueue, expected: []const Event) !void {
    for (expected) |want| {
        const got = q.pop() orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualDeep(want, got);
    }
    try std.testing.expectEqual(null, q.pop());
}

const Case = struct {
    name: []const u8,
    in: []const Event,
    out: []const Event,
};

test "table: what is merged, kept, reordered and refused" {
    const cases = [_]Case{
        .{
            .name = "pointer moves merge into the latest",
            .in = &.{ evAt(1, w1, move(1, 1)), evAt(2, w1, move(2, 2)), evAt(3, w1, move(3, 3)) },
            .out = &.{evAt(3, w1, move(3, 3))},
        },
        .{
            .name = "a press between moves keeps both sides",
            .in = &.{ evAt(1, w1, move(1, 1)), evAt(2, w1, buttonPayload(.press, .left)), evAt(3, w1, move(2, 2)) },
            .out = &.{ evAt(1, w1, move(1, 1)), evAt(2, w1, buttonPayload(.press, .left)), evAt(3, w1, move(2, 2)) },
        },
        .{
            .name = "moves in two windows do not merge",
            .in = &.{ evAt(1, w1, move(1, 1)), evAt(2, w2, move(2, 2)) },
            .out = &.{ evAt(1, w1, move(1, 1)), evAt(2, w2, move(2, 2)) },
        },
        .{
            .name = "wheel travel sums, a new gesture phase does not",
            .in = &.{
                evAt(1, w1, .{ .wheel = .{ .dx = 0, .dy = 1, .at = .{}, .precise = true, .phase = .began } }),
                evAt(2, w1, .{ .wheel = .{ .dx = 0, .dy = 2, .at = .{ .x = 5 }, .precise = true, .phase = .began } }),
                evAt(3, w1, .{ .wheel = .{ .dx = 0, .dy = 4, .at = .{}, .precise = true, .phase = .changed } }),
            },
            .out = &.{
                evAt(2, w1, .{ .wheel = .{ .dx = 0, .dy = 3, .at = .{ .x = 5 }, .precise = true, .phase = .began } }),
                evAt(3, w1, .{ .wheel = .{ .dx = 0, .dy = 4, .at = .{}, .precise = true, .phase = .changed } }),
            },
        },
        .{
            .name = "a notched wheel and a trackpad do not merge",
            .in = &.{
                evAt(1, w1, .{ .wheel = .{ .dx = 0, .dy = 1, .at = .{}, .precise = false } }),
                evAt(2, w1, .{ .wheel = .{ .dx = 0, .dy = 1, .at = .{}, .precise = true } }),
            },
            .out = &.{
                evAt(1, w1, .{ .wheel = .{ .dx = 0, .dy = 1, .at = .{}, .precise = false } }),
                evAt(2, w1, .{ .wheel = .{ .dx = 0, .dy = 1, .at = .{}, .precise = true } }),
            },
        },
        .{
            .name = "a resize keeps the latest size, and the end of a drag",
            .in = &.{
                evAt(1, w1, .{ .resized = .{ .size = .{ .w = 10, .h = 10 }, .scale = 1, .live = true } }),
                evAt(2, w1, .{ .resized = .{ .size = .{ .w = 20, .h = 10 }, .scale = 1, .live = true } }),
                evAt(3, w1, .{ .resized = .{ .size = .{ .w = 30, .h = 10 }, .scale = 1, .live = false } }),
            },
            .out = &.{evAt(3, w1, .{ .resized = .{ .size = .{ .w = 30, .h = 10 }, .scale = 1, .live = false } })},
        },
        .{
            .name = "window moves merge, close requests do not repeat",
            .in = &.{
                evAt(1, w1, .{ .moved = .{ .x = 1 } }),
                evAt(2, w1, .{ .moved = .{ .x = 9 } }),
                evAt(3, w1, .close_requested),
                evAt(4, w1, .close_requested),
            },
            .out = &.{ evAt(2, w1, .{ .moved = .{ .x = 9 } }), evAt(3, w1, .close_requested) },
        },
        .{
            .name = "a key goes down, repeats and comes up; strays are dropped",
            .in = &.{
                evAt(1, w1, keyPayload(.a, .up)),
                evAt(2, w1, keyPayload(.a, .down)),
                evAt(3, w1, keyPayload(.a, .down)),
                evAt(4, w1, keyPayload(.a, .repeat)),
                evAt(5, w1, keyPayload(.a, .up)),
                evAt(6, w1, keyPayload(.a, .up)),
                evAt(7, w1, keyPayload(.b, .repeat)),
                evAt(8, w1, keyPayload(.b, .up)),
            },
            .out = &.{
                evAt(2, w1, keyPayload(.a, .down)),
                evAt(3, w1, keyPayload(.a, .repeat)),
                evAt(4, w1, keyPayload(.a, .repeat)),
                evAt(5, w1, keyPayload(.a, .up)),
                evAt(7, w1, keyPayload(.b, .down)),
                evAt(8, w1, keyPayload(.b, .up)),
            },
        },
        .{
            .name = "the same key in two windows is two keys",
            .in = &.{ evAt(1, w1, keyPayload(.a, .down)), evAt(2, w2, keyPayload(.a, .down)), evAt(3, w2, keyPayload(.a, .up)) },
            .out = &.{ evAt(1, w1, keyPayload(.a, .down)), evAt(2, w2, keyPayload(.a, .down)), evAt(3, w2, keyPayload(.a, .up)) },
        },
        .{
            .name = "text that beats its key at the same instant goes behind it",
            .in = &.{ evAt(5, w1, .{ .text = "a" }), evAt(5, w1, keyPayload(.a, .down)) },
            .out = &.{ evAt(5, w1, keyPayload(.a, .down)), evAt(5, w1, .{ .text = "a" }) },
        },
        .{
            .name = "text from an earlier instant stays where it was",
            .in = &.{ evAt(4, w1, .{ .text = "a" }), evAt(5, w1, keyPayload(.a, .down)) },
            .out = &.{ evAt(4, w1, .{ .text = "a" }), evAt(5, w1, keyPayload(.a, .down)) },
        },
        .{
            .name = "text for another window stays where it was",
            .in = &.{ evAt(5, w2, .{ .text = "a" }), evAt(5, w1, keyPayload(.a, .down)) },
            .out = &.{ evAt(5, w2, .{ .text = "a" }), evAt(5, w1, keyPayload(.a, .down)) },
        },
        .{
            .name = "empty text is nothing",
            .in = &.{ evAt(1, w1, .{ .text = "" }), evAt(2, w1, .{ .text = "é" }) },
            .out = &.{evAt(2, w1, .{ .text = "é" })},
        },
        .{
            .name = "time never goes backward",
            .in = &.{ evAt(9, w1, move(1, 1)), evAt(3, w1, buttonPayload(.press, .left)), evAt(1, w1, buttonPayload(.release, .left)) },
            .out = &.{ evAt(9, w1, move(1, 1)), evAt(9, w1, buttonPayload(.press, .left)), evAt(9, w1, buttonPayload(.release, .left)) },
        },
        .{
            .name = "a second press is nothing and a stray release too",
            .in = &.{
                evAt(1, w1, buttonPayload(.release, .right)),
                evAt(2, w1, buttonPayload(.press, .left)),
                evAt(3, w1, buttonPayload(.press, .left)),
                evAt(4, w1, buttonPayload(.release, .left)),
            },
            .out = &.{ evAt(2, w1, buttonPayload(.press, .left)), evAt(4, w1, buttonPayload(.release, .left)) },
        },
    };
    for (cases) |c| {
        var q: EventQueue = .{};
        for (c.in) |e| q.push(e);
        expectDrained(&q, c.out) catch |err| {
            std.debug.print("case failed: {s}\n", .{c.name});
            return err;
        };
    }
}

test "text is cut between code points, in order" {
    var q: EventQueue = .{};
    const s = "éééééééééééééééééééé" ++ "x"; // 20 two-byte letters and one more byte
    q.push(evAt(1, w1, .{ .text = s }));
    var got: [64]u8 = undefined;
    var n: usize = 0;
    var pieces: usize = 0;
    while (q.pop()) |e| {
        const t = e.payload.text;
        try std.testing.expect(t.len > 0 and t.len <= text_max);
        try std.testing.expect(std.unicode.utf8ValidateSlice(t));
        @memcpy(got[n..][0..t.len], t);
        n += t.len;
        pieces += 1;
    }
    try std.testing.expectEqualStrings(s, got[0..n]);
    try std.testing.expectEqual(2, pieces);
}

test "text outlives the slot it was popped from" {
    var q: EventQueue = .{};
    q.push(evAt(1, w1, .{ .text = "one" }));
    const first = q.pop().?;
    q.push(evAt(2, w1, .{ .text = "two" }));
    try std.testing.expectEqualStrings("one", first.payload.text);
}

test "a modifier key shows its own bit, and its pair keeps it" {
    var q: EventQueue = .{};
    q.push(evAt(1, w1, keyPayload(.left_shift, .down)));
    q.push(evAt(2, w1, keyPayload(.right_shift, .down)));
    q.push(evAt(3, w1, keyPayload(.left_shift, .up)));
    q.push(evAt(4, w1, keyPayload(.right_shift, .up)));
    const want = [_]bool{ true, true, true, false };
    for (want) |shift| try std.testing.expectEqual(shift, q.pop().?.payload.key.mods.shift);
    try std.testing.expect(!q.mods.shift);
}

test "the OS's modifiers on other events are remembered" {
    var q: EventQueue = .{};
    q.push(evAt(1, w1, .{ .pointer = .{ .kind = .move, .at = .{}, .mods = .{ .ctrl = true, .caps_lock = true } } }));
    try std.testing.expect(q.mods.ctrl and q.mods.caps_lock);
}

test "losing focus releases what the window holds, ahead of the focus event" {
    var q: EventQueue = .{};
    q.push(evAt(1, w1, keyPayload(.a, .down)));
    q.push(evAt(2, w1, keyPayload(.left_ctrl, .down)));
    q.push(evAt(3, w2, keyPayload(.b, .down)));
    q.push(evAt(4, w1, .{ .pointer = .{ .kind = .press, .at = .{ .x = 7, .y = 8 }, .button = .middle } }));
    q.push(evAt(5, w1, fingerPayload(.down, 40, 0.5)));
    q.push(evAt(6, w1, .{ .pointer = .{ .kind = .move, .at = .{ .x = 9 }, .mods = .{ .ctrl = true, .num_lock = true } } }));
    q.push(evAt(7, w1, .{ .focus = false }));
    for (0..6) |_| _ = q.pop();
    const rest = [_]Event{
        evAt(7, w1, keyPayload(.a, .up)),
        evAt(7, w1, keyPayload(.left_ctrl, .up)),
        evAt(7, w1, .{ .pointer = .{ .kind = .release, .at = .{ .x = 9 }, .button = .middle, .mods = .{ .num_lock = true } } }),
        evAt(7, w1, .{ .touch = .{ .kind = .cancel, .device = 1, .finger = 40, .at = .{ .x = 0.5 } } }),
        evAt(7, w1, .{ .focus = false }),
    };
    // The key and modifier ups carry the locks only: every modifier is let go together.
    var want = rest;
    want[0].payload.key.mods = .{ .num_lock = true };
    want[1].payload.key.mods = .{ .num_lock = true };
    try expectDrained(&q, &want);
    // Window 2's key is still held, and releases on its own focus loss.
    try std.testing.expectEqual(1, q.heldCount());
    q.push(evAt(8, w2, .{ .focus = false }));
    try std.testing.expectEqual(0, q.heldCount());
}

test "going to the background releases every window's holds" {
    var q: EventQueue = .{};
    q.push(evAt(1, w1, keyPayload(.a, .down)));
    q.push(evAt(2, w2, buttonPayload(.press, .left)));
    q.push(evAt(3, w2, fingerPayload(.down, 1, 0.1)));
    q.push(evAt(4, null, .background));
    try std.testing.expectEqual(0, q.heldCount());
    for (0..3) |_| _ = q.pop();
    const ups = [_]Event{
        evAt(4, w1, keyPayload(.a, .up)),
        evAt(4, w2, buttonPayload(.release, .left)),
        evAt(4, w2, .{ .touch = .{ .kind = .cancel, .device = 1, .finger = 1, .at = .{ .x = 0.1 } } }),
        evAt(4, null, .background),
    };
    try expectDrained(&q, &ups);
}

test "fingers keep a slot from down to up, and the slot is reused" {
    var q: EventQueue = .{};
    q.push(evAt(1, w1, fingerPayload(.down, 100, 0)));
    q.push(evAt(2, w1, fingerPayload(.down, 200, 0)));
    q.push(evAt(3, w1, fingerPayload(.up, 100, 0)));
    q.push(evAt(4, w1, fingerPayload(.down, 300, 0)));
    q.push(evAt(5, w1, fingerPayload(.move, 200, 0.5)));
    const slots = [_]u4{ 0, 1, 0, 0, 1 };
    for (slots) |s| try std.testing.expectEqual(s, q.pop().?.payload.touch.slot);
}

test "a finger's moves merge and sum their travel; an eleventh finger is not seen" {
    var q: EventQueue = .{};
    q.push(evAt(1, w1, fingerPayload(.down, 1, 0)));
    inline for (.{ 0.1, 0.2 }) |x| q.push(evAt(2, w1, .{ .touch = .{
        .kind = .move,
        .device = 1,
        .finger = 1,
        .at = .{ .x = x },
        .delta = .{ .x = 0.1 },
    } }));
    _ = q.pop();
    const m = q.pop().?.payload.touch;
    try std.testing.expectEqual(@as(f32, 0.2), m.at.x);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), m.delta.x, 1e-6);
    try std.testing.expectEqual(null, q.pop());

    for (10..21) |i| q.push(evAt(3, w1, fingerPayload(.down, i, 0)));
    // One slot is taken by finger 1, so nine of these are seen.
    try std.testing.expectEqual(9, q.len());
    q.push(evAt(4, w1, fingerPayload(.move, 20, 0)));
    q.push(evAt(4, w1, fingerPayload(.up, 20, 0)));
    try std.testing.expectEqual(9, q.len());
}

test "a flood cannot make a release unfit" {
    var q: EventQueue = .{};
    for (0..max_held) |i| q.push(evAt(1, w1, keyPayload(@fromBackingInt(@intCast(1 + i)), .down)));
    for (0..4 * capacity) |i| q.push(evAt(2, w1, .{ .text = if (i % 2 == 0) "a" else "bc" }));
    try std.testing.expect(q.dropped > 0);
    try std.testing.expect(q.len() <= capacity);
    q.push(evAt(3, w1, .{ .focus = false }));
    try std.testing.expectEqual(0, q.heldCount());
    var ups: usize = 0;
    while (q.pop()) |e| switch (e.payload) {
        .key => |k| ups += @intFromBool(k.action == .up),
        else => {},
    };
    try std.testing.expectEqual(max_held, ups);
}

test "a full queue gives up an old move for a release" {
    var q: EventQueue = .{};
    q.push(evAt(1, w1, buttonPayload(.press, .left)));
    for (0..capacity) |i| q.push(evAt(2, w1, if (i % 2 == 0) move(@floatFromInt(i), 0) else .{ .text = "x" }));
    try std.testing.expect(q.len() < capacity or q.dropped > 0);
    q.push(evAt(3, w1, buttonPayload(.release, .left)));
    var released = false;
    while (q.pop()) |e| switch (e.payload) {
        .pointer => |p| released = released or p.kind == .release,
        else => {},
    };
    try std.testing.expect(released);
}

test "fuzz: no stuck input, balanced downs and ups, time that only goes forward" {
    const windows = [_]Window{ w1, w2, .{ .id = 3 } };
    const codes = [_]Event.Code{ .a, .b, .space, .left_shift, .right_shift, .left_ctrl, .left_alt, .right_alt };
    const buttons = [_]Event.Button{ .left, .right, .middle };

    // The model reads only what comes out of the queue.
    const Model = struct {
        keys: [3][codes.len]bool = @splat(@splat(false)),
        buttons: [3][buttons.len]bool = @splat(@splat(false)),
        fingers: [TouchSlots.count]?struct { w: u64, id: u64 } = @splat(null),
        last: u64 = 0,

        fn check(m: *@This(), e: Event) !void {
            try std.testing.expect(e.time_ns >= m.last);
            m.last = e.time_ns;
            const w: usize = if (e.window) |win| win.id - 1 else 0;
            switch (e.payload) {
                .key => |k| {
                    const c = std.mem.indexOfScalar(Event.Code, &codes, k.physical).?;
                    switch (k.action) {
                        .down => {
                            try std.testing.expect(!m.keys[w][c]);
                            m.keys[w][c] = true;
                        },
                        .repeat => try std.testing.expect(m.keys[w][c]),
                        .up => {
                            try std.testing.expect(m.keys[w][c]);
                            m.keys[w][c] = false;
                        },
                    }
                },
                .pointer => |p| {
                    const b = std.mem.indexOfScalar(Event.Button, &buttons, p.button).?;
                    switch (p.kind) {
                        .press => {
                            try std.testing.expect(!m.buttons[w][b]);
                            m.buttons[w][b] = true;
                        },
                        .release => {
                            try std.testing.expect(m.buttons[w][b]);
                            m.buttons[w][b] = false;
                        },
                        else => {},
                    }
                },
                .touch => |t| {
                    try std.testing.expect(t.slot < TouchSlots.count);
                    switch (t.kind) {
                        .down => {
                            try std.testing.expect(m.fingers[t.slot] == null);
                            m.fingers[t.slot] = .{ .w = w, .id = t.finger };
                        },
                        .move => try std.testing.expectEqual(t.finger, m.fingers[t.slot].?.id),
                        .up, .cancel => {
                            try std.testing.expectEqual(t.finger, m.fingers[t.slot].?.id);
                            m.fingers[t.slot] = null;
                        },
                    }
                },
                .text => |t| try std.testing.expect(t.len > 0 and t.len <= text_max),
                else => {},
            }
        }

        fn idle(m: *const @This()) bool {
            for (m.keys) |row| for (row) |h| if (h) return false;
            for (m.buttons) |row| for (row) |h| if (h) return false;
            for (m.fingers) |f| if (f != null) return false;
            return true;
        }
    };

    for (0..300) |seed| {
        var prng = std.Random.DefaultPrng.init(seed);
        const rng = prng.random();
        var q: EventQueue = .{};
        var model: Model = .{};
        // Some runs drain often, some almost never, so the queue is sometimes full.
        const drain_odds: u32 = switch (seed % 3) {
            0 => 2,
            1 => 8,
            else => 400,
        };
        var clock: u64 = 1000;
        for (0..3000) |_| {
            // The clock mostly moves forward and sometimes steps back, as a bad platform's would.
            clock = if (rng.uintLessThan(u8, 20) == 0) clock -| rng.uintLessThan(u64, 50) else clock + rng.uintLessThan(u64, 5);
            const win = windows[rng.uintLessThan(usize, windows.len)];
            const payload: Event.Payload = switch (rng.uintLessThan(u8, 14)) {
                0, 1, 2 => .{ .key = .{
                    .physical = codes[rng.uintLessThan(usize, codes.len)],
                    .logical = .none,
                    .action = rng.enumValue(@FieldType(Event.Key, "action")),
                    .mods = @bitCast(rng.int(u8) & 0x7f),
                } },
                3 => blk: {
                    var buf: [80]u8 = undefined;
                    const n = rng.uintLessThan(usize, buf.len);
                    for (buf[0..n]) |*b| b.* = if (rng.boolean()) 'a' else 0xC3;
                    // `push` copies, so a stack buffer is fine to lend.
                    q.push(.{ .time_ns = clock, .window = win, .payload = .{ .text = buf[0..n] } });
                    break :blk .quit;
                },
                4, 5 => .{ .pointer = .{ .kind = rng.enumValue(Event.Pointer.Kind), .at = .{ .x = rng.float(f32) }, .button = buttons[rng.uintLessThan(usize, buttons.len)] } },
                6 => .{ .wheel = .{ .dx = 1, .dy = 1, .at = .{}, .precise = rng.boolean() } },
                7, 8, 9 => .{ .touch = .{
                    .kind = rng.enumValue(@FieldType(Event.Touch, "kind")),
                    .device = rng.uintLessThan(u64, 2),
                    .finger = rng.uintLessThan(u64, 14),
                    .at = .{ .x = rng.float(f32) },
                } },
                10 => .{ .focus = rng.boolean() },
                11 => .{ .resized = .{ .size = .{ .w = rng.int(u8), .h = 4 }, .scale = 1, .live = rng.boolean() } },
                12 => .background,
                else => .{ .moved = .{ .x = rng.int(i8) } },
            };
            if (payload != .quit) q.push(.{ .time_ns = clock, .window = if (payload == .background) null else win, .payload = payload });
            try std.testing.expect(q.len() <= capacity);
            if (rng.uintLessThan(u32, drain_odds) == 0) while (q.pop()) |e| try model.check(e);
        }
        for (windows) |win| q.push(.{ .time_ns = clock, .window = win, .payload = .{ .focus = false } });
        while (q.pop()) |e| try model.check(e);
        try std.testing.expect(model.idle());
        try std.testing.expectEqual(0, q.heldCount());
    }
}
