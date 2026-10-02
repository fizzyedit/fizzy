//! A demo as data: what happens, and when.
//!
//! A tape is to a demo what a video file is to a film, and borrows its two ideas:
//!
//!   * **Keyframes and deltas.** A `keyframe` op puts the app into a state it declares outright
//!     (these files, these open, the default layout); every other op is a small delta on what is
//!     there — a pointer glide, a click, a typed string, a command. Any moment of the demo is
//!     therefore "the last keyframe, plus the ops since", which is the whole of how a demo is
//!     rewound: `Sequencer.rewind` to the keyframe, then replay the deltas to the moment, fast.
//!   * **Tracks.** `ops` is the input track — the only one that changes the app. `captions` and
//!     `chapters` are presentation: read by time, never replayed, so they cost a seek nothing.
//!
//! Times are **demo time** in milliseconds from the start of the tape. Demo time is not wall time:
//! a `wait` holds it still until the app catches up (a file still loading, a pane still opening),
//! so a slow machine plays the same demo slower rather than a different demo.
//!
//! Ops name what they act on by `dvui.tag` (`Target.tag`) rather than by pixel, so a demo authored
//! in one window size plays in any other — the web embed's included. Keys are chord strings in the
//! keymap's own spelling (`"mod+shift+p"`, `"enter"`), so `mod` is ⌘ on a Mac and Ctrl elsewhere.
//!
//! Everything here is plain data with no pointers into anything but its own strings, so a tape
//! round-trips through ZON (`parse`, `write`): the same thing a script builds (`Script`) is what
//! a recorder would write and what a web page can fetch and play.
//!
//! std-only on purpose (the keymap's chord parser is std-only too), so the format and the
//! sequencing over it are unit-tested in `zig build test` without a window.
const Tape = @This();

const std = @import("std");
const chord = @import("../keymap/chord.zig");

/// Short, stable id: `tour`. Names the keyframes' mount (`demo://tour`) and the web's `?demo=`.
name: []const u8,
/// What a person would call it: "A tour of fizzy".
title: []const u8 = "",
/// The input track, ordered by `at`. Starts with a keyframe at 0.
ops: []const Op,
/// Text shown over the app for a while. Presentation only.
captions: []const Caption = &.{},
/// Named points on the timeline a viewer can jump between. Presentation only.
chapters: []const Chapter = &.{},
/// The states `keyframe` ops cut to, by index.
keyframes: []const Keyframe = &.{},

pub const Op = struct {
    /// When it starts, in ms of demo time.
    at: u32,
    /// How long it takes: a glide's travel, a string's typing. Zero for everything instant.
    ms: u32 = 0,
    do: Action,

    /// The demo time this op is done by.
    pub fn end(self: Op) u32 {
        return self.at + self.ms;
    }
};

pub const Action = union(enum) {
    /// Cut to `keyframes[i]`: the stage puts the app into that state. Seeking starts from here.
    keyframe: u16,
    /// Glide the pointer onto a target over `Op.ms`.
    move: Target,
    /// A pointer button goes down where the pointer is.
    press: Button,
    /// A pointer button comes up where the pointer is.
    release: Button,
    /// Wheel ticks at the pointer: positive scrolls up (`y`) or right (`x`), as dvui counts them.
    scroll: Scroll,
    /// Press and release a key chord in the keymap's spelling: `"enter"`, `"mod+s"`,
    /// `"mod+k mod+c"`. Delivered as key events, to whatever has focus.
    key: []const u8,
    /// Type text over `Op.ms`, as a person would: `\n` presses Enter and `\t` presses Tab, so
    /// an editor's auto-indent and auto-close behave as they do under a person's hands.
    type: []const u8,
    /// Run a command by id — what its shortcut or menu row would run. The keystroke display shows
    /// the chord bound to it, so a viewer learns the shortcut while the demo stays independent of
    /// how anyone has their keys bound.
    command: []const u8,
    /// Hold demo time until a condition holds. Waits are how a tape stays deterministic over an
    /// app that does things on its own time (loading a file, animating a pane open).
    wait: Wait,
};

pub const Button = enum { left, right, middle };

pub const Scroll = struct {
    x: f32 = 0,
    y: f32 = 0,
};

/// Where the pointer goes: a point in a tagged widget's rect, or in the window.
pub const Target = struct {
    /// A `dvui.tag` name. Empty means the window itself.
    tag: []const u8 = "",
    /// Where in the rect, as fractions of it: 0.5, 0.5 is the middle.
    x: f32 = 0.5,
    y: f32 = 0.5,
    /// Then nudged by this many natural pixels — "just inside the left edge" is `x = 0, dx = 8`.
    dx: f32 = 0,
    dy: f32 = 0,
};

