//! Plays a live tape: input played on the app as it is, a step at a time, each once the last has
//! landed. The other way to play a tape besides a demo, and a driver of its own rather than a
//! mode of the `Player` (`docs/AGENTS_PLAN.md`, "Driving a live tape"):
//!
//! |                       | a demo (`Player`)                   | a live tape (this)                |
//! |-----------------------|-------------------------------------|-----------------------------------|
//! | starts from           | a keyframe; the session set aside   | the app as it is (`Check.live`)   |
//! | pacing                | the tape's authored times           | each op once the app has settled  |
//! | a person steps in     | pause, and replay on resume         | stop, and say before which op     |
//! | going back            | seek: snapshots, keyframes          | none — undo, through commands     |
//!
//! Consumers: a plugin's tests, a macro, a scripted tutorial, anything driving fizzy the way a
//! person does. Plugins reach it through the `automation` service (`Service`).
//!
//! The input is `Input`'s, shared with the `Player`; of the `Stage` it reads only what a live
//! tape needs — `idle` and `command` — and never `begin`, `end`, `keyframe` or snapshots. Its
//! owner arbitrates with the `Player`: one tape drives the app at a time (the service refuses a
//! live tape while a demo is loaded, and fizzy's `Demo` a demo while a live tape plays).
//!
//! **Pacing.** Authored times are ignored: each frame the driver asks the sequencer for the next
//! moment anything happens (`Sequencer.nextAt`) and applies it, and goes on only while the stage
//! is idle — nothing it was asked to load still loading. The sequencer still yields after
//! everything the app has to draw before the next op can land (a press, a key, the end of a
//! glide), so a click on a menu the last click opened finds it open. A tape's own waits hold as
//! they do in a demo, and one that gives up stops the tape: a live tape that has lost its place
//! is better stopped and reported than carried on blind.
//!
//! **Interruption.** A real click, tap, scroll, key or typed text stops it, and the person's
//! input goes on to do what they meant. Real pointer motion is held off while it plays, as a
//! demo's is: the tape owns the pointer.
//!
//! Call `frame` once at the very start of the app's frame, before anything reads `dvui.events()`
//! — the same place as `Player.frame`.
const LiveDriver = @This();

const std = @import("std");
const dvui = @import("dvui");
const core = @import("core");
const Tape = @import("tape").Tape;
const Sequencer = @import("tape").Sequencer;
const Stage = @import("Stage.zig");
const Input = @import("Input.zig");

stage: Stage,
owned: ?Tape.Owned = null,
seq: Sequencer = undefined,
input: Input = .{},
/// How the last tape ended; null while one plays, or before any has.
outcome: ?Outcome = null,
/// A wait gave up during this frame's advance: the op index it gave up at.
gave_up_at: ?usize = null,
/// What the overlay shows of the tape's hand (`overlay.drawLive`), in wall time: a live tape's
/// own clock jumps from op to op, so nothing drawn can be timed by it.
hand: Hand = .{},

pub const Hand = struct {
    /// The last press, where and when, for the ripple.
    press: ?struct { pt: Sequencer.Point, ns: i128 } = null,
    /// Typing (a key, text, a command) rather than pointing: the pointer steps aside, as a
    /// desktop's does.
    typing: bool = false,
    /// When `typing` last changed, or the tape started: the pointer fades from there.
    since_ns: i128 = 0,

    fn set(self: *Hand, typing: bool) void {
        if (self.typing == typing) return;
        self.typing = typing;
        self.since_ns = dvui.frameTimeNS();
    }
};

pub const Outcome = union(enum) {
    /// Every op was applied.
    finished,
    /// A person's input stopped it; the index of the first op not applied.
    interrupted: usize,
    /// The wait at this op index gave up: what it waited for never came.
    timed_out: usize,
    /// `stop` was called; the index of the first op not applied.
    stopped: usize,
};

pub fn init(stage: Stage) LiveDriver {
    return .{ .stage = stage };
}

pub fn deinit(self: *LiveDriver) void {
    self.unload();
}

/// Whether a tape is playing.
pub fn playing(self: *const LiveDriver) bool {
    return self.owned != null;
}

pub const PlayError = error{
    /// A tape is already playing here: one at a time.
    Busy,
} || Tape.Error;

/// Start playing `owned`, which the driver now owns either way. It must be a live tape —
/// checked here as `Tape.validate` with `Check.live` would, whatever it was loaded with.
pub fn play(self: *LiveDriver, owned: Tape.Owned) PlayError!void {
    var o = owned;
    if (self.owned != null) {
        o.deinit();
        return error.Busy;
    }
    o.tape.validate(.{ .live = true }) catch |err| {
        o.deinit();
        return err;
    };
    self.owned = o;
    self.seq = .init(&self.owned.?.tape);
    // Where the person's pointer is now: the first glide starts from there, not the corner.
    const p = dvui.currentWindow().mouse_pt;
    self.seq.pointer = .{ .x = p.x, .y = p.y };
    self.outcome = null;
    self.gave_up_at = null;
    self.hand = .{ .since_ns = dvui.frameTimeNS() };
    dvui.refresh(null, @src(), null);
}

