//! The shell-provided read/utility surface a plugin reaches through the `Host`.
//!
//! The shell installs one of these on the `Host` during startup (`Host.installShell`);
//! plugins call the convenience forwarders on `Host` (e.g. `host.arena()`), which
//! dispatch through this vtable. It exposes only the genuinely shared shell state a
//! plugin still needs — the per-frame arena, the open project folder, the few shell-
//! owned settings plugins read, and the dirty-mark hook — without leaking the concrete
//! `Editor` type across the SDK boundary.
const std = @import("std");
const dvui = @import("dvui");

const EditorAPI = @This();

/// Sub-rect within the shell UI spritesheet. Layout matches `core.Sprite`.
pub const UiSprite = struct {
    origin: [2]f32 = .{ 0.0, 0.0 },
    source: [4]u32,
};

/// Read-only view of the shell's UI icon atlas (source texture + sprite table).
pub const UiAtlasView = struct {
    source: dvui.ImageSource,
    sprites: []const UiSprite,
};

/// A name/extension-pattern pair for a native save dialog. Layout matches the backend's
/// `DialogFileFilter` (which mirrors `SDL_DialogFileFilter`), so the shell forwards a slice
/// of these straight to the backend without a copy. `pattern` is a `;`-separated extension
/// list, e.g. `"png;jpg;jpeg"`.
pub const SaveDialogFilter = extern struct {
    name: [*:0]const u8,
    pattern: [*:0]const u8,
};

/// Invoked when a native save dialog resolves: the chosen paths, or null if cancelled.
pub const SaveDialogCallback = *const fn (?[][:0]const u8) void;

ctx: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    /// The shell's per-frame arena allocator (reset every frame; do not free).
    arena: *const fn (ctx: *anyopaque) std.mem.Allocator,
    /// The open project root folder, or null when none is open.
    folder: *const fn (ctx: *anyopaque) ?[]const u8,
    /// The user palettes folder (config), or null on platforms without one (web).
    paletteFolder: *const fn (ctx: *anyopaque) ?[]const u8,
    /// Mark shell settings dirty so the debounced autosave persists them.
    markSettingsDirty: *const fn (ctx: *anyopaque) void,
    /// Shell-owned content-area opacity (also drives the shell's own panes); plugins
    /// read it to match the shell chrome.
    contentOpacity: *const fn (ctx: *anyopaque) f32,
    /// Whether the OS window is currently maximized (always false on web).
    isMaximized: *const fn (ctx: *anyopaque) bool,
    /// The explorer pane's content rect (shell layout); plugins drawn inside the explorer
    /// read it to size their content. Zero rect when no shell is installed.
    explorerRect: *const fn (ctx: *anyopaque) dvui.Rect,
    /// The explorer scroll area's virtual content size (shell layout). Zero size when no
    /// shell is installed.
    explorerVirtualSize: *const fn (ctx: *anyopaque) dvui.Size,
    /// Run the platform's native "save file" dialog (native: OS dialog; web: download
    /// picker). `cb` is invoked when it resolves. No-op when no shell is installed.
    showSaveDialog: *const fn (
        ctx: *anyopaque,
        cb: SaveDialogCallback,
        filters: []const SaveDialogFilter,
        default_filename: []const u8,
        default_folder: ?[]const u8,
    ) void,
    /// Shell-owned UI icon spritesheet (cursors, tool icons, logo). Stable for the
    /// editor lifetime; plugins read `.source` / `.sprites` but never mutate it.
    uiAtlas: *const fn (ctx: *anyopaque) UiAtlasView,
};

pub fn arena(self: EditorAPI) std.mem.Allocator {
    return self.vtable.arena(self.ctx);
}

pub fn folder(self: EditorAPI) ?[]const u8 {
    return self.vtable.folder(self.ctx);
}

pub fn paletteFolder(self: EditorAPI) ?[]const u8 {
    return self.vtable.paletteFolder(self.ctx);
}

pub fn markSettingsDirty(self: EditorAPI) void {
    self.vtable.markSettingsDirty(self.ctx);
}

pub fn contentOpacity(self: EditorAPI) f32 {
    return self.vtable.contentOpacity(self.ctx);
}

pub fn isMaximized(self: EditorAPI) bool {
    return self.vtable.isMaximized(self.ctx);
}

pub fn explorerRect(self: EditorAPI) dvui.Rect {
    return self.vtable.explorerRect(self.ctx);
}

pub fn explorerVirtualSize(self: EditorAPI) dvui.Size {
    return self.vtable.explorerVirtualSize(self.ctx);
}

pub fn showSaveDialog(
    self: EditorAPI,
    cb: SaveDialogCallback,
    filters: []const SaveDialogFilter,
    default_filename: []const u8,
    default_folder: ?[]const u8,
) void {
    self.vtable.showSaveDialog(self.ctx, cb, filters, default_filename, default_folder);
}

pub fn uiAtlas(self: EditorAPI) UiAtlasView {
    return self.vtable.uiAtlas(self.ctx);
}