pub const Wait = struct {
    until: Until,
    /// Wall-clock ms to hold before giving up and carrying on (logged). A wait that times out
    /// means the tape and the app disagree; carrying on beats a demo frozen forever.
    timeout: u32 = 10_000,
};

pub const Until = union(enum) {
    /// The tagged widget is drawn and visible.
    shown: []const u8,
    /// The tagged widget is no longer drawn.
    gone: []const u8,
    /// The stage has nothing in flight — every file it was asked to open has landed.
    idle,
};

pub const Caption = struct {
    at: u32,
    ms: u32,
    /// A heading over `text`. Optional.
    title: []const u8 = "",
    text: []const u8,
    /// How far down the view it sits: a quarter, half or three quarters of the way.
    place: Place = .bottom,
    /// The view it is about, by anchor — what it sits over, so it is near the action however
    /// large the window. Empty: the window. Where it goes when there is nothing to sit beside
    /// (`near`).
    on: []const u8 = "",
    /// What it sits beside, by anchor: the thing the action it narrates is done to, where the
    /// viewer is looking. Empty: whatever the tape's pointer is aimed at while it shows
    /// (`aimedAt`); with no pointer action in its time either, it sits over `on`.
    near: []const u8 = "",
    /// What it must not cover, by anchor, besides what it sits beside, the pointer and what the
    /// pointer is aimed at in its time: whatever else the viewer is meant to be watching — the
    /// text being typed, a preview redrawing as it is.
    clear: []const []const u8 = &.{},

    pub const Place = enum { top, middle, bottom };

    pub fn shownAt(self: Caption, t: f64) bool {
        return t >= @as(f64, @floatFromInt(self.at)) and t < @as(f64, @floatFromInt(self.at + self.ms));
    }
};

pub const Chapter = struct {
    at: u32,
    title: []const u8,
};

/// A state the app can be put into outright. What it *means* is the stage's (the app's): fizzy
/// mounts `files` under `root` as the project folder, opens `open`, and resets the layout.
pub const Keyframe = struct {
    /// Where the stage mounts `files`, conventionally `demo://<tape name>`. Targets that name a
    /// file name it under this root.
    root: []const u8,
    files: []const File = &.{},
    /// Paths relative to `root`, opened in order; the last one is the active document.
    open: []const []const u8 = &.{},
    layout: Layout = .focused,
    /// Settings the demo depends on — an editor that closes brackets, a preview beside the text —
    /// put in place at the cut whatever the viewer has chosen, and given back when the demo ends.
    settings: []const Setting = &.{},

    /// How the window is arranged at the cut. The stage's to interpret, like the rest.
    pub const Layout = enum {
        /// As it is.
        keep,
        /// The app's default.
        reset,
        /// The app's default with only what the work needs showing, so the eye goes to the
        /// demo rather than the chrome (fizzy: the documents — no bottom panel, the explorer put
        /// away until the demo opens it).
        focused,
    };
};

/// One setting, as `settings.zon` spells it.
pub const Setting = struct {
    /// Whose setting: a plugin id (`text`, `markdown`).
    owner: []const u8,
    /// The field, as `settings.zon` names it (`default_md_view`).
    key: []const u8,
    /// The value as ZON: `.split`, `true`, `4`.
    value: []const u8,
};

pub const File = struct {
    /// Relative to the keyframe's `root`: `src/main.zig`.
    path: []const u8,
    text: []const u8,
};

// ---- reading -------------------------------------------------------------------------------

/// The demo time the last thing on any track ends.
pub fn duration(self: Tape) u32 {
    var d: u32 = 0;
    for (self.ops) |op| d = @max(d, op.end());
    for (self.captions) |c| d = @max(d, c.at + c.ms);
    for (self.chapters) |c| d = @max(d, c.at);
    return d;
}

/// The keyframe op a seek to `t` replays from: the last one at or before it. Index into `ops`.
pub fn keyframeBefore(self: Tape, t: f64) usize {
    var found: usize = 0;
    for (self.ops, 0..) |op, i| {
        if (@as(f64, @floatFromInt(op.at)) > t) break;
        if (op.do == .keyframe) found = i;
    }
    return found;
}

