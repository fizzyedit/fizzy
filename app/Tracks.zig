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
//! makes it, and the steps' bytes, in memory for the session. Chunking, deflating off the UI thread,
//! thinning checkpoints and a cap are the next step of the plan; until then tracks are behind
//! `on` (fizzy: `FIZZY_TRACKS=1`).
const Tracks = @This();

const std = @import("std");
const dvui = @import("dvui");
const core = @import("core");
const sdk = @import("fizzy_sdk");

gpa: std.mem.Allocator,
host: *sdk.Host,
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

/// A step takes a checkpoint after this many since the last one, or this many bytes of them, or
/// this long a pause before it: so a seek never replays more than this from the last state.
pub const checkpoint_steps = 256;
pub const checkpoint_bytes = 1 << 20;
pub const checkpoint_gap_ms = 30_000;

pub const Focus = struct {
    /// ms since the session's start.
    at: u32,
    doc_id: u64,
};

pub const Track = struct {
    doc_id: u64,
    owner: *sdk.Plugin,
    /// The owner's `step_format` when the track began.
    format: u32,
    /// The document when the track began; null until the next frame takes it.
    base: ?State = null,
    steps: std.ArrayListUnmanaged(Rec) = .empty,
    /// Every step's effect and motion, one after another.
    bytes: std.ArrayListUnmanaged(u8) = .empty,
    checkpoints: std.ArrayListUnmanaged(State) = .empty,
    checkpoint_due: bool = false,
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

    /// The document as `captureDocumentState` gave it, after the first `step` steps.
    pub const State = struct {
        at: u32,
        step: usize,
        bytes: []u8,
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

    fn deinit(self: *Track, gpa: std.mem.Allocator) void {
        if (self.base) |b| gpa.free(b.bytes);
        for (self.checkpoints.items) |c| gpa.free(c.bytes);
        self.checkpoints.deinit(gpa);
        self.steps.deinit(gpa);
        self.bytes.deinit(gpa);
        gpa.destroy(self);
    }
};

pub fn init(gpa: std.mem.Allocator, host: *sdk.Host) Tracks {
    return .{ .gpa = gpa, .host = host };
}

pub fn deinit(self: *Tracks) void {
    for (self.open.values()) |t| t.deinit(self.gpa);
    self.open.deinit(self.gpa);
    for (self.ended.items) |t| t.deinit(self.gpa);
    self.ended.deinit(self.gpa);
    self.focus.deinit(self.gpa);
    self.* = .{ .gpa = self.gpa, .host = self.host, .on = self.on };
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
    t.* = .{ .doc_id = doc.id, .owner = doc.owner, .format = doc.owner.step_format };
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
    if (t.base == null) return t.deinit(self.gpa);
    self.ended.append(self.gpa, t) catch t.deinit(self.gpa);
}

/// At the top of a frame, before anything draws: take each state a track asked for. Returns at
/// once when none did.
pub fn tick(self: *Tracks) void {
    if (!self.due) return;
    self.due = false;
    const prof = core.profile.begin("fizzy", "tracks.tick");
    defer prof.end();
    for (self.open.values()) |t| {
        const doc = self.host.docById(t.doc_id) orelse continue;
        if (t.base == null) {
            // Steps reported before the base was taken (an open then an edit in one frame) are
            // in it, so they go.
            t.steps.clearRetainingCapacity();
            t.bytes.clearRetainingCapacity();
            t.base = self.take(doc, 0) orelse continue;
        } else if (t.checkpoint_due) {
            const s = self.take(doc, t.steps.items.len) orelse continue;
            t.checkpoints.append(self.gpa, s) catch {
                self.gpa.free(s.bytes);
                continue;
            };
        } else continue;
        t.checkpoint_due = false;
        t.since_steps = 0;
        t.since_bytes = 0;
    }
}

fn take(self: *Tracks, doc: sdk.DocHandle, count: usize) ?Track.State {
    const bytes = doc.owner.captureDocumentState(doc, self.gpa) orelse return null;
    return .{ .at = self.now(), .step = count, .bytes = bytes, .fingerprint = doc.owner.documentFingerprint(doc) };
}

/// ms since the session's start, on the frame clock.
fn now(self: *Tracks) u32 {
    const t = dvui.frameTimeNS();
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
        fresh.* = .{ .doc_id = doc_id, .owner = t.owner, .format = t.owner.step_format };
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
    // After a pause the state is taken just after the step that ended it: near enough the
    // pause's start for a seek, and taken where nothing is half applied.
    if (t.since_steps >= checkpoint_steps or t.since_bytes >= checkpoint_bytes or at -| last_at >= checkpoint_gap_ms) {
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
    self.muted = target.id;
    defer self.muted = 0;
    if (!target.owner.restoreDocumentState(target, s.bytes)) return error.RestoreFailed;
    for (t.steps.items[s.step..n]) |r| {
        if (!target.owner.applyStep(target, t.effect(r), t.motion(r), 0)) return error.StepFailed;
    }
    for (t.checkpoints.items) |c| if (c.step == n) if (c.fingerprint) |want| {
        if (target.owner.documentFingerprint(target) != want) return error.Mismatch;
    };
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
