//! One thing that happened, as `Platform.poll` hands it out: the same shape on every platform,
//! with the platform's own quirks already normalised away (what that means per kind is below).
//!
//! The event is an envelope (when, to which window) around a `Payload`. Delivery is by window:
//! the window the OS says it concerns, not the one the app thinks has focus, so a release that
//! lands in another window than its press still names the window it landed in
//! (`docs/window-notes/input.md`). `window` is null only for events that concern the process
//! (`quit`).
//!
//! Everything a payload borrows (`text`, drop paths, composition) is valid until the next
//! `Platform.poll` on the same platform and must be copied to outlive that.
const std = @import("std");
const geometry = @import("geometry.zig");
const Window = @import("Window.zig");
const Clipboard = @import("Clipboard.zig");
const Drop = @import("Drop.zig");
const Ime = @import("Ime.zig");

const Event = @This();

/// Nanoseconds on the platform's monotonic clock (`Platform.now`): the time the OS stamped the
/// event, not the time it was polled. Never wall-clock, never goes backward, and the origin is
/// the platform's own. Only differences mean anything, which is also why a recorded session
/// replays: the replayer supplies its own clock.
time_ns: u64,
window: ?Window,
payload: Payload,

pub const Payload = union(enum) {
    /// A key went down, repeated or came up.
    key: Key,
    /// Committed text to insert: a keystroke's character(s), or an input method's result. UTF-8,
    /// never empty. Arrives after the `key` event that caused it, if any.
    text: []const u8,
    /// Provisional text still being composed (`Ime`).
    ime: Ime,
    pointer: Pointer,
    /// A finger on a touch screen. A trackpad's fingers and a pen's are not touches: they arrive
    /// as `pointer` (`touch_slots.zig` records why).
    touch: Touch,
    wheel: Wheel,
    /// The window gained (true) or lost (false) keyboard focus. On loss the app releases every
    /// key, button and finger it holds: the OS will not send their releases.
    focus: bool,
    /// The drawable size changed, in physical pixels. Sent once per size the platform actually
    /// shows, so the size drawn at and the size shown can be compared.
    resized: Resized,
    moved: geometry.DesktopPoint,
    /// Shown, hidden or changed `Window.State` (`StateChange`).
    state: StateChange,
    /// Someone else replaced the clipboard.
    clipboard: Clipboard,
    /// A drag from another program is over the window.
    drop: Drop,
    /// The user asked the window to close (its close button, a shortcut). It is *not* closed: the
    /// app decides, then calls `Platform.closeWindow`.
    close_requested,
    /// The app is leaving the foreground (mobile): release touches, stop animating.
    background,
    /// Back in the foreground.
    foreground,
    /// The window is entirely hidden (true: behind others, on another Space, minimized) or
    /// visible again (false). While hidden nothing it draws is seen, so pacing may stop.
    occluded: bool,
    /// The process was asked to quit (dock menu, OS shutdown). `window` is null.
    quit,
};

/// A key by where it is (`physical`, the name of the key a US keyboard has there) and by what
/// the layout makes of it (`logical`). Shortcuts want `physical` when they mean a place (WASD)
/// and `logical` when they mean a letter (Cmd+S), so both come (`docs/window-notes/input.md`).
pub const Key = struct {
    physical: Code,
    logical: Logical,
    action: enum { down, repeat, up },
    mods: Mods,

    /// What the layout gives the key with no modifier held: the Unicode scalar it types, or, for
    /// a key that types nothing (arrows, F-keys, modifiers), its name. A Cyrillic or Greek
    /// layout's letters are `char`s that no US-named `Code` has, which is why the character is
    /// carried and not looked up.
    pub const Logical = union(enum) {
        char: u21,
        named: Code,
        /// The platform could not tell.
        none,
    };
};

/// The modifiers held when the event happened, from the OS's own state and not tracked from key
/// events: a modifier released in another app must not stay stuck (the backend re-reads it on
/// every press today).
pub const Mods = packed struct(u8) {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    /// Command on macOS, Windows/Super elsewhere.
    gui: bool = false,
    /// Right Alt as a character shifter on layouts that have one (German AltGr).
    altgr: bool = false,
    caps_lock: bool = false,
    num_lock: bool = false,
    _reserved: u1 = 0,
};

pub const Button = enum { left, middle, right, back, forward };

pub const Pointer = struct {
    kind: Kind,
    /// Window pixels from the top left, physical. For `leave`, the last place it was.
    at: geometry.Point,
    /// Only for `press` and `release`.
    button: Button = .left,
    mods: Mods = .{},

    /// `leave`: the pointer left this window, for another window or for none; the next `move`,
    /// in whichever window, says which.
    pub const Kind = enum { move, press, release, leave };
};