/// The chapter playing at `t`, by index, or null before the first.
pub fn chapterAt(self: Tape, t: f64) ?usize {
    var found: ?usize = null;
    for (self.chapters, 0..) |c, i| {
        if (@as(f64, @floatFromInt(c.at)) > t) break;
        found = i;
    }
    return found;
}

/// The caption shown at `t` — the latest-starting one when two overlap.
pub fn captionAt(self: Tape, t: f64) ?Caption {
    var found: ?Caption = null;
    for (self.captions) |c| {
        if (c.shownAt(t) and (found == null or c.at >= found.?.at)) found = c;
    }
    return found;
}

/// Where the tape's pointer is aimed while `c` shows, with the first `applied` ops applied: the
/// target of the latest move in its time, or before there is one, of the first move to come in
/// its time. Null when the pointer does not move in its time.
pub fn aimedAt(self: Tape, c: Caption, applied: usize) ?Target {
    const start = c.at;
    const stop = c.at + c.ms;
    var latest: ?Target = null;
    for (self.ops, 0..) |op, i| {
        if (op.at < start) continue;
        if (op.at >= stop) break;
        const target = switch (op.do) {
            .move => |m| m,
            else => continue,
        };
        if (i >= applied) return latest orelse target;
        latest = target;
    }
    return latest;
}

/// How much of the tape's pointer shows at `t`, 0…1, with the first `applied` ops applied: it
/// goes the way a desktop's pointer does while someone types — away when the keyboard is used (a
/// `type`, `key` or `command`), back when the pointer next moves, presses or scrolls — fading
/// over `fade_ms` each way. Read from the ops and the time, so a seek shows what live play did.
pub fn pointerShown(self: Tape, applied: usize, t: f64, fade_ms: f64) f32 {
    const Kind = enum { pointer, keyboard };
    const fade = struct {
        fn in(now: f64, at: f64, ms: f64) f32 {
            return if (ms <= 0) 1 else @floatCast(std.math.clamp((now - at) / ms, 0, 1));
        }
    }.in;
    // Back from the latest op applied: the first keyboard op since the latest pointer op, if any.
    var typed_at: ?f64 = null;
    var i = @min(applied, self.ops.len);
    var moved_at: ?f64 = null;
    while (i > 0) {
        i -= 1;
        const op = self.ops[i];
        const kind: Kind = switch (op.do) {
            .type, .key, .command => .keyboard,
            .move, .press, .release, .scroll => .pointer,
            // A keyframe is a fresh start, the pointer showing.
            .keyframe => break,
            .wait => continue,
        };
        const at: f64 = @floatFromInt(op.at);
        if (moved_at) |m| {
            // The op before the latest pointer op: it came back from typing, or it never left.
            return if (kind == .keyboard) fade(t, m, fade_ms) else 1;
        }
        switch (kind) {
            .keyboard => typed_at = at,
            .pointer => {
                if (typed_at) |k| return 1 - fade(t, k, fade_ms);
                moved_at = at;
            },
        }
    }
    if (typed_at) |k| return 1 - fade(t, k, fade_ms);
    return 1;
}

pub const Error = error{
    /// A tape starts with a keyframe at 0, or a seek to the start has nothing to reset to.
    NoKeyframeAtStart,
    OpsOutOfOrder,
    BadKeyframeIndex,
    BadChord,
    /// Overlapping chapters or captions out of order would make `chapterAt` lie.
    ChaptersOutOfOrder,
};

/// Check what `Sequencer` relies on, once, at load — a tape that fails here would misplay rather
/// than crash, which is worse to debug.
pub fn validate(self: Tape) Error!void {
    if (self.ops.len == 0 or self.ops[0].at != 0 or self.ops[0].do != .keyframe) return error.NoKeyframeAtStart;
    var prev: u32 = 0;
    for (self.ops) |op| {
        if (op.at < prev) return error.OpsOutOfOrder;
        prev = op.at;
        switch (op.do) {
            .keyframe => |i| if (i >= self.keyframes.len) return error.BadKeyframeIndex,
            .key => |k| _ = chord.parseKeys(k, .other) catch return error.BadChord,
            else => {},
        }
    }
    prev = 0;
    for (self.chapters) |c| {
        if (c.at < prev) return error.ChaptersOutOfOrder;
        prev = c.at;
    }
}

// ---- ZON -----------------------------------------------------------------------------------

/// A tape and the memory it lives in.
pub const Owned = struct {
    arena: std.heap.ArenaAllocator,
    tape: Tape,

    pub fn deinit(self: *Owned) void {
        self.arena.deinit();
    }
};

