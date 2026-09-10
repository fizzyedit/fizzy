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

pub fn workbench() *Workbench {
    if (fizzy_workbench) |w| return w;
    if (sdk.injectedState(Workbench)) |w| return w;
    @panic("workbench pointer not wired");
}
