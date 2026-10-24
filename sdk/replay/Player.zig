//! Plays a `Tape` into the running app — the dvui half of automation.
//!
//! The player is the `Sequencer`'s sink: a glide becomes mouse motion, a press a button event, a
//! key a key down and up (`Input`, which a live tape's driver shares), all added to dvui's event
//! list exactly where a backend adds the real ones, so every widget, keybind and plugin handles
//! them as it handles a person; commands, keyframes and waits on the app go to its `Stage`. Nothing
//! in the app is told a demo is playing; that is the point — the demo shows the real app doing
//! real work.
//!
//! An app calls `frame` once at the very start of its frame, before anything reads
//! `dvui.events()` (it also tells widgets whether to publish their anchors, `anchor`, and the
//! frame whether it is seen, `set_unseen`), and
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
//! a frame's drawing (an `unseen` switch, through the app's `set_unseen`) the silent frames draw
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
//! **Closing** always leaves the app as it is (`Stage.keep`), and "Revert to before" (`revert`) is the one way back to the session
//! the demo set aside. `play` after a person changed things carries on from there as a new branch
//! (`branched`) rather than replaying over their work; seeking back is the history.
//!
//! **Interruption**: while playing, a real click, tap, scroll or key pauses the demo — a pointer
//! event goes on to do what the person meant, the first key is only taken as "stop". Real pointer
//! motion is held off (the tape owns the pointer while it plays). Anything real that reaches the app
//! while paused marks the app `diverged` from the tape.
const Player = @This();

const std = @import("std");
const dvui = @import("dvui");
const Tape = @import("tape").Tape;
const Sequencer = @import("tape").Sequencer;
const Stage = @import("Stage.zig");
const Input = @import("Input.zig");
const anchor = @import("anchor.zig");

const log = std.log.scoped(.automation);

stage: Stage,
gpa: std.mem.Allocator,
/// Mark the frame running as one nobody will see, or not, and say whether it is unseen now — for
/// an app whose backend can drop what such a frame draws (fizzy's `core.FrameTarget.setUnseen`).
/// Null: every frame draws, and a seek's silent frames draw over each other.
set_unseen: ?*const fn (on: bool) bool = null,
/// The loaded demo, owned. Null when nothing is loaded.
owned: ?Tape.Owned = null,
seq: Sequencer = undefined,
state: State = .idle,
/// What a seek turns into when it arrives.
after_seek: After = .pause,
seek_target: f64 = 0,
/// Where the seek replays from, for the overlay's progress.
seek_from: f64 = 0,
/// Real input reached the app since the tape last put it in a known state.
diverged: bool = false,
/// The tape went on from a state the person had changed (`play` after a divergence) rather than
/// replaying over it: a new branch. What it does is no longer the tape's own history, so no
/// snapshot is taken of it or checked against it. A seek back into the history (`restoreSnapshot`,
/// `rewind`) is the way out.
branched: bool = false,
/// How the bar's close ends the demo, decided when it was pressed (`close`, `revert`).
leave: Leave = .keep,
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
/// The run going now draws nothing (`frame`, `set_unseen`): a seek is catching up
/// in it, and a later run of the same displayed frame is the one shown. Never on a backend that
/// draws every run.
run_unseen: bool = false,
/// The displayed frame's wall time, which `wallNs` keeps to through its catch-up runs.
shown_wall_ns: i128 = 0,
/// The last displayed frame drove the tape, so the app has been drawing since: the time to this
/// one is a frame's, however slow, not however long the demo sat paused (`frame`).
live: bool = false,
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
/// A rewind let go of held buttons (`letGo`): the next run lets the release land, and cuts after.
cut_waits: bool = false,
/// Put back from a snapshot, the app is still settling and no op lands yet (`restoreSnapshot`).
settling: ?Settling = null,
/// A seek's glide held until its target stops moving (`Sequencer.Sink.VTable.still`): the op, and
/// where its target was the run before.
/// This seek let go of a drag the tape held (`letGo`): forward, it cannot carry on from there.
let_go: bool = false,
aiming: ?struct { op: usize, last: Sequencer.Point, runs: u8 = 0 } = null,
/// The op a snapshot's fingerprint was last compared at, so a moment is checked once a pass.
checked_cursor: ?usize = null,
/// The keyframe op the app's scene began with: set as each keyframe is cut to, and by a restore;
/// null after a rewind, while the app is still wherever the seek began, until the cut. What a
/// snapshot is taken in and checked in (`keepSnapshot`), by the ops applied rather than the time.
scene: ?usize = null,
/// Replays that did not reach the model a snapshot holds (`Stage.fingerprint`): the tape does
/// not replay exactly. Logged as they happen; tests read it.
mismatches: u32 = 0,
/// Waits that gave up since the demo was loaded: what one waited for never came, and the tape
/// carried on regardless. Logged as they happen; tests read it.
timeouts: u32 = 0,
/// Whether letting go of the scrubber plays or stays paused: as it was when it was taken.
scrub_after: After = .pause,
/// The demo time the scrubber last sought to while held.
scrubbed_to: ?f64 = null,
/// The tape's input as dvui events, and the buttons it is holding down — released before a
/// rewind or a pause, so a drag cut short does not leave a widget holding the mouse.
input: Input = .{},
/// The last press the tape made, for the overlay's ripple.
last_press: ?Press = null,
transport: Transport = .{},

