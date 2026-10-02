//! The high-level way to write a demo: say what a person does, and the script works out when.
//!
//! ```zig
//! var s: Script = .init(gpa, "tour", "A tour");
//! try s.keyframe(.{ .root = "demo://tour", .files = &files, .open = &.{"README.md"} });
//! try s.caption("Everything here is a plugin.", .{});
//! try s.click(.{ .tag = try s.print("workbench.file:{s}/src/main.zig", .{s.root}) }, .{});
//! try s.typeText("// hello\n", .{});
//! try s.command("fizzy.commandPalette");
//! var owned = try s.finish();
//! ```
//!
//! Each call appends ops at the script's pen (`t`) and moves the pen past them by a person's pace
//! (`Pace`): a glide to the target, a short hover before the press, the beat after an action
//! while the viewer takes in what happened. Anything aimed at a tag first waits for the tag to be
//! drawn, so a click never lands on a pane still opening. The result is an ordinary `Tape` — the
//! same data a ZON file or a recorder produces — and nothing at play time knows a script made it.
const Script = @This();

const std = @import("std");
const Tape = @import("Tape.zig");
const Sequencer = @import("Sequencer.zig");
const chord = @import("../keymap/chord.zig");

/// Owns every string and list the finished tape points into.
arena: std.heap.ArenaAllocator,
name: []const u8,
title: []const u8,
ops: std.ArrayList(Tape.Op) = .empty,
captions: std.ArrayList(Tape.Caption) = .empty,
chapters: std.ArrayList(Tape.Chapter) = .empty,
keyframes: std.ArrayList(Tape.Keyframe) = .empty,
/// The pen: the demo time the next action starts at, in ms.
t: u32 = 0,
pace: Pace = .{},
/// The latest keyframe's root, for building the names of things under it.
root: []const u8 = "",
/// The view captions are about unless they say otherwise (`CaptionOptions.on`), by anchor: an
/// app's documents, say, so its captions sit over the work rather than at the window's foot.
caption_on: []const u8 = "",

/// How a person moves, by default. Every call can override its own.
pub const Pace = struct {
    /// The pointer crossing to a target.
    move_ms: u32 = 800,
    /// Hovering on the target before pressing — long enough for hover feedback to show.
    hover_ms: u32 = 160,
    /// Between press and release.
    click_ms: u32 = 110,
    /// After an action, before the next: the viewer sees what happened.
    beat_ms: u32 = 650,
    /// Typing speed, characters a second.
    cps: f32 = 12,
};

pub fn init(gpa: std.mem.Allocator, name: []const u8, title: []const u8) Script {
    return .{ .arena = .init(gpa), .name = name, .title = title };
}

/// Only for a script abandoned before `finish` — `finish` hands the memory to the tape.
pub fn deinit(self: *Script) void {
    self.arena.deinit();
}

/// The finished tape, validated. The script is spent: its memory now belongs to the result.
pub fn finish(self: *Script) !Tape.Owned {
    const a = self.arena.allocator();
    const tape: Tape = .{
        .name = try a.dupe(u8, self.name),
        .title = try a.dupe(u8, self.title),
        .ops = self.ops.items,
        .captions = self.captions.items,
        .chapters = self.chapters.items,
        .keyframes = self.keyframes.items,
    };
    try tape.validate();
    return .{ .arena = self.arena, .tape = tape };
}

/// Format a string that lives as long as the tape — a tag name built from `root`, say.
pub fn print(self: *Script, comptime fmt: []const u8, args: anytype) ![]const u8 {
    return std.fmt.allocPrint(self.arena.allocator(), fmt, args);
}

fn dupe(self: *Script, bytes: []const u8) ![]const u8 {
    return self.arena.allocator().dupe(u8, bytes);
}

fn push(self: *Script, op: Tape.Op) !void {
    try self.ops.append(self.arena.allocator(), op);
}

// ---- state and structure -------------------------------------------------------------------

