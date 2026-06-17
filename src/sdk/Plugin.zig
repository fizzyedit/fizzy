//! A feature module that plugs into the editor shell. Today plugins are compiled
//! in and registered statically; the same vtable shape is what a prebuilt plugin
//! dylib will expose at runtime (validated in `spikes/shared-globals/`). All hooks
//! are optional function pointers taking the plugin's own opaque `state`, so a
//! plugin implements only what it needs (e.g. the workbench plugin has no
//! `drawDocument`; an editor plugin does).
//!
//! Cross-boundary types may be normal Zig types (not strict C-ABI): host and
//! plugins are pinned to the same SDK build, so layouts match. Only the dlopen
//! entry symbols (added in Phase 4) need `callconv(.c)`.
//!
//! Phase 0: type definition only; nothing constructs or calls plugins yet.
const std = @import("std");
const dvui = @import("dvui");
const DocHandle = @import("DocHandle.zig");

pub const Plugin = @This();

/// Opaque, plugin-owned state passed back to every vtable call.
state: *anyopaque,
vtable: *const VTable,

/// Stable, unique identifier (snake_case), e.g. "pixelart", "workbench".
id: []const u8,
/// User-facing name shown in UI.
display_name: []const u8,

pub const VTable = struct {
    /// Tear down `state`. Called when the plugin is unregistered / app shuts down.
    deinit: ?*const fn (state: *anyopaque) void = null,

    /// Priority for opening files with extension `ext` (including the dot, e.g.
    /// ".fiz"); lower value wins. `null` = this plugin does not handle `ext`.
    /// Mirrors dvui-editor's fileTypePriority. A plugin may claim many extensions.
    fileTypePriority: ?*const fn (state: *anyopaque, ext: []const u8) ?u8 = null,

    // ---- document lifecycle (operates on the plugin's own type via DocHandle) ----
    openDocument: ?*const fn (state: *anyopaque, path: []const u8) anyerror!DocHandle = null,
    saveDocument: ?*const fn (state: *anyopaque, doc: DocHandle) anyerror!void = null,
    closeDocument: ?*const fn (state: *anyopaque, doc: DocHandle) void = null,
    isDirty: ?*const fn (state: *anyopaque, doc: DocHandle) bool = null,
    undo: ?*const fn (state: *anyopaque, doc: DocHandle) anyerror!void = null,
    redo: ?*const fn (state: *anyopaque, doc: DocHandle) anyerror!void = null,

    // ---- render hooks (the plugin draws its own dvui UI into the host window) ----
    /// Draw the plugin's explorer/sidebar pane (left region).
    drawExplorerPane: ?*const fn (state: *anyopaque) anyerror!void = null,
    /// Draw an open document (center/workspace region).
    drawDocument: ?*const fn (state: *anyopaque, doc: DocHandle) anyerror!void = null,
    /// Draw the plugin's bottom panel content.
    drawBottomPanel: ?*const fn (state: *anyopaque) anyerror!void = null,

    // ---- shell contributions ----
    contributeMenu: ?*const fn (state: *anyopaque) anyerror!void = null,
    contributeKeybinds: ?*const fn (state: *anyopaque, win: *dvui.Window) anyerror!void = null,
};

// Thin wrappers so callers don't repeat the optional-vtable dance.

pub fn fileTypePriority(self: Plugin, ext: []const u8) ?u8 {
    return if (self.vtable.fileTypePriority) |f| f(self.state, ext) else null;
}

pub fn deinit(self: Plugin) void {
    if (self.vtable.deinit) |f| f(self.state);
}
