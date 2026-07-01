//! Minimal `std.Io` for the wasm web build: identical to `std.Io.failing` for
//! every operation EXCEPT `now`, which returns a real monotonic time read from
//! JavaScript via the DVUI `wasm_now` extern.
//!
//! Why this matters: DVUI uses `Clock.boot.now(dvui.io).nanoseconds` for any
//! time-based heuristic that runs even when no real Io is plugged in
//! (`mouseTypeIndicated` 1-second stale reset for trackpad vs wheel detection,
//! animation timers, etc.). The stock `std.Io.failing.now` returns
//! `Timestamp.zero` always — so on wasm those heuristics see time stuck at 0
//! and never advance.
//!
//! Wiring: `App.zig` passes `wasm_io` as `dvui.App.config.options.io` on wasm.
//! DVUI's web backend installs it as `dvui.io`, and `Clock.boot.now(dvui.io)`
//! now returns real milliseconds-since-page-load (converted to ns) instead of
//! 0. FS / async / dialog calls still hit the failing handlers — which is
//! correct, the browser has no filesystem.

const std = @import("std");
const builtin = @import("builtin");

const wasm = struct {
    extern "dvui" fn wasm_now() f64;
};

fn now(_: ?*anyopaque, _: std.Io.Clock) std.Io.Timestamp {
    // `wasm_now` returns `performance.now()` in milliseconds (monotonic
    // milliseconds since page load). Promote to i96 nanoseconds via i64.
    const ms = wasm.wasm_now();
    const ns: i64 = @intFromFloat(ms * std.time.ns_per_ms);
    return .{ .nanoseconds = ns };
}

/// Vtable: copy of `failing.vtable` with `.now` swapped out. Built at comptime
/// so the override is statically resolved.
const wasm_vtable: std.Io.Vtable = blk: {
    var v = std.Io.failing.vtable.*;
    v.now = now;
    break :blk v;
};

/// Use this in place of `std.Io.failing` whenever a wasm-only path needs a
/// working clock. On non-wasm targets it's not referenced from anywhere
/// reachable, so it costs nothing.
pub const wasm_io: std.Io = .{
    .userdata = null,
    .vtable = &wasm_vtable,
};

comptime {
    if (builtin.target.cpu.arch != .wasm32) {
        @compileError("web_io.zig is wasm-only; gate the import with `arch == .wasm32`");
    }
}
