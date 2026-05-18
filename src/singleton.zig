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
pub const acquireLock = impl.acquireLock;
pub const registerWindow = impl.registerWindow;
pub const deinit = impl.deinit;
pub const drainPending = impl.drainPending;
pub const queuePath = impl.queuePath;
pub const collectAndResolveArgv = impl.collectAndResolveArgv;
pub const freeResolvedArgv = impl.freeResolvedArgv;
