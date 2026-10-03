//! Plays a `Tape` into the running app — the dvui half of automation.
//!
//! The player is the `Sequencer`'s sink: a glide becomes mouse motion, a press a button event, a
//! key a key down and up, all added to dvui's event list exactly where a backend adds the real
//! ones, so every widget, keybind and plugin handles them as it handles a person. Nothing in the
//! app is told a demo is playing; that is the point — the demo shows the real app doing real work.
//!
//! An app calls `frame` once at the very start of its frame, before anything reads
//! `dvui.events()` (it also tells widgets whether to publish their anchors, `core.anchor`, and the
//! frame whether it is seen, `core.FrameTarget.setUnseen`), and
//! `overlay.draw` at the end, after everything else has drawn; and it runs its whole frame
//! function through `frames`, which is what makes a seek silent. Between frames it drives the
//! transport: `load`, `play`, `pause`, `seek`, `unload`.
//!
//! **Seeking** is `Tape.keyframeBefore` + `Sequencer.rewind` + replaying to the moment with the
//! stage told to skip animation (`Stage.fastForward`). The replay costs a frame per op the app
//! has to see land (a click, a key, a keyframe), and those frames are *silent*: `frames` runs the
//! app's frame again and again inside one displayed frame, ending each unseen, until the seek
//! arrives or a budget of wall time (`budget_ns`) is spent. A seek across a demo-sized tape lands
//! in the frame it was asked for; a longer one carries on in the next. Where the backend can drop
//! a frame's drawing (an `unseen` switch, `core.FrameTarget.setUnseen`) the silent frames draw
//! nothing, and one more run, drawn, ends the displayed frame — on a phone, drawing each in full
//! had the GPU doing many frames' work per frame shown.
//!
//! **Snapshots** make the way back short. While the tape drives, at calm moments — nothing in
//! flight, nothing held, the app idle — the player asks the stage for the app's model
//! (`Stage.capture`): once a scene has settled after its keyframe, at every chapter, and every
//! `snapshot_every_ms` of demo time. A seek back goes to the nearest one before the moment and
//! replays only from there, the app put back in place (`Stage.restore`) rather than cut to its
//! keyframe and reloaded; a stage that cannot restore from where it is says so and the seek
//! cuts to the keyframe as before. Each keeps a fingerprint of the model, and a replay that
//! reaches its moment again compares (`mismatches`): a tape that does not replay exactly is
//! caught, not carried. The scrubber seeks as it is dragged, not only when let go, and with a
//! snapshot every few seconds a move lands in the frame it was made.
//!
//! **The app's clock** follows the demo while it catches up: each silent frame begins at the
//! demo moment of the next thing the tape does (`Sequencer.nextAt`), counted from where the
//! displayed frame left off, so a press and its release are as far apart, and timers and
//! debounces fire, as they did live. That puts the app's clock ahead of the wall, by `ahead_ns`,
//! and the backend's clock is moved on by as much (`frames`' `clock`) so dvui's stays monotonic
//! and continuous after. The player's own chrome (the transport bar) runs on the wall (`wallNs`).
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
const Tape = @import("tape").Tape;
const Sequencer = @import("tape").Sequencer;
const Stage = @import("Stage.zig");
const chord = @import("../keymap/chord.zig");
const dvui_adapter = @import("../keymap/dvui_adapter.zig");

const log = std.log.scoped(.automation);