pub const Touch = struct {
    kind: enum { down, move, up, cancel },
    /// Which screen, and which finger on it; a finger keeps its pair from `down` to `up`.
    device: u64,
    finger: u64,
    /// Across the window, as a fraction (`geometry.Norm`). A deliberate exception to "window
    /// positions are physical pixels": the screen reports where on itself, and the window size
    /// the platform would convert by can change before the event is read. Multiply by the window's current size (`Platform.windowSize`) at
    /// the time the event is handled; a `resized` ahead of it in the queue is then already
    /// applied.
    at: geometry.Norm,
    /// Since the last event of this finger, same unit as `at`. Zero for `down`.
    delta: geometry.Norm = .{},
};

pub const Wheel = struct {
    /// Wheel travel in notches (a fraction of one when `precise`): positive x is right, positive
    /// y is away from the user, the OS's own convention (natural scrolling already applied),
    /// before the app's scroll speed.
    dx: f32,
    dy: f32,
    /// Where the pointer is, window pixels: the scroll goes to what is under it.
    at: geometry.Point,
    /// A trackpad or touch scroll (continuous, no notches) rather than a notched wheel, where
    /// the platform can tell.
    precise: bool,
    /// Where a continuous scroll is in its gesture, so a fling can be told from a new scroll;
    /// `none` for a notched wheel.
    phase: enum { none, began, changed, momentum, ended } = .none,
    mods: Mods = .{},
    // Not here until a consumer needs them: a per-refresh flag (macOS delivers continuous scroll
    // at the display rate; normalising it is the event queue's, with `Display.refresh_hz`).
};

pub const Resized = struct {
    size: geometry.Size,
    /// Physical pixels per desktop point now, which changes when the window moves between
    /// displays or the user changes scaling.
    scale: f32,
    /// The size is still changing under the user's hand (a live drag). False on the last one.
    /// Not guaranteed to be sent: a tiled window can stop mid-drag, so a drag state is also
    /// ended by any `state` or the pointer coming back.
    live: bool = false,
};

/// What just happened to the window, as a transition; what it *is* afterwards is
/// `Platform.windowState`. Visibility (`shown`/`hidden`) is separate from `Window.State`.
/// `restored` is the return to `Window.State.normal` from maximized; `unminimized` and
/// `left_fullscreen` go back to wherever the window was, which `windowState` then names (a
/// window that went full screen from maximized comes back maximized, not normal).
pub const StateChange = enum {
    shown,
    hidden,
    minimized,
    unminimized,
    maximized,
    restored,
    entered_fullscreen,
    left_fullscreen,
};

/// The keys, named by their meaning on a US layout. Not SDL's or dvui's numbering: the platform
/// maps its own scancodes and keycodes to these.
// zig fmt: off
pub const Code = enum(u16) {
    unknown,
    a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p, q, r, s, t, u, v, w, x, y, z,
    @"0", @"1", @"2", @"3", @"4", @"5", @"6", @"7", @"8", @"9",
    f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12,
    f13, f14, f15, f16, f17, f18, f19, f20, f21, f22, f23, f24,
    left, right, up, down, page_up, page_down, home, end, insert, delete,
    enter, escape, tab, space, backspace,
    minus, equal, left_bracket, right_bracket, backslash,
    semicolon, apostrophe, grave, comma, period, slash,
    caps_lock, num_lock, scroll_lock, print_screen, pause, menu,
    kp_0, kp_1, kp_2, kp_3, kp_4, kp_5, kp_6, kp_7, kp_8, kp_9,
    kp_decimal, kp_divide, kp_multiply, kp_minus, kp_plus, kp_enter, kp_equal, kp_clear,
    left_shift, right_shift, left_ctrl, right_ctrl, left_alt, right_alt, left_gui, right_gui,
    // The extra key of ISO and JIS boards, and the Japanese and Korean input-mode keys.
    intl_backslash, intl_ro, intl_yen, lang_kana, lang_eisu, lang_hangul, lang_hanja,
    media_play_pause, media_stop, media_next, media_prev, volume_up, volume_down, volume_mute,
};
// zig fmt: on

test "an event is small enough to queue by value" {
    try std.testing.expect(@sizeOf(Event) <= 128);
}

test "modifiers fit one byte" {
    try std.testing.expectEqual(@as(usize, 1), @sizeOf(Mods));
}