/// The app put back from a snapshot, settling before the tape goes on (`restoreSnapshot`).
pub const Settling = struct {
    /// The anchor the tape last moved the pointer onto: the pointer goes back onto it once it
    /// has stopped moving. Null: the tape had not moved the pointer in the scene yet.
    target: ?Tape.Target,
    /// Where the target was in the run before, to tell when it has stopped moving.
    last: ?Sequencer.Point = null,
    runs: u8 = 0,

    /// The most runs the app gets to settle. A target never seen in them leaves the pointer
    /// where it was, as a glide does.
    pub const max_runs = 8;
};

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
    /// "Revert to before", while the overlay shows it (`drawRevert`); empty otherwise.
    revert: dvui.Rect.Physical = .{},
    /// The tab on the bar that sends it into where it rests (`tucked`).
    tab: dvui.Rect.Physical = .{},
    /// Where the bar rests was drawn last frame (fizzy: corner glass in the window's own corner),
    /// physical, as far round it as the pointer is on it: what the bar hides into, and a press
    /// there brings it back. Null when it was not drawn.
    rest: ?dvui.Rect.Physical = null,
    /// Sent into where it rests (its tab): the bar stays there, playing or not, until that brings it
    /// back (a press here, the pointer held on it in the overlay).
    tucked: bool = false,
    /// The speed slider, label and line (`Sequencer.speed`), whose notches are `Sequencer.speeds`.
    speed: dvui.Rect.Physical = .{},
    /// The slider's line alone, where a press lands on a notch.
    speed_line: dvui.Rect.Physical = .{},
    /// A viewer is dragging the slider's knob.
    speed_drag: bool = false,
    /// The slider took the last press: the arrow keys, Home and End move its notch (and
    /// do not pause the demo) until a press lands elsewhere.
    speed_focus: bool = false,
    /// The demo time the scrubber is held at while a viewer drags it; the player seeks there as
    /// it moves (`frame`), and once more when it is let go.
    scrub: ?f64 = null,
    /// The real pointer, physical, as last seen.
    pointer: ?dvui.Point.Physical = null,
    /// Where an app shows parts of its frame in OS windows of their own (a dialog's, a menu's) over
    /// the window the bar is in, those windows' rects last frame, physical: the app's to set. The
    /// bar is drawn under them, so a press there is theirs, not the bar's.
    covered: [8]dvui.Rect.Physical = undefined,
    /// Each of `covered` as it lies over the main window's frame, physical: where the OS window is
    /// on screen, which a caption in the main window keeps clear of.
    covered_main: [8]dvui.Rect.Physical = undefined,
    covered_n: u8 = 0,
    /// When the real pointer was last on the bar, or its rest brought it (ns, `wallNs`): while
    /// playing, the bar shows for a while after, then goes back to rest.
    stirred_ns: ?i128 = null,
    /// The bar opening (`wanted`) or closing, since `since_ns` (`wallNs`), and how open it was
    /// last frame — kept by the overlay, which opens and closes it as a floating surface does.
    wanted: bool = false,
    since_ns: ?i128 = null,
    openness: f32 = 0,
    /// Closed from its own close button (`Player.close`): the bar runs its pieces back together
    /// and goes, and the demo is let go only once it has (`shut`).
    closing: bool = false,
    /// Shut, having been closing — the overlay's word to `frame` that the demo can go now.
    shut: bool = false,

    /// The notch of `Sequencer.speeds` nearest physical x on the speed line.
    pub fn speedAt(self: Transport, x: f32) usize {
        if (self.speed_line.w <= 0) return 0;
        const f = std.math.clamp((x - self.speed_line.x) / self.speed_line.w, 0, 1);
        return @intFromFloat(@round(f * @as(f32, Sequencer.speeds.len - 1)));
    }

    /// Let go of a speed drag (and the slider's key focus) that can no longer be answered: the
    /// bar is gone, closing or tucked away, so nothing under the pointer is the slider.
    pub fn dropStaleDrag(self: *Transport) void {
        if (self.bar == null or self.closing or self.tucked) {
            self.speed_drag = false;
            self.speed_focus = false;
        }
    }

    /// The demo time under physical x on the track.
    pub fn timeAt(self: Transport, x: f32, total_ms: u32) f64 {
        if (self.track.w <= 0) return 0;
        const f = std.math.clamp((x - self.track.x) / self.track.w, 0, 1);
        return f * @as(f64, @floatFromInt(total_ms));
    }
};

