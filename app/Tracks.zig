//! A track per open document: its history with the time put back in (`plans/RECORDING_PLAN.md`).
//!
//! The host's recorder (`sdk.Host.Recorder`): owners report each step as it happens
//! (`sdk.Step`), and a track keeps it with the moment it came, beside the document's state when
//! the track began (`base`) and every so often since (`checkpoints`), so any moment of it can be
//! put back into a document: the nearest state, then the steps after it (`replayInto`).
//!
//! **Nothing runs on a clock.** A step costs an append, when it comes. Taking a document's state
//! is never done while an edit is half applied (the owner reports a step from inside its edit):
//! a track asks for one, and the next frame takes it at its top (`tick`), before anything draws.
//! A frame with nothing asked of it returns at once, and a sleeping app does nothing at all.
//!
//! **What it costs.** A base per open document that records steps, as `captureDocumentState`
//! makes it, the steps' bytes, and the checkpoints, in memory for the session (`held`). A
//! checkpoint is kept as what differs from the latest whole state (`state_delta`): the base, or a
//! checkpoint kept whole because its delta had come to half the document. Older
//! checkpoints are thinned (`thin`), and past `cap` the oldest ended tracks go, then all but each
//! open track's newest checkpoint (`shed`); steps and bases stay, since undo will walk them.
//! Taking and diffing a checkpoint happen on the frame that takes it, on every target (the web has
//! no threads); were that ever too long, the diff would be spread over the frames after, a slice
//! each, the copy being immutable once taken. Until tracks are on by default they are behind `on`
//! (fizzy: `FIZZY_TRACKS=1`). `zig build bench-tracks` measures what a step, a checkpoint and a
//! replay cost.
const Tracks = @This();

const std = @import("std");
const dvui = @import("dvui");
const core = @import("core");
const sdk = @import("fizzy_sdk");
const state_delta = @import("state_delta.zig");
const tape = @import("tape");

gpa: std.mem.Allocator,
/// The frame clock: what a step's moment is read from. A bench gives its own.
clock: *const fn () i128 = dvui.frameTimeNS,
/// Whether documents are recorded. Set before documents open: one opened while off has no track.
on: bool = false,
/// The tracks of open documents, by document id.
open: std.AutoArrayHashMapUnmanaged(u64, *Track) = .empty,
/// Tracks that ended this session: their document closed, or its history started over.
ended: std.ArrayListUnmanaged(*Track) = .empty,
/// Which document the person was working in, each time it changed, as steps landed.
focus: std.ArrayListUnmanaged(Focus) = .empty,
/// Some track wants its document's state taken at the next frame's top.
due: bool = false,
/// A document being replayed into: its own steps are not recorded meanwhile.
muted: u64 = 0,
/// The session's start, on the frame clock (`dvui.frameTimeNS`): what `Track.Rec.at` counts from.
start_ns: ?i128 = null,
/// Bytes every track holds: bases, steps and checkpoints.
held: usize = 0,
/// What `held` may come to before tracks shed (`shed`).
cap: usize = default_cap,
/// Frames whose top did any work (`tick`): one per state asked for, never one a frame.
worked: u64 = 0,

pub const default_cap = 256 << 20;
/// Checkpoints older than this are thinned to one per `sparse_steps` steps.
pub const dense_ms = 60 * std.time.ms_per_min;
pub const sparse_steps = 4096;

/// When a step asks for a checkpoint. A checkpoint costs what differs from the latest whole state,
/// so it is taken only once the steps since the last are worth a share of one (`state_share`:
/// their bytes times it reach the last checkpoint's size), and then after `checkpoint_steps` of
/// them, or a pause of `checkpoint_gap_ms` before one. Past `checkpoint_max_steps` one is taken
/// whatever it costs, so a seek never replays more than that.
pub const checkpoint_steps = 256;
pub const checkpoint_max_steps = 8192;
pub const checkpoint_gap_ms = 30_000;
pub const state_share = 1;

pub const Focus = struct {
    /// ms since the session's start.
    at: u32,
    doc_id: u64,
};

