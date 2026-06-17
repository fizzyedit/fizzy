//! The Workbench owns cross-cutting file-management UI: today the per-branch
//! decoration registry for the file explorer; in later Phase 1 work it grows to
//! own the file tree, the open/load flow, and the tabs/splits system, then becomes
//! a standalone plugin exposing this as a service (`workbench-api`).
//!
//! Per-branch decorations let any plugin draw a right-justified icon on a file row
//! (e.g. the built-in "unsaved" dot). Decorators run inside the row's hbox after
//! the label, so an expanding label pushes them to the right edge.
const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const fizzy = @import("../fizzy.zig");

pub const Workbench = @This();

/// A hook to draw a decoration on a file row. `ctx` is decorator-owned (null for
/// stateless built-ins). `path` is the file's absolute path; `id_extra` is the
/// row's disambiguator (pass through to any dvui widget drawn).
pub const BranchDecorator = struct {
    ctx: ?*anyopaque = null,
    draw: *const fn (ctx: ?*anyopaque, path: []const u8, id_extra: usize) void,
};

allocator: std.mem.Allocator,
decorators: std.ArrayListUnmanaged(BranchDecorator) = .empty,

pub fn init(allocator: std.mem.Allocator) Workbench {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Workbench) void {
    self.decorators.deinit(self.allocator);
}

/// Register the decorations the shell ships with. Called once after the editor is
/// constructed. (Plugins register their own via `registerBranchDecorator`.)
pub fn registerBuiltins(self: *Workbench) !void {
    try self.registerBranchDecorator(.{ .draw = &drawUnsavedDot });
}

pub fn registerBranchDecorator(self: *Workbench, decorator: BranchDecorator) !void {
    try self.decorators.append(self.allocator, decorator);
}

/// Called by the file explorer for each file row (inside the row's hbox).
pub fn drawBranchDecorations(self: *Workbench, path: []const u8, id_extra: usize) void {
    for (self.decorators.items) |decorator| decorator.draw(decorator.ctx, path, id_extra);
}

/// Built-in: a dot on rows whose file is open with unsaved changes. Mirrors the
/// tab dirty indicator (`Workspace.zig` ~:528) so the two stay visually consistent.
fn drawUnsavedDot(_: ?*anyopaque, path: []const u8, id_extra: usize) void {
    const file = fizzy.editor.getFileFromPath(path) orelse return;
    if (!file.dirty()) return;
    dvui.icon(@src(), "explorer_dirty", icons.tvg.lucide.@"circle-small", .{
        .stroke_color = dvui.themeGet().color(.window, .text),
    }, .{
        .gravity_x = 1.0,
        .gravity_y = 0.5,
        .padding = dvui.Rect.all(2),
        .id_extra = id_extra,
    });
}