/// The longest a frame may take and still count as one while the tape drives (`frame`): longer,
/// and the app was not drawing at all.
pub const max_frame_ms: f64 = 1000;

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

/// How a demo is let go of: `keep` leaves the app as the tape and the person have it; `revert`
/// gives the person back the session the demo set aside.
pub const Leave = enum { keep, revert };

pub const LoadOptions = struct {
    autoplay: bool = true,
};

/// Take ownership of a tape and cut to its start — the stage sets the user's session aside first.
pub fn load(self: *Player, owned: Tape.Owned, opts: LoadOptions) void {
    self.unload();
    self.owned = owned;
    const t = &self.owned.?.tape;
    self.seq = .init(t);
    self.scene = null;
    const win = dvui.windowRectPixels();
    self.seq.pointer = .{ .x = win.x + win.w / 2, .y = win.y + win.h / 2 };
    self.diverged = false;
    self.branched = false;
    self.transport = .{};
    self.mismatches = 0;
    self.timeouts = 0;
    self.stage.begin(t);
    self.seekTo(0, if (opts.autoplay) .play else .pause);
}

/// Close the demo from its bar: the bar runs its pieces back together and goes, as it does when it
/// gets out of the way of a playing demo, and only then is the demo let go (`frame` → `release`).
/// Unloaded at once, the bar vanished under the pointer that closed it. Paused meanwhile, where
/// it is. A bar not showing has nothing to close: the demo goes at once. The demo stops where
/// it is and the app stays as it is, always; `revert` is the way back.
pub fn close(self: *Player) void {
    self.dismiss(.keep);
}

/// Close the demo from its bar and give the person the session it set aside (`Leave.revert`).
pub fn revert(self: *Player) void {
    self.dismiss(.revert);
}

/// Stop at once and keep the app as it is, as `close` does: the command's way, with no bar to run back.
pub fn stop(self: *Player) void {
    self.release(.keep);
}

fn dismiss(self: *Player, how: Leave) void {
    self.leave = how;
    if (self.transport.openness <= 0.001) return self.release(how);
    self.pause();
    self.transport.closing = true;
    dvui.refresh(null, @src(), null);
}

/// Stop and let go of the demo; the stage gives the user their session back.
pub fn unload(self: *Player) void {
    self.release(.revert);
}

fn release(self: *Player, how: Leave) void {
    if (self.owned == null) return;
    self.input.releaseHeld();
    if (self.state == .seeking) self.stage.fastForward(false);
    self.dropSnapshots();
    switch (how) {
        .keep => self.stage.keep(),
        .revert => self.stage.end(),
    }
    self.owned.?.deinit();
    self.owned = null;
    self.state = .idle;
    self.scene = null;
    self.cut_waits = false;
    self.settling = null;
    self.live = false;
    self.last_press = null;
    self.diverged = false;
    self.branched = false;
    self.transport = .{};
    if (dvui.current_window != null) dvui.refresh(null, @src(), null);
}

