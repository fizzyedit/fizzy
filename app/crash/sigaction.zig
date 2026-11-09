//! `sigaction` for every caller in the app, so a handler reaches 64-bit Android's libc as itself.
const std = @import("std");
const builtin = @import("builtin");

// The last term retires the conversion by itself once std has bionic's layout.
const convert = builtin.target.abi.isAndroid() and @sizeOf(usize) == 8 and @offsetOf(std.c.Sigaction, "flags") != 0;

/// 64-bit bionic's `struct sigaction` (NDK `bits/signal_types.h`): 32 bytes.
pub const Bionic = extern struct { flags: c_int, handler: usize, mask: c_ulong, restorer: usize };

/// `std.posix.sigaction`'s contract. Zig 0.17's `std.c.Sigaction` is glibc's on 64-bit Android, so
/// bionic read the handler from the mask: std.Io's SIGIO handler, which cancelling the losing
/// connects raises, arrived as SIG_DFL and killed the app. This hands bionic its own layout.
pub fn sigaction(sig: std.posix.SIG, act: ?*const std.posix.Sigaction, oact: ?*std.posix.Sigaction) void {
    // Windows has no sigaction for std to link; `crash.zig`'s refAllDecls still compiles this.
    if (builtin.target.os.tag == .windows) unreachable;
    if (!convert) return std.posix.sigaction(sig, act, oact); // lint-allow(raw-sigaction): std's layout is the libc's here
    var new: Bionic = undefined;
    var old: Bionic = undefined;
    if (act) |a| new = toBionic(a.*);
    const rc = std.c.sigaction( // lint-allow(raw-sigaction): the one call, in bionic's layout
        sig,
        if (act != null) @ptrCast(&new) else null,
        if (oact != null) @ptrCast(&old) else null,
    );
    std.debug.assert(rc == 0);
    if (oact) |o| o.* = fromBionic(old);
}

/// The handler's bits, the flags, the first mask word and the restorer; the rest of the mask is
/// dropped, as bionic's one word holds every signal there is.
pub fn toBionic(act: std.posix.Sigaction) Bionic {
    return .{
        .flags = @bitCast(act.flags),
        .handler = @intFromPtr(act.handler.handler),
        .mask = maskWord(act.mask),
        .restorer = if (@hasField(std.posix.Sigaction, "restorer")) @intFromPtr(act.restorer) else 0,
    };
}

/// `toBionic`'s inverse: the mask past its first word is empty.
pub fn fromBionic(b: Bionic) std.posix.Sigaction {
    var act: std.posix.Sigaction = .{
        .handler = .{ .handler = @ptrFromInt(b.handler) },
        .mask = std.posix.sigemptyset(),
        .flags = @bitCast(b.flags),
    };
    switch (@typeInfo(@TypeOf(act.mask))) {
        .array => act.mask[0] = @truncate(b.mask),
        else => act.mask = @truncate(b.mask),
    }
    if (@hasField(std.posix.Sigaction, "restorer")) act.restorer = @ptrFromInt(b.restorer);
    return act;
}

fn maskWord(mask: std.posix.sigset_t) c_ulong {
    return switch (@typeInfo(std.posix.sigset_t)) {
        .array => mask[0],
        else => mask,
    };
}