/// Read a tape from ZON source — the format `write` produces.
pub fn parse(gpa: std.mem.Allocator, source: [:0]const u8) !Owned {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const tape = try std.zon.parse.fromSliceAlloc(Tape, arena.allocator(), source, null, .{});
    try tape.validate();
    return .{ .arena = arena, .tape = tape };
}

/// Write the tape as ZON, the inverse of `parse`.
pub fn write(self: Tape, w: *std.Io.Writer) !void {
    try std.zon.stringify.serialize(self, .{ .emit_default_optional_fields = false }, w);
}

// ---- tests ---------------------------------------------------------------------------------

const testing = std.testing;

fn sample() Tape {
    const S = struct {
        const keyframes = [_]Keyframe{
            .{ .root = "demo://t", .files = &.{.{ .path = "a.txt", .text = "hello" }}, .open = &.{"a.txt"} },
            .{ .root = "demo://t" },
        };
        const ops = [_]Op{
            .{ .at = 0, .do = .{ .keyframe = 0 } },
            .{ .at = 100, .ms = 400, .do = .{ .move = .{ .tag = "button" } } },
            .{ .at = 500, .do = .{ .press = .left } },
            .{ .at = 560, .do = .{ .release = .left } },
            .{ .at = 1000, .do = .{ .keyframe = 1 } },
            .{ .at = 1200, .ms = 300, .do = .{ .type = "abc" } },
        };
        const chapters = [_]Chapter{ .{ .at = 0, .title = "one" }, .{ .at = 1000, .title = "two" } };
        const captions = [_]Caption{.{ .at = 200, .ms = 2000, .text = "hi", .on = "pane", .near = "button", .clear = &.{"field"} }};
    };
    return .{ .name = "t", .ops = &S.ops, .keyframes = &S.keyframes, .chapters = &S.chapters, .captions = &S.captions };
}

test "a seek replays from the last keyframe at or before it" {
    const tape = sample();
    try tape.validate();
    try testing.expectEqual(@as(usize, 0), tape.keyframeBefore(0));
    try testing.expectEqual(@as(usize, 0), tape.keyframeBefore(999));
    try testing.expectEqual(@as(usize, 4), tape.keyframeBefore(1000));
    try testing.expectEqual(@as(usize, 4), tape.keyframeBefore(5000));
}

test "presentation tracks are read by time" {
    const tape = sample();
    try testing.expectEqual(@as(u32, 2200), tape.duration());
    try testing.expectEqual(@as(?usize, 0), tape.chapterAt(10));
    try testing.expectEqual(@as(?usize, 1), tape.chapterAt(1500));
    try testing.expect(tape.captionAt(100) == null);
    try testing.expectEqualStrings("hi", tape.captionAt(300).?.text);
    try testing.expect(tape.captionAt(2200) == null);
}

test "the pointer goes while the keyboard is used, and comes back when it moves" {
    const ops = [_]Op{
        .{ .at = 0, .do = .{ .keyframe = 0 } },
        .{ .at = 100, .ms = 400, .do = .{ .move = .{ .tag = "field" } } },
        .{ .at = 500, .do = .{ .press = .left } },
        .{ .at = 600, .do = .{ .release = .left } },
        .{ .at = 1000, .ms = 500, .do = .{ .type = "hello" } },
        .{ .at = 1800, .do = .{ .key = "enter" } },
        .{ .at = 3000, .ms = 400, .do = .{ .move = .{ .tag = "button" } } },
    };
    const tape: Tape = .{ .name = "t", .ops = &ops, .keyframes = &.{.{ .root = "demo://t" }} };
    // Before anything is typed it shows.
    try testing.expectEqual(@as(f32, 1), tape.pointerShown(4, 900, 200));
    // Typing: going, then gone — and a key after it does not bring it back.
    try testing.expectEqual(@as(f32, 0.5), tape.pointerShown(5, 1100, 200));
    try testing.expectEqual(@as(f32, 0), tape.pointerShown(5, 1400, 200));
    try testing.expectEqual(@as(f32, 0), tape.pointerShown(6, 1810, 200));
    // Moving again: back.
    try testing.expectEqual(@as(f32, 0.5), tape.pointerShown(7, 3100, 200));
    try testing.expectEqual(@as(f32, 1), tape.pointerShown(7, 3300, 200));
    // Motion off: at once.
    try testing.expectEqual(@as(f32, 0), tape.pointerShown(5, 1000, 0));
}