pub const Track = struct {
    doc_id: u64,
    /// The document's own handle, stable for its life: what its states are taken from.
    doc: sdk.DocHandle,
    owner: *sdk.Plugin,
    /// The owner's `step_format` when the track began.
    format: u32,
    /// The document when the track began; null until the next frame takes it.
    base: ?State = null,
    /// Where the document's history stood when the base was taken (`HistoryLine`'s step id, 0
    /// before any): what an export rewinds the document to for its file (`exportTape`).
    base_top: u64 = 0,
    steps: std.ArrayListUnmanaged(Rec) = .empty,
    /// Every step's effect and motion, one after another.
    bytes: std.ArrayListUnmanaged(u8) = .empty,
    checkpoints: std.ArrayListUnmanaged(State) = .empty,
    checkpoint_due: bool = false,
    /// The size of the last checkpoint kept as a delta: about what the next will cost. 0 after a
    /// whole state, whose next delta starts small.
    state_len: usize = 0,
    /// Steps, and their bytes, since the last state taken.
    since_steps: u32 = 0,
    since_bytes: usize = 0,

    pub const Rec = struct {
        kind: sdk.Step.Kind,
        /// The history entry (`sdk.Step.id`).
        id: u64,
        /// ms since the session's start.
        at: u32,
        ms: u32,
        effect: Span,
        motion: Span,
    };

    pub const Span = struct { start: usize, len: usize };

    /// The document as `captureDocumentState` gave it, after the first `step` steps: whole, or as
    /// what differs from the latest whole state before it (`state_delta`).
    pub const State = struct {
        at: u32,
        step: usize,
        bytes: []u8,
        whole: bool = true,
        /// `documentFingerprint` then, when the owner has one: a replay that reaches this moment
        /// must come out the same.
        fingerprint: ?u64,
    };

    pub fn effect(self: *const Track, r: Rec) []const u8 {
        return self.bytes.items[r.effect.start..][0..r.effect.len];
    }

    pub fn motion(self: *const Track, r: Rec) []const u8 {
        return self.bytes.items[r.motion.start..][0..r.motion.len];
    }

    /// The state a replay to `count` steps starts from: the latest at or before it.
    pub fn stateBefore(self: *const Track, count: usize) ?*const State {
        var i = self.checkpoints.items.len;
        while (i > 0) {
            i -= 1;
            if (self.checkpoints.items[i].step <= count) return &self.checkpoints.items[i];
        }
        return if (self.base) |*b| b else null;
    }

    /// The latest whole state before checkpoint `i` (`checkpoints.len`: after them all): what a
    /// delta there is against. The base when no checkpoint before it is whole.
    fn wholeBefore(self: *const Track, i: usize) []const u8 {
        var j = i;
        while (j > 0) {
            j -= 1;
            if (self.checkpoints.items[j].whole) return self.checkpoints.items[j].bytes;
        }
        return self.base.?.bytes;
    }

    /// `s` (the base, or one of the checkpoints) as the whole state: borrowed when it is kept
    /// whole, else made from its delta, `owned` by `gpa`.
    pub fn wholeState(self: *const Track, gpa: std.mem.Allocator, s: *const State) state_delta.Error!struct { bytes: []const u8, owned: bool } {
        if (s.whole) return .{ .bytes = s.bytes, .owned = false };
        const i = (@intFromPtr(s) - @intFromPtr(self.checkpoints.items.ptr)) / @sizeOf(State);
        return .{ .bytes = try state_delta.apply(gpa, self.wholeBefore(i), s.bytes), .owned = true };
    }

    /// Bytes this track holds.
    pub fn size(self: *const Track) usize {
        var n = self.bytes.items.len + self.steps.items.len * @sizeOf(Rec);
        if (self.base) |b| n += b.bytes.len;
        for (self.checkpoints.items) |c| n += c.bytes.len;
        return n;
    }

    fn deinit(self: *Track, gpa: std.mem.Allocator) void {
        if (self.base) |b| gpa.free(b.bytes);
        for (self.checkpoints.items) |c| gpa.free(c.bytes);
        self.checkpoints.deinit(gpa);
        self.steps.deinit(gpa);
        self.bytes.deinit(gpa);
        gpa.destroy(self);
    }
};

pub fn init(gpa: std.mem.Allocator) Tracks {
    return .{ .gpa = gpa };
}

pub fn deinit(self: *Tracks) void {
    for (self.open.values()) |t| t.deinit(self.gpa);
    self.open.deinit(self.gpa);
    for (self.ended.items) |t| t.deinit(self.gpa);
    self.ended.deinit(self.gpa);
    self.focus.deinit(self.gpa);
    self.* = .{ .gpa = self.gpa, .clock = self.clock, .on = self.on, .cap = self.cap };
}

/// What the host calls with each step (`sdk.Host.recorder`).
pub fn recorder(self: *Tracks) sdk.Host.Recorder {
    return .{ .ctx = self, .vtable = &.{ .wants = wants, .step = step } };
}

/// `doc` has opened: give it a track, when tracks are on and its owner records steps. Its base is
/// taken at the next frame's top.
pub fn opened(self: *Tracks, doc: sdk.DocHandle) void {
    if (!self.on or doc.owner.step_format == 0 or doc.owner.vtable.captureDocumentState == null) return;
    if (self.open.contains(doc.id)) return;
    const t = self.gpa.create(Track) catch return;
    t.* = .{ .doc_id = doc.id, .doc = doc, .owner = doc.owner, .format = doc.owner.step_format };
    self.open.put(self.gpa, doc.id, t) catch {
        self.gpa.destroy(t);
        return;
    };
    self.due = true;
}

/// `doc_id` has closed: its track ends, kept for the session. One whose base was never taken
/// holds nothing and goes.
pub fn closed(self: *Tracks, doc_id: u64) void {
    const kv = self.open.fetchSwapRemove(doc_id) orelse return;
    self.end(kv.value);
}

fn end(self: *Tracks, t: *Track) void {
    if (t.base == null) return self.drop(t);
    self.ended.append(self.gpa, t) catch self.drop(t);
}

fn drop(self: *Tracks, t: *Track) void {
    self.held -|= t.size();
    t.deinit(self.gpa);
}

/// At the top of a frame, before anything draws: take each state a track asked for. Returns at
/// once when none did.
pub fn tick(self: *Tracks) void {
    if (!self.due) return;
    self.due = false;
    self.worked += 1;
    const prof = core.profile.begin("fizzy", "tracks.tick");
    defer prof.end();
    for (self.open.values()) |t| {
        const before = t.size();
        if (t.base == null) {
            // Steps reported before the base was taken (an open then an edit in one frame) are
            // in it, so they go.
            t.steps.clearRetainingCapacity();
            t.bytes.clearRetainingCapacity();
            t.base = self.take(t.doc, 0) orelse continue;
            t.base_top = historyTop(t.doc, self.gpa) orelse 0;
        } else if (t.checkpoint_due) {
            var s = self.take(t.doc, t.steps.items.len) orelse continue;
            // As what differs from the latest whole state, unless that is half the document or
            // more: then whole, and the next ones differ from it.
            if (state_delta.encode(self.gpa, t.wholeBefore(t.checkpoints.items.len), s.bytes)) |delta| {
                if (delta.len * 2 < s.bytes.len) {
                    self.gpa.free(s.bytes);
                    s.bytes = delta;
                    s.whole = false;
                } else self.gpa.free(delta);
            } else |_| {}
            t.checkpoints.append(self.gpa, s) catch {
                self.gpa.free(s.bytes);
                continue;
            };
            self.thin(t);
        } else continue;
        t.checkpoint_due = false;
        t.since_steps = 0;
        t.since_bytes = 0;
        t.state_len = if (t.checkpoints.getLastOrNull()) |c| (if (c.whole) 0 else c.bytes.len) else 0;
        self.held = self.held - @min(self.held, before) + t.size();
    }
    if (self.held > self.cap) self.shed();
}

