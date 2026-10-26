//! Plays a tape's input track into a `Sink`, one frame at a time, deterministically.
//!
//! This is the low-level engine, and it knows nothing about dvui or fizzy: the `Sink` is told
//! "the pointer is here", "this button went down", "type these bytes", and decides what that means
//! (`Player` turns it into dvui events). That keeps the rules that make replay exact in one small
//! place that a unit test can drive frame by frame.
//!
//! The rules:
//!
//!   * **Demo time never runs ahead of what has been applied.** `advance` is asked to reach a time;
//!     it applies every op due by then, but stops early — *yields* — after any op the app has to
//!     draw a frame for before the next can land: a button, a key, a command, a keyframe, the end
//!     of a glide (so a widget that only appears on hover has appeared before the click). When it
//!     yields, `now` is the time of the op it stopped after, so the next frame carries on from
//!     there. A hitch therefore plays the same ops a frame each, a little late, rather than
//!     collapsing a click and the click on the menu it opened into one frame.
//!   * **Seeking is the same call with a far target.** Spans (glides, typing) are functions of
//!     time, so asked for a time past their end they finish at once; everything else lands a frame
//!     per op as above. A rewind is `rewind` to a keyframe and `advance` to the moment.
//!   * **Finishing at once is not skipping.** A glide covered in one call still passes along its
//!     path a point per `path_step_ms`, the frames live play would have drawn, so whatever it
//!     crosses sees the pointer pass — a text field it leaves forgets its click count, as it did
//!     live — and typing still arrives a keystroke at a time.
//!   * **Steps land together.** A `step` is a document's own change, not input: it needs no frame
//!     drawn before the next op, so a seek over an hour of drawing applies it all in one call.
//!   * **Waits hold time still.** A `wait` that does not hold yet stops the clock at the wait until
//!     it does (or its timeout passes, in wall time), so the ops after it land on an app that has
//!     caught up — at any speed, on any machine.
const Sequencer = @This();

const std = @import("std");
const Tape = @import("Tape.zig");

tape: *const Tape,
/// Demo time, in ms.
now: f64 = 0,
/// The next op to start, as an index into `tape.ops`.
cursor: usize = 0,
/// The last failure (see `Failure`): the op that failed and the op index its skip resumed at.
/// Only tests read these, to check the skip landed on the next chapter.
failed_op: ?usize = null,
resumed_at: ?usize = null,
/// Where the pointer is, in the sink's coordinates.
pointer: Point = .{},
glide: ?Glide = null,
typing: ?Typing = null,
/// The op at `cursor` is a wait that has not held yet; `held_ms` of wall time spent on it.
holding: bool = false,
held_ms: f64 = 0,
/// Buttons the tape holds down: a glide while one is carries something (`Glide.carried`).
pressed: std.EnumSet(Tape.Button) = .empty,
/// Set by whoever plays the tape while it replays to a moment rather than plays live (a seek):
/// a carried glide then takes a frame per step of its path (`path_step_ms`).
replaying: bool = false,
/// Demo time per wall time while a tape plays live: a plain value in `min_speed`...`max_speed`
/// (`setSpeed`). Only `playUntil` reads it, so a seek, which replays to a demo time,
/// lands exactly at any speed.
speed: f32 = default_speed,

pub const min_speed: f32 = 0.5;
pub const max_speed: f32 = 4.0;
pub const default_speed: f32 = 1.0;
/// The speeds a transport steps through.
pub const speeds = [_]f32{ 0.5, 0.75, 1, 1.5, 2, 3, 4 };

pub const Point = struct {
    x: f32 = 0,
    y: f32 = 0,
};

const Glide = struct {
    op: usize,
    from: Point,
    /// Where the target was last seen, for a frame it is not drawn (scrolled away, mid-cut).
    to: ?Point = null,
    /// Demo time the pointer was last put down along the path.
    at: f64,
    /// Begun with a button held: carrying something, the pointer goes where the target was seen
    /// to settle, and does not follow it after (`locked`). What it is carried over moves for it — a
    /// tab strip makes room for the tab, a drop opens under it — and chasing that moved the room
    /// it made: the tab carried at a tab went back and forth between two places every other frame.
    /// A person aims where they saw it, too.
    carried: bool = false,
    /// Carried, and the target seen in the same place on two frames: `to` is where it goes.
    locked: bool = false,
};

/// Demo time between the points of a glide that one call covers more of than a frame (a replay,
/// a hitch): live play's frame.
pub const path_step_ms: f64 = 16;

const Typing = struct {
    op: usize,
    /// Bytes of the op's text delivered so far.
    sent: usize = 0,
};

/// What the sequencer acts on. Every call is synchronous and on the frame's thread.
pub const Sink = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Where `target` is right now, or null when it is not drawn.
        locate: *const fn (ctx: *anyopaque, target: Tape.Target) ?Point,
        moveTo: *const fn (ctx: *anyopaque, pt: Point) void,
        button: *const fn (ctx: *anyopaque, button: Tape.Button, down: bool) void,
        scroll: *const fn (ctx: *anyopaque, by: Tape.Scroll) void,
        /// A key chord pressed and released, as the tape spells it (`"mod+s"`, `"mod+k mod+c"`; a
        /// typed newline or tab as `"enter"` or `"tab"`). The app turns its spelling into keys.
        key: *const fn (ctx: *anyopaque, chord: []const u8) void,
        /// Text typed; never contains `\n` or `\t` (those arrive as `key`).
        text: *const fn (ctx: *anyopaque, bytes: []const u8) void,
        /// Run a command, with its arguments as ZON (empty for none).
        command: *const fn (ctx: *anyopaque, cmd: Tape.Command) void,
        keyframe: *const fn (ctx: *anyopaque, kf: *const Tape.Keyframe) void,
        holds: *const fn (ctx: *anyopaque, until: Tape.Until) bool,
        /// An op could not do its job (see `Failure`) and the rest of its chapter was skipped. The
        /// sink says so where a person will see it. Called before the skip lands, with the
        /// sequencer's cursor already past the failed op.
        failed: *const fn (ctx: *anyopaque, failure: Failure) void,
        /// Apply a step to its file, shown being made over `ms` (the op's). Null for a sink that
        /// plays only live tapes, which have none (`Tape.validate`).
        step: ?*const fn (ctx: *anyopaque, step: Tape.Step, ms: u32) void = null,
        /// Whether `target` has stopped moving, asked as a glide onto it is about to begin: false
        /// holds the glide for a frame, and it is asked again. A replay covers a glide in one
        /// call and finds its target once, where live play follows it for the glide's whole
        /// length, so a place still sliding open when the glide began sends a replay's pointer
        /// where the place was. Null, or always true: glides begin at once (live play).
        still: ?*const fn (ctx: *anyopaque, target: Tape.Target) bool = null,
    };
};

/// What went wrong, and how much of the tape it cost. A tape that carries on after a missing
/// anchor acts on an app that is not where the script thinks: a press lands off its target, a
/// key types into the wrong view. So the rest of that chapter is skipped, and the next chapter
/// begins from whatever state the app is in (a chapter is the unit a viewer can jump to).
pub const Failure = struct {
    /// The index of the op that failed.
    op: usize,
    what: union(enum) {
        /// The wait's timeout passed before what it waited for came.
        wait: Tape.Until,
        /// A move or trace never saw its target drawn.
        target: Tape.Target,
    },
    /// The ops skipped after it: those up to the next chapter (keyframes included) that were
    /// not releases of a button already held.
    skipped: usize,
};

