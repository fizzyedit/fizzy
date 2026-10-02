//! Plays a `Tape` into the running app — the dvui half of automation.
//!
//! The player is the `Sequencer`'s sink: a glide becomes mouse motion, a press a button event, a
//! key a key down and up, all added to dvui's event list exactly where a backend adds the real
//! ones, so every widget, keybind and plugin handles them as it handles a person. Nothing in the
//! app is told a demo is playing; that is the point — the demo shows the real app doing real work.
//!
//! An app calls `frame` once at the very start of its frame, before anything reads
//! `dvui.events()` (it also tells widgets whether to publish their anchors, `core.anchor`), and
//! `overlay.draw` at the end, after everything else has drawn. Between frames
//! it drives the transport: `load`, `play`, `pause`, `seek`, `unload`.
//!
//! **Rewind** is `Tape.keyframeBefore` + `Sequencer.rewind` + replaying to the moment with the
//! stage told to skip animation (`Stage.fastForward`): a frame per op, not per millisecond, so a
//! seek costs a second or so of frames and shows as a quick replay rather than a blank.
//!
//! **Interruption**: while playing, a real click, tap, scroll or key pauses the demo — a pointer
//! event goes on to do what the person meant, the first key is only taken as "stop". Real pointer
//! motion is held off (the tape owns the pointer while it plays). Anything real that reaches the app
//! while paused marks the app `diverged` from the tape; resuming then replays to the paused moment
//! first, so the demo carries on from its own state, not from whatever the person left behind.
const Player = @This();

const std = @import("std");
const dvui = @import("dvui");
const core = @import("core");
const Tape = @import("Tape.zig");
const Sequencer = @import("Sequencer.zig");
const Stage = @import("Stage.zig");
const chord = @import("../keymap/chord.zig");
const dvui_adapter = @import("../keymap/dvui_adapter.zig");

stage: Stage,
/// The loaded demo, owned. Null when nothing is loaded.
owned: ?Tape.Owned = null,
seq: Sequencer = undefined,
state: State = .idle,
/// What a seek turns into when it arrives.
after_seek: After = .pause,
seek_target: f64 = 0,
/// Where the seek replays from, for the overlay's progress.
seek_from: f64 = 0,
/// Demo time per wall time while playing.
rate: f32 = 1,
/// Real input reached the app since the tape last put it in a known state.
diverged: bool = false,
/// Buttons the tape is holding down — released before a rewind or a pause, so a drag cut short
/// does not leave a widget holding the mouse.
held: std.EnumSet(Tape.Button) = .initEmpty(),
/// The last press the tape made, for the overlay's ripple.
last_press: ?Press = null,
transport: Transport = .{},

pub const State = enum {
    /// Nothing loaded.
    idle,
    playing,
    paused,
    /// Replaying fast to `seek_target`; becomes `after_seek` when it gets there.
    seeking,
    /// Paused at the end; `play` starts over.
    ended,
};

pub const After = enum { play, pause };

pub const Press = struct {
    at: f64,
    pt: Sequencer.Point,
};

/// The bar a viewer drives the demo with. The overlay draws it and records where its parts went;
/// `frame` hit-tests real pointer events against those rects before anything else sees them.
pub const Transport = struct {
    /// Where the bar was drawn last frame, physical. Null when it was not drawn.
    bar: ?dvui.Rect.Physical = null,
    play: dvui.Rect.Physical = .{},
    prev: dvui.Rect.Physical = .{},
    next: dvui.Rect.Physical = .{},
    track: dvui.Rect.Physical = .{},
    close: dvui.Rect.Physical = .{},
    /// The demo time the scrubber is held at while a viewer drags it. The seek happens on release.
    scrub: ?f64 = null,
    /// The real pointer, physical, as last seen.
    pointer: ?dvui.Point.Physical = null,
    /// When the real pointer last moved over the app (ns, frame time): the bar shows for a while
    /// after, then gets out of the demo's way.
    stirred_ns: ?i128 = null,
    /// The bar opening (`wanted`) or closing, since `since_ns` (frame time), and how open it was
    /// last frame — kept by the overlay, which opens and closes it as a floating surface does.
    wanted: bool = false,
    since_ns: ?i128 = null,
    openness: f32 = 0,

    /// The demo time under physical x on the track.
    pub fn timeAt(self: Transport, x: f32, total_ms: u32) f64 {
        if (self.track.w <= 0) return 0;
        const f = std.math.clamp((x - self.track.x) / self.track.w, 0, 1);
        return f * @as(f64, @floatFromInt(total_ms));
    }
};

pub fn init(stage: Stage) Player {
    return .{ .stage = stage };
}

pub fn deinit(self: *Player) void {
    self.unload();
}

pub fn tape(self: *const Player) ?*const Tape {
    return if (self.owned) |*o| &o.tape else null;
}