/// Thin `t`'s checkpoints older than `dense_ms` to one per `sparse_steps` steps: a seek that far
/// back replays more, and the track holds less. Only deltas go: a whole state is what the deltas
/// after it are made from.
fn thin(self: *Tracks, t: *Track) void {
    const now_ms = self.now();
    var kept: usize = 0;
    var last_step: ?usize = null;
    for (t.checkpoints.items) |c| {
        const old = now_ms -| c.at >= dense_ms;
        if (old and !c.whole) if (last_step) |l| if (c.step - l < sparse_steps) {
            self.gpa.free(c.bytes);
            continue;
        };
        t.checkpoints.items[kept] = c;
        kept += 1;
        last_step = c.step;
    }
    t.checkpoints.shrinkRetainingCapacity(kept);
}

/// Over the cap: the oldest ended tracks go first; then every open track keeps only its newest
/// checkpoint, and the whole state it is a delta of. Steps and bases stay: undo will walk them,
/// and compacting (plan step 12) is what makes them smaller.
pub fn shed(self: *Tracks) void {
    const prof = core.profile.begin("fizzy", "tracks.shed");
    defer prof.end();
    var gone: usize = 0;
    while (self.held > self.cap and gone < self.ended.items.len) : (gone += 1) self.drop(self.ended.items[gone]);
    if (gone > 0) {
        std.mem.copyForwards(*Track, self.ended.items, self.ended.items[gone..]);
        self.ended.shrinkRetainingCapacity(self.ended.items.len - gone);
    }
    if (self.held <= self.cap) return;
    for (self.open.values()) |t| {
        const items = t.checkpoints.items;
        if (items.len < 2) continue;
        const last = items.len - 1;
        // The whole state the newest is a delta of, when that is a checkpoint and not the base.
        var whole: ?usize = null;
        if (!items[last].whole) {
            var j = last;
            while (j > 0) {
                j -= 1;
                if (items[j].whole) {
                    whole = j;
                    break;
                }
            }
        }
        var kept: usize = 0;
        for (items, 0..) |c, i| {
            if (i == last or i == whole) {
                items[kept] = c;
                kept += 1;
                continue;
            }
            self.held -|= c.bytes.len;
            self.gpa.free(c.bytes);
        }
        t.checkpoints.shrinkRetainingCapacity(kept);
    }
}

/// The step `doc`'s history is at (0 before any), or null when its owner keeps no line.
fn historyTop(doc: sdk.DocHandle, gpa: std.mem.Allocator) ?u64 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const line = doc.owner.historyLine(doc, arena.allocator()) orelse return null;
    return if (line.at == 0) 0 else line.entries[line.at - 1].id;
}

fn take(self: *Tracks, doc: sdk.DocHandle, count: usize) ?Track.State {
    const bytes = doc.owner.captureDocumentState(doc, self.gpa) orelse return null;
    return .{ .at = self.now(), .step = count, .bytes = bytes, .fingerprint = doc.owner.documentFingerprint(doc) };
}

/// ms since the session's start, on the frame clock.
fn now(self: *Tracks) u32 {
    const t = self.clock();
    const start = self.start_ns orelse blk: {
        self.start_ns = t;
        break :blk t;
    };
    return std.math.lossyCast(u32, @divTrunc(t - start, std.time.ns_per_ms));
}

fn from(ctx: *anyopaque) *Tracks {
    return @ptrCast(@alignCast(ctx));
}

fn wants(ctx: *anyopaque, doc_id: u64) bool {
    const self = from(ctx);
    return self.on and doc_id != self.muted and self.open.contains(doc_id);
}

fn step(ctx: *anyopaque, doc_id: u64, st: sdk.Step) void {
    const self = from(ctx);
    const prof = core.profile.begin("fizzy", "tracks.step");
    defer prof.end();
    const t = self.open.get(doc_id) orelse return;
    if (st.kind == .restarted) {
        // What came before applies to nothing the document is now: a new track, from what it is.
        const fresh = self.gpa.create(Track) catch return;
        fresh.* = .{ .doc_id = doc_id, .doc = t.doc, .owner = t.owner, .format = t.owner.step_format };
        self.open.putAssumeCapacity(doc_id, fresh);
        self.end(t);
        self.due = true;
        return;
    }
    const at = self.now();
    const last_at = if (t.steps.getLastOrNull()) |r| r.at else if (t.base) |b| b.at else at;
    const effect_at = t.bytes.items.len;
    t.bytes.ensureUnusedCapacity(self.gpa, st.effect.len + st.motion.len) catch return;
    t.steps.ensureUnusedCapacity(self.gpa, 1) catch return;
    t.bytes.appendSliceAssumeCapacity(st.effect);
    t.bytes.appendSliceAssumeCapacity(st.motion);
    t.steps.appendAssumeCapacity(.{
        .kind = st.kind,
        .id = st.id,
        .at = at,
        .ms = st.ms,
        .effect = .{ .start = effect_at, .len = st.effect.len },
        .motion = .{ .start = effect_at + st.effect.len, .len = st.motion.len },
    });
    t.since_steps += 1;
    t.since_bytes += st.effect.len + st.motion.len;
    self.held += st.effect.len + st.motion.len + @sizeOf(Track.Rec);
    if (self.held > self.cap) self.shed();
    // After a pause the state is taken just after the step that ended it: near enough the
    // pause's start for a seek, and taken where nothing is half applied.
    const worth = t.since_bytes * state_share >= t.state_len;
    if (t.since_steps >= checkpoint_max_steps or (worth and (t.since_steps >= checkpoint_steps or at -| last_at >= checkpoint_gap_ms))) {
        t.checkpoint_due = true;
        self.due = true;
    }

    // A step in another document than the last is a cut. (Looking at a document without editing
    // it is not seen here; a `fizzy.document.activated` event from the workbench is the seam.)
    if (self.focus.getLastOrNull()) |f| if (f.doc_id == doc_id) return;
    self.focus.append(self.gpa, .{ .at = at, .doc_id = doc_id }) catch {};
}

