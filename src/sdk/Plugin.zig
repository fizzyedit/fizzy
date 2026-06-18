//! A feature module that plugs into the editor shell. Today plugins are compiled
//! in and registered statically; the same vtable shape is what a prebuilt plugin
//! dylib will expose at runtime. All hooks are optional function pointers taking
//! the plugin's own opaque `state`, so a plugin implements only what it needs
//! (e.g. the workbench plugin has no `drawDocument`; an editor plugin does).
//!
//! Cross-boundary types may be normal Zig types (not strict C-ABI): host and
//! plugins are pinned to the same SDK build, so layouts match. Only the dlopen
//! entry symbols need `callconv(.c)`.
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
    /// A plugin may claim many extensions.
    fileTypePriority: ?*const fn (state: *anyopaque, ext: []const u8) ?u8 = null,

    // ---- document lifecycle (operates on the plugin's own type via DocHandle) ----
    /// Load the document at `path`, constructing the plugin's own document value in
    /// place at `out_doc`. The shell owns the typed buffer behind `out_doc` (for pixel
    /// art a `*Internal.File`); the SDK stays type-agnostic. Runs on the shell's load
    /// worker thread, so it must only touch the host allocator + the given buffer.
    loadDocument: ?*const fn (state: *anyopaque, path: []const u8, out_doc: *anyopaque) anyerror!void = null,
    /// `loadDocument`, but from in-memory bytes (browser file picker). `path` is used
    /// for extension detection + display name. Synchronous (web has no load worker).
    loadDocumentFromBytes: ?*const fn (state: *anyopaque, path: []const u8, bytes: []const u8, out_doc: *anyopaque) anyerror!void = null,
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

    // ---- per-frame shell hooks (global keybinds, overlays) ----
    tickKeybinds: ?*const fn (state: *anyopaque) anyerror!void = null,
    processRadialMenuInput: ?*const fn (state: *anyopaque) void = null,
    radialMenuVisible: ?*const fn (state: *anyopaque) bool = null,
    drawRadialMenu: ?*const fn (state: *anyopaque) anyerror!void = null,
};

// Thin wrappers so callers don't repeat the optional-vtable dance.

pub fn fileTypePriority(self: Plugin, ext: []const u8) ?u8 {
    return if (self.vtable.fileTypePriority) |f| f(self.state, ext) else null;
}

pub fn contributeKeybinds(self: Plugin, win: *dvui.Window) !void {
    if (self.vtable.contributeKeybinds) |f| try f(self.state, win);
}

pub fn tickKeybinds(self: Plugin) !void {
    if (self.vtable.tickKeybinds) |f| try f(self.state);
}

pub fn processRadialMenuInput(self: Plugin) void {
    if (self.vtable.processRadialMenuInput) |f| f(self.state);
}

pub fn radialMenuVisible(self: Plugin) bool {
    return if (self.vtable.radialMenuVisible) |f| f(self.state) else false;
}

pub fn drawRadialMenu(self: Plugin) !void {
    if (self.vtable.drawRadialMenu) |f| try f(self.state);
}

// ---- document lifecycle wrappers (operate on a DocHandle this plugin owns) ----

/// Load `path` into the shell-owned buffer at `out_doc`. Returns whether the plugin
/// handled it; `false` means this plugin exposes no loader (the shell should treat the
/// open as failed). See the `loadDocument` vtable field for the threading contract.
pub fn loadDocument(self: Plugin, path: []const u8, out_doc: *anyopaque) !bool {
    if (self.vtable.loadDocument) |f| {
        try f(self.state, path, out_doc);
        return true;
    }
    return false;
}

/// `loadDocument`, but from in-memory `bytes` (browser file picker).
pub fn loadDocumentFromBytes(self: Plugin, path: []const u8, bytes: []const u8, out_doc: *anyopaque) !bool {
    if (self.vtable.loadDocumentFromBytes) |f| {
        try f(self.state, path, bytes, out_doc);
        return true;
    }
    return false;
}

pub fn isDirty(self: Plugin, doc: DocHandle) bool {
    return if (self.vtable.isDirty) |f| f(self.state, doc) else false;
}

pub fn saveDocument(self: Plugin, doc: DocHandle) !void {
    if (self.vtable.saveDocument) |f| try f(self.state, doc);
}

/// Tear down an open document. Returns whether the plugin handled it, so the shell
/// can fall back to its own teardown when no plugin claims the document.
pub fn closeDocument(self: Plugin, doc: DocHandle) bool {
    if (self.vtable.closeDocument) |f| {
        f(self.state, doc);
        return true;
    }
    return false;
}

pub fn undo(self: Plugin, doc: DocHandle) !void {
    if (self.vtable.undo) |f| try f(self.state, doc);
}

pub fn redo(self: Plugin, doc: DocHandle) !void {
    if (self.vtable.redo) |f| try f(self.state, doc);
}

// ---- render hook wrappers ----

/// Draw an open document into the current dvui parent (the workbench sets up the
/// container, then routes here). Returns whether the plugin drew anything.
pub fn drawDocument(self: Plugin, doc: DocHandle) !bool {
    if (self.vtable.drawDocument) |f| {
        try f(self.state, doc);
        return true;
    }
    return false;
}

pub fn deinit(self: Plugin) void {
    if (self.vtable.deinit) |f| f(self.state);
}