test "a caption is beside what the pointer is aimed at in its time" {
    const ops = [_]Op{
        .{ .at = 0, .do = .{ .keyframe = 0 } },
        .{ .at = 100, .ms = 400, .do = .{ .move = .{ .tag = "before" } } },
        .{ .at = 1000, .ms = 400, .do = .{ .move = .{ .tag = "rail" } } },
        .{ .at = 1500, .do = .{ .press = .left } },
        .{ .at = 2000, .ms = 400, .do = .{ .move = .{ .tag = "row" } } },
        .{ .at = 5000, .ms = 400, .do = .{ .move = .{ .tag = "after" } } },
    };
    const tape: Tape = .{ .name = "t", .ops = &ops, .keyframes = &.{.{ .root = "demo://t" }} };
    const c: Caption = .{ .at = 800, .ms = 3000, .text = "" };
    // Before its first move: where the pointer is going.
    try testing.expectEqualStrings("rail", tape.aimedAt(c, 2).?.tag);
    // Then wherever it went last, and never past its own time.
    try testing.expectEqualStrings("rail", tape.aimedAt(c, 4).?.tag);
    try testing.expectEqualStrings("row", tape.aimedAt(c, 5).?.tag);
    try testing.expectEqualStrings("row", tape.aimedAt(c, 6).?.tag);
    // No move in its time: nothing to sit beside.
    try testing.expect(tape.aimedAt(.{ .at = 2500, .ms = 1000, .text = "" }, 5) == null);
}

test "a tape must open on a keyframe, in order, with chords that parse" {
    const bad_start = [_]Op{.{ .at = 0, .do = .{ .press = .left } }};
    try testing.expectError(error.NoKeyframeAtStart, (Tape{ .name = "x", .ops = &bad_start }).validate());

    const kf = [_]Keyframe{.{ .root = "demo://x" }};
    const backwards = [_]Op{ .{ .at = 0, .do = .{ .keyframe = 0 } }, .{ .at = 50, .do = .{ .key = "a" } }, .{ .at = 10, .do = .{ .key = "b" } } };
    try testing.expectError(error.OpsOutOfOrder, (Tape{ .name = "x", .ops = &backwards, .keyframes = &kf }).validate());

    const bad_chord = [_]Op{ .{ .at = 0, .do = .{ .keyframe = 0 } }, .{ .at = 1, .do = .{ .key = "mod+nosuchkey" } } };
    try testing.expectError(error.BadChord, (Tape{ .name = "x", .ops = &bad_chord, .keyframes = &kf }).validate());

    const bad_index = [_]Op{.{ .at = 0, .do = .{ .keyframe = 3 } }};
    try testing.expectError(error.BadKeyframeIndex, (Tape{ .name = "x", .ops = &bad_index, .keyframes = &kf }).validate());
}

test "a tape round-trips through ZON" {
    const tape = sample();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try tape.write(&out.writer);
    const text = try testing.allocator.dupeZ(u8, out.written());
    defer testing.allocator.free(text);

    var back = try parse(testing.allocator, text);
    defer back.deinit();
    try testing.expectEqualStrings("t", back.tape.name);
    try testing.expectEqual(tape.ops.len, back.tape.ops.len);
    try testing.expectEqualStrings("button", back.tape.ops[1].do.move.tag);
    try testing.expectEqual(@as(u32, 400), back.tape.ops[1].ms);
    try testing.expectEqualStrings("abc", back.tape.ops[5].do.type);
    try testing.expectEqualStrings("hello", back.tape.keyframes[0].files[0].text);
    try testing.expectEqual(tape.duration(), back.tape.duration());
}

test "a hand-written tape parses with every default left out" {
    var owned = try parse(testing.allocator,
        \\.{
        \\    .name = "hand",
        \\    .keyframes = .{ .{ .root = "demo://hand" } },
        \\    .ops = .{
        \\        .{ .at = 0, .do = .{ .keyframe = 0 } },
        \\        .{ .at = 10, .ms = 300, .do = .{ .move = .{ .tag = "fizzy.palette" } } },
        \\        .{ .at = 400, .do = .{ .wait = .{ .until = .idle } } },
        \\        .{ .at = 400, .do = .{ .key = "mod+shift+p" } },
        \\    },
        \\}
    );
    defer owned.deinit();
    try testing.expectEqual(@as(usize, 4), owned.tape.ops.len);
    try testing.expectEqual(@as(f32, 0.5), owned.tape.ops[1].do.move.x);
    try testing.expect(owned.tape.ops[2].do.wait.until == .idle);
    try testing.expectEqual(@as(u32, 10_000), owned.tape.ops[2].do.wait.timeout);
}