pub fn init(tape: *const Tape) Sequencer {
    return .{ .tape = tape };
}

/// The demo time of the next thing the tape does: the end of a glide or typing in flight, or the
/// next op's start — whichever comes first. Never before `now`. A replay that runs frames faster
/// than demo time begins each at this moment, so the app's clock reads in every frame what it
/// read when that frame's input landed live (`Player.frames`).
pub fn nextAt(self: Sequencer) f64 {
    const ops = self.tape.ops;
    var t: f64 = if (self.cursor < ops.len) @floatFromInt(ops[self.cursor].at) else std.math.inf(f64);
    if (self.holding) t = self.now;
    if (self.glide) |g| {
        t = @min(t, @as(f64, @floatFromInt(ops[g.op].end())));
        // Replayed a step a frame (`advanceSpans`), each frame begins at its own step.
        if (self.replaying and g.carried and ops[g.op].do == .move) t = @min(t, g.at + path_step_ms);
    }
    if (self.typing) |ty| t = @min(t, @as(f64, @floatFromInt(ops[ty.op].end())));
    return @max(t, self.now);
}

/// Between ops: no glide or typing in flight and no wait holding — a moment the app's model can
/// be taken as a whole (`Player`'s snapshots).
pub fn calm(self: Sequencer) bool {
    return self.glide == null and self.typing == null and !self.holding;
}

/// Put the sequencer back at a moment it was `calm` at: `cursor` the next op, `now` the demo
/// time, the pointer where it was. The app is put back to that moment by its stage.
pub fn restoreTo(self: *Sequencer, cursor: usize, now: f64, pointer: Point) void {
    self.cursor = cursor;
    self.now = now;
    self.pointer = pointer;
    self.glide = null;
    self.typing = null;
    self.holding = false;
    self.held_ms = 0;
    // A moment is calm with no button held (`Player.keepSnapshot`).
    self.pressed = .empty;
}

/// Play at `speed` times the tape's own pace, kept within `min_speed`...`max_speed`.
pub fn setSpeed(self: *Sequencer, speed: f32) void {
    self.speed = std.math.clamp(speed, min_speed, max_speed);
}

/// The next of `speeds` above the current one, round to the slowest.
pub fn stepSpeed(self: *Sequencer) void {
    for (speeds) |sp| {
        if (sp > self.speed + 0.001) return self.setSpeed(sp);
    }
    self.setSpeed(speeds[0]);
}

/// The index in `speeds` of the notch nearest the current speed.
pub fn speedIndex(self: *const Sequencer) usize {
    var best: usize = 0;
    for (speeds, 0..) |sp, i| {
        if (@abs(sp - self.speed) < @abs(speeds[best] - self.speed)) best = i;
    }
    return best;
}

/// Play at the notch `i` of `speeds`, kept within them.
pub fn setSpeedIndex(self: *Sequencer, i: usize) void {
    self.setSpeed(speeds[@min(i, speeds.len - 1)]);
}

/// Move `by` notches from the nearest one, stopping at the ends.
pub fn nudgeSpeed(self: *Sequencer, by: i32) void {
    const i: i32 = @intCast(self.speedIndex());
    self.setSpeedIndex(@intCast(std.math.clamp(i + by, 0, @as(i32, speeds.len) - 1)));
}

/// The demo time `wall_ms` of live playing reaches: what to ask `advance` for.
pub fn playUntil(self: Sequencer, wall_ms: f64) f64 {
    return self.now + wall_ms * self.speed;
}

/// Every op has been applied and nothing is in flight.
pub fn done(self: Sequencer) bool {
    return self.cursor >= self.tape.ops.len and self.glide == null and self.typing == null and !self.holding;
}

/// Go back to the keyframe op at `op_index` (see `Tape.keyframeBefore`), ready to replay from it.
/// Leaves the pointer where it is: the next glide starts from wherever it is drawn.
pub fn rewind(self: *Sequencer, op_index: usize) void {
    self.cursor = op_index;
    self.now = @floatFromInt(self.tape.ops[op_index].at);
    self.glide = null;
    self.typing = null;
    self.holding = false;
    self.held_ms = 0;
    self.pressed = .empty;
}

pub const Progress = enum {
    /// `now` is the time asked for.
    reached,
    /// Stopped after an op the app has to draw before the next lands. Call again next frame.
    yielded,
    /// Held on a wait. Call again next frame.
    holding,
};

/// Apply what is due up to demo time `until`, within this frame's budget (see the file comment).
/// `wall_ms` is the wall time since the last call, which only a wait's timeout reads.
pub fn advance(self: *Sequencer, until: f64, wall_ms: f64, sink: Sink) Progress {
    const ops = self.tape.ops;
    if (self.holding) {
        const wait = ops[self.cursor].do.wait;
        const gave_up = !sink.vtable.holds(sink.ctx, wait.until);
        if (gave_up) {
            self.held_ms += wall_ms;
            if (self.held_ms < @as(f64, @floatFromInt(wait.timeout))) return .holding;
        }
        const failed_op = self.cursor;
        self.holding = false;
        self.held_ms = 0;
        self.cursor += 1;
        // A wait that gave up yields: whoever plays the tape hears of it before anything after
        // the wait lands, and may stop there (a live tape does) or carry on (a demo does) from
        // the next chapter.
        if (gave_up) {
            self.fail(failed_op, .{ .wait = wait.until }, sink);
            return .yielded;
        }
    }

    while (true) {
        const next_at: f64 = if (self.cursor < ops.len) @floatFromInt(ops[self.cursor].at) else std.math.inf(f64);
        // Spans run up to the next op's start: anything still in flight then lands before it.
        if (self.advanceSpans(@min(until, next_at), sink)) |p| return p;
        // Past the last op, `until` may itself be infinite: `nextAt`'s "nothing next", which a
        // live driver asks for as it is. Infinity is not past infinity, so the end is its own test.
        if (self.cursor >= ops.len or next_at > until) {
            if (std.math.isFinite(until)) self.now = @max(self.now, until);
            return .reached;
        }
        if (self.finishSpans(sink)) |missed| {
            self.fail(missed.op, .{ .target = missed.target }, sink);
            return .yielded;
        }
        self.now = next_at;

        const op = ops[self.cursor];
        switch (op.do) {
            .wait => |w| {
                if (!sink.vtable.holds(sink.ctx, w.until)) {
                    self.holding = true;
                    self.held_ms = 0;
                    return .holding;
                }
                self.cursor += 1;
            },
            .skip => |sk| {
                self.cursor += 1;
                if (sink.vtable.holds(sink.ctx, sk.when)) self.cursor = @min(self.cursor + sk.count, ops.len);
            },
            .move, .trace => |target| {
                // A move only: a stroke's points are on a canvas that is not going anywhere, and a
                // drawing has hundreds of them.
                if (op.do == .move) if (sink.vtable.still) |still| if (!still(sink.ctx, target)) return .holding;
                self.glide = .{
                    .op = self.cursor,
                    .from = self.pointer,
                    .at = self.now,
                    .carried = self.pressed.count() > 0,
                };
                self.cursor += 1;
            },
            .type => {
                self.typing = .{ .op = self.cursor };
                self.cursor += 1;
            },
            .step => |st| {
                self.cursor += 1;
                if (sink.vtable.step) |f| f(sink.ctx, st, op.ms);
            },
            .keyframe => |i| {
                self.cursor += 1;
                sink.vtable.keyframe(sink.ctx, &self.tape.keyframes[i]);
                return .yielded;
            },
            .press => |b| {
                self.cursor += 1;
                self.pressed.insert(b);
                sink.vtable.button(sink.ctx, b, true);
                return .yielded;
            },
            .release => |b| {
                self.cursor += 1;
                self.pressed.remove(b);
                sink.vtable.button(sink.ctx, b, false);
                return .yielded;
            },
            .scroll => |s| {
                self.cursor += 1;
                sink.vtable.scroll(sink.ctx, s);
                return .yielded;
            },
            .key => |k| {
                self.cursor += 1;
                sink.vtable.key(sink.ctx, k);
                return .yielded;
            },
            .command => |cmd| {
                self.cursor += 1;
                sink.vtable.command(sink.ctx, cmd);
                return .yielded;
            },
        }
    }
}

