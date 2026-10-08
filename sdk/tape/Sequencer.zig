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
/// Where the pointer is, in the sink's coordinates.
pointer: Point = .{},
glide: ?Glide = null,
typing: ?Typing = null,
/// The op at `cursor` is a wait that has not held yet; `held_ms` of wall time spent on it.
holding: bool = false,
held_ms: f64 = 0,

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
        /// A wait gave up. The sink says so where a person will see it.
        timedOut: *const fn (ctx: *anyopaque, until: Tape.Until) void,
    };
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
    if (self.glide) |g| t = @min(t, @as(f64, @floatFromInt(ops[g.op].end())));
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
            sink.vtable.timedOut(sink.ctx, wait.until);
        }
        self.holding = false;
        self.held_ms = 0;
        self.cursor += 1;
        // A wait that gave up yields: whoever plays the tape hears of it before anything after
        // the wait lands, and may stop there (a live tape does) or carry on (a demo does).
        if (gave_up) return .yielded;
    }

    while (true) {
        const next_at: f64 = if (self.cursor < ops.len) @floatFromInt(ops[self.cursor].at) else std.math.inf(f64);
        // Spans run up to the next op's start: anything still in flight then lands before it.
        if (self.advanceSpans(@min(until, next_at), sink)) |p| return p;
        if (next_at > until) {
            self.now = @max(self.now, until);
            return .reached;
        }
        self.finishSpans(sink);
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
            .move => {
                self.glide = .{ .op = self.cursor, .from = self.pointer, .at = self.now };
                self.cursor += 1;
            },
            .type => {
                self.typing = .{ .op = self.cursor };
                self.cursor += 1;
            },
            .keyframe => |i| {
                self.cursor += 1;
                sink.vtable.keyframe(sink.ctx, &self.tape.keyframes[i]);
                return .yielded;
            },
            .press => |b| {
                self.cursor += 1;
                sink.vtable.button(sink.ctx, b, true);
                return .yielded;
            },
            .release => |b| {
                self.cursor += 1;
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
        if (sink.vtable.locate(sink.ctx, op.do.move)) |pt| g.to = pt;
        // A target never seen leaves the pointer where it is rather than flying to the corner.
        const dest = g.to orelse g.from;
        // The frames live play would have drawn between, each a point along the way.
        const end: f64 = @min(to, @as(f64, @floatFromInt(op.end())));
        var t = g.at + path_step_ms;
        while (t < end) : (t += path_step_ms) {
            const pt = glidePoint(g.from, dest, fraction(op, t));
            if (pt.x == self.pointer.x and pt.y == self.pointer.y) continue;
            self.pointer = pt;
            sink.vtable.moveTo(sink.ctx, pt);
        }
        g.at = @max(g.at, to);
        self.pointer = glidePoint(g.from, dest, f);
        sink.vtable.moveTo(sink.ctx, self.pointer);
        if (f >= 1) {
            self.glide = null;
            self.now = @max(self.now, @as(f64, @floatFromInt(op.end())));
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

/// Land whatever is still in flight, as if its time had come.
fn finishSpans(self: *Sequencer, sink: Sink) void {
    if (self.glide) |g| {
        if (sink.vtable.locate(sink.ctx, self.tape.ops[g.op].do.move)) |pt| {
            self.pointer = pt;
            sink.vtable.moveTo(sink.ctx, pt);
        }
        self.glide = null;
    }
    if (self.typing) |ty| {
        const text = self.tape.ops[ty.op].do.type;
        self.deliver(text[ty.sent..], sink);
        self.typing = null;
    }
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

/// The pointer `f` of the way along a glide: eased in and out, on a slight bow rather than a ruled
/// line — a hand moving a mouse swings a little, and a dead-straight constant-speed pointer reads as
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
            .timedOut = timedOut,
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
    fn timedOut(ctx: *anyopaque, _: Tape.Until) void {
        from(ctx).print("timeout", .{});
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
        const comma = std.mem.indexOfScalar(u8, l, ',').?;
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
    // Entering the wait, then 30, 60 and 90 ms held; at 120 it gives up, and yields so whoever
    // plays it hears before the key lands — which it does on the next call.
    try testing.expectEqual(@as(usize, 4), frames);
    try testing.expectEqualStrings("keyframe demo://a\ntimeout\n", log.out.items);
    _ = seq.advance(0, 30, log.sink());
    try testing.expectEqualStrings("keyframe demo://a\ntimeout\nkey mod+s\n", log.out.items);
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