pub const ReplayError = error{ NoTrack, NoState, RestoreFailed, StepFailed, Mismatch };

/// Put `target` (a document of the track's owner) where `doc_id`'s track was after its first
/// `count` steps: the latest state at or before them, restored, then the steps since, applied at
/// once. `target` records none of it. Where a checkpoint stands at `count` with a fingerprint,
/// the replay must reach it (`error.Mismatch`).
pub fn replayInto(self: *Tracks, doc_id: u64, target: sdk.DocHandle, count: usize) ReplayError!void {
    const prof = core.profile.begin("fizzy", "tracks.replay");
    defer prof.end();
    const t = self.trackOf(doc_id) orelse return error.NoTrack;
    const n = @min(count, t.steps.items.len);
    const s = t.stateBefore(n) orelse return error.NoState;
    const state = t.wholeState(self.gpa, s) catch return error.RestoreFailed;
    defer if (state.owned) self.gpa.free(state.bytes);
    self.muted = target.id;
    defer self.muted = 0;
    if (!target.owner.restoreDocumentState(target, state.bytes)) return error.RestoreFailed;
    for (t.steps.items[s.step..n]) |r| {
        if (!target.owner.applyStep(target, t.effect(r), t.motion(r), 0)) return error.StepFailed;
    }
    for (t.checkpoints.items) |c| if (c.step == n) if (c.fingerprint) |want| {
        if (target.owner.documentFingerprint(target) != want) return error.Mismatch;
    };
}

pub const ExportOptions = struct {
    /// Keep every pause as long as it was.
    real_time: bool = false,
    /// The range of the track's steps to share: from the document as it was after the first
    /// `from`, through step `to` (exclusive; null: the last).
    from: usize = 0,
    to: ?usize = null,
};
/// A pause longer than this plays as `short_gap_ms`.
pub const gap_ms = 2000;
pub const short_gap_ms = 600;

pub const ExportError = error{
    /// No open document has a track by that id: a tape is made from the document itself.
    NoTrack,
    /// The track has nothing yet: its base is taken at the next frame.
    NoBase,
    /// The owner keeps no history to go back through.
    NoHistory,
    /// Where the range begins is no longer on the document's history (undone past and edited
    /// over), was reached by undoing past the track's start, or a step joined the entry it began
    /// in: the document cannot be put back there.
    StartNotInHistory,
    /// The range holds no steps.
    EmptyRange,
    /// An entry in the range was made before the document's track began: its steps were never
    /// recorded.
    NotRecorded,
    /// The owner could not write the document as a file.
    NoBytes,
    /// The document went back to the track's start for its file and could not come forward
    /// again: it is left there, the rest of its history a redo away.
    NotReturned,
    OutOfMemory,
};

/// Where `t`'s document's history stood after its first `count` steps: the top entry's id (0 for
/// none), worked out from the steps themselves, so it holds for any owner. Null where it cannot be
/// known: an undo or redo reached an entry from before the track began.
pub fn topAfter(t: *const Track, gpa: std.mem.Allocator, count: usize) error{OutOfMemory}!?u64 {
    // The entries added since the track began, and how many of them are done.
    var line: std.ArrayListUnmanaged(u64) = .empty;
    defer line.deinit(gpa);
    var at: usize = 0;
    for (t.steps.items[0..@min(count, t.steps.items.len)]) |r| switch (r.kind) {
        .added => {
            line.shrinkRetainingCapacity(at);
            try line.append(gpa, r.id);
            at += 1;
        },
        .joined => {},
        .undone => at = std.mem.indexOfScalar(u64, line.items[0..at], r.id) orelse return null,
        .redone => at = 1 + (std.mem.indexOfScalar(u64, line.items, r.id) orelse return null),
        .restarted => return null,
    };
    return if (at == 0) t.base_top else line.items[at - 1];
}

/// What a range of a track holds, for the person to see before it is shared (`summarize`).
pub const Summary = struct {
    /// The range, as it will be exported (`to` resolved and clamped).
    from: usize,
    to: usize,
    steps: usize,
    /// From the range's first step to its last's end, as it happened; and as the tape plays it,
    /// its long pauses shortened unless `real_time`.
    recorded_ms: u64,
    played_ms: u64,
    /// Who made its steps, each once, in the order they first came.
    authors: []const sdk.Author,
    /// Why the range cannot be shared as it stands, when it cannot (`exportTape` would refuse).
    refused: ?ExportError = null,
};