/// Play glides and typing forward to demo time `to`. A span that finishes yields, so the frame
/// it ended on is drawn before whatever comes next acts on it.
fn advanceSpans(self: *Sequencer, to: f64, sink: Sink) ?Progress {
    if (self.glide) |*g| {
        const op = self.tape.ops[g.op];
        const f = fraction(op, to);
        if (!g.locked) if (sink.vtable.locate(sink.ctx, op.do.target().?)) |pt| {
            // Carried, it locks on once the target is seen in the same place twice: still
            // easing in, it is followed there.
            if (g.carried and g.to != null and g.to.?.x == pt.x and g.to.?.y == pt.y) g.locked = true;
            g.to = pt;
        };
        // A target never seen leaves the pointer where it is rather than flying to the corner.
        const dest = g.to orelse g.from;
        // The frames live play would have drawn between, each a point along the way.
        const end: f64 = @min(to, @as(f64, @floatFromInt(op.end())));
        var t = g.at + path_step_ms;
        while (t < end) : (t += path_step_ms) {
            const pt = pathPoint(op, g.from, dest, fraction(op, t));
            if (pt.x == self.pointer.x and pt.y == self.pointer.y) continue;
            self.pointer = pt;
            sink.vtable.moveTo(sink.ctx, pt);
            // Replaying, a step of a carried glide is a frame of its own, as it was live: what
            // is carried moves with the frames it is drawn in (a float by its header), and the
            // rest of a glide landed in one frame was lost to it. Not a trace: a stroke's points
            // are the canvas's to take as they come, and a drawing has hundreds of them.
            if (g.carried and op.do == .move and self.replaying) {
                g.at = t;
                return .yielded;
            }
        }
        g.at = @max(g.at, to);
        self.pointer = pathPoint(op, g.from, dest, f);
        sink.vtable.moveTo(sink.ctx, self.pointer);
        if (f >= 1) {
            const never_seen = g.to == null;
            const op_index = g.op;
            self.glide = null;
            self.now = @max(self.now, @as(f64, @floatFromInt(op.end())));
            if (never_seen) self.fail(op_index, .{ .target = op.do.target().? }, sink);
            return .yielded;
        }
    }
    if (self.typing) |*ty| {
        const op = self.tape.ops[ty.op];
        const text = op.do.type;
        const n = if (fraction(op, to) >= 1) text.len else typedCount(text, op.ms, to - @as(f64, @floatFromInt(op.at)));
        self.deliver(text[ty.sent..n], sink);
        ty.sent = n;
        if (n >= text.len) {
            self.typing = null;
            self.now = @max(self.now, @as(f64, @floatFromInt(op.end())));
            return .yielded;
        }
    }
    return null;
}

const Missed = struct { op: usize, target: Tape.Target };

/// Land whatever is still in flight, as if its time had come. Returns the glide whose target was
/// never drawn, if there was one: the pointer did not go anywhere, and what follows would act on
/// the wrong place.
fn finishSpans(self: *Sequencer, sink: Sink) ?Missed {
    var missed: ?Missed = null;
    if (self.glide) |g| {
        const target = self.tape.ops[g.op].do.target().?;
        const to = if (g.locked) g.to else sink.vtable.locate(sink.ctx, target) orelse g.to;
        if (to) |pt| {
            self.pointer = pt;
            sink.vtable.moveTo(sink.ctx, pt);
        } else missed = .{ .op = g.op, .target = target };
        self.glide = null;
    }
    if (self.typing) |ty| {
        const text = self.tape.ops[ty.op].do.type;
        self.deliver(text[ty.sent..], sink);
        self.typing = null;
    }
    return missed;
}

/// `op` failed: tell the sink, then skip to the next chapter. Releases of a button already held
/// still land, or the app would be left mid-drag by a tape that has gone on.
fn fail(self: *Sequencer, op: usize, what: @FieldType(Failure, "what"), sink: Sink) void {
    const ops = self.tape.ops;
    const failed_at = ops[op].at;
    const chapter_at: u32 = for (self.tape.chapters) |c| {
        if (c.at > failed_at) break c.at;
    } else std.math.maxInt(u32);
    var end = self.cursor;
    while (end < ops.len and ops[end].at < chapter_at) end += 1;
    var skipped = end - self.cursor;
    // A button releases at most once while skipped (the set is empty after), so the releases fit
    // one slot per button, in tape order.
    var releases: [std.enums.values(Tape.Button).len]Tape.Button = undefined;
    var released: usize = 0;
    var pressed = self.pressed;
    for (ops[self.cursor..end]) |o| {
        if (o.do == .release and pressed.contains(o.do.release)) {
            pressed.remove(o.do.release);
            releases[released] = o.do.release;
            released += 1;
            skipped -= 1;
        }
    }
    sink.vtable.failed(sink.ctx, .{ .op = op, .what = what, .skipped = skipped });
    for (releases[0..released]) |button| sink.vtable.button(sink.ctx, button, false);
    self.pressed = pressed;
    self.cursor = end;
    self.failed_op = op;
    self.resumed_at = end;
}

/// Send typed bytes a keystroke at a time, turning `\n` and `\t` into the keys a person presses
/// for them. One character per event even when several land in one frame: an editor decides what
/// a keystroke does (close a bracket, step over one) per keystroke, and reads a run of text as a
/// paste.
fn deliver(self: *Sequencer, bytes: []const u8, sink: Sink) void {
    _ = self;
    var i: usize = 0;
    while (i < bytes.len) {
        const n = @min(std.unicode.utf8ByteSequenceLength(bytes[i]) catch 1, bytes.len - i);
        switch (bytes[i]) {
            '\n' => sink.vtable.key(sink.ctx, "enter"),
            '\t' => sink.vtable.key(sink.ctx, "tab"),
            else => sink.vtable.text(sink.ctx, bytes[i..][0..n]),
        }
        i += n;
    }
}