/// The demo time to show: the scrubber's while it is held, else the sequencer's.
pub fn now(self: *const Player) f64 {
    if (self.transport.scrub) |t| return t;
    return if (self.state == .seeking) self.seek_target else self.seq.now;
}

pub fn duration(self: *const Player) u32 {
    return if (self.tape()) |t| t.duration() else 0;
}

/// Whether the tape, not a person, is what the app's pointer and keys are doing right now.
pub fn driving(self: *const Player) bool {
    return switch (self.state) {
        .playing, .seeking => true,
        .paused, .ended => !self.diverged,
        .idle => false,
    };
}

pub const LoadOptions = struct {
    autoplay: bool = true,
};

/// Take ownership of a tape and cut to its start — the stage sets the user's session aside first.
pub fn load(self: *Player, owned: Tape.Owned, opts: LoadOptions) void {
    self.unload();
    self.owned = owned;
    const t = &self.owned.?.tape;
    self.seq = .init(t, if (core.platform.isMacOS()) .mac else .other);
    const win = dvui.windowRectPixels();
    self.seq.pointer = .{ .x = win.x + win.w / 2, .y = win.y + win.h / 2 };
    self.diverged = false;
    self.transport = .{};
    self.stage.begin(t);
    self.seekTo(0, if (opts.autoplay) .play else .pause);
}

/// Stop and let go of the demo; the stage gives the user their session back.
pub fn unload(self: *Player) void {
    if (self.owned == null) return;
    self.releaseHeld();
    if (self.state == .seeking) self.stage.fastForward(false);
    self.stage.end();
    self.owned.?.deinit();
    self.owned = null;
    self.state = .idle;
    self.last_press = null;
    self.transport = .{};
    dvui.refresh(null, @src(), null);
}

pub fn play(self: *Player) void {
    switch (self.state) {
        .paused => if (self.diverged) self.seekTo(self.seq.now, .play) else {
            self.state = .playing;
        },
        .ended => self.seekTo(0, .play),
        .seeking => self.after_seek = .play,
        .playing, .idle => {},
    }
    dvui.refresh(null, @src(), null);
}

pub fn pause(self: *Player) void {
    switch (self.state) {
        .playing => {
            self.state = .paused;
            // A drag cut short is dropped where it is — which the tape did not do.
            if (self.held.count() > 0) {
                self.releaseHeld();
                self.diverged = true;
            }
        },
        .seeking => self.after_seek = .pause,
        .paused, .ended, .idle => {},
    }
    dvui.refresh(null, @src(), null);
}

pub fn toggle(self: *Player) void {
    switch (self.state) {
        .playing => self.pause(),
        .seeking => if (self.after_seek == .play) self.pause() else self.play(),
        else => self.play(),
    }
}

/// Jump to demo time `t` (ms), keeping whether it was playing.
pub fn seek(self: *Player, t: f64) void {
    const after: After = switch (self.state) {
        .playing => .play,
        .seeking => self.after_seek,
        else => .pause,
    };
    self.seekTo(t, after);
}

/// Jump to the start of the chapter `delta` away from the current one (-1 is "this chapter
/// again, or the one before if it only just started").
pub fn stepChapter(self: *Player, delta: i32) void {
    const t = self.tape() orelse return;
    if (t.chapters.len == 0) return self.seek(if (delta < 0) 0 else @floatFromInt(self.duration()));
    const at = self.now();
    var i: i32 = @intCast(t.chapterAt(at) orelse 0);
    // "Previous" from well into a chapter means its own start, as a music player does.
    if (delta < 0 and at - @as(f64, @floatFromInt(t.chapters[@intCast(i)].at)) > 1500) i += 1;
    i = std.math.clamp(i + delta, 0, @as(i32, @intCast(t.chapters.len)) - 1);
    self.seek(@floatFromInt(t.chapters[@intCast(i)].at));
}

fn seekTo(self: *Player, t_in: f64, after: After) void {
    const t_ptr = self.tape() orelse return;
    const t = std.math.clamp(t_in, 0, @as(f64, @floatFromInt(t_ptr.duration())));
    const kf = t_ptr.keyframeBefore(t);
    // Forward on the tape's own state can simply carry on — unless a keyframe lies ahead, when
    // cutting to it beats replaying everything up to it. Anything else rewinds.
    if (self.diverged or t < self.seq.now or kf >= self.seq.cursor) {
        self.releaseHeld();
        self.seq.rewind(kf);
        self.last_press = null;
        self.diverged = false;
    }
    self.seek_from = self.seq.now;
    self.seek_target = t;
    self.after_seek = after;
    if (self.state != .seeking) self.stage.fastForward(true);
    self.state = .seeking;
    dvui.refresh(null, @src(), null);
}