/// The range `opts` names of `doc`'s track, summed up: how many steps, how long, by whom, and
/// whether the document can be put back where it begins. Moves nothing; `arena` holds the authors.
pub fn summarize(self: *Tracks, host: *const sdk.Host, doc: sdk.DocHandle, arena: std.mem.Allocator, opts: ExportOptions) ExportError!Summary {
    const t = self.open.get(doc.id) orelse return error.NoTrack;
    const base = t.base orelse return error.NoBase;
    const to = @min(opts.to orelse t.steps.items.len, t.steps.items.len);
    const first = @min(opts.from, to);
    var out: Summary = .{ .from = first, .to = to, .steps = to - first, .recorded_ms = 0, .played_ms = 0, .authors = &.{} };
    if (first == to) {
        out.refused = error.EmptyRange;
        return out;
    }
    _ = self.startOf(doc, arena, t, first) catch |err| {
        out.refused = err;
    };

    var timing: Timing = .init(t, base, first, opts.real_time);
    var authors: std.ArrayListUnmanaged(sdk.Author) = .empty;
    for (t.steps.items[first..to]) |r| {
        out.played_ms = timing.place(r) + r.ms;
        const who = host.stepAuthor(doc.id, r.id);
        for (authors.items) |a| {
            if (a.same(who)) break;
        } else try authors.append(arena, who);
    }
    out.recorded_ms = timing.recorded_end -| (if (first == 0) base.at else t.steps.items[first].at);
    out.authors = authors.items;
    return out;
}

/// The history entry a range starting after step `first` goes back to, checked against the
/// document's line as it is now. Errors as `exportTape` refuses.
fn startOf(self: *Tracks, doc: sdk.DocHandle, arena: std.mem.Allocator, t: *const Track, first: usize) ExportError!u64 {
    _ = self;
    const top = (try topAfter(t, arena, first)) orelse return error.StartNotInHistory;
    // A step after it that joined that entry changed it: going back to the entry would keep it.
    if (top != 0) for (t.steps.items[first..]) |r| if (r.kind == .joined and r.id == top) return error.StartNotInHistory;
    const line = doc.owner.historyLine(doc, arena) orelse return error.NoHistory;
    // Gone from the line (undone past, and edited over).
    if (top != 0) for (line.entries) |e| {
        if (e.id == top) break;
    } else return error.StartNotInHistory;
    return top;
}

/// When each step plays, in ms from the tape's start: each pause runs from where the step before
/// it ended, recorded and played, so a stroke drawn over a second and a half is never cut short
/// by the next step arriving early; a pause past `gap_ms` plays as `short_gap_ms` unless real time.
const Timing = struct {
    played_end: u32 = 0,
    recorded_end: u32,
    real_time: bool,

    /// From the track's start, its time opening counts; from a step, the range opens on it.
    fn init(t: *const Track, base: Track.State, first: usize, real_time: bool) Timing {
        return .{ .recorded_end = if (first == 0) base.at else t.steps.items[first].at, .real_time = real_time };
    }

    fn place(self: *Timing, r: Track.Rec) u32 {
        const gap = r.at -| self.recorded_end;
        const at = self.played_end + if (!self.real_time and gap > gap_ms) short_gap_ms else gap;
        self.played_end = at + r.ms;
        self.recorded_end = @max(self.recorded_end, r.at + r.ms);
        return at;
    }
};

/// `doc`'s track as a tape, in the binary form, deflated (`tape.binary`): a keyframe holding
/// the document's file as it was where the range begins (`ExportOptions.from`; the track's start
/// by default), a wait for it to open, then each step of the range at the moment it came, a
/// replay of how the document was made that plays anywhere.
///
/// The file is the document's own, written by its owner (`Plugin.documentBytes`), as it stood at
/// the range's start (`topAfter`): the document is taken back there through its history (`historyGoTo`),
/// written, and brought forward again in the same call, with nothing drawn between and neither
/// the track nor the activity feed hearing of it. The person's history is as it was. Named
/// `name` (the document's file name, with its owner's extension when it has none), under
/// `demo://share`. Owned by `gpa`.
///
/// Pauses longer than `ExportOptions.gap_ms` play as `short_gap_ms` (`real_time` keeps them as
/// they were): a tape of an hour's drawing is the drawing, not the hour, and the moment before
/// the first step is a beat rather than however long the document sat open.
pub fn exportTape(self: *Tracks, host: *sdk.Host, doc: sdk.DocHandle, gpa: std.mem.Allocator, opts: ExportOptions) ExportError![]u8 {
    const prof = core.profile.begin("fizzy", "tracks.export");
    defer prof.end();
    const t = self.open.get(doc.id) orelse return error.NoTrack;
    const base = t.base orelse return error.NoBase;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const to = @min(opts.to orelse t.steps.items.len, t.steps.items.len);
    const first = @min(opts.from, to);
    if (first == to) return error.EmptyRange;
    // Refused before anything moves.
    const start_top = try self.startOf(doc, arena, t, first);
    const line = doc.owner.historyLine(doc, arena) orelse return error.NoHistory;
    const now_top = if (line.at == 0) 0 else line.entries[line.at - 1].id;

    const name = try fileName(doc, arena);
    const bytes = try self.fileAt(host, doc, arena, name, start_top, now_top);

    const files = try arena.alloc(tape.Tape.File, 1);
    files[0] = .{ .path = name, .text = bytes, .owner = doc.owner.id, .format = t.format };
    const keyframes = try arena.alloc(tape.Tape.Keyframe, 1);
    keyframes[0] = .{ .root = "demo://share", .files = files, .open = try arena.dupe([]const u8, &.{name}), .layout = .focused };
    const ops = try arena.alloc(tape.Tape.Op, to - first + 2);
    ops[0] = .{ .at = 0, .do = .{ .keyframe = 0 } };
    ops[1] = .{ .at = 0, .do = .{ .wait = .{ .until = .idle } } };
    var timing: Timing = .init(t, base, first, opts.real_time);
    for (t.steps.items[first..to], ops[2..]) |r, *op| {
        op.* = .{ .at = timing.place(r), .ms = r.ms, .do = .{ .step = .{ .file = name, .effect = t.effect(r), .motion = t.motion(r) } } };
    }
    const title = try std.fmt.allocPrint(arena, "How {s} was made", .{name});
    return tape.binary.encode(gpa, .{ .name = "share", .title = title, .ops = ops, .keyframes = keyframes }, .{ .deflate = true }) catch return error.OutOfMemory;
}