/// How far through `op` demo time `t` is, 0 to 1. An instant op is done the moment it starts.
fn fraction(op: Tape.Op, t: f64) f32 {
    if (op.ms == 0) return 1;
    const f = (t - @as(f64, @floatFromInt(op.at))) / @as(f64, @floatFromInt(op.ms));
    return @floatCast(std.math.clamp(f, 0, 1));
}

// ---- how a person moves --------------------------------------------------------------------

/// The pointer `f` of the way along `op`: a `move`'s glide, or a `trace`'s ruled line.
fn pathPoint(op: Tape.Op, from: Point, to: Point, f: f32) Point {
    if (op.do == .move) return glidePoint(from, to, f);
    return .{ .x = from.x + (to.x - from.x) * f, .y = from.y + (to.y - from.y) * f };
}

/// The pointer `f` of the way along a glide: eased in and out, on a slight bow rather than a ruled
/// line — a hand moving a mouse swings a little, and a dead-straight constant-speed pointer reads
/// as
/// a machine.
pub fn glidePoint(from: Point, to: Point, f: f32) Point {
    const e = easeInOut(std.math.clamp(f, 0, 1));
    if (e >= 1) return to;
    const dx = to.x - from.x;
    const dy = to.y - from.y;
    const len = @sqrt(dx * dx + dy * dy);
    var x = from.x + dx * e;
    var y = from.y + dy * e;
    if (len > 1) {
        const bow = @min(len * 0.08, 40) * @sin(std.math.pi * e);
        x += -dy / len * bow;
        y += dx / len * bow;
    }
    return .{ .x = x, .y = y };
}

fn easeInOut(t: f32) f32 {
    return if (t < 0.5) 4 * t * t * t else 1 - std.math.pow(f32, -2 * t + 2, 3) / 2;
}

/// How many bytes of `text` are typed `elapsed` ms into a `ms`-long typing span. Keystrokes are
/// unevenly spaced the way a person's are — a word's letters come quicker than the pause after it,
/// a line break takes a breath — but the spacing is a function of the text alone, so every replay
/// types the same characters on the same frames. Never splits a UTF-8 sequence.
pub fn typedCount(text: []const u8, ms: u32, elapsed: f64) usize {
    if (text.len == 0 or elapsed <= 0) return 0;
    if (ms == 0 or elapsed >= @as(f64, @floatFromInt(ms))) return text.len;
    const total = typingWeight(text, text.len);
    const want = total * elapsed / @as(f64, @floatFromInt(ms));
    var acc: f64 = 0;
    var i: usize = 0;
    while (i < text.len) {
        const n = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        acc += keystrokeWeight(text, i);
        if (acc > want) return i;
        i += n;
    }
    return text.len;
}

fn typingWeight(text: []const u8, upto: usize) f64 {
    var acc: f64 = 0;
    var i: usize = 0;
    while (i < upto) {
        acc += keystrokeWeight(text, i);
        i += std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
    }
    return acc;
}

/// How long the keystroke for the character at byte `i` takes, relative to an average one.
fn keystrokeWeight(text: []const u8, i: usize) f64 {
    var h: u32 = @truncate(i *% 2654435761);
    h ^= h >> 13;
    const jitter = 0.6 + @as(f64, @floatFromInt(h % 1000)) / 1000.0 * 0.8;
    const pause: f64 = switch (text[i]) {
        '\n' => 2.6,
        ' ', '.', ',', ';', ':', '(', ')' => 1.5,
        else => 1,
    };
    return jitter * pause;
}

/// A typing span's length for `text` at `cps` characters a second.
pub fn typingMs(text: []const u8, cps: f32) u32 {
    const chars: f32 = @floatFromInt(std.unicode.utf8CountCodepoints(text) catch text.len);
    return @intFromFloat(@ceil(chars / @max(cps, 0.1) * 1000));
}

// ---- tests ---------------------------------------------------------------------------------

const testing = std.testing;

/// A sink that writes what it was told as lines, and answers waits from a flag.
const Log = struct {
    out: std.ArrayList(u8) = .empty,
    /// Where tagged targets are. Untagged targets are window fractions of a 1000×1000 window.
    tags: std.StringHashMapUnmanaged(Point) = .empty,
    idle: bool = true,

    fn deinit(self: *Log) void {
        self.out.deinit(testing.allocator);
        self.tags.deinit(testing.allocator);
    }

    fn print(self: *Log, comptime fmt: []const u8, args: anytype) void {
        self.out.print(testing.allocator, fmt ++ "\n", args) catch unreachable;
    }

    fn sink(self: *Log) Sink {
        return .{ .ctx = self, .vtable = &.{
            .locate = locate,
            .moveTo = moveTo,
            .button = button,
            .scroll = scroll,
            .key = key,
            .text = text,
            .command = command,
            .keyframe = keyframe,
            .holds = holds,
            .failed = failed,
            .step = step,
        } };
    }
    fn from(ctx: *anyopaque) *Log {
        return @ptrCast(@alignCast(ctx));
    }
    fn locate(ctx: *anyopaque, t: Tape.Target) ?Point {
        if (t.tag.len == 0) return .{ .x = t.x * 1000, .y = t.y * 1000 };
        return from(ctx).tags.get(t.tag);
    }
    fn moveTo(ctx: *anyopaque, pt: Point) void {
        from(ctx).print("move {d:.0},{d:.0}", .{ pt.x, pt.y });
    }
    fn button(ctx: *anyopaque, b: Tape.Button, down: bool) void {
        from(ctx).print("{s} {t}", .{ if (down) "press" else "release", b });
    }
    fn scroll(ctx: *anyopaque, s: Tape.Scroll) void {
        from(ctx).print("scroll {d}", .{s.y});
    }
    fn key(ctx: *anyopaque, c: []const u8) void {
        from(ctx).print("key {s}", .{c});
    }
    fn text(ctx: *anyopaque, bytes: []const u8) void {
        from(ctx).print("text {s}", .{bytes});
    }
    fn command(ctx: *anyopaque, cmd: Tape.Command) void {
        if (cmd.args.len == 0) return from(ctx).print("command {s}", .{cmd.id});
        from(ctx).print("command {s} {s}", .{ cmd.id, cmd.args });
    }
    fn keyframe(ctx: *anyopaque, kf: *const Tape.Keyframe) void {
        from(ctx).print("keyframe {s}", .{kf.root});
    }
    fn holds(ctx: *anyopaque, until: Tape.Until) bool {
        return switch (until) {
            .idle => from(ctx).idle,
            .shown => |t| from(ctx).tags.contains(t),
            .gone => |t| !from(ctx).tags.contains(t),
        };
    }
    fn failed(ctx: *anyopaque, f: Failure) void {
        switch (f.what) {
            .wait => from(ctx).print("timeout {d} skipping {d}", .{ f.op, f.skipped }),
            .target => |t| from(ctx).print("missing {s} {d} skipping {d}", .{ t.tag, f.op, f.skipped }),
        }
    }
    fn step(ctx: *anyopaque, st: Tape.Step, ms: u32) void {
        from(ctx).print("step {s} {s} {d}", .{ st.file, st.effect, ms });
    }
};

const test_keyframes = [_]Tape.Keyframe{ .{ .root = "demo://a" }, .{ .root = "demo://b" } };