fn arrive(self: *Player) void {
    self.stage.fastForward(false);
    self.state = switch (self.after_seek) {
        .play => .playing,
        .pause => .paused,
    };
}

/// Once a frame, before anything reads `dvui.events()`: let the transport and the interrupt rule
/// see real input, then advance the tape and add its input after the real.
pub fn frame(self: *Player) void {
    // Widgets name themselves for the tape only while one is loaded (`core.anchor`).
    core.anchor.publish(self.owned != null);
    if (self.owned == null) return;
    self.takeRealInput();
    if (self.owned == null) return; // the bar's close button

    // Clamped: the first frame after a pause can report however long the app slept.
    const wall_ms: f64 = @min(dvui.secondsSinceLastFrame() * 1000, 100);
    switch (self.state) {
        .playing => {
            self.holdPointer();
            _ = self.seq.advance(self.seq.now + wall_ms * self.rate, wall_ms, self.sink());
            if (self.seq.done() and self.seq.now >= @as(f64, @floatFromInt(self.duration()))) self.state = .ended;
        },
        .seeking => {
            self.holdPointer();
            if (self.seq.advance(self.seek_target, wall_ms, self.sink()) == .reached) self.arrive();
        },
        .paused, .ended, .idle => return,
    }
    dvui.refresh(null, @src(), null);
}

/// Real events, before any widget sees them: the bar's, then the interrupt rule.
fn takeRealInput(self: *Player) void {
    const wd = dvui.currentWindow().data();
    for (dvui.events()) |*e| {
        if (e.handled) continue;
        switch (e.evt) {
            .mouse => |me| {
                if (me.action == .position) continue;
                if (self.transportTakes(e, me)) continue;
                switch (self.state) {
                    .playing => switch (me.action) {
                        // The tape owns the pointer while it plays.
                        .motion => e.handle(@src(), wd),
                        .focus, .press, .wheel_x, .wheel_y => {
                            self.pause();
                            self.diverged = true;
                        },
                        .release, .position => {},
                    },
                    // A replay in progress takes nothing from anyone.
                    .seeking => e.handle(@src(), wd),
                    .paused, .ended => switch (me.action) {
                        .focus, .press, .wheel_x, .wheel_y => self.diverged = true,
                        else => {},
                    },
                    .idle => {},
                }
            },
            .key, .text => switch (self.state) {
                .playing => {
                    e.handle(@src(), wd);
                    self.pause();
                },
                .seeking => e.handle(@src(), wd),
                .paused, .ended => self.diverged = true,
                .idle => {},
            },
            .window, .app => {},
        }
    }
}

/// Whether a real pointer event belongs to the transport bar; if so it is handled here.
fn transportTakes(self: *Player, e: *dvui.Event, me: dvui.Event.Mouse) bool {
    const wd = dvui.currentWindow().data();
    const tr = &self.transport;
    if (me.action == .motion or me.action == .press) {
        tr.pointer = me.p;
        // Stirring near the bottom of the window brings the bar back while playing.
        const win = dvui.windowRectPixels();
        if (me.p.y > win.y + win.h * 0.7) tr.stirred_ns = dvui.frameTimeNS();
    }
    if (tr.scrub != null) {
        switch (me.action) {
            .motion => tr.scrub = tr.timeAt(me.p.x, self.duration()),
            .release => {
                const to = tr.scrub.?;
                tr.scrub = null;
                self.seek(to);
            },
            else => {},
        }
        e.handle(@src(), wd);
        return true;
    }
    const bar = tr.bar orelse return false;
    if (!bar.contains(me.p)) return false;
    tr.stirred_ns = dvui.frameTimeNS();
    if (me.action == .press and me.button.pointer()) {
        if (tr.play.contains(me.p)) {
            self.toggle();
        } else if (tr.track.contains(me.p)) {
            tr.scrub = tr.timeAt(me.p.x, self.duration());
        } else if (tr.prev.contains(me.p)) {
            self.stepChapter(-1);
        } else if (tr.next.contains(me.p)) {
            self.stepChapter(1);
        } else if (tr.close.contains(me.p)) {
            e.handle(@src(), wd);
            self.unload();
            return true;
        }
    }
    e.handle(@src(), wd);
    return true;
}

/// Put dvui's pointer back where the tape has it, if anything real moved it.
fn holdPointer(self: *Player) void {
    const cw = dvui.currentWindow();
    const p = self.seq.pointer;
    if (cw.mouse_pt.x == p.x and cw.mouse_pt.y == p.y) return;
    _ = cw.addEventMouseMotion(.{ .pt = .{ .x = p.x, .y = p.y } }) catch {};
}

fn releaseHeld(self: *Player) void {
    var it = self.held.iterator();
    while (it.next()) |b| {
        _ = dvui.currentWindow().addEventMouseButton(dvuiButton(b), .release) catch {};
    }
    self.held = .initEmpty();
}

