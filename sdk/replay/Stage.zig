//! What a `Player` or a `LiveDriver` needs from the application it drives — the `{ctx, vtable}`
//! seam an app fills in. A live tape needs only `idle` and `command`.
//!
//! The player knows how to deliver input and when; only the app knows what its state *is*. A
//! keyframe says "these files, these open, the default layout", and it is the stage that closes
//! what was open, mounts the files and opens them. The same goes for the user's own session: the
//! stage sets it aside when a demo loads and gives it back when the demo is unloaded, so playing
//! a demo inside someone's working copy of the app never costs them their open documents.
//!
//! **Snapshots** are the app's model at a moment, taken while a demo plays so a seek can go
//! back to the nearest one instead of to the keyframe (`Player`). What one holds is the app's
//! business — the player keeps it as an opaque pointer — and so is whether it can put one back
//! where it is now: one that cannot says so, and the seek cuts to the keyframe as before. They
//! live in memory for one session; nothing about them is ever written down. All four hooks are
//! optional: an app without them seeks from keyframes.
const Stage = @This();

const Tape = @import("tape").Tape;
const chord = @import("tape").chord;

ctx: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    /// Nothing the stage or the app started is still in flight.
    idle: *const fn (ctx: *anyopaque) bool,
    /// Run a command by id. `args` empty, as its menu row or shortcut would; otherwise with
    /// `args`, ZON keyed by its parameters (`Tape.Command`), as the palette would once a person
    /// had given them.
    command: *const fn (ctx: *anyopaque, id: []const u8, args: []const u8) void,

    // A live tape (`LiveDriver`) needs only the two above. The rest are a demo's (`Player`): an
    // app that plays only live tapes leaves them null.

    /// A demo was loaded. Set aside whatever of the user's session a keyframe would replace, and
    /// stop persisting anything the demo will change (layout, recent folders).
    begin: ?*const fn (ctx: *anyopaque, tape: *const Tape) void = null,
    /// The demo was unloaded. Put the user's session back.
    end: ?*const fn (ctx: *anyopaque) void = null,
    /// Put the app into `kf` outright, discarding what the demo did before. May leave work in
    /// flight (files loading); `idle` reports when it has landed. Null: a keyframe changes
    /// nothing, and a demo plays on the app as it is.
    keyframe: ?*const fn (ctx: *anyopaque, kf: *const Tape.Keyframe) void = null,
    /// The chord bound to a command, for the keystroke display. Null when unbound.
    chordFor: ?*const fn (ctx: *anyopaque, id: []const u8) ?chord.Stroke = null,
    /// What a person would call a command ("Format Document"), for the keystroke display.
    commandTitle: ?*const fn (ctx: *anyopaque, id: []const u8) ?[]const u8 = null,
    /// Replaying fast (a seek): turn animation off so every replayed frame lands where it is
    /// going, and back on after.
    fastForward: ?*const fn (ctx: *anyopaque, on: bool) void = null,

    /// The app's model now, as something `restore` can put back — or null when this is not a
    /// moment to keep (work in flight, a popup open, a document whose owner cannot say what it
    /// holds). Owned by the stage until `release`.
    capture: ?*const fn (ctx: *anyopaque) ?*anyopaque = null,
    /// Put the app back to `snap`, in place — the documents' contents, carets and scroll, what
    /// is open, the explorer — and run whatever frames that takes on its own. False when it
    /// cannot from where the app is now (another scene's files, a document it would have to
    /// load): the player cuts to the keyframe instead.
    restore: ?*const fn (ctx: *anyopaque, snap: *anyopaque) bool = null,
    release: ?*const fn (ctx: *anyopaque, snap: *anyopaque) void = null,
    /// A hash of the model now — what a snapshot taken now would hold, less anything that may
    /// differ between passes (scroll, layout caches). A replay that reaches a snapshot's moment
    /// compares, so a demo that does not replay exactly is caught (`Player.mismatches`).
    fingerprint: ?*const fn (ctx: *anyopaque) u64 = null,
};

pub fn begin(self: Stage, tape: *const Tape) void {
    if (self.vtable.begin) |f| f(self.ctx, tape);
}
pub fn end(self: Stage) void {
    if (self.vtable.end) |f| f(self.ctx);
}
pub fn keyframe(self: Stage, kf: *const Tape.Keyframe) void {
    if (self.vtable.keyframe) |f| f(self.ctx, kf);
}
pub fn idle(self: Stage) bool {
    return self.vtable.idle(self.ctx);
}
pub fn command(self: Stage, id: []const u8, args: []const u8) void {
    self.vtable.command(self.ctx, id, args);
}
pub fn chordFor(self: Stage, id: []const u8) ?chord.Stroke {
    const f = self.vtable.chordFor orelse return null;
    return f(self.ctx, id);
}
pub fn commandTitle(self: Stage, id: []const u8) ?[]const u8 {
    const f = self.vtable.commandTitle orelse return null;
    return f(self.ctx, id);
}
pub fn fastForward(self: Stage, on: bool) void {
    if (self.vtable.fastForward) |f| f(self.ctx, on);
}
pub fn snapshots(self: Stage) bool {
    return self.vtable.capture != null and self.vtable.restore != null and self.vtable.release != null;
}
pub fn capture(self: Stage) ?*anyopaque {
    const f = self.vtable.capture orelse return null;
    return f(self.ctx);
}
pub fn restore(self: Stage, snap: *anyopaque) bool {
    const f = self.vtable.restore orelse return false;
    return f(self.ctx, snap);
}
pub fn release(self: Stage, snap: *anyopaque) void {
    if (self.vtable.release) |f| f(self.ctx, snap);
}
pub fn fingerprint(self: Stage) ?u64 {
    const f = self.vtable.fingerprint orelse return null;
    return f(self.ctx);
}