/// `out` with each run of `move` lines cut to its last: what landed where, without the path.
fn landings(out: []const u8) ![]u8 {
    var kept: std.ArrayList(u8) = .empty;
    errdefer kept.deinit(testing.allocator);
    var lines = std.mem.tokenizeScalar(u8, out, '\n');
    var pending: ?[]const u8 = null;
    while (lines.next()) |l| {
        if (std.mem.startsWith(u8, l, "move ")) {
            pending = l;
            continue;
        }
        if (pending) |m| try kept.print(testing.allocator, "{s}\n", .{m});
        pending = null;
        try kept.print(testing.allocator, "{s}\n", .{l});
    }
    if (pending) |m| try kept.print(testing.allocator, "{s}\n", .{m});
    return kept.toOwnedSlice(testing.allocator);
}

/// Run frames of `frame_ms` until `t` is reached, the way a player plays live.
fn playTo(seq: *Sequencer, t: f64, frame_ms: f64, sink: Sink) void {
    var guard: usize = 0;
    while (seq.now < t and guard < 10_000) : (guard += 1) {
        _ = seq.advance(@min(t, seq.now + frame_ms), frame_ms, sink);
    }
}

test "asked for what is next with nothing left, it has reached the end" {
    // A live driver asks for `nextAt`, which is infinite once the ops are spent — at once, for an
    // empty tape (valid live: `Tape.validate`).
    var log: Log = .{};
    defer log.deinit();
    const empty: Tape = .{ .name = "empty", .ops = &.{} };
    var seq: Sequencer = .init(&empty);
    try testing.expect(seq.done());
    try testing.expectEqual(Progress.reached, seq.advance(seq.nextAt(), 16, log.sink()));
    try testing.expectEqual(@as(f64, 0), seq.now);
    try testing.expectEqualStrings("", log.out.items);

    const ops = [_]Tape.Op{.{ .at = 40, .do = .{ .key = "mod+s" } }};
    const one: Tape = .{ .name = "one", .ops = &ops };
    seq = .init(&one);
    try testing.expectEqual(Progress.yielded, seq.advance(seq.nextAt(), 16, log.sink()));
    try testing.expect(seq.done());
    try testing.expectEqual(Progress.reached, seq.advance(seq.nextAt(), 16, log.sink()));
    try testing.expectEqual(@as(f64, 40), seq.now);
}

test "a click lands a frame after the glide that brought the pointer to it" {
    const ops = [_]Tape.Op{
        .{ .at = 0, .do = .{ .keyframe = 0 } },
        .{ .at = 0, .ms = 100, .do = .{ .move = .{ .tag = "ok" } } },
        .{ .at = 100, .do = .{ .press = .left } },
        .{ .at = 150, .do = .{ .release = .left } },
    };
    const tape: Tape = .{ .name = "t", .ops = &ops, .keyframes = &test_keyframes };
    var log: Log = .{};
    defer log.deinit();
    try log.tags.put(testing.allocator, "ok", .{ .x = 100, .y = 0 });

    var seq: Sequencer = .init(&tape);
    // One huge frame: everything is due, but each op still gets a frame of its own.
    try testing.expectEqual(Progress.yielded, seq.advance(1000, 16, log.sink()));
    try testing.expectEqualStrings("keyframe demo://a\n", log.out.items);
    try testing.expectEqual(Progress.yielded, seq.advance(1000, 16, log.sink()));
    try testing.expectEqual(@as(f64, 100), seq.now);
    try testing.expectEqual(Progress.yielded, seq.advance(1000, 16, log.sink()));
    try testing.expectEqual(Progress.yielded, seq.advance(1000, 16, log.sink()));
    try testing.expectEqual(Progress.reached, seq.advance(1000, 16, log.sink()));
    const landed = try landings(log.out.items);
    defer testing.allocator.free(landed);
    try testing.expectEqualStrings(
        \\keyframe demo://a
        \\move 100,0
        \\press left
        \\release left
        \\
    , landed);
    try testing.expect(seq.done());
}

test "steps land together, with no frame between them, each at its own time" {
    const ops = [_]Tape.Op{
        .{ .at = 0, .do = .{ .keyframe = 0 } },
        .{ .at = 100, .ms = 40, .do = .{ .step = .{ .file = "a.pixi", .effect = "one" } } },
        .{ .at = 200, .do = .{ .step = .{ .file = "a.pixi", .effect = "two" } } },
        .{ .at = 300, .ms = 90, .do = .{ .step = .{ .file = "a.pixi", .effect = "three" } } },
        .{ .at = 400, .do = .{ .key = "a" } },
    };
    const tape: Tape = .{ .name = "t", .ops = &ops, .keyframes = &test_keyframes };
    var log: Log = .{};
    defer log.deinit();

    var seq: Sequencer = .init(&tape);
    try testing.expectEqual(Progress.yielded, seq.advance(0, 16, log.sink()));
    // Played live, each lands when it is due.
    try testing.expectEqual(Progress.reached, seq.advance(150, 16, log.sink()));
    try testing.expectEqualStrings("keyframe demo://a\nstep a.pixi one 40\n", log.out.items);
    // Sought past, the rest land in the one call, up to the key that needs a frame of its own.
    try testing.expectEqual(Progress.yielded, seq.advance(1000, 16, log.sink()));
    try testing.expectEqualStrings(
        \\keyframe demo://a
        \\step a.pixi one 40
        \\step a.pixi two 0
        \\step a.pixi three 90
        \\key a
        \\
    , log.out.items);
}

test "a glide covered in one call still passes along its path, a frame's worth at a time" {
    const ops = [_]Tape.Op{
        .{ .at = 0, .do = .{ .keyframe = 0 } },
        .{ .at = 0, .ms = 160, .do = .{ .move = .{ .x = 1, .y = 0 } } },
    };
    const tape: Tape = .{ .name = "t", .ops = &ops, .keyframes = &test_keyframes };
    var log: Log = .{};
    defer log.deinit();
    var seq: Sequencer = .init(&tape);
    while (seq.advance(1000, 16, log.sink()) != .reached) {}

    // The points live play at 60 fps would have delivered, in order, ending on the target.
    var xs: std.ArrayList(f32) = .empty;
    defer xs.deinit(testing.allocator);
    var lines = std.mem.tokenizeScalar(u8, log.out.items, '\n');
    while (lines.next()) |l| {
        if (!std.mem.startsWith(u8, l, "move ")) continue;
        const comma = std.mem.findScalar(u8, l, ',').?;
        try xs.append(testing.allocator, try std.fmt.parseFloat(f32, l[5..comma]));
    }
    try testing.expectEqual(@as(usize, 10), xs.items.len);
    for (xs.items[1..], xs.items[0 .. xs.items.len - 1]) |x, before| try testing.expect(x > before);
    try testing.expectEqual(@as(f32, 1000), xs.items[xs.items.len - 1]);

    // A glide that goes nowhere passes nowhere: one landing, not a run of the same point.
    var still: Log = .{};
    defer still.deinit();
    seq.rewind(0);
    while (seq.advance(1000, 16, still.sink()) != .reached) {}
    try testing.expectEqualStrings("keyframe demo://a\nmove 1000,0\n", still.out.items);
}