// ---- the sink: tape input as dvui events ---------------------------------------------------

fn sink(self: *Player) Sequencer.Sink {
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

fn from(ctx: *anyopaque) *Player {
    return @ptrCast(@alignCast(ctx));
}

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

fn locate(_: *anyopaque, target: Tape.Target) ?Sequencer.Point {
    return targetPoint(target);
}

fn moveTo(_: *anyopaque, pt: Sequencer.Point) void {
    _ = dvui.currentWindow().addEventMouseMotion(.{ .pt = .{ .x = pt.x, .y = pt.y } }) catch {};
}

fn dvuiButton(b: Tape.Button) dvui.enums.Button {
    return switch (b) {
        .left => .left,
        .right => .right,
        .middle => .middle,
    };
}

fn button(ctx: *anyopaque, b: Tape.Button, down: bool) void {
    const self = from(ctx);
    _ = dvui.currentWindow().addEventMouseButton(dvuiButton(b), if (down) .press else .release) catch {};
    if (down) {
        self.held.insert(b);
        self.last_press = .{ .at = self.seq.now, .pt = self.seq.pointer };
    } else {
        self.held.remove(b);
    }
}

fn scroll(_: *anyopaque, by: Tape.Scroll) void {
    const cw = dvui.currentWindow();
    if (by.y != 0) _ = cw.addEventMouseWheel(by.y, .vertical, .mouse) catch {};
    if (by.x != 0) _ = cw.addEventMouseWheel(by.x, .horizontal, .mouse) catch {};
}

fn dvuiMod(m: chord.Mods) dvui.enums.Mod {
    var bits: u16 = 0;
    if (m.ctrl) bits |= @intFromEnum(dvui.enums.Mod.lcontrol);
    if (m.shift) bits |= @intFromEnum(dvui.enums.Mod.lshift);
    if (m.alt) bits |= @intFromEnum(dvui.enums.Mod.lalt);
    if (m.command) bits |= @intFromEnum(dvui.enums.Mod.lcommand);
    return @enumFromInt(bits);
}

fn key(_: *anyopaque, c: chord.Chord) void {
    const cw = dvui.currentWindow();
    const code = dvui_adapter.toDvuiKey(c.key);
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

fn text(_: *anyopaque, bytes: []const u8) void {
    _ = dvui.currentWindow().addEventText(.{ .text = bytes }) catch {};
}

fn command(ctx: *anyopaque, id: []const u8) void {
    from(ctx).stage.command(id);
}

fn keyframe(ctx: *anyopaque, kf: *const Tape.Keyframe) void {
    const self = from(ctx);
    self.releaseHeld();
    self.last_press = null;
    self.stage.keyframe(kf);
}

fn holds(ctx: *anyopaque, until: Tape.Until) bool {
    return switch (until) {
        .idle => from(ctx).stage.idle(),
        .shown => |tag| if (dvui.tagGet(tag)) |td| td.visible else false,
        .gone => |tag| if (dvui.tagGet(tag)) |td| !td.visible else true,
    };
}

fn timedOut(ctx: *anyopaque, until: Tape.Until) void {
    const name = if (from(ctx).tape()) |t| t.name else "?";
    switch (until) {
        .idle => dvui.log.warn("demo '{s}': gave up waiting for the app to settle", .{name}),
        .shown => |tag| dvui.log.warn("demo '{s}': gave up waiting for '{s}' to be drawn", .{ name, tag }),
        .gone => |tag| dvui.log.warn("demo '{s}': gave up waiting for '{s}' to go", .{ name, tag }),
    }
}

/// What the keystroke display shows at the current moment (`recentKeys`).
pub const Keys = struct {
    /// The latest key or command applied.
    op: Tape.Op,
    /// When the display came up for it: the first of a run of keys each pressed while the one
    /// before was still showing, so a run keeps one display open rather than reopening it per key.
    since: f64,
};

/// The key or command the keystroke display shows at the current moment: the latest one applied
/// in the last `window_ms`. Derived from the tape and the time, so a seek shows the right one.
pub fn recentKeys(self: *const Player, window_ms: f64) ?Keys {
    const t = self.tape() orelse return null;
    const at = self.seq.now;
    var shown: ?Keys = null;
    var i = @min(self.seq.cursor, t.ops.len);
    while (i > 0) {
        i -= 1;
        const op = t.ops[i];
        const op_at: f64 = @floatFromInt(op.at);
        // Past the latest key's window, or past the gap before the run's first.
        if (op_at < (if (shown) |k| k.since else at) - window_ms) break;
        switch (op.do) {
            .key, .command => if (shown) |*k| {
                k.since = op_at;
            } else {
                shown = .{ .op = op, .since = op_at };
            },
            .keyframe => break,
            else => {},
        }
    }
    return shown;
}