stage: Stage,
gpa: std.mem.Allocator,
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
/// Wall time one displayed frame may spend on silent frames while a seek catches up (`frames`).
budget_ns: i128 = 8 * std.time.ns_per_ms,
/// How far the app's clock is ahead of the wall: the demo time silent frames covered that the
/// wall did not (see the file comment). Never goes down: dvui's clock may not run backwards.
ahead_ns: i128 = 0,
/// The frame running now is one of `frames`' catch-up runs (after the first): its clock step is
/// demo time, not the wall's.
catching_up: bool = false,
/// The run `frames` ends a catch-up with: drawn, though the seek may still be in flight.
showing: bool = false,
/// The run going now draws nothing (`frame`, `core.FrameTarget.setUnseen`): a seek is catching up
/// in it, and a later run of the same displayed frame is the one shown. Never on a backend that
/// draws every run.
run_unseen: bool = false,
/// The displayed frame's wall time, which `wallNs` keeps to through its catch-up runs.
shown_wall_ns: i128 = 0,
/// The seek in flight, or the last one: how long it took to land, for logs, tests and the
/// benchmark.
seek_stats: SeekStats = .{},
/// Snapshots taken while the demo played, in tape order: where a seek back goes instead of the
/// keyframe (see the file comment). Freed when the demo unloads.
snapshots: std.ArrayListUnmanaged(Snapshot) = .empty,
/// Demo time between snapshots, at most.
snapshot_every_ms: f64 = 3000,
/// The snapshot a seek is going back to, put back at the start of the next frame — a seek can
/// be asked for mid-frame (a command), and the app is put back before anything draws.
restore_pending: ?usize = null,
/// The pending seek is forward on the tape's own state: should no snapshot restore, it carries on
/// from here rather than going back to the keyframe.
restore_forward: bool = false,
/// The op a snapshot's fingerprint was last compared at, so a moment is checked once a pass.
checked_cursor: ?usize = null,
/// Replays that did not reach the model a snapshot holds (`Stage.fingerprint`): the tape does
/// not replay exactly. Logged as they happen; tests read it.
mismatches: u32 = 0,
/// Whether letting go of the scrubber plays or stays paused: as it was when it was taken.
scrub_after: After = .pause,
/// The demo time the scrubber last sought to while held.
scrubbed_to: ?f64 = null,
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

pub const Snapshot = struct {
    /// The sequencer's place, calm (`Sequencer.calm`): the next op, the demo time, the pointer.
    cursor: usize,
    at: f64,
    pointer: Sequencer.Point,
    /// The keyframe op its scene began with (`Tape.keyframeBefore`).
    scene: usize,
    /// The stage's (`Stage.capture`).
    state: *anyopaque,
    /// `Stage.fingerprint` when it was taken.
    print: ?u64,
};

pub const SeekStats = struct {
    /// The snapshot the seek went back to, or null for a keyframe or none.
    restored: ?usize = null,
    /// Displayed frames from the seek to its arrival, the one it was asked in included.
    shown: u32 = 0,
    /// Frames run unseen in that time.
    silent: u32 = 0,
    /// Wall time from the seek to its arrival, ns. Zero while it is in flight.
    wall_ns: i128 = 0,
    /// Wall time when it was asked for (`wallClock`).
    started_ns: i128 = 0,
};

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
    /// The demo time the scrubber is held at while a viewer drags it; the player seeks there as
    /// it moves (`frame`), and once more when it is let go.
    scrub: ?f64 = null,
    /// The real pointer, physical, as last seen.
    pointer: ?dvui.Point.Physical = null,
    /// When the real pointer last moved over the app (ns, `wallNs`): the bar shows for a while
    /// after, then gets out of the demo's way.
    stirred_ns: ?i128 = null,
    /// The bar opening (`wanted`) or closing, since `since_ns` (`wallNs`), and how open it was
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

pub fn init(gpa: std.mem.Allocator, stage: Stage) Player {
    return .{ .gpa = gpa, .stage = stage };
}

pub fn deinit(self: *Player) void {
    self.unload();
}

pub fn tape(self: *const Player) ?*const Tape {
    return if (self.owned) |*o| &o.tape else null;
}

/// The frame's time on the wall (`dvui.frameTimeNS` less what silent frames skipped; in a
/// catch-up run, the displayed frame's): for what answers the viewer rather than the demo — the
/// transport bar's linger and its opening.
pub fn wallNs(self: *const Player) i128 {
    if (self.catching_up) return self.shown_wall_ns;
    return dvui.frameTimeNS() - self.ahead_ns;
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
    self.seq = .init(t);
    const win = dvui.windowRectPixels();
    self.seq.pointer = .{ .x = win.x + win.w / 2, .y = win.y + win.h / 2 };
    self.diverged = false;
    self.transport = .{};
    self.mismatches = 0;
    self.stage.begin(t);
    self.seekTo(0, if (opts.autoplay) .play else .pause);
}