test "a glide moves a little every frame and ends on its target" {
    const ops = [_]Tape.Op{
        .{ .at = 0, .do = .{ .keyframe = 0 } },
        .{ .at = 0, .ms = 100, .do = .{ .move = .{ .x = 1, .y = 0 } } },
    };
    const tape: Tape = .{ .name = "t", .ops = &ops, .keyframes = &test_keyframes };
    var log: Log = .{};
    defer log.deinit();
    var seq: Sequencer = .init(&tape);
    playTo(&seq, 200, 25, log.sink());
    var moves: usize = 0;
    var lines = std.mem.tokenizeScalar(u8, log.out.items, '\n');
    while (lines.next()) |l| {
        if (std.mem.startsWith(u8, l, "move")) moves += 1;
    }
    try testing.expect(moves >= 4);
    try testing.expectEqual(@as(f32, 1000), seq.pointer.x);
}

test "typing spreads keystrokes over the span, and Enter is a key" {
    const ops = [_]Tape.Op{
        .{ .at = 0, .do = .{ .keyframe = 0 } },
        .{ .at = 0, .ms = 1000, .do = .{ .type = "ab\ncd" } },
    };
    const tape: Tape = .{ .name = "t", .ops = &ops, .keyframes = &test_keyframes };
    var log: Log = .{};
    defer log.deinit();
    var seq: Sequencer = .init(&tape);
    playTo(&seq, 1000, 50, log.sink());
    var typed: std.ArrayList(u8) = .empty;
    defer typed.deinit(testing.allocator);
    var lines = std.mem.tokenizeScalar(u8, log.out.items, '\n');
    var keystrokes: usize = 0;
    while (lines.next()) |l| {
        if (std.mem.startsWith(u8, l, "text ")) {
            try typed.appendSlice(testing.allocator, l[5..]);
            keystrokes += 1;
        }
        if (std.mem.eql(u8, l, "key enter")) try typed.append(testing.allocator, '\n');
    }
    try testing.expectEqualStrings("ab\ncd", typed.items);
    try testing.expectEqual(@as(usize, 4), keystrokes);
}

test "typing is the same characters at the same times on every replay" {
    const text = "const answer = 42;\n";
    var prev: usize = 0;
    var t: f64 = 0;
    while (t <= 2000) : (t += 10) {
        const n = typedCount(text, 2000, t);
        try testing.expect(n >= prev);
        try testing.expectEqual(n, typedCount(text, 2000, t));
        prev = n;
    }
    try testing.expectEqual(text.len, prev);
    // Never mid-codepoint.
    const accented = "héllo";
    t = 0;
    while (t <= 500) : (t += 1) {
        const n = typedCount(accented, 500, t);
        try testing.expect(n == accented.len or (accented[n] & 0xC0) != 0x80);
    }
}

test "a wait holds demo time until it holds, then carries on in the same frame" {
    const ops = [_]Tape.Op{
        .{ .at = 0, .do = .{ .keyframe = 0 } },
        .{ .at = 10, .do = .{ .wait = .{ .until = .idle } } },
        .{ .at = 10, .do = .{ .command = .{ .id = "x.go" } } },
        .{ .at = 10, .do = .{ .command = .{ .id = "x.to", .args = ".{ .line = 3 }" } } },
    };
    const tape: Tape = .{ .name = "t", .ops = &ops, .keyframes = &test_keyframes };
    var log: Log = .{ .idle = false };
    defer log.deinit();
    var seq: Sequencer = .init(&tape);
    _ = seq.advance(100, 16, log.sink());
    try testing.expectEqual(Progress.holding, seq.advance(100, 16, log.sink()));
    try testing.expectEqual(Progress.holding, seq.advance(100, 16, log.sink()));
    try testing.expectEqual(@as(f64, 10), seq.now);
    log.idle = true;
    try testing.expectEqual(Progress.yielded, seq.advance(100, 16, log.sink()));
    try testing.expectEqualStrings("keyframe demo://a\ncommand x.go\n", log.out.items);
    // A command's arguments reach the sink as written, a frame after the command before it.
    try testing.expectEqual(Progress.yielded, seq.advance(100, 16, log.sink()));
    try testing.expectEqualStrings("keyframe demo://a\ncommand x.go\ncommand x.to .{ .line = 3 }\n", log.out.items);
}

test "a skip leaves out the ops after it when its condition holds, and plays them when it does not" {
    const ops = [_]Tape.Op{
        .{ .at = 0, .do = .{ .keyframe = 0 } },
        .{ .at = 10, .do = .{ .skip = .{ .when = .{ .shown = "open" }, .count = 2 } } },
        .{ .at = 20, .do = .{ .key = "a" } },
        .{ .at = 30, .do = .{ .key = "b" } },
        .{ .at = 40, .do = .{ .key = "c" } },
    };
    const tape: Tape = .{ .name = "t", .ops = &ops, .keyframes = &test_keyframes };
    var log: Log = .{};
    defer log.deinit();
    var seq: Sequencer = .init(&tape);
    try log.tags.put(testing.allocator, "open", .{ .x = 0, .y = 0 });
    playTo(&seq, 100, 16, log.sink());
    try testing.expectEqualStrings("keyframe demo://a\nkey c\n", log.out.items);

    // Rewound and replayed with it shut, the same ops play whole.
    log.out.clearRetainingCapacity();
    _ = log.tags.remove("open");
    seq.rewind(0);
    playTo(&seq, 100, 16, log.sink());
    try testing.expectEqualStrings("keyframe demo://a\nkey a\nkey b\nkey c\n", log.out.items);
}

test "a wait that never holds gives up after its timeout, in wall time" {
    const ops = [_]Tape.Op{
        .{ .at = 0, .do = .{ .keyframe = 0 } },
        .{ .at = 0, .do = .{ .wait = .{ .until = .{ .shown = "never" }, .timeout = 100 } } },
        .{ .at = 0, .do = .{ .key = "mod+s" } },
    };
    const tape: Tape = .{ .name = "t", .ops = &ops, .keyframes = &test_keyframes };
    var log: Log = .{};
    defer log.deinit();
    var seq: Sequencer = .init(&tape);
    _ = seq.advance(0, 16, log.sink());
    var frames: usize = 0;
    while (seq.advance(0, 30, log.sink()) == .holding) frames += 1;
    // Entering the wait, then 30, 60 and 90 ms held; at 120 it gives up and yields. With no
    // chapter after it, the key that followed is skipped with the rest of the tape.
    try testing.expectEqual(@as(usize, 4), frames);
    try testing.expectEqualStrings("keyframe demo://a\ntimeout 1 skipping 1\n", log.out.items);
    try testing.expect(seq.done());
}

test "a timed-out wait skips the rest of its chapter and the next one plays" {
    const ops = [_]Tape.Op{
        .{ .at = 0, .do = .{ .keyframe = 0 } },
        .{ .at = 100, .do = .{ .wait = .{ .until = .{ .shown = "never" }, .timeout = 50 } } },
        .{ .at = 200, .do = .{ .key = "skipped" } },
        .{ .at = 900, .do = .{ .command = .{ .id = "skipped.too" } } },
        .{ .at = 1000, .do = .{ .key = "plays" } },
    };
    const chapters = [_]Tape.Chapter{ .{ .at = 0, .title = "one" }, .{ .at = 1000, .title = "two" } };
    const tape: Tape = .{ .name = "t", .ops = &ops, .keyframes = &test_keyframes, .chapters = &chapters };
    var log: Log = .{};
    defer log.deinit();
    var seq: Sequencer = .init(&tape);
    while (!seq.done()) _ = seq.advance(std.math.inf(f64), 30, log.sink());
    try testing.expectEqualStrings("keyframe demo://a\ntimeout 1 skipping 2\nkey plays\n", log.out.items);
}