pub fn play(self: *Player) void {
    switch (self.state) {
        // Carrying on from what the person did is a new branch: the tape's own history up to here
        // stays to be rewound to, and is not replayed over their work.
        .paused => {
            if (self.diverged) {
                self.diverged = false;
                self.branched = true;
            }
            self.state = .playing;
        },
        // A restart: the tape's first keyframe replaces whatever is on screen, so nothing of a
        // person's is left to branch from (`seekTo` clears `diverged` as it cuts).
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
            if (self.input.held.count() > 0) {
                self.input.releaseHeld();
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
    self.aiming = null;
    self.let_go = false;
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
    if (self.letGo()) self.cut_waits = true;
    self.settling = null;
    self.aiming = null;
    self.seq.rewind(kf);
    self.scene = null;
    self.last_press = null;
    self.diverged = false;
    self.branched = false;
    self.checked_cursor = null;
}

/// Let go of the buttons the tape holds, ahead of a cut (a rewind, a restore), and say whether it
/// held any. dvui hands a release to what the press was on, which takes it as a click, so the cut
/// waits a run (`cut_waits`) for the release to land on the app it belongs to: let go after a
/// restore, it acted on the app put back, and a tree row held mid-click opened a file the
/// snapshot never had.
fn letGo(self: *Player) bool {
    if (self.input.held.count() == 0) return false;
    self.input.releaseHeld();
    // A drag the tape had under way is dropped where it is: the app is not where the tape is
    // until a cut puts it somewhere the tape has been (`goBack`).
    self.let_go = true;
    return true;
}

/// Put the app back to snapshot `i` and the sequencer to its moment. False when the stage cannot
/// from where the app is now.
fn restoreSnapshot(self: *Player, i: usize) bool {
    const s = self.snapshots.items[i];
    if (!self.stage.restore(s.state)) return false;
    self.seq.restoreTo(s.cursor, s.at, s.pointer);
    self.aiming = null;
    self.scene = s.scene;
    // The pointer is kept in pixels, and they are only where the tape left it in the layout the
    // snapshot was taken in. The app put back takes a few runs to get there — a sidebar the
    // restore shut eases away, even with motion off, and the document beside it moves over — and
    // a press at the old pixels, or at where the anchor was drawn mid-way, went into the sidebar
    // or onto the wrong line. So no op lands until what the pointer was last sent to has stopped
    // moving, and the pointer goes back onto it there: a tape aims at anchors, never at pixels.
    self.settling = .{ .target = null };
    const ops = self.tape().?.ops;
    var op = s.cursor;
    while (op > s.scene) {
        op -= 1;
        switch (ops[op].do) {
            .move, .trace => |target| {
                self.settling.?.target = target;
                break;
            },
            else => {},
        }
    }
    self.last_press = null;
    self.diverged = false;
    self.branched = false;
    // The moment is checked again: a restore is a replay too.
    self.checked_cursor = null;
    self.seek_from = s.at;
    self.seek_stats.restored = i;
    return true;
}

/// A run of the app settling after a restore (`settling`): true while it still is, and no op may
/// land.
fn settle(self: *Player) bool {
    const st = &(self.settling orelse return false);
    st.runs += 1;
    const pt = if (st.target) |t| Input.targetPoint(self.stage, t) else null;
    const still = if (st.target == null) true else if (pt != null and st.last != null)
        pt.?.x == st.last.?.x and pt.?.y == st.last.?.y
    else
        false;
    if (!still and st.runs < Settling.max_runs) {
        st.last = pt;
        return true;
    }
    if (pt) |p| self.seq.pointer = p;
    self.settling = null;
    return false;
}

/// Put the app back to the latest snapshot from `first` down, in its scene, that the stage can
/// restore where the app is now — one taken before a document was opened, when that document
/// has since been closed again, say. None: a forward seek carries on from where the tape is, any
/// other goes back to the keyframe. True when a snapshot was put back.
fn goBack(self: *Player, first: usize) bool {
    const scene = self.snapshots.items[first].scene;
    var i = first + 1;
    while (i > 0) {
        i -= 1;
        const s = self.snapshots.items[i];
        if (s.scene != scene) break;
        // Forward, a snapshot no further on than the tape already is gains nothing.
        if (self.restore_forward and s.at <= self.seq.now) break;
        if (self.restoreSnapshot(i)) return true;
    }
    // Forward, it carries on from where the tape is, unless the app has left it: let go of mid-drag
    // ahead of a restore that then could not be made, say.
    if (!self.restore_forward or self.let_go) {
        self.rewind(self.tape().?.keyframeBefore(self.seek_target));
        self.seek_from = self.seq.now;
    }
    return false;
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
    if (!self.stage.snapshots() or self.branched) return;
    const t = self.tape() orelse return;
    if (self.seq.cursor == 0 or !self.seq.calm() or self.input.held.count() > 0) return;
    if (!self.stage.idle()) return;
    const cursor = self.seq.cursor;
    // After a rewind, until the keyframe is cut to, the app is in no scene of the tape: the last
    // moment before the keyframe shares the keyframe op's cursor, and the app is still wherever
    // the seek began, so nothing here is at that moment.
    const scene = self.scene orelse return;
    var at: usize = self.snapshots.items.len;
    for (self.snapshots.items, 0..) |s, i| {
        if (s.cursor == cursor) {
            if (s.scene != scene) return;
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
/// frame is seen, `set_unseen`): let the transport and the interrupt rule see real
/// input, then advance the tape and add its input after the real.
pub fn frame(self: *Player) void {
    // Whether this run is seen, once the seek it asks for (or lands) is known: a run while a seek
    // catches up draws nothing, but the one `frames` ends it with.
    defer self.run_unseen = if (self.set_unseen) |set| set((self.state == .seeking or self.catching_up) and !self.showing) else false;
    if (self.owned == null) return;
    // Widgets name themselves for the tape while one is loaded (`anchor`).
    anchor.want();
    // The bar has closed itself shut (`close`): the demo goes now.
    if (self.transport.shut) return self.release(self.leave);
    self.takeRealInput();
    if (self.owned == null) return; // the bar's close button, with no bar showing
    self.claimCursor();

    // The scrubber held and moved: there, now, rather than when it is let go.
    if (self.transport.scrub) |t| {
        if (self.scrubbed_to == null or @abs(t - self.scrubbed_to.?) >= 1) {
            self.scrubbed_to = t;
            self.seekTo(t, .pause);
        }
    }
    // Put back from a snapshot this run: a cut, as a keyframe is, which the app draws before the
    // next op lands on it. dvui sends a press to the floating window under it as the last frame
    // drew them, and that frame was drawn for wherever the app was when the seek was asked: a
    // palette still open over the rail took the tape's first click.
    // A run that cuts — or lets go ahead of a cut (`letGo`) — applies no ops, and neither takes
    // a snapshot nor checks one: the app is not at a moment of the tape until it has drawn.
    var cut = false;
    if (self.cut_waits) {
        self.cut_waits = false;
        cut = true;
    } else if (self.restore_pending) |i| {
        if (self.letGo()) {
            cut = true;
        } else {
            self.restore_pending = null;
            if (self.state == .seeking) cut = self.goBack(i);
        }
    }
    if (!cut and self.state == .seeking) cut = self.settle();
    if (!cut and (self.state == .playing or self.state == .seeking)) self.keepSnapshot();

    // While the tape drives, a frame's wall time is all demo time, however slow the frame: a
    // browser that slows to a few frames a second plays the demo at its pace, choppily, rather
    // than in slow motion — a card meant to show for eight seconds up for a minute. Only waits
    // slow a demo down. Clamped: the first frame after it stopped driving, which can report
    // however long the demo sat paused, and a frame past `max_frame_ms`, the app not drawing at
    // all (a hidden tab draws nothing). A catch-up run's step is demo time, and no wall time
    // passed for a wait to count.
    const since_ms = dvui.secondsSinceLastFrame() * 1000;
    const wall_ms: f64 = if (self.catching_up) 0 else @min(since_ms, if (self.live) max_frame_ms else 100);
    if (!self.catching_up) self.live = self.state == .playing or self.state == .seeking;
    switch (self.state) {
        .playing => {
            Input.holdPointer(self.seq.pointer);
            self.seq.replaying = false;
            _ = self.seq.advance(self.seq.playUntil(wall_ms), wall_ms, self.sink());
            if (self.seq.done() and self.seq.now >= @as(f64, @floatFromInt(self.duration()))) self.state = .ended;
        },
        .seeking => {
            Input.holdPointer(self.seq.pointer);
            self.seq.replaying = true;
            if (!cut and self.seq.advance(self.seek_target, wall_ms, self.sink()) == .reached) self.arrive();
        },
        .paused, .ended, .idle => return,
    }
    dvui.refresh(null, @src(), null);
}

/// Run the app's frame function, `frame_fn`, as the player needs it: once, as it is — and while
/// a seek is catching up, again and again inside the same displayed frame, each run ended
/// unseen (`Window.end` without presenting) and the next begun, until the seek arrives or
/// `budget_ns` of wall time is spent. Where the backend has an `unseen` switch
/// (`set_unseen`), every run of the catch-up draws nothing — the first too, when
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
    // Waiting on a glide's target to stop moving (`targetStill`), a run is a frame of motion where
    // the backend's clock can be moved on: on a microsecond's clock, a place sliding open would
    // never move between runs, and look still.
    const soonest = win.frame_time_ns + if (self.aiming != null and clock != null) msToNs(Sequencer.path_step_ms) else std.time.ns_per_us;
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
/// dvui's testing backend has none, and needs none: `dvui.testing.step` begins each frame a fixed
/// step after the last frame's time, not on a wall, so its clock carries on from wherever the
/// catch-up runs took it. It gets an offset no one reads, so a seek under test runs on demo time
/// as it does on a real backend.
pub fn backendClock(win: *dvui.Window) ?*i128 {
    const impl = win.backend.impl;
    const Impl = @TypeOf(impl.*);
    if (@hasField(Impl, "clock_ahead_ns")) return &impl.clock_ahead_ns;
    if (@hasDecl(Impl, "kind") and Impl.kind == .testing) return &testing_clock;
    return null;
}

/// The offset `backendClock` hands out for dvui's testing backend.
var testing_clock: i128 = 0;

/// Real events, before any widget sees them: the bar's, then the interrupt rule.
fn takeRealInput(self: *Player) void {
    const wd = dvui.currentWindow().data();
    for (dvui.events()) |*e| {
        if (e.handled) continue;
        switch (e.evt) {
            .mouse => |me| {
                if (me.action == .position) continue;
                if (self.transportTakes(e, me)) continue;
                if (me.action == .press) self.transport.speed_focus = false;
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
                        .focus, .press, .wheel_x, .wheel_y => {
                            self.diverged = true;
                        },
                        else => {},
                    },
                    .idle => {},
                }
            },
            .key => |ke| if (self.speedKey(e, ke)) {} else switch (self.state) {
                .playing => {
                    e.handle(@src(), wd);
                    self.pause();
                },
                .seeking => e.handle(@src(), wd),
                .paused, .ended => {
                    self.diverged = true;
                },
                .idle => {},
            },
            .text => switch (self.state) {
                .playing => {
                    e.handle(@src(), wd);
                    self.pause();
                },
                .seeking => e.handle(@src(), wd),
                .paused, .ended => {
                    self.diverged = true;
                },
                .idle => {},
            },
            .window, .app => {},
        }
    }
}

/// A key on the speed slider, while it holds focus or the pointer is on it: the arrows step a
/// notch, Home and End go to the ends, Escape lets go. True when it took the key.
fn speedKey(self: *Player, e: *dvui.Event, ke: dvui.Event.Key) bool {
    const tr = &self.transport;
    const hovered = if (tr.pointer) |p| tr.speed.contains(p) else false;
    if (tr.bar == null or tr.closing or !(tr.speed_focus or hovered)) return false;
    switch (ke.code) {
        .left, .down => if (ke.action != .up) self.seq.nudgeSpeed(-1),
        .right, .up => if (ke.action != .up) self.seq.nudgeSpeed(1),
        .home => if (ke.action != .up) self.seq.setSpeedIndex(0),
        .end => if (ke.action != .up) self.seq.setSpeedIndex(Sequencer.speeds.len - 1),
        .escape => tr.speed_focus = false,
        else => return false,
    }
    e.handle(@src(), dvui.currentWindow().data());
    dvui.refresh(null, @src(), null);
    return true;
}

/// Whether a real pointer event belongs to the transport bar; if so it is handled here.
fn transportTakes(self: *Player, e: *dvui.Event, me: dvui.Event.Mouse) bool {
    const wd = dvui.currentWindow().data();
    const tr = &self.transport;
    if (me.action == .motion or me.action == .press) tr.pointer = me.p;
    tr.dropStaleDrag();
    // A press while dragging means the release was lost (focus left the window).
    if (me.action == .press) tr.speed_drag = false;
    if (tr.speed_drag) {
        switch (me.action) {
            .motion => self.seq.setSpeedIndex(tr.speedAt(me.p.x)),
            .release => tr.speed_drag = false,
            else => {},
        }
        e.handle(@src(), wd);
        return true;
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
    for (tr.covered[0..tr.covered_n]) |r| if (r.contains(me.p)) {
        tr.pointer = null;
        return false;
    };
    // A press where the bar rests brings it out at once, and is not the app's.
    if (tr.rest) |d| if (d.contains(me.p)) {
        if (me.action == .press and me.button.pointer() and !tr.closing) {
            tr.tucked = false;
            tr.stirred_ns = self.wallNs();
            dvui.refresh(null, @src(), null);
        }
        // Its motion goes on to the app (the rest only sits on it); the rest is the bar's.
        if (me.action == .motion) return false;
        e.handle(@src(), wd);
        return true;
    };
    const bar = tr.bar orelse return false;
    const on_tab = tr.tab.contains(me.p);
    if (!bar.contains(me.p) and !on_tab and !tr.revert.contains(me.p)) return false;
    if (!tr.tucked) tr.stirred_ns = self.wallNs();
    // Closing, the bar is on its way out: what is pressed on it on the way does nothing.
    if (tr.closing) {
        e.handle(@src(), wd);
        return true;
    }
    if (me.action == .press and me.button.pointer()) {
        tr.speed_focus = tr.speed.contains(me.p);
        if (on_tab) {
            tr.tucked = true;
            tr.stirred_ns = null;
            dvui.refresh(null, @src(), null);
        } else if (tr.play.contains(me.p)) {
            self.toggle();
        } else if (tr.speed.contains(me.p)) {
            tr.speed_drag = true;
            self.seq.setSpeedIndex(tr.speedAt(me.p.x));
        } else if (tr.track.contains(me.p)) {
            tr.scrub = tr.timeAt(me.p.x, self.duration());
            self.scrub_after = if (self.state == .playing or (self.state == .seeking and self.after_seek == .play)) .play else .pause;
            self.scrubbed_to = null;
        } else if (tr.prev.contains(me.p)) {
            self.stepChapter(-1);
        } else if (tr.next.contains(me.p)) {
            self.stepChapter(1);
        } else if (tr.revert.contains(me.p)) {
            e.handle(@src(), wd);
            self.revert();
            return true;
        } else if (tr.close.contains(me.p)) {
            e.handle(@src(), wd);
            self.close();
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
        if (tr.tab.contains(p) or tr.revert.contains(p)) return dvui.cursorSet(.hand);
        if (tr.rest) |d| if (d.contains(p)) return dvui.cursorSet(.hand);
        if (tr.bar) |bar| {
            if (bar.contains(p)) {
                for ([_]dvui.Rect.Physical{ tr.play, tr.prev, tr.next, tr.track, tr.close, tr.revert }) |r| {
                    if (r.contains(p)) return dvui.cursorSet(.hand);
                }
                return dvui.cursorSet(.arrow);
            }
        }
    }
    if (self.state == .playing or self.state == .seeking) dvui.cursorSet(.arrow);
}

// ---- the sink: tape input as dvui events (`Input`), the rest from the stage --------------------

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
    .step = step,
    .still = targetStill,
};

/// Live, a glide follows its target as it goes; a seek's replay finds it once, so it waits for the
/// target to stop moving first — two runs seeing it in the same place, or `Settling.max_runs`.
fn targetStill(ctx: *anyopaque, target: Tape.Target) bool {
    const self = from(ctx);
    // Untagged, it is the window's own coordinates, which go nowhere.
    if (self.state != .seeking or target.tag.len == 0) return true;
    const pt = Input.targetPoint(self.stage, target) orelse {
        self.aiming = null;
        return true;
    };
    const op = self.seq.cursor;
    if (self.aiming) |*a| if (a.op == op) {
        a.runs += 1;
        if ((a.last.x == pt.x and a.last.y == pt.y) or a.runs >= Settling.max_runs) {
            self.aiming = null;
            return true;
        }
        a.last = pt;
        return false;
    };
    self.aiming = .{ .op = op, .last = pt };
    return false;
}

fn from(ctx: *anyopaque) *Player {
    return @ptrCast(@alignCast(ctx));
}

fn locate(ctx: *anyopaque, target: Tape.Target) ?Sequencer.Point {
    return Input.targetPoint(from(ctx).stage, target);
}

fn moveTo(_: *anyopaque, pt: Sequencer.Point) void {
    Input.moveTo(pt);
}

fn button(ctx: *anyopaque, b: Tape.Button, down: bool) void {
    const self = from(ctx);
    self.input.button(b, down);
    if (down) self.last_press = .{ .at = self.seq.now, .pt = self.seq.pointer };
}

fn scroll(_: *anyopaque, by: Tape.Scroll) void {
    Input.scroll(by);
}

fn key(_: *anyopaque, spelled: []const u8) void {
    Input.key(spelled);
}

fn text(_: *anyopaque, bytes: []const u8) void {
    Input.text(bytes);
}

fn command(ctx: *anyopaque, cmd: Tape.Command) void {
    from(ctx).stage.command(cmd.id, cmd.args);
}

fn step(ctx: *anyopaque, st: Tape.Step, ms: u32) void {
    const self = from(ctx);
    // A seek, or a frame run unseen to catch up, lands it at once.
    self.stage.step(st, if (self.state == .seeking or self.catching_up) 0 else ms);
}

fn keyframe(ctx: *anyopaque, kf: *const Tape.Keyframe) void {
    const self = from(ctx);
    // The op just applied: the sequencer moves its cursor on before it calls here.
    self.scene = self.seq.cursor - 1;
    self.input.releaseHeld();
    self.last_press = null;
    self.stage.keyframe(kf);
}

fn holds(ctx: *anyopaque, until: Tape.Until) bool {
    return Input.tagHolds(from(ctx).stage, until) orelse from(ctx).stage.idle();
}

fn timedOut(ctx: *anyopaque, until: Tape.Until) void {
    from(ctx).timeouts += 1;
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

test "the speed slider snaps to the nearest notch and clamps past its ends" {
    const last = Sequencer.speeds.len - 1;
    const tr: Transport = .{ .speed_line = .{ .x = 100, .y = 0, .w = 60, .h = 10 } };
    try std.testing.expectEqual(@as(usize, 0), tr.speedAt(100));
    try std.testing.expectEqual(@as(usize, 0), tr.speedAt(-50));
    try std.testing.expectEqual(last, tr.speedAt(160));
    try std.testing.expectEqual(last, tr.speedAt(900));
    // The middle of the line is the middle notch; a hair off a notch snaps to it.
    try std.testing.expectEqual(last / 2, tr.speedAt(130));
    const notch = 60.0 / @as(f32, @floatFromInt(last));
    try std.testing.expectEqual(@as(usize, 1), tr.speedAt(100 + notch * 1.2));
    // Without a line there is nothing to land on.
    try std.testing.expectEqual(@as(usize, 0), (Transport{}).speedAt(130));
}

test "a speed drag does not outlive the bar it began on" {
    const bar: dvui.Rect.Physical = .{ .x = 0, .y = 0, .w = 10, .h = 10 };
    var tr: Transport = .{ .bar = bar, .speed_drag = true };
    tr.dropStaleDrag();
    try std.testing.expect(tr.speed_drag);
    tr.closing = true;
    tr.dropStaleDrag();
    try std.testing.expect(!tr.speed_drag);
    tr = .{ .bar = bar, .tucked = true, .speed_drag = true };
    tr.dropStaleDrag();
    try std.testing.expect(!tr.speed_drag);
    tr = .{ .speed_drag = true, .speed_focus = true };
    tr.dropStaleDrag();
    try std.testing.expect(!tr.speed_drag);
    try std.testing.expect(!tr.speed_focus);
}