/// Stop and let go of the demo; the stage gives the user their session back.
pub fn unload(self: *Player) void {
    if (self.owned == null) return;
    self.releaseHeld();
    if (self.state == .seeking) self.stage.fastForward(false);
    self.dropSnapshots();
    self.stage.end();
    self.owned.?.deinit();
    self.owned = null;
    self.state = .idle;
    self.last_press = null;
    self.transport = .{};
    if (dvui.current_window != null) dvui.refresh(null, @src(), null);
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
    // cutting to it beats replaying everything up to it. Anything else goes back.
    const forward = !self.diverged and t >= self.seq.now and kf < self.seq.cursor;
    self.restore_pending = null;
    // Back to the nearest snapshot before the moment, in its scene — or, forward, to one further
    // on than here. Put back at the start of the next frame (`restore_pending`).
    const snap = self.nearestSnapshot(t, kf);
    if (snap != null and (!forward or self.snapshots.items[snap.?].at > self.seq.now)) {
        self.restore_pending = snap;
        self.restore_forward = forward;
    } else if (!forward) {
        self.rewind(kf);
    }
    self.seek_from = self.seq.now;
    self.seek_target = t;
    self.after_seek = after;
    self.seek_stats = .{ .started_ns = self.wallClock(dvui.currentWindow()) };
    if (self.state != .seeking) self.stage.fastForward(true);
    self.state = .seeking;
    dvui.refresh(null, @src(), null);
}

fn arrive(self: *Player) void {
    self.stage.fastForward(false);
    const st = &self.seek_stats;
    st.wall_ns = @max(1, self.wallClock(dvui.currentWindow()) - st.started_ns);
    // Asked for and landed within one run of a displayed frame (`frames` counts the frames a
    // seek is still in flight at): that frame is shown.
    st.shown = @max(st.shown, 1);
    log.debug("seek to {d:.0} ms from {s} {d} landed in {d} shown + {d} silent frames, {d:.1} ms", .{
        self.seek_target,
        if (st.restored != null) "snapshot" else "the tape at",
        if (st.restored) |i| @as(f64, @floatFromInt(i)) else self.seek_from,
        st.shown,
        st.silent,
        @as(f64, @floatFromInt(st.wall_ns)) / std.time.ns_per_ms,
    });
    self.state = switch (self.after_seek) {
        .play => .playing,
        .pause => .paused,
    };
}

/// Back to the keyframe op `kf`, to replay from there.
fn rewind(self: *Player, kf: usize) void {
    self.releaseHeld();
    self.seq.rewind(kf);
    self.last_press = null;
    self.diverged = false;
    self.checked_cursor = null;
}

/// Put the app back to snapshot `i` and the sequencer to its moment. False when the stage cannot
/// from where the app is now.
fn restoreSnapshot(self: *Player, i: usize) bool {
    const s = self.snapshots.items[i];
    self.releaseHeld();
    if (!self.stage.restore(s.state)) return false;
    self.seq.restoreTo(s.cursor, s.at, s.pointer);
    self.last_press = null;
    self.diverged = false;
    // The moment is checked again: a restore is a replay too.
    self.checked_cursor = null;
    self.seek_from = s.at;
    self.seek_stats.restored = i;
    return true;
}

/// Put the app back to the latest snapshot from `first` down, in its scene, that the stage can
/// restore where the app is now — one taken before a document was opened, when that document
/// has since been closed again, say. None: a forward seek carries on from where the tape is, any
/// other goes back to the keyframe.
fn goBack(self: *Player, first: usize) void {
    const scene = self.snapshots.items[first].scene;
    var i = first + 1;
    while (i > 0) {
        i -= 1;
        const s = self.snapshots.items[i];
        if (s.scene != scene) break;
        // Forward, a snapshot no further on than the tape already is gains nothing.
        if (self.restore_forward and s.at <= self.seq.now) break;
        if (self.restoreSnapshot(i)) return;
    }
    if (!self.restore_forward) {
        self.rewind(self.tape().?.keyframeBefore(self.seek_target));
        self.seek_from = self.seq.now;
    }
}

/// The latest snapshot at or before demo time `t` in the scene of keyframe op `kf`.
fn nearestSnapshot(self: *const Player, t: f64, kf: usize) ?usize {
    var i = self.snapshots.items.len;
    while (i > 0) {
        i -= 1;
        const s = self.snapshots.items[i];
        if (s.at <= t and s.scene == kf) return i;
    }
    return null;
}

