//! Workbench inter-plugin service — SDK-facing definition of the `"workbench"` service.
//!
//! The workbench plugin registers an instance via `host.registerService`. Plugin code
//! uses `host.getServiceTyped(workbench.Api)`. The layout is part of the ABI fingerprint.
//!
//! ## What is *not* here, and why
//!
//! This was fifteen functions, twelve of which forwarded straight to the host: `open` called
//! `Host.openFilePath`, `close` called `Host.closeDocById`, `isOpen` called `Host.docFromPath`,
//! and `createFile` / `rename` / `delete` / `move` are now `Host` methods over
//! `core.FileTable`. `Editor` even described the service as "the file explorer's programmatic
//! surface" — which is the tell: it had become the place plugins met each other, and every
//! meeting made the workbench plugin a hard dependency of things that had nothing to do with
//! tabs. A plugin that wanted to create a file could not do it unless the plugin that draws tab
//! strips happened to be installed.
//!
//! So the rule this service now follows: **a service holds only what its own plugin is the
//! authority on.** Everything a plugin might reasonably ask fizzy for lives on `Host`, where it
//! degrades to a no-op in an app that ships no workbench instead of being unreachable. What is
//! left is the two questions only the thing drawing tabs can answer — *which split* — plus the
//! decoration hook, which is a request to draw inside a surface the workbench owns.
const std = @import("std");
const dvui = @import("dvui");

pub const Api = struct {
    /// Bump whenever this struct's layout changes: `getServiceTyped` refuses a provider whose
    /// version differs rather than reinterpreting one shape as another across `dlopen`.
    pub const service_version: u32 = 1;
    pub const service_name = "workbench";

    ctx: *anyopaque,
    vtable: *const VTable,

    pub const BranchDecorator = struct {
        ctx: ?*anyopaque = null,
        draw: *const fn (ctx: ?*anyopaque, path: []const u8, id_extra: usize) void,
    };

    pub const VTable = struct {
        /// The split newly opened documents land in. Pass to `Host.openFilePath` to open
        /// alongside whatever the user is looking at; an app with no splits can ignore the
        /// concept entirely and pass 0.
        currentGrouping: *const fn (ctx: *anyopaque) u64,
        /// Allocate a fresh split, for an "open to the side" action.
        newGrouping: *const fn (ctx: *anyopaque) u64,
        /// Draw something extra on every file row of the workbench's file tree — a badge, a
        /// status dot, a count. Called once per visible row, inside that row's box.
        registerBranchDecorator: *const fn (ctx: *anyopaque, decorator: BranchDecorator) anyerror!void,
    };

    pub fn currentGrouping(self: Api) u64 {
        return self.vtable.currentGrouping(self.ctx);
    }
    pub fn newGrouping(self: Api) u64 {
        return self.vtable.newGrouping(self.ctx);
    }
    pub fn registerBranchDecorator(self: Api, decorator: BranchDecorator) !void {
        return self.vtable.registerBranchDecorator(self.ctx, decorator);
    }
};
