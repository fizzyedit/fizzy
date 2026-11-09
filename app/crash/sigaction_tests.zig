//! `sigaction.zig`: bionic's layout, the conversion both ways, and the host's plain call.
const std = @import("std");
const builtin = @import("builtin");
const sig = @import("sigaction.zig");
const posix = std.posix;

/// Windows has no `std.posix.Sigaction`: the tests compile there, and skip.
const no_signals = builtin.target.os.tag == .windows;

fn nothing(_: posix.SIG) callconv(.c) void {}
fn nothingInfo(_: posix.SIG, _: *const posix.siginfo_t, _: ?*anyopaque) callconv(.c) void {}

fn restorer() callconv(.c) void {}

/// An action with the first mask word set, and the restorer where the host has one.
fn withMask(handler: @FieldType(posix.Sigaction, "handler"), flags: @FieldType(posix.Sigaction, "flags")) posix.Sigaction {
    var act: posix.Sigaction = .{ .handler = handler, .mask = posix.sigemptyset(), .flags = flags };
    posix.sigaddset(&act.mask, .USR1);
    posix.sigaddset(&act.mask, .TERM);
    if (@hasField(posix.Sigaction, "restorer")) act.restorer = &restorer;
    return act;
}

test "bionic's sigaction: flags at 0, the handler at 8, the mask at 16, the restorer at 24" {
    if (no_signals) return error.SkipZigTest;
    try std.testing.expectEqual(32, @sizeOf(sig.Bionic));
    const act = withMask(.{ .handler = nothing }, posix.SA.RESTART);
    const b = sig.toBionic(act);
    const bytes = std.mem.asBytes(&b);
    try std.testing.expectEqual(@as(u32, @bitCast(act.flags)), std.mem.readInt(u32, bytes[0..4], builtin.cpu.arch.endian()));
    try std.testing.expectEqual(@intFromPtr(&nothing), std.mem.readInt(usize, bytes[8..16], builtin.cpu.arch.endian()));
    const mask_word: c_ulong = switch (@typeInfo(posix.sigset_t)) {
        .array => act.mask[0],
        else => act.mask,
    };
    try std.testing.expectEqual(mask_word, std.mem.readInt(c_ulong, bytes[16..24], builtin.cpu.arch.endian()));
    const restorer_bits: usize = if (@hasField(posix.Sigaction, "restorer")) @intFromPtr(&restorer) else 0;
    try std.testing.expectEqual(restorer_bits, std.mem.readInt(usize, bytes[24..32], builtin.cpu.arch.endian()));
}

test "an action survives bionic's layout: its handler, flags and first mask word" {
    if (no_signals) return error.SkipZigTest;
    const acts = [_]posix.Sigaction{
        withMask(.{ .handler = posix.SIG.IGN }, 0),
        withMask(.{ .handler = nothing }, posix.SA.RESTART),
        withMask(.{ .sigaction = nothingInfo }, posix.SA.SIGINFO | posix.SA.ONSTACK),
    };
    for (acts) |act| {
        const back = sig.fromBionic(sig.toBionic(act));
        try std.testing.expectEqual(@intFromPtr(act.handler.handler), @intFromPtr(back.handler.handler));
        try std.testing.expectEqual(act.flags, back.flags);
        switch (@typeInfo(posix.sigset_t)) {
            .array => try std.testing.expectEqual(act.mask[0], back.mask[0]),
            else => try std.testing.expectEqual(act.mask, back.mask),
        }
    }
}

test "on the host, an action installed is the one read back" {
    if (no_signals) return error.SkipZigTest;
    const ignore: posix.Sigaction = .{ .handler = .{ .handler = posix.SIG.IGN }, .mask = posix.sigemptyset(), .flags = 0 };
    var before: posix.Sigaction = undefined;
    sig.sigaction(.USR2, &ignore, &before);
    defer sig.sigaction(.USR2, &before, null);
    var now: posix.Sigaction = undefined;
    sig.sigaction(.USR2, null, &now);
    try std.testing.expectEqual(@intFromPtr(posix.SIG.IGN), @intFromPtr(now.handler.handler));
}