/// At a calm moment while the tape drives, take a snapshot if one is due — or, where one was
/// taken on an earlier pass, check the replay reached the same model.
fn keepSnapshot(self: *Player) void {
    if (!self.stage.snapshots()) return;
    const t = self.tape() orelse return;
    if (self.seq.cursor == 0 or !self.seq.calm() or self.held.count() > 0) return;
    if (!self.stage.idle()) return;
    const cursor = self.seq.cursor;
    var at: usize = self.snapshots.items.len;
    for (self.snapshots.items, 0..) |s, i| {
        if (s.cursor == cursor) {
            if (self.checked_cursor != cursor) {
                self.checked_cursor = cursor;
                self.verify(s);
            }
            return;
        }
        if (s.cursor > cursor) {
            at = i;
            break;
        }
    }
    const scene = t.keyframeBefore(self.seq.now);
    if (!self.snapshotDue(t, scene, at)) return;
    const state = self.stage.capture() orelse return;
    self.snapshots.insert(self.gpa, at, .{
        .cursor = cursor,
        .at = self.seq.now,
        .pointer = self.seq.pointer,
        .scene = scene,
        .state = state,
        .print = self.stage.fingerprint(),
    }) catch {
        self.stage.release(state);
        return;
    };
    self.checked_cursor = cursor;
}

/// Whether a snapshot is due now, the one before it in the list at `before - 1`: the first of
/// its scene, a chapter begun since the last, or `snapshot_every_ms` gone by.
fn snapshotDue(self: *const Player, t: *const Tape, scene: usize, before: usize) bool {
    if (before == 0) return true;
    const last = self.snapshots.items[before - 1];
    if (last.scene != scene) return true;
    if (self.seq.now - last.at >= self.snapshot_every_ms) return true;
    for (t.chapters) |c| {
        const at: f64 = @floatFromInt(c.at);
        if (at > last.at and at <= self.seq.now) return true;
    }
    return false;
}

fn verify(self: *Player, s: Snapshot) void {
    const want = s.print orelse return;
    const got = self.stage.fingerprint() orelse return;
    if (got == want) return;
    self.mismatches += 1;
    const name = if (self.tape()) |t| t.name else "?";
    log.warn("demo '{s}': replaying to {d:.0} ms did not reach what playing did — the tape does not replay exactly", .{ name, s.at });
}

fn dropSnapshots(self: *Player) void {
    for (self.snapshots.items) |s| self.stage.release(s.state);
    self.snapshots.clearAndFree(self.gpa);
    self.restore_pending = null;
    self.checked_cursor = null;
}