/// Cut to a state declared outright. Every script starts with one, and a demo may cut again
/// wherever a seek should not have to replay everything before it. Waits for the stage to settle.
pub fn keyframe(self: *Script, kf: Tape.Keyframe) !void {
    const a = self.arena.allocator();
    const files = try a.alloc(Tape.File, kf.files.len);
    for (kf.files, files) |f, *out| out.* = .{ .path = try self.dupe(f.path), .text = try self.dupe(f.text) };
    const open = try a.alloc([]const u8, kf.open.len);
    for (kf.open, open) |p, *out| out.* = try self.dupe(p);
    const settings = try a.alloc(Tape.Setting, kf.settings.len);
    for (kf.settings, settings) |st, *out| out.* = .{ .owner = try self.dupe(st.owner), .key = try self.dupe(st.key), .value = try self.dupe(st.value) };
    const root = try self.dupe(kf.root);
    try self.keyframes.append(a, .{ .root = root, .files = files, .open = open, .layout = kf.layout, .settings = settings });
    try self.push(.{ .at = self.t, .do = .{ .keyframe = @intCast(self.keyframes.items.len - 1) } });
    try self.push(.{ .at = self.t, .do = .{ .wait = .{ .until = .idle } } });
    self.root = root;
}

/// A named point a viewer can jump to.
pub fn chapter(self: *Script, title: []const u8) !void {
    try self.chapters.append(self.arena.allocator(), .{ .at = self.t, .title = try self.dupe(title) });
}

pub const CaptionOptions = struct {
    title: []const u8 = "",
    /// How long it shows. Null: long enough to read.
    ms: ?u32 = null,
    place: Tape.Caption.Place = .bottom,
    /// The view it is about, by anchor. Null: `caption_on`.
    on: ?[]const u8 = null,
    /// Hold the next action until the caption is done, rather than acting under it.
    hold: bool = false,
};

/// Words over the app, starting now.
pub fn caption(self: *Script, text: []const u8, opts: CaptionOptions) !void {
    const ms = opts.ms orelse readingMs(opts.title.len + text.len);
    // A caption takes over from the one before: that one is cut to end here, so it closes as this
    // one opens rather than vanishing under it.
    if (self.captions.items.len > 0) {
        const last = &self.captions.items[self.captions.items.len - 1];
        if (last.at + last.ms > self.t) last.ms = self.t - last.at;
    }
    try self.captions.append(self.arena.allocator(), .{
        .at = self.t,
        .ms = ms,
        .title = try self.dupe(opts.title),
        .text = try self.dupe(text),
        .place = opts.place,
        .on = try self.dupe(opts.on orelse self.caption_on),
    });
    if (opts.hold) self.t += ms;
}

/// Long enough to read at an unhurried pace and still look at the app, never shorter than a
/// glance: about fourteen characters a second, after a couple of seconds to find it.
pub fn readingMs(chars: usize) u32 {
    return std.math.clamp(@as(u32, @intCast(chars)) * 70 + 1800, 3200, 12_000);
}

/// Nothing for a while.
pub fn pause(self: *Script, ms: u32) void {
    self.t += ms;
}

pub const WaitOptions = struct {
    timeout: u32 = 10_000,
};

/// Hold the demo until the tagged widget is drawn.
pub fn waitFor(self: *Script, tag: []const u8, opts: WaitOptions) !void {
    try self.push(.{ .at = self.t, .do = .{ .wait = .{ .until = .{ .shown = try self.dupe(tag) }, .timeout = opts.timeout } } });
}

/// Hold the demo until the tagged widget is gone.
pub fn waitGone(self: *Script, tag: []const u8, opts: WaitOptions) !void {
    try self.push(.{ .at = self.t, .do = .{ .wait = .{ .until = .{ .gone = try self.dupe(tag) }, .timeout = opts.timeout } } });
}