/// The document's file name for a tape: its own, with its owner's first extension when it has
/// none (an untitled document), so it opens with the right owner.
fn fileName(doc: sdk.DocHandle, arena: std.mem.Allocator) error{OutOfMemory}![]const u8 {
    const base_name = std.fs.path.basename(doc.owner.documentPath(doc));
    if (std.fs.path.extension(base_name).len > 0) return base_name;
    const types = doc.owner.fileTypes();
    if (types.len == 0) return base_name;
    return std.mem.concat(arena, u8, &.{ base_name, types[0] });
}

/// `doc`'s file as it stood with history entry `top` on top, written by its owner: the document
/// taken back there through its history, written, and brought forward to `now_top` again in the
/// same call, with nothing drawn between and neither its track nor the activity feed hearing of
/// it. The move forward is checked, since a failure would leave the person's document back there.
fn fileAt(self: *Tracks, host: *sdk.Host, doc: sdk.DocHandle, arena: std.mem.Allocator, name: []const u8, top: u64, now_top: u64) ExportError![]const u8 {
    const was_track_muted = self.muted;
    self.muted = doc.id;
    defer self.muted = was_track_muted;
    const was_muted = host.activity_muted;
    host.activity_muted = true;
    defer host.activity_muted = was_muted;
    const moved = now_top != top;
    if (moved and !doc.owner.historyGoTo(doc, top)) return error.StartNotInHistory;
    const written = doc.owner.documentBytes(doc, name, arena) catch null;
    if (moved and !doc.owner.historyGoTo(doc, now_top)) {
        std.log.err("tracks: {s} went back for a tape's file and could not come forward; redo brings the rest back", .{doc.owner.documentPath(doc)});
        return error.NotReturned;
    }
    return written orelse error.NoBytes;
}

/// The recorded steps that made the entries of `doc`'s history line from stop `lo` to stop
/// `hi` (the entries `line.entries[lo..hi]`): each entry's step that added it and those that
/// joined it, in the order they came, which is the line's. What the strip shows played forward,
/// with the undos and redos between left out. `error.NotRecorded` when an entry was made before
/// its track began.
fn lineSteps(t: *const Track, arena: std.mem.Allocator, line: sdk.Plugin.HistoryLine, lo: usize, hi: usize) ExportError![]Track.Rec {
    var want: std.AutoHashMapUnmanaged(u64, bool) = .empty;
    for (line.entries[lo..hi]) |e| try want.put(arena, e.id, false);
    var out: std.ArrayListUnmanaged(Track.Rec) = .empty;
    for (t.steps.items) |r| switch (r.kind) {
        .added, .joined => if (want.getPtr(r.id)) |seen| {
            if (r.kind == .added) seen.* = true;
            try out.append(arena, r);
        },
        else => {},
    };
    var it = want.valueIterator();
    while (it.next()) |seen| if (!seen.*) return error.NotRecorded;
    return out.items;
}

/// What a stretch of the history line holds, for the strip's export window to say: how many
/// entries, how long they took to make (as the tape plays them), whose they are. Null when an
/// entry in it was made before the track began.
pub fn lineSummary(self: *Tracks, host: *const sdk.Host, doc: sdk.DocHandle, arena: std.mem.Allocator, line: sdk.Plugin.HistoryLine, lo: usize, hi: usize) ?Summary {
    const t = self.open.get(doc.id) orelse return null;
    if (lo >= hi or hi > line.entries.len) return null;
    const recs = lineSteps(t, arena, line, lo, hi) catch return null;
    if (recs.len == 0) return null;
    var timing: Timing = .{ .recorded_end = recs[0].at, .real_time = false };
    var out: Summary = .{ .from = lo, .to = hi, .steps = hi - lo, .recorded_ms = 0, .played_ms = 0, .authors = &.{} };
    var authors: std.ArrayListUnmanaged(sdk.Author) = .empty;
    for (recs) |r| {
        out.played_ms = timing.place(r) + r.ms;
        const who = host.stepAuthor(doc.id, r.id);
        for (authors.items) |a| {
            if (a.same(who)) break;
        } else authors.append(arena, who) catch {};
    }
    out.recorded_ms = timing.recorded_end -| recs[0].at;
    out.authors = authors.items;
    return out;
}

