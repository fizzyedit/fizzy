//! Stand-in for dvui: a global immediate-mode context pointer plus a "widget"
//! call that reads the global and mutates the shared Window. Both the host exe
//! and the plugin dylib compile THIS source independently (as dvui would be
//! compiled into each), so each binary gets its own copy of these globals.
//! The spike answers: can the plugin still drive the host's dvui state — its
//! Window, its per-frame arena allocator, and its FreeType handle?
const std = @import("std");

/// Stand-in for dvui's FT_Library handle (`dvui.ft2lib`, dvui.zig:346): a host-
/// owned resource the plugin must use, not reinitialize.
pub const FreeType = struct {
    shape_calls: u32 = 0,
};

pub const Window = struct {
    widget_count: u32 = 0,
    magic: u64 = 0xDEADBEEF,
    /// Stand-in for dvui's per-frame arena, which lives in the Window. Plugins
    /// allocate widget data through this — i.e. the HOST's allocator.
    arena: ?std.mem.Allocator = null,
};

/// Mirrors `dvui.current_window` (dvui.zig:416) — the shared immediate-mode context.
pub var current_window: ?*Window = null;
/// Mirrors `dvui.ft2lib` — a global library handle that must be injected too.
pub var ft2lib: ?*FreeType = null;

/// Mirrors a dvui widget constructor: reads the global, allocates label text in
/// the Window's arena, shapes it via the FreeType handle, mutates the Window.
pub fn label(text: []const u8) ![]u8 {
    const w = current_window orelse return error.NoCurrentWindow;
    std.debug.assert(w.magic == 0xDEADBEEF); // layout/pointer sanity across boundary
    const ft = ft2lib orelse return error.NoFreeType;

    const arena = w.arena orelse return error.NoArena;
    const copy = try arena.dupe(u8, text); // allocate via the HOST's allocator
    ft.shape_calls += 1; // touch the HOST's FreeType handle
    w.widget_count += 1;
    return copy;
}

pub fn setCurrentWindow(w: ?*Window) void {
    current_window = w;
}
pub fn setFreeType(ft: ?*FreeType) void {
    ft2lib = ft;
}
pub fn currentWindowAddr() usize {
    return @intFromPtr(&current_window);
}