/// Hold the demo until the stage has nothing in flight.
pub fn waitIdle(self: *Script, opts: WaitOptions) !void {
    try self.push(.{ .at = self.t, .do = .{ .wait = .{ .until = .idle, .timeout = opts.timeout } } });
}

// ---- the pointer ---------------------------------------------------------------------------

pub const MoveOptions = struct {
    /// Null: `Pace.move_ms`.
    ms: ?u32 = null,
};

/// Glide the pointer onto a target, waiting for it to be drawn first.
pub fn moveTo(self: *Script, target: Tape.Target, opts: MoveOptions) !void {
    var tgt = target;
    if (tgt.tag.len > 0) {
        tgt.tag = try self.dupe(tgt.tag);
        try self.waitFor(tgt.tag, .{});
    }
    const ms = opts.ms orelse self.pace.move_ms;
    try self.push(.{ .at = self.t, .ms = ms, .do = .{ .move = tgt } });
    self.t += ms;
}

pub const ClickOptions = struct {
    button: Tape.Button = .left,
    /// Null: `Pace.move_ms`. Zero clicks where the pointer already is.
    move_ms: ?u32 = null,
    /// Two clicks, close enough together to be read as a double click.
    double: bool = false,
};

/// Move onto a target, hover a moment, and click it.
pub fn click(self: *Script, target: Tape.Target, opts: ClickOptions) !void {
    if (opts.move_ms != 0) try self.moveTo(target, .{ .ms = opts.move_ms });
    self.t += self.pace.hover_ms;
    for (0..if (opts.double) 2 else 1) |_| {
        try self.push(.{ .at = self.t, .do = .{ .press = opts.button } });
        self.t += self.pace.click_ms;
        try self.push(.{ .at = self.t, .do = .{ .release = opts.button } });
        self.t += self.pace.click_ms;
    }
    self.t += self.pace.beat_ms;
}

pub const DragOptions = struct {
    button: Tape.Button = .left,
    /// The carry from `from` to `to`; null is half again `Pace.move_ms`, a drag being slower.
    ms: ?u32 = null,
};

/// Press on one target, carry to another, release.
pub fn drag(self: *Script, from: Tape.Target, to: Tape.Target, opts: DragOptions) !void {
    try self.moveTo(from, .{});
    self.t += self.pace.hover_ms;
    try self.push(.{ .at = self.t, .do = .{ .press = opts.button } });
    self.t += self.pace.hover_ms;
    try self.moveTo(to, .{ .ms = opts.ms orelse self.pace.move_ms * 3 / 2 });
    self.t += self.pace.hover_ms;
    try self.push(.{ .at = self.t, .do = .{ .release = opts.button } });
    self.t += self.pace.beat_ms;
}

/// Wheel ticks where the pointer is: positive `y` scrolls up.
pub fn scroll(self: *Script, by: Tape.Scroll) !void {
    try self.push(.{ .at = self.t, .do = .{ .scroll = by } });
    self.t += 60;
}

// ---- the keyboard --------------------------------------------------------------------------

pub const TypeOptions = struct {
    /// Characters a second. Null: `Pace.cps`.
    cps: ?f32 = null,
};

/// Type into whatever has focus. `\n` is Enter and `\t` is Tab, pressed as keys — so write code
/// the way a person types it, and let the editor indent and close brackets as it does for them.
pub fn typeText(self: *Script, text: []const u8, opts: TypeOptions) !void {
    const ms = Sequencer.typingMs(text, opts.cps orelse self.pace.cps);
    try self.push(.{ .at = self.t, .ms = ms, .do = .{ .type = try self.dupe(text) } });
    self.t += ms + self.pace.beat_ms;
}

/// Press a chord: `"enter"`, `"escape"`, `"mod+a"`. Checked here, so a typo fails the build of
/// the tape rather than silently pressing nothing.
pub fn key(self: *Script, keys: []const u8) !void {
    _ = try chord.parseKeys(keys, .other);
    try self.push(.{ .at = self.t, .do = .{ .key = try self.dupe(keys) } });
    self.t += self.pace.beat_ms;
}

