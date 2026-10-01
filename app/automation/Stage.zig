//! What a `Player` needs from the application it drives — the `{ctx, vtable}` seam an app fills
//! in, the way it does `store.Manager` and `FolderWatcher.Sink`.
//!
//! The player knows how to deliver input and when; only the app knows what its state *is*. A
//! keyframe says "these files, these open, the default layout", and it is the stage that closes
//! what was open, mounts the files and opens them. The same goes for the user's own session: the
//! stage sets it aside when a demo loads and gives it back when the demo is unloaded, so playing
//! a demo inside someone's working copy of the app never costs them their open documents.
const Stage = @This();

const Tape = @import("Tape.zig");
const chord = @import("../keymap/chord.zig");

ctx: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    /// A demo was loaded. Set aside whatever of the user's session a keyframe would replace, and
    /// stop persisting anything the demo will change (layout, recent folders).
    begin: *const fn (ctx: *anyopaque, tape: *const Tape) void,
    /// The demo was unloaded. Put the user's session back.
    end: *const fn (ctx: *anyopaque) void,
    /// Put the app into `kf` outright, discarding what the demo did before. May leave work in
    /// flight (files loading); `idle` reports when it has landed.
    keyframe: *const fn (ctx: *anyopaque, kf: *const Tape.Keyframe) void,
    /// Nothing the stage or the app started is still in flight.
    idle: *const fn (ctx: *anyopaque) bool,
    /// Run a command by id, as its menu row or shortcut would.
    command: *const fn (ctx: *anyopaque, id: []const u8) void,
    /// The chord bound to a command, for the keystroke display. Null when unbound.
    chordFor: *const fn (ctx: *anyopaque, id: []const u8) ?chord.Stroke,
    /// What a person would call a command ("Format Document"), for the keystroke display.
    commandTitle: *const fn (ctx: *anyopaque, id: []const u8) ?[]const u8,
    /// Replaying fast (a seek): turn animation off so every replayed frame lands where it is
    /// going, and back on after.
    fastForward: *const fn (ctx: *anyopaque, on: bool) void,
};

pub fn begin(self: Stage, tape: *const Tape) void {
    self.vtable.begin(self.ctx, tape);
}
pub fn end(self: Stage) void {
    self.vtable.end(self.ctx);
}
pub fn keyframe(self: Stage, kf: *const Tape.Keyframe) void {
    self.vtable.keyframe(self.ctx, kf);
}
pub fn idle(self: Stage) bool {
    return self.vtable.idle(self.ctx);
}
pub fn command(self: Stage, id: []const u8) void {
    self.vtable.command(self.ctx, id);
}
pub fn chordFor(self: Stage, id: []const u8) ?chord.Stroke {
    return self.vtable.chordFor(self.ctx, id);
}
pub fn commandTitle(self: Stage, id: []const u8) ?[]const u8 {
    return self.vtable.commandTitle(self.ctx, id);
}
pub fn fastForward(self: Stage, on: bool) void {
    self.vtable.fastForward(self.ctx, on);
}
