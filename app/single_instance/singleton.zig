//! Arch-switching facade for single-instance support. Native (`singleton_native.zig`)
//! uses Unix sockets / Windows named pipes via `dvui-singleton-app`. Web
//! (`singleton_web.zig`) is a no-op layer: one browser tab = one fizzy, no
//! cross-tab argv forwarding.
//!
//! Zig only semantically analyzes the chosen branch, so the wasm build never
//! sees the socket / pipe / process imports inside `singleton_native.zig`.

const builtin = @import("builtin");

const impl = if (builtin.target.cpu.arch == .wasm32)
    @import("singleton_web.zig")
else
    @import("singleton_native.zig");

pub const app_id = impl.app_id;
pub const earlyStartup = impl.earlyStartup;
pub const consumeStartupArgv = impl.consumeStartupArgv;
pub const acquireLock = impl.acquireLock;
pub const registerWindow = impl.registerWindow;
pub const deinit = impl.deinit;
pub const drainPending = impl.drainPending;
pub const queuePath = impl.queuePath;
pub const collectAndResolveArgv = impl.collectAndResolveArgv;
/// What the application does with a forwarded path. Native only — one browser tab is one app,
/// so the web layer has nothing to forward.
pub const setSink = if (builtin.target.cpu.arch == .wasm32) noopSetSink else impl.setSink;

fn noopSetSink(_: anytype) void {}

/// The application's own identity: the bundle id the lock is named for, and the executable name
/// used when argv has to be reconstructed. Set before `earlyStartup`.
pub fn setIdentity(bundle_id: [:0]const u8, name: []const u8) void {
    impl.app_id = bundle_id;
    impl.app_name = name;
}
pub const freeResolvedArgv = impl.freeResolvedArgv;
