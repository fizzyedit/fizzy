//! The shell-provided read/utility surface a plugin reaches through the `Host`.
//!
//! The shell installs one of these on the `Host` during startup (`Host.installShell`);
//! plugins call the convenience forwarders on `Host` (e.g. `host.arena()`), which
//! dispatch through this vtable. It exposes only the genuinely shared shell state a
//! plugin still needs — the per-frame arena, the open project folder, the few shell-
//! owned settings plugins read, and the dirty-mark hook — without leaking the concrete
//! `Editor` type across the SDK boundary.
const std = @import("std");

const ShellApi = @This();

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
};

pub fn arena(self: ShellApi) std.mem.Allocator {
    return self.vtable.arena(self.ctx);
}

pub fn folder(self: ShellApi) ?[]const u8 {
    return self.vtable.folder(self.ctx);
}

pub fn paletteFolder(self: ShellApi) ?[]const u8 {
    return self.vtable.paletteFolder(self.ctx);
}

pub fn markSettingsDirty(self: ShellApi) void {
    self.vtable.markSettingsDirty(self.ctx);
}

pub fn contentOpacity(self: ShellApi) f32 {
    return self.vtable.contentOpacity(self.ctx);
}