/// Stop the tape where it is, letting go of anything it holds.
pub fn stop(self: *LiveDriver) void {
    if (self.owned == null) return;
    self.finish(.{ .stopped = self.seq.cursor });
}

fn finish(self: *LiveDriver, outcome: Outcome) void {
    self.outcome = outcome;
    self.unload();
}

fn unload(self: *LiveDriver) void {
    self.input.releaseHeld();
    if (self.owned) |*o| o.deinit();
    self.owned = null;
}

/// Drive the tape for this frame. First thing in the app's frame.
pub fn frame(self: *LiveDriver) void {
    if (self.owned == null) return;
    // Widgets name themselves for the tape while it plays (`core.anchor`).
    core.anchor.want();
    if (self.takeRealInput()) return;
    Input.holdPointer(self.seq.pointer);
    // Another frame either way: the next op, or another look at whether the app has settled.
    dvui.refresh(null, @src(), null);
    if (!self.seq.holding and !self.stage.idle()) return;

    const wall_ms = @min(dvui.secondsSinceLastFrame() * 1000, 1000);
    _ = self.seq.advance(self.seq.nextAt(), wall_ms, self.sink());
    if (self.gave_up_at) |at| return self.finish(.{ .timed_out = at });
    if (self.seq.done()) self.finish(.finished);
}

/// A person's click, tap, scroll, key or text stops the tape and goes on to do what they meant;
/// their pointer motion is held off. True when it stopped.
fn takeRealInput(self: *LiveDriver) bool {
    const wd = dvui.currentWindow().data();
    for (dvui.events()) |*e| {
        if (e.handled) continue;
        switch (e.evt) {
            .mouse => |me| switch (me.action) {
                .motion => e.handle(@src(), wd),
                .focus, .press, .wheel_x, .wheel_y => {
                    self.finish(.{ .interrupted = self.seq.cursor });
                    return true;
                },
                .release, .position => {},
            },
            .key, .text => {
                self.finish(.{ .interrupted = self.seq.cursor });
                return true;
            },
            .window, .app => {},
        }
    }
    return false;
}

// ---- the sink: `Input`'s, and the stage's commands ------------------------------------------

fn sink(self: *LiveDriver) Sequencer.Sink {
    return .{ .ctx = self, .vtable = &sink_vtable };
}

const sink_vtable: Sequencer.Sink.VTable = .{
    .locate = locate,
    .moveTo = moveTo,
    .button = button,
    .scroll = scroll,
    .key = key,
    .text = text,
    .command = command,
    .keyframe = keyframe,
    .holds = holds,
    .timedOut = timedOut,
};

fn from(ctx: *anyopaque) *LiveDriver {
    return @ptrCast(@alignCast(ctx));
}

fn locate(_: *anyopaque, target: Tape.Target) ?Sequencer.Point {
    return Input.targetPoint(target);
}

fn moveTo(ctx: *anyopaque, pt: Sequencer.Point) void {
    from(ctx).hand.set(false);
    Input.moveTo(pt);
}

fn button(ctx: *anyopaque, b: Tape.Button, down: bool) void {
    const self = from(ctx);
    self.hand.set(false);
    self.input.button(b, down);
    if (down) self.hand.press = .{ .pt = self.seq.pointer, .ns = dvui.frameTimeNS() };
}

fn scroll(ctx: *anyopaque, by: Tape.Scroll) void {
    from(ctx).hand.set(false);
    Input.scroll(by);
}

fn key(ctx: *anyopaque, spelled: []const u8) void {
    from(ctx).hand.set(true);
    Input.key(spelled);
}

fn text(ctx: *anyopaque, bytes: []const u8) void {
    from(ctx).hand.set(true);
    Input.text(bytes);
}

fn command(ctx: *anyopaque, cmd: Tape.Command) void {
    const self = from(ctx);
    self.hand.set(true);
    self.stage.command(cmd.id, cmd.args);
}

/// Never reached: `play` refuses a tape with a keyframe.
fn keyframe(_: *anyopaque, _: *const Tape.Keyframe) void {}

fn holds(ctx: *anyopaque, until: Tape.Until) bool {
    return Input.tagHolds(until) orelse from(ctx).stage.idle();
}

fn timedOut(ctx: *anyopaque, until: Tape.Until) void {
    const self = from(ctx);
    // The sequencer has not moved past the wait yet: its cursor is the wait.
    self.gave_up_at = self.seq.cursor;
    // Reported in `outcome`, so only noted here.
    const name = if (self.owned) |o| o.tape.name else "?";
    switch (until) {
        .idle => dvui.log.info("live tape '{s}': gave up waiting for the app to settle", .{name}),
        .shown => |tag| dvui.log.info("live tape '{s}': gave up waiting for '{s}' to be drawn", .{ name, tag }),
        .gone => |tag| dvui.log.info("live tape '{s}': gave up waiting for '{s}' to go", .{ name, tag }),
    }
}