/// A stretch of `doc`'s history line as a tape, as the strip shows it (`HistoryTransport`'s
/// export window): the document's file at stop `lo` (`fileAt`), then the steps that made each
/// entry to stop `hi` (`lineSteps`), timed as they came. Owned by `gpa`.
pub fn exportLine(self: *Tracks, host: *sdk.Host, doc: sdk.DocHandle, gpa: std.mem.Allocator, lo: usize, hi: usize, opts: ExportOptions) ExportError![]u8 {
    const prof = core.profile.begin("fizzy", "tracks.export");
    defer prof.end();
    const t = self.open.get(doc.id) orelse return error.NoTrack;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const line = doc.owner.historyLine(doc, arena) orelse return error.NoHistory;
    if (lo >= hi or hi > line.entries.len) return error.EmptyRange;
    const recs = try lineSteps(t, arena, line, lo, hi);
    const stop = struct {
        fn id(l: sdk.Plugin.HistoryLine, i: usize) u64 {
            return if (i == 0) 0 else l.entries[i - 1].id;
        }
    }.id;
    const name = try fileName(doc, arena);
    const bytes = try self.fileAt(host, doc, arena, name, stop(line, lo), stop(line, line.at));

    const files = try arena.alloc(tape.Tape.File, 1);
    files[0] = .{ .path = name, .text = bytes, .owner = doc.owner.id, .format = t.format };
    const keyframes = try arena.alloc(tape.Tape.Keyframe, 1);
    keyframes[0] = .{ .root = "demo://share", .files = files, .open = try arena.dupe([]const u8, &.{name}), .layout = .focused };
    const ops = try arena.alloc(tape.Tape.Op, recs.len + 2);
    ops[0] = .{ .at = 0, .do = .{ .keyframe = 0 } };
    ops[1] = .{ .at = 0, .do = .{ .wait = .{ .until = .idle } } };
    var timing: Timing = .{ .recorded_end = recs[0].at, .real_time = opts.real_time };
    for (recs, ops[2..]) |r, *op| {
        op.* = .{ .at = timing.place(r), .ms = r.ms, .do = .{ .step = .{ .file = name, .effect = t.effect(r), .motion = t.motion(r) } } };
    }
    const title = try std.fmt.allocPrint(arena, "How {s} was made", .{name});
    return tape.binary.encode(gpa, .{ .name = "share", .title = title, .ops = ops, .keyframes = keyframes }, .{ .deflate = true }) catch return error.OutOfMemory;
}

/// The open document's track, or else the latest that ended for it.
pub fn trackOf(self: *Tracks, doc_id: u64) ?*Track {
    if (self.open.get(doc_id)) |t| return t;
    var i = self.ended.items.len;
    while (i > 0) {
        i -= 1;
        if (self.ended.items[i].doc_id == doc_id) return self.ended.items[i];
    }
    return null;
}

// ---- tests ---------------------------------------------------------------------------------

const testing = std.testing;

/// A stand-in owner whose document is a buffer: its state a copy, a step written in at its start.
const Stand = struct {
    var bytes: [4096]u8 = @splat(0);
    var clock_ns: i128 = 0;

    fn clock() i128 {
        return clock_ns;
    }
    fn capture(_: *anyopaque, _: sdk.DocHandle, allocator: std.mem.Allocator) anyerror![]u8 {
        return allocator.dupe(u8, &bytes);
    }
    fn restore(_: *anyopaque, _: sdk.DocHandle, saved: []const u8) anyerror!void {
        @memcpy(&bytes, saved);
    }
    fn fingerprint(_: *anyopaque, _: sdk.DocHandle) u64 {
        return std.hash.Wyhash.hash(0, &bytes);
    }
    fn apply(_: *anyopaque, _: sdk.DocHandle, effect: []const u8, _: []const u8, _: u32) anyerror!void {
        @memcpy(bytes[0..effect.len], effect);
    }

    var state: u8 = 0;
    const vtable: sdk.Plugin.VTable = .{ .captureDocumentState = capture, .restoreDocumentState = restore, .documentFingerprint = fingerprint, .applyStep = apply };
    var plugin: sdk.Plugin = .{ .state = &state, .vtable = &vtable, .id = "stand", .display_name = "Stand", .step_format = 1 };

    fn doc(id: u64) sdk.DocHandle {
        return .{ .ptr = &state, .owner = &plugin, .id = id };
    }

    fn tracks() Tracks {
        bytes = @splat(0);
        clock_ns = 0;
        var t: Tracks = .init(testing.allocator);
        t.clock = clock;
        t.on = true;
        return t;
    }

    /// A step of `effect` (written into the document as the owner would have) at `ms` past the last.
    fn step(t: *Tracks, id: u64, effect: []const u8, ms: i128) void {
        clock_ns += ms * std.time.ns_per_ms;
        @memcpy(bytes[0..effect.len], effect);
        const rec = t.recorder();
        rec.vtable.step(rec.ctx, id, .{ .kind = .added, .id = 1, .effect = effect });
    }
};

test "a frame's top does work only when a track asked for some" {
    var t = Stand.tracks();
    defer t.deinit();
    t.opened(Stand.doc(1));
    t.tick();
    try testing.expectEqual(@as(u64, 1), t.worked);
    for (0..1000) |_| t.tick();
    try testing.expectEqual(@as(u64, 1), t.worked);
    // A step that asks for nothing asks nothing of a frame.
    Stand.step(&t, 1, "ab", 10);
    t.tick();
    try testing.expectEqual(@as(u64, 1), t.worked);
    try testing.expectEqual(@as(usize, 1), t.trackOf(1).?.steps.items.len);
}

