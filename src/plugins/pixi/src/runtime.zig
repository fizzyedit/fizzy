//! Runtime accessors — backed by `sdk.runtime` and shell-owned state.
const std = @import("std");
const sdk = @import("sdk");
const State = @import("State.zig");
const Packer = @import("Packer.zig");

var shell_state: ?*State = null;

/// Static embed: App creates state and calls this before `postInit`.
pub fn adoptShellState(st: *State) void {
    shell_state = st;
}

pub fn allocator() std.mem.Allocator {
    return sdk.allocator();
}

pub fn host() *sdk.Host {
    return sdk.host();
}

pub fn state() *State {
    if (shell_state) |s| return s;
    if (sdk.injectedState(State)) |s| return s;
    const pl = sdk.host().pluginById("pixi") orelse @panic("pixi plugin not registered");
    return @ptrCast(@alignCast(pl.state));
}

pub fn packer() *Packer {
    return state().packer orelse @panic("pixi packer not wired");
}

pub fn setPacker(p: *Packer) void {
    if (shell_state) |s| s.packer = p;
}