/// Run a command by id; the keystroke display shows its shortcut.
pub fn command(self: *Script, id: []const u8) !void {
    try self.push(.{ .at = self.t, .do = .{ .command = try self.dupe(id) } });
    self.t += self.pace.beat_ms;
}

// ---- tests ---------------------------------------------------------------------------------

const testing = std.testing;

test "a script paces a person's actions and waits for what it aims at" {
    var s: Script = .init(testing.allocator, "t", "Test");
    const files = [_]Tape.File{.{ .path = "a.txt", .text = "hi" }};
    try s.keyframe(.{ .root = "demo://t", .files = &files, .open = &.{"a.txt"} });
    try s.chapter("Start");
    try s.click(.{ .tag = try s.print("file:{s}/a.txt", .{s.root}) }, .{});
    try s.typeText("hello", .{ .cps = 10 });
    try s.key("mod+s");
    var owned = try s.finish();
    defer owned.deinit();
    const tape = owned.tape;

    try testing.expectEqualStrings("demo://t", tape.keyframes[0].root);
    try testing.expectEqualStrings("hi", tape.keyframes[0].files[0].text);
    try testing.expect(tape.ops[1].do.wait.until == .idle);
    try testing.expectEqualStrings("file:demo://t/a.txt", tape.ops[2].do.wait.until.shown);
    try testing.expectEqualStrings("file:demo://t/a.txt", tape.ops[3].do.move.tag);

    // The click: glide, hover, press, release — in that order, each later than the last.
    const move = tape.ops[3];
    const press = tape.ops[4];
    const release = tape.ops[5];
    const pace: Pace = .{};
    try testing.expectEqual(pace.move_ms, move.ms);
    try testing.expectEqual(move.end() + pace.hover_ms, press.at);
    try testing.expect(release.at > press.at);

    const typed = tape.ops[6];
    try testing.expectEqual(@as(u32, 500), typed.ms);
    try testing.expect(typed.at > release.at);
    try testing.expectEqual(typed.end() + pace.beat_ms, tape.ops[7].at);
    try testing.expectEqualStrings("mod+s", tape.ops[7].do.key);
}

test "a caption can hold the next action until it has been read" {
    var s: Script = .init(testing.allocator, "t", "");
    try s.keyframe(.{ .root = "demo://t" });
    try s.caption("Read me first.", .{ .ms = 3000, .hold = true });
    try s.command("x.y");
    try s.caption("Read me while it happens.", .{ .ms = 3000 });
    try s.command("x.z");
    var owned = try s.finish();
    defer owned.deinit();
    const beat = (Pace{}).beat_ms;
    try testing.expectEqual(@as(u32, 3000), owned.tape.ops[2].at);
    try testing.expectEqual(3000 + beat, owned.tape.ops[3].at);
    try testing.expectEqual(3000 + beat + 3000, owned.tape.duration());
}

test "a caption takes over from the one before" {
    var s: Script = .init(testing.allocator, "t", "");
    try s.keyframe(.{ .root = "demo://t" });
    try s.caption("First.", .{ .ms = 5000 });
    s.pause(2000);
    try s.caption("Second.", .{ .ms = 5000 });
    var owned = try s.finish();
    defer owned.deinit();
    const c = owned.tape.captions;
    try testing.expectEqual(c[1].at, c[0].at + c[0].ms);
    try testing.expectEqual(@as(u32, 2000), c[0].ms);
    try testing.expectEqualStrings("Second.", owned.tape.captionAt(2500).?.text);
}

test "a mistyped chord is caught when the script is written" {
    var s: Script = .init(testing.allocator, "t", "");
    defer s.deinit();
    try s.keyframe(.{ .root = "demo://t" });
    try testing.expectError(error.UnknownKey, s.key("mod+nope"));
}