test "a checkpoint is what differs from the whole state, taken once the steps since are worth one" {
    var t = Stand.tracks();
    defer t.deinit();
    t.opened(Stand.doc(1));
    t.tick();
    const track = t.trackOf(1).?;
    const sixteen: [16]u8 = @splat(5);
    // The first after the base is a small delta: 16 bytes changed of 4 KB.
    for (0..checkpoint_steps) |_| Stand.step(&t, 1, &sixteen, 1);
    t.tick();
    try testing.expectEqual(@as(usize, 1), track.checkpoints.items.len);
    try testing.expect(!track.checkpoints.items[0].whole);
    try testing.expect(track.checkpoints.items[0].bytes.len < 64);
    // A bigger change, a third of the document: still a delta, and what the next one weighs.
    const third: [1500]u8 = @splat(6);
    Stand.step(&t, 1, &third, 1);
    for (0..checkpoint_steps - 1) |_| Stand.step(&t, 1, "", 1);
    t.tick();
    try testing.expectEqual(@as(usize, 2), track.checkpoints.items.len);
    try testing.expect(!track.checkpoints.items[1].whole);
    // Steps worth less than that delta ask for none.
    for (0..checkpoint_steps) |_| Stand.step(&t, 1, "x", 1);
    t.tick();
    try testing.expectEqual(@as(usize, 2), track.checkpoints.items.len);
    // However little they are worth, a seek replays no more than the most.
    for (0..checkpoint_max_steps) |_| Stand.step(&t, 1, "", 1);
    t.tick();
    try testing.expectEqual(@as(usize, 3), track.checkpoints.items.len);
    // Changed by more than half: kept whole, and what the next deltas are made from.
    const most: [3000]u8 = @splat(7);
    Stand.step(&t, 1, &most, 1);
    for (0..checkpoint_max_steps) |_| Stand.step(&t, 1, "", 1);
    t.tick();
    try testing.expect(track.checkpoints.getLast().whole);
    for (0..checkpoint_steps) |_| Stand.step(&t, 1, &sixteen, 1);
    t.tick();
    try testing.expect(!track.checkpoints.getLast().whole);
    try testing.expectEqual(t.held, track.size());

    // A replay lands where the document was through a delta, and checks the fingerprint kept.
    const want = Stand.bytes;
    @memset(&Stand.bytes, 0);
    try t.replayInto(1, Stand.doc(2), track.steps.items.len);
    try testing.expectEqualSlices(u8, &want, &Stand.bytes);
    // And through the one before the whole state.
    try t.replayInto(1, Stand.doc(2), track.checkpoints.items[1].step);
}

test "checkpoints older than an hour thin to one per sparse_steps" {
    var t = Stand.tracks();
    defer t.deinit();
    t.opened(Stand.doc(1));
    t.tick();
    const track = t.trackOf(1).?;
    // A checkpoint every `checkpoint_steps` steps of 16 bytes (a state's worth), a ms apart:
    // dense while young.
    var buf: [16]u8 = @splat(7);
    for (0..sparse_steps * 2 / checkpoint_steps) |i| {
        for (0..checkpoint_steps) |_| Stand.step(&t, 1, &buf, 1);
        buf[0] = @truncate(i);
        t.tick();
    }
    const young = track.checkpoints.items.len;
    try testing.expectEqual(@as(usize, sparse_steps * 2 / checkpoint_steps), young);
    // An hour on, the next checkpoint thins the old ones.
    Stand.clock_ns += dense_ms * std.time.ns_per_ms;
    for (0..checkpoint_steps) |_| Stand.step(&t, 1, &buf, 1);
    t.tick();
    const kept = track.checkpoints.items;
    try testing.expect(kept.len < young);
    for (kept[1 .. kept.len - 1], kept[0 .. kept.len - 2]) |c, prev| try testing.expect(c.step - prev.step >= sparse_steps);
    try testing.expectEqual(t.held, track.size());
}

test "over the cap, ended tracks go first, then all but each open track's newest checkpoint" {
    var t = Stand.tracks();
    defer t.deinit();
    for ([_]u64{ 1, 2 }) |id| t.opened(Stand.doc(id));
    t.tick();
    var buf: [16]u8 = @splat(3);
    for (0..3) |_| {
        for (0..checkpoint_steps) |_| Stand.step(&t, 1, &buf, 1);
        t.tick();
    }
    try testing.expectEqual(@as(usize, 3), t.trackOf(1).?.checkpoints.items.len);
    t.closed(2);
    try testing.expectEqual(@as(usize, 1), t.ended.items.len);

    t.cap = t.held - 1;
    t.shed();
    try testing.expectEqual(@as(usize, 0), t.ended.items.len);
    try testing.expect(t.trackOf(2) == null);
    t.cap = 1;
    t.shed();
    const track = t.trackOf(1).?;
    try testing.expectEqual(@as(usize, 1), track.checkpoints.items.len);
    try testing.expectEqual(track.steps.items.len, track.checkpoints.items[0].step);
    try testing.expectEqual(t.held, track.size());
}

test "where the history stood after each step, from the steps alone" {
    var t: Track = .{ .doc_id = 1, .doc = Stand.doc(1), .owner = &Stand.plugin, .format = 1, .base_top = 7 };
    defer t.steps.deinit(testing.allocator);
    const steps = [_]struct { sdk.Step.Kind, u64 }{
        .{ .added, 10 },  .{ .joined, 10 }, .{ .added, 11 }, .{ .undone, 11 }, .{ .undone, 10 },
        .{ .redone, 10 }, .{ .added, 12 },  .{ .undone, 7 },
    };
    for (steps) |st| try t.steps.append(testing.allocator, .{ .kind = st[0], .id = st[1], .at = 0, .ms = 0, .effect = .{ .start = 0, .len = 0 }, .motion = .{ .start = 0, .len = 0 } });
    // Before any step, where the track began; then each step's top. Adding 12 after undoing 11
    // overwrites it, and undoing 7 (from before the track) cannot be known.
    const want = [_]?u64{ 7, 10, 10, 11, 10, 7, 10, 12, null };
    for (want, 0..) |w, count| try testing.expectEqual(w, try topAfter(&t, testing.allocator, count));
}
