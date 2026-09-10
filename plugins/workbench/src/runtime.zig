//! Runtime accessors — backed by `sdk.runtime` and fizzy-injected workbench pointer.
const std = @import("std");
const sdk = @import("fizzy_sdk");
const Workbench = @import("Workbench.zig");

var fizzy_workbench: ?*Workbench = null;

/// Static embed: App calls this before `postInit`.
pub fn setWorkbench(w: *Workbench) void {
    fizzy_workbench = w;
}

pub fn allocator() std.mem.Allocator {
    return sdk.allocator();
}

pub fn host() *sdk.Host {
    return sdk.host();
}

/// The app's `files` service, or null when it offers none.
///
/// Optional by construction: a file tree that cannot rename is still a file tree, so every
/// caller here degrades rather than failing. It was `Host.renamePath` and friends, which made
/// fizzy's implementation the only one an app could have.
pub fn files() ?sdk.services.files.Api {
    return if (host().getServiceTyped(sdk.services.files.Api)) |api| api.* else null;
}

pub fn workbench() *Workbench {
    if (fizzy_workbench) |w| return w;
    if (sdk.injectedState(Workbench)) |w| return w;
    @panic("workbench pointer not wired");
}