test "a timed-out wait still releases a button held across it, but not a press it skipped" {
    const ops = [_]Tape.Op{
        .{ .at = 0, .do = .{ .keyframe = 0 } },
        .{ .at = 0, .do = .{ .press = .left } },
        .{ .at = 10, .do = .{ .wait = .{ .until = .{ .shown = "never" }, .timeout = 10 } } },
        .{ .at = 20, .do = .{ .release = .left } },
        .{ .at = 30, .do = .{ .press = .left } },
        .{ .at = 40, .do = .{ .release = .left } },
    };
    const tape: Tape = .{ .name = "t", .ops = &ops, .keyframes = &test_keyframes };
    var log: Log = .{};
    defer log.deinit();
    var seq: Sequencer = .init(&tape);
    while (!seq.done()) _ = seq.advance(std.math.inf(f64), 30, log.sink());
    try testing.expectEqualStrings(
        "keyframe demo://a\npress left\ntimeout 2 skipping 2\nrelease left\n",
        log.out.items,
    );
}

test "a timed-out wait skips a keyframe and the commands after it, up to the next chapter" {
    const ops = [_]Tape.Op{
        .{ .at = 0, .do = .{ .keyframe = 0 } },
        .{ .at = 100, .do = .{ .wait = .{ .until = .{ .shown = "never" }, .timeout = 50 } } },
        .{ .at = 200, .do = .{ .keyframe = 0 } },
        .{ .at = 300, .do = .{ .command = .{ .id = "skipped" } } },
        .{ .at = 1000, .do = .{ .key = "plays" } },
    };
    const chapters = [_]Tape.Chapter{ .{ .at = 0, .title = "one" }, .{ .at = 1000, .title = "two" } };
    const tape: Tape = .{ .name = "t", .ops = &ops, .keyframes = &test_keyframes, .chapters = &chapters };
    var log: Log = .{};
    defer log.deinit();
    var seq: Sequencer = .init(&tape);
    while (!seq.done()) _ = seq.advance(std.math.inf(f64), 30, log.sink());
    try testing.expectEqualStrings("keyframe demo://a\ntimeout 1 skipping 2\nkey plays\n", log.out.items);
}

test "a timed-out wait releases the buttons held across it, whichever order the tape lets go" {
    const ops = [_]Tape.Op{
        .{ .at = 0, .do = .{ .keyframe = 0 } },
        .{ .at = 0, .do = .{ .press = .left } },
        .{ .at = 10, .do = .{ .wait = .{ .until = .{ .shown = "never" }, .timeout = 10 } } },
        .{ .at = 20, .do = .{ .press = .right } },
        .{ .at = 30, .do = .{ .release = .right } },
        .{ .at = 40, .do = .{ .release = .left } },
    };
    const tape: Tape = .{ .name = "t", .ops = &ops, .keyframes = &test_keyframes };
    var log: Log = .{};
    defer log.deinit();
    var seq: Sequencer = .init(&tape);
    while (!seq.done()) _ = seq.advance(std.math.inf(f64), 30, log.sink());
    try testing.expectEqualStrings(
        "keyframe demo://a\npress left\ntimeout 2 skipping 2\nrelease left\n",
        log.out.items,
    );
    try testing.expectEqual(@as(usize, 0), seq.pressed.count());
}

test "a move to a target never drawn skips the chapter, so no press lands off target" {
    const ops = [_]Tape.Op{
        .{ .at = 0, .do = .{ .keyframe = 0 } },
        .{ .at = 0, .ms = 100, .do = .{ .move = .{ .tag = "missing" } } },
        .{ .at = 100, .do = .{ .press = .left } },
        .{ .at = 150, .do = .{ .release = .left } },
        .{ .at = 500, .do = .{ .key = "plays" } },
    };
    const chapters = [_]Tape.Chapter{ .{ .at = 0, .title = "one" }, .{ .at = 500, .title = "two" } };
    const tape: Tape = .{ .name = "t", .ops = &ops, .keyframes = &test_keyframes, .chapters = &chapters };
    var log: Log = .{};
    defer log.deinit();
    var seq: Sequencer = .init(&tape);
    while (!seq.done()) _ = seq.advance(std.math.inf(f64), 30, log.sink());
    try testing.expectEqualStrings(
        "keyframe demo://a\nmove 0,0\nmissing missing 1 skipping 2\nkey plays\n",
        log.out.items,
    );
}

test "rewinding to a keyframe and replaying fast lands where live play did" {
    const ops = [_]Tape.Op{
        .{ .at = 0, .do = .{ .keyframe = 0 } },
        .{ .at = 0, .ms = 300, .do = .{ .move = .{ .tag = "field" } } },
        .{ .at = 300, .do = .{ .press = .left } },
        .{ .at = 380, .do = .{ .release = .left } },
        .{ .at = 400, .ms = 600, .do = .{ .type = "hello" } },
        .{ .at = 1200, .do = .{ .keyframe = 1 } },
        .{ .at = 1300, .ms = 400, .do = .{ .type = "world" } },
    };
    const tape: Tape = .{ .name = "t", .ops = &ops, .keyframes = &test_keyframes };
    try tape.validate(.{});

    var live: Log = .{};
    defer live.deinit();
    try live.tags.put(testing.allocator, "field", .{ .x = 50, .y = 60 });
    var seq: Sequencer = .init(&tape);
    playTo(&seq, 1100, 16, live.sink());

    // Rewind from past the second keyframe back into the first scene, then replay fast.
    playTo(&seq, 1500, 16, live.sink());
    var replay: Log = .{};
    defer replay.deinit();
    try replay.tags.put(testing.allocator, "field", .{ .x = 50, .y = 60 });
    seq.rewind(tape.keyframeBefore(1100));
    var frames: usize = 0;
    while (seq.advance(1100, 16, replay.sink()) != .reached) frames += 1;

    // Same effects: a keyframe, the pointer on the field, a click, the whole word typed — a
    // keystroke at a time even though it all lands in one frame.
    const landed = try landings(replay.out.items);
    defer testing.allocator.free(landed);
    try testing.expectEqualStrings(
        \\keyframe demo://a
        \\move 50,60
        \\press left
        \\release left
        \\text h
        \\text e
        \\text l
        \\text l
        \\text o
        \\
    , landed);
    try testing.expectEqual(@as(usize, 5), frames);
    try testing.expectEqual(@as(f64, 1100), seq.now);
    try testing.expectEqual(@as(f32, 50), seq.pointer.x);
}