/// Once a frame, before anything reads `dvui.events()` (and before anything that asks whether the
/// frame is seen, `core.FrameTarget.unseen`): let the transport and the interrupt rule see real
/// input, then advance the tape and add its input after the real.
pub fn frame(self: *Player) void {
    // Whether this run is seen, once the seek it asks for (or lands) is known: a run while a seek
    // catches up draws nothing, but the one `frames` ends it with.
    defer self.run_unseen = core.FrameTarget.setUnseen((self.state == .seeking or self.catching_up) and !self.showing);
    // Widgets name themselves for the tape only while one is loaded (`core.anchor`).
    core.anchor.publish(self.owned != null);
    if (self.owned == null) return;
    self.takeRealInput();
    if (self.owned == null) return; // the bar's close button
    self.claimCursor();

    // The scrubber held and moved: there, now, rather than when it is let go.
    if (self.transport.scrub) |t| {
        if (self.scrubbed_to == null or @abs(t - self.scrubbed_to.?) >= 1) {
            self.scrubbed_to = t;
            self.seekTo(t, .pause);
        }
    }
    if (self.restore_pending) |i| {
        self.restore_pending = null;
        if (self.state == .seeking) self.goBack(i);
    }
    if (self.state == .playing or self.state == .seeking) self.keepSnapshot();

    // Clamped: the first frame after a pause can report however long the app slept. A catch-up
    // run's step is demo time, and no wall time passed for a wait to count.
    const wall_ms: f64 = if (self.catching_up) 0 else @min(dvui.secondsSinceLastFrame() * 1000, 100);
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

/// Run the app's frame function, `frame_fn`, as the player needs it: once, as it is — and while
/// a seek is catching up, again and again inside the same displayed frame, each run ended
/// unseen (`Window.end` without presenting) and the next begun, until the seek arrives or
/// `budget_ns` of wall time is spent. Where the backend has an `unseen` switch
/// (`core.FrameTarget.setUnseen`), every run of the catch-up draws nothing — the first too, when
/// the seek began in it (`frame`) — and one more run, drawn, is the one shown; elsewhere each
/// draws over the last, and the last is shown.
/// The app calls this from inside its frame function, in place of the frame itself: dvui has
/// begun the frame and will end and present it, as ever.
///
/// Each silent run begins at the demo moment of what it is about to do (see the file comment).
/// `clock` is the backend's clock offset, which its `nanoTime` adds to the wall (fizzy's
/// backends have one, `clock_ahead_ns`; `backendClock` finds it): it is moved on by however far
/// the runs took the app's clock past the wall — and, a seek still in flight, to the moment it
/// goes on from — so the next frame carries on from there. Without one a silent run steps the
/// clock the least dvui accepts, a microsecond, and timers wait for the wall.
pub fn frames(self: *Player, win: *dvui.Window, frame_fn: *const fn () anyerror!dvui.App.Result, clock: ?*i128) anyerror!dvui.App.Result {
    // Counted before the run, which may land the seek, and after it, which may have asked for one.
    const was_seeking = self.state == .seeking;
    if (was_seeking) self.seek_stats.shown += 1;
    self.showing = false;
    var res = try frame_fn();
    // The first run began in a seek and drew nothing (`frame`): the frame ends with one that draws.
    const show_last = self.run_unseen;
    if (self.state != .seeking and !show_last) return res;
    if (!was_seeking) self.seek_stats.shown += 1;
    const start = win.backend.nanoTime();
    defer self.catching_up = false;
    // Demo time onto the app's clock, from where the displayed frame left them.
    const base_ns = win.frame_time_ns;
    const base_ms = self.seq.now;
    self.shown_wall_ns = self.wallNs();
    // A wait holding the seek up is the app catching up too — files loading, a document opening
    // — and the app does that a frame at a time, so it runs on through waits: only the budget
    // stops it. (Waits time out on the wall, which only displayed frames count.)
    while (res == .ok and self.state == .seeking) {
        if (win.backend.nanoTime() - start >= self.budget_ns) break;
        _ = try win.end(.{ .manage_backend = false });
        try win.begin(self.runAt(win, clock, base_ns, base_ms));
        self.catching_up = true;
        self.seek_stats.silent += 1;
        res = try frame_fn();
    }
    // The frame shown: where the catch-up got to — the moment the seek landed on, or as far as the
    // budget went. Every run before it drew nothing, so it draws on a clean window, and the frame
    // target still holds the last frame shown for it to read.
    if (res == .ok and show_last) {
        _ = try win.end(.{ .manage_backend = false });
        try win.begin(self.runAt(win, clock, base_ns, base_ms));
        self.catching_up = true;
        self.showing = true;
        res = try frame_fn();
    }
    if (clock) |c| {
        var next_ns = win.frame_time_ns;
        if (self.state == .seeking) next_ns = @max(next_ns, base_ns + msToNs(self.nextMoment() - base_ms));
        const lead = next_ns - win.backend.nanoTime();
        if (lead > 0) {
            self.ahead_ns += lead;
            c.* = self.ahead_ns;
        }
    }
    return res;
}

/// When the next run of a displayed frame begins on the app's clock: at the demo moment of what it
/// is about to do while a seek is in flight (see the file comment), else just after the last.
fn runAt(self: *const Player, win: *dvui.Window, clock: ?*i128, base_ns: i128, base_ms: f64) i128 {
    const soonest = win.frame_time_ns + std.time.ns_per_us;
    if (clock == null or self.state != .seeking) return soonest;
    return @max(soonest, base_ns + msToNs(self.nextMoment() - base_ms));
}

/// Wall time since the seek in flight was asked for, ns. Only valid while seeking.
pub fn seekingNs(self: *const Player) i128 {
    return self.wallClock(dvui.currentWindow()) - self.seek_stats.started_ns;
}

/// The demo moment a catch-up goes on from: the next thing the tape does, or the seek's end.
fn nextMoment(self: *const Player) f64 {
    return @min(self.seek_target, self.seq.nextAt());
}

fn msToNs(ms: f64) i128 {
    return @intFromFloat(@max(0, ms) * std.time.ns_per_ms);
}

/// The backend's clock less what `frames` moved it on by: the wall, for timing the player itself.
fn wallClock(self: *const Player, win: *dvui.Window) i128 {
    return win.backend.nanoTime() - self.ahead_ns;
}

/// The backend's clock offset, if it has one (`frames`): a `clock_ahead_ns` its `nanoTime` adds.
pub fn backendClock(win: *dvui.Window) ?*i128 {
    const impl = win.backend.impl;
    if (@hasField(@TypeOf(impl.*), "clock_ahead_ns")) return &impl.clock_ahead_ns;
    return null;
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
        if (me.p.y > win.y + win.h * 0.7) tr.stirred_ns = self.wallNs();
    }
    if (tr.scrub != null) {
        switch (me.action) {
            .motion => tr.scrub = tr.timeAt(me.p.x, self.duration()),
            .release => {
                const to = tr.scrub.?;
                tr.scrub = null;
                self.scrubbed_to = null;
                self.seekTo(to, self.scrub_after);
            },
            else => {},
        }
        e.handle(@src(), wd);
        return true;
    }
    const bar = tr.bar orelse return false;
    if (!bar.contains(me.p)) return false;
    tr.stirred_ns = self.wallNs();
    if (me.action == .press and me.button.pointer()) {
        if (tr.play.contains(me.p)) {
            self.toggle();
        } else if (tr.track.contains(me.p)) {
            tr.scrub = tr.timeAt(me.p.x, self.duration());
            self.scrub_after = if (self.state == .playing or (self.state == .seeking and self.after_seek == .play)) .play else .pause;
            self.scrubbed_to = null;
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

/// The real pointer's cursor, asked for before any widget can (dvui keeps a frame's first request):
/// a hand over the bar's controls and an arrow over the rest of it, rather than whatever lies under
/// the bar (a split's resize arrows); an arrow while the tape owns the pointer, rather than
/// whatever the tape's pointer is over.
fn claimCursor(self: *Player) void {
    const tr = &self.transport;
    if (tr.scrub != null) return dvui.cursorSet(.hand);
    if (tr.pointer) |p| {
        if (tr.bar) |bar| {
            if (bar.contains(p)) {
                for ([_]dvui.Rect.Physical{ tr.play, tr.prev, tr.next, tr.track, tr.close }) |r| {
                    if (r.contains(p)) return dvui.cursorSet(.hand);
                }
                return dvui.cursorSet(.arrow);
            }
        }
    }
    if (self.state == .playing or self.state == .seeking) dvui.cursorSet(.arrow);
}

/// Put dvui's pointer back where the tape has it, if anything real moved it.
fn holdPointer(self: *Player) void {
    const cw = dvui.currentWindow();
    const p = self.seq.pointer;
    if (cw.mouse_pt.x == p.x and cw.mouse_pt.y == p.y) return;
    _ = cw.addEventMouseMotion(.{ .pt = .{ .x = p.x, .y = p.y } }) catch {};
}

fn releaseHeld(self: *Player) void {
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

/// The tape's spelling of a chord is the keymap's (`check`): `mod` is ⌘ on a Mac and Ctrl
/// elsewhere, and a two-stroke chord is pressed a stroke at a time.
fn key(_: *anyopaque, spelled: []const u8) void {
    // `check` passed it at load; a tape that skipped that loses the key.
    const stroke = chord.parseKeys(spelled, platform()) catch return;
    pressChord(stroke.first);
    if (stroke.second) |second| pressChord(second);
}

fn platform() chord.Platform {
    return if (core.platform.isMacOS()) .mac else .other;
}

/// What the player checks a tape against (`Tape.Check`): its key chords in the keymap's spelling.
pub const check: Tape.Check = .{ .key = struct {
    fn ok(spelled: []const u8) bool {
        _ = chord.parseKeys(spelled, .other) catch return false;
        return true;
    }
}.ok };

fn pressChord(c: chord.Chord) void {
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

/// How much of the tape's pointer shows at the current moment (`Tape.pointerShown`): away while
/// the tape types, back when it moves.
pub fn pointerShown(self: *const Player, fade_ms: f64) f32 {
    const t = self.tape() orelse return 1;
    return t.pointerShown(self.seq.cursor, self.seq.now, fade_ms);
}
