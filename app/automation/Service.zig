//! The `automation` service (`sdk.services.automation`) over a `LiveDriver`: what an app that
//! plays live tapes offers its plugins. The service's doc says what a plugin sees; this is the
//! bookkeeping behind it — tickets, the outcomes of the last few tapes, and the arbitration with
//! whatever else drives the app.
//!
//! An app owns one beside its driver and registers `&service.api` once it is at its final
//! address. An outcome is read off the driver when asked for, and moved into `recent` only when
//! the next tape starts.
//!
//! **Settled** includes dvui itself: no refresh asked for and no animation running. dvui says so
//! only as `Window.end`'s return, so the app hands that over after each frame (`frameEnded`) —
//! fizzy from its backends' `frame_ended_hook`. An app that never does is taken to be quiet, and
//! `settled` falls back to the stage and the driver.
const Service = @This();

const std = @import("std");
const sdk = @import("fizzy_sdk");
const Tape = @import("tape").Tape;
const LiveDriver = @import("replay").LiveDriver;
const Input = @import("replay").Input;

const Api = sdk.services.automation.Api;

gpa: std.mem.Allocator,
driver: *LiveDriver,
/// Something else that drives the app, refusing a tape while it does — fizzy's demos.
other: ?Other = null,
/// The value to register (`Host.registerService`), pointing back here.
api: Api = undefined,
/// The ticket the driver's current or last tape was played under.
current: ?Api.Ticket = null,
next: u32 = 1,
/// How the tapes before `current` ended, oldest overwritten first.
recent: [8]?Past = @splat(null),
recent_at: usize = 0,
/// The last frame ended with dvui wanting no frame: nothing refreshed, nothing animating.
quiet: bool = true,
/// Someone was told "not settled" since the last frame ended.
asked: bool = false,

pub const Other = struct {
    ctx: *anyopaque,
    driving: *const fn (ctx: *anyopaque) bool,
};

const Past = struct {
    ticket: Api.Ticket,
    outcome: Api.Outcome,
};

/// Fill in `api`. `self` must not move afterwards (it is the service's context).
pub fn bind(self: *Service) void {
    self.api = .{ .ctx = self, .vtable = &vtable };
}

const vtable: Api.VTable = .{
    .play = play,
    .stop = stop,
    .outcome = outcome,
    .settled = settled,
};

fn from(ctx: *anyopaque) *Service {
    return @ptrCast(@alignCast(ctx));
}

fn othersDriving(self: *Service) bool {
    const o = self.other orelse return false;
    return o.driving(o.ctx);
}

fn play(ctx: *anyopaque, bytes: []const u8) Api.Play {
    const self = from(ctx);
    if (self.driver.playing() or self.othersDriving()) return .busy;
    var check = Input.check;
    check.live = true;
    const owned = Tape.load(self.gpa, bytes, check) catch |err| return .{ .invalid = @errorName(err) };
    // Read before the driver starts over and forgets it.
    const last = self.driverOutcome();
    self.driver.play(owned) catch |err| return switch (err) {
        error.Busy => .busy,
        else => .{ .invalid = @errorName(err) },
    };
    if (self.current) |t| self.remember(.{ .ticket = t, .outcome = last });
    const ticket: Api.Ticket = @enumFromInt(self.next);
    self.next += 1;
    self.current = ticket;
    return .{ .started = ticket };
}

fn remember(self: *Service, past: Past) void {
    self.recent[self.recent_at] = past;
    self.recent_at = (self.recent_at + 1) % self.recent.len;
}

fn driverOutcome(self: *Service) Api.Outcome {
    if (self.driver.playing()) return .playing;
    const o = self.driver.outcome orelse return .unknown;
    return switch (o) {
        .finished => .finished,
        .interrupted => |at| .{ .interrupted = @intCast(at) },
        .timed_out => |at| .{ .timed_out = @intCast(at) },
        .stopped => |at| .{ .stopped = @intCast(at) },
    };
}

fn stop(ctx: *anyopaque, ticket: Api.Ticket) void {
    const self = from(ctx);
    if (self.current != ticket) return;
    self.driver.stop();
}

fn outcome(ctx: *anyopaque, ticket: Api.Ticket) Api.Outcome {
    const self = from(ctx);
    if (self.current == ticket) return self.driverOutcome();
    for (self.recent) |past| {
        const p = past orelse continue;
        if (p.ticket == ticket) return p.outcome;
    }
    return .unknown;
}

fn settled(ctx: *anyopaque) bool {
    const self = from(ctx);
    const yes = self.quiet and !self.driver.playing() and !self.othersDriving() and self.driver.stage.idle();
    if (!yes) self.asked = true;
    return yes;
}

/// The frame just ended, and `Window.end` returned `end_micros`: null when dvui would sleep, 0
/// when it wants the next frame now, the wait for a later animation otherwise. True asks the app
/// to run one more frame now anyway: someone was told "not settled", and dvui has gone quiet, so
/// without it they would not see the answer change until something else woke the app. That frame
/// is the app's own, after `end` decided, so it leaves dvui quiet.
pub fn frameEnded(self: *Service, end_micros: ?u32) bool {
    self.quiet = end_micros == null;
    const wake = self.asked and self.quiet;
    self.asked = false;
    return wake;
}