test "carrying something, the pointer goes where the target settled; with nothing held, it follows" {
    const ops = [_]Tape.Op{
        .{ .at = 0, .do = .{ .keyframe = 0 } },
        .{ .at = 0, .ms = 300, .do = .{ .move = .{ .tag = "slot" } } },
        .{ .at = 300, .do = .{ .press = .left } },
        .{ .at = 320, .ms = 300, .do = .{ .move = .{ .tag = "slot" } } },
        .{ .at = 620, .do = .{ .release = .left } },
    };
    const tape: Tape = .{ .name = "t", .ops = &ops, .keyframes = &test_keyframes };
    var log: Log = .{};
    defer log.deinit();
    try log.tags.put(testing.allocator, "slot", .{ .x = 100, .y = 10 });
    var seq: Sequencer = .init(&tape);
    // Free, the glide follows the slot where it moves to.
    playTo(&seq, 100, 16, log.sink());
    try log.tags.put(testing.allocator, "slot", .{ .x = 400, .y = 10 });
    playTo(&seq, 310, 16, log.sink());
    try testing.expectEqual(@as(f32, 400), seq.pointer.x);
    // Carried, the slot moving out from under the pointer (room made for what it carries) leaves
    // the glide going where it first saw it.
    try log.tags.put(testing.allocator, "slot", .{ .x = 700, .y = 10 });
    playTo(&seq, 400, 16, log.sink());
    try log.tags.put(testing.allocator, "slot", .{ .x = 100, .y = 10 });
    playTo(&seq, 700, 16, log.sink());
    try testing.expectEqual(@as(f32, 700), seq.pointer.x);
    try testing.expectEqual(@as(usize, 0), seq.pressed.count());
}

test "replaying, a carried glide takes a frame per step of its path" {
    const ops = [_]Tape.Op{
        .{ .at = 0, .do = .{ .keyframe = 0 } },
        .{ .at = 0, .do = .{ .press = .left } },
        .{ .at = 0, .ms = 160, .do = .{ .move = .{ .x = 1, .y = 0 } } },
        .{ .at = 160, .do = .{ .release = .left } },
    };
    const tape: Tape = .{ .name = "t", .ops = &ops, .keyframes = &test_keyframes };
    var log: Log = .{};
    defer log.deinit();
    var seq: Sequencer = .init(&tape);
    seq.replaying = true;
    var frames: usize = 0;
    while (seq.advance(1000, 16, log.sink()) != .reached) frames += 1;
    // The keyframe, the press, a frame per 16 ms step of the glide, its end, the release.
    try testing.expect(frames >= 160 / 16);
    try testing.expectEqual(@as(f32, 1000), seq.pointer.x);
}

test "a seek into the middle of a span leaves it part done, to finish live" {
    const ops = [_]Tape.Op{
        .{ .at = 0, .do = .{ .keyframe = 0 } },
        .{ .at = 0, .ms = 1000, .do = .{ .type = "abcdefghij" } },
    };
    const tape: Tape = .{ .name = "t", .ops = &ops, .keyframes = &test_keyframes };
    var log: Log = .{};
    defer log.deinit();
    var seq: Sequencer = .init(&tape);
    while (seq.advance(500, 16, log.sink()) != .reached) {}
    try testing.expect(seq.typing != null);
    const sent = seq.typing.?.sent;
    try testing.expect(sent > 0 and sent < 10);
    playTo(&seq, 1000, 16, log.sink());
    try testing.expect(seq.done());
}

test "the pointer bows on its way and arrives exactly" {
    const a: Point = .{ .x = 0, .y = 0 };
    const b: Point = .{ .x = 400, .y = 0 };
    try testing.expectEqual(a, glidePoint(a, b, 0));
    try testing.expectEqual(b.x, glidePoint(a, b, 1).x);
    try testing.expectApproxEqAbs(@as(f32, 0), glidePoint(a, b, 1).y, 0.001);
    try testing.expect(@abs(glidePoint(a, b, 0.5).y) > 1);
}

test "a trace runs ruled: on the line between, evenly" {
    const a: Point = .{ .x = 0, .y = 0 };
    const b: Point = .{ .x = 400, .y = 0 };
    const op: Tape.Op = .{ .at = 0, .ms = 100, .do = .{ .trace = .{} } };
    try testing.expectEqual(@as(f32, 0), pathPoint(op, a, b, 0.5).y);
    try testing.expectEqual(@as(f32, 100), pathPoint(op, a, b, 0.25).x);
}

test "speed notches snap and nudge to the ends" {
    const tape: Tape = .{ .name = "t", .ops = &.{} };
    var seq = Sequencer.init(&tape);
    seq.setSpeed(1.4);
    try testing.expectEqual(@as(usize, 3), seq.speedIndex());
    seq.nudgeSpeed(-1);
    try testing.expectEqual(@as(f32, 1), seq.speed);
    seq.nudgeSpeed(100);
    try testing.expectEqual(@as(f32, 4), seq.speed);
    seq.nudgeSpeed(-100);
    try testing.expectEqual(@as(f32, 0.5), seq.speed);
}

test "speed is clamped, steps through its notches and divides demo time" {
    const tape: Tape = .{ .name = "t", .ops = &.{} };
    var seq = Sequencer.init(&tape);
    try testing.expectEqual(@as(f32, 1), seq.speed);
    seq.setSpeed(0.1);
    try testing.expectEqual(min_speed, seq.speed);
    seq.setSpeed(40);
    try testing.expectEqual(max_speed, seq.speed);

    // Every notch: a frame of wall time reaches `speed` times as much demo time.
    for (speeds) |sp| {
        seq.setSpeed(sp);
        try testing.expectEqual(sp, seq.speed);
        seq.now = 100;
        try testing.expectEqual(100 + 16 * @as(f64, sp), seq.playUntil(16));
    }

    // The transport steps through them in order and wraps to the slowest.
    seq.setSpeed(min_speed);
    for (speeds[1..]) |sp| {
        seq.stepSpeed();
        try testing.expectEqual(sp, seq.speed);
    }
    seq.stepSpeed();
    try testing.expectEqual(speeds[0], seq.speed);
}

test "a rewind and seek land on the same moment at every speed" {
    const ops = [_]Tape.Op{
        .{ .at = 0, .do = .{ .keyframe = 0 } },
        .{ .at = 0, .ms = 100, .do = .{ .move = .{ .tag = "ok" } } },
        .{ .at = 100, .do = .{ .press = .left } },
        .{ .at = 150, .do = .{ .release = .left } },
    };
    const tape: Tape = .{ .name = "t", .ops = &ops, .keyframes = &test_keyframes };

    var expected: ?[]u8 = null;
    defer if (expected) |e| testing.allocator.free(e);
    for (speeds) |sp| {
        var log: Log = .{};
        defer log.deinit();
        try log.tags.put(testing.allocator, "ok", .{ .x = 100, .y = 0 });

        var seq: Sequencer = .init(&tape);
        seq.setSpeed(sp);
        // Play on a way, then go back and replay to a moment, as a seek does.
        _ = seq.advance(seq.playUntil(40), 40, log.sink());
        seq.rewind(0);
        log.out.clearRetainingCapacity();
        seq.replaying = true;
        while (seq.advance(120, 0, log.sink()) != .reached) {}
        try testing.expectEqual(@as(f64, 120), seq.now);
        const landed = try landings(log.out.items);
        if (expected) |e| {
            defer testing.allocator.free(landed);
            try testing.expectEqualStrings(e, landed);
        } else expected = landed;
    }
}
