//! The Workbench is the file-management home of the editor. Its module now owns
//! the file tree (`files.zig`), the open/load flow (`FileLoadJob.zig`), and the
//! workspace/tabs/splits system (`Workspace.zig`); in a later phase it becomes a
//! standalone plugin. It exposes its capabilities to other plugins through the
//! `workbench-api` Host service (`Workbench.Api`) so they never reach into the
//! `fizzy.editor` globals.
//!
//! Per-branch decorations let any plugin draw a right-justified icon on a file row
//! (e.g. the built-in "unsaved" dot). Decorators run inside the row's hbox after
//! the label, so an expanding label pushes them to the right edge.
const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const fizzy = @import("../../fizzy.zig");
const files = @import("files.zig");

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

/// The `workbench-api` service instance handed to plugins. Its `ctx` must be the
/// editor's FINAL heap address, so it's filled in by `initService` from
/// `Editor.postInit` (after `Editor.init`'s by-value result is copied to the heap),
/// not during `init` where `&editor.*` would point at a stack temporary.
api: Api = undefined,

pub fn init(allocator: std.mem.Allocator) Workbench {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Workbench) void {
    self.decorators.deinit(self.allocator);
}

/// Build the `workbench-api` service. `editor_ctx` is the host's heap `*Editor`,
/// passed opaquely so the API has no compile-time dependency back on the editor.
pub fn initService(self: *Workbench, editor_ctx: *anyopaque) void {
    self.api = .{ .ctx = editor_ctx, .vtable = &service_vtable };
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

// ============================================================================
// workbench-api — the formal Host service
// ============================================================================

/// The capabilities the workbench exposes to other plugins, retrieved via
/// `host.getService(Workbench.Api.service_name)` and `@ptrCast` to `*Api`. Plugins
/// drive file management through this instead of touching `fizzy.editor`: they open
/// documents, place them in tab groups/splits, mutate the file tree, and decorate
/// explorer rows.
///
/// Cross-boundary types are normal Zig (host + plugins share one pinned SDK build),
/// so this is a plain vtable struct; only the dlopen entry symbols need
/// `callconv(.c)`. The implementation lives below; `ctx` is the host's `*Editor`.
pub const Api = struct {
    /// Service-locator key for `host.registerService` / `host.getService`.
    pub const service_name = "workbench";

    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        // ---- open documents + tab/split placement ----
        /// Open `path` into workspace `grouping` (the tab group / split target).
        /// Returns true if newly opened (false if already open or unowned).
        open: *const fn (ctx: *anyopaque, path: []const u8, grouping: u64) anyerror!bool,
        /// The currently focused workspace grouping — the default placement target.
        currentGrouping: *const fn (ctx: *anyopaque) u64,
        /// Allocate a fresh grouping id for a new tab group / split.
        newGrouping: *const fn (ctx: *anyopaque) u64,
        /// Close the open document whose file id is `id`.
        close: *const fn (ctx: *anyopaque, id: u64) anyerror!void,
        /// Save the active document.
        save: *const fn (ctx: *anyopaque) anyerror!void,
        /// True if `path` is currently open in some workspace.
        isOpen: *const fn (ctx: *anyopaque, path: []const u8) bool,

        // ---- list open documents (no plugin-specific type leaks the boundary) ----
        /// Number of currently open documents.
        openCount: *const fn (ctx: *anyopaque) usize,
        /// Absolute path of the open document at `index`, or null if out of range.
        openPathAt: *const fn (ctx: *anyopaque, index: usize) ?[]const u8,

        // ---- file-tree operations ----
        createFile: *const fn (ctx: *anyopaque, path: []const u8) anyerror!void,
        createDir: *const fn (ctx: *anyopaque, path: []const u8) anyerror!void,
        rename: *const fn (ctx: *anyopaque, path: []const u8, new_path: []const u8, kind: std.Io.File.Kind) anyerror!void,
        delete: *const fn (ctx: *anyopaque, path: []const u8) void,
        /// Move `path` into directory `target_dir`. Returns true if it moved.
        move: *const fn (ctx: *anyopaque, path: []const u8, target_dir: []const u8) anyerror!bool,

        // ---- explorer row decorations ----
        registerBranchDecorator: *const fn (ctx: *anyopaque, decorator: BranchDecorator) anyerror!void,
    };

    // Thin wrappers so callers skip the `self.vtable.x(self.ctx, …)` dance.
    pub fn open(self: Api, path: []const u8, grouping: u64) !bool {
        return self.vtable.open(self.ctx, path, grouping);
    }
    pub fn currentGrouping(self: Api) u64 {
        return self.vtable.currentGrouping(self.ctx);
    }
    pub fn newGrouping(self: Api) u64 {
        return self.vtable.newGrouping(self.ctx);
    }
    pub fn close(self: Api, id: u64) !void {
        return self.vtable.close(self.ctx, id);
    }
    pub fn save(self: Api) !void {
        return self.vtable.save(self.ctx);
    }
    pub fn isOpen(self: Api, path: []const u8) bool {
        return self.vtable.isOpen(self.ctx, path);
    }
    pub fn openCount(self: Api) usize {
        return self.vtable.openCount(self.ctx);
    }
    pub fn openPathAt(self: Api, index: usize) ?[]const u8 {
        return self.vtable.openPathAt(self.ctx, index);
    }
    pub fn createFile(self: Api, path: []const u8) !void {
        return self.vtable.createFile(self.ctx, path);
    }
    pub fn createDir(self: Api, path: []const u8) !void {
        return self.vtable.createDir(self.ctx, path);
    }
    pub fn rename(self: Api, path: []const u8, new_path: []const u8, kind: std.Io.File.Kind) !void {
        return self.vtable.rename(self.ctx, path, new_path, kind);
    }
    pub fn delete(self: Api, path: []const u8) void {
        return self.vtable.delete(self.ctx, path);
    }
    pub fn move(self: Api, path: []const u8, target_dir: []const u8) !bool {
        return self.vtable.move(self.ctx, path, target_dir);
    }
    pub fn registerBranchDecorator(self: Api, decorator: BranchDecorator) !void {
        return self.vtable.registerBranchDecorator(self.ctx, decorator);
    }
};

const service_vtable: Api.VTable = .{
    .open = svcOpen,
    .currentGrouping = svcCurrentGrouping,
    .newGrouping = svcNewGrouping,
    .close = svcClose,
    .save = svcSave,
    .isOpen = svcIsOpen,
    .openCount = svcOpenCount,
    .openPathAt = svcOpenPathAt,
    .createFile = svcCreateFile,
    .createDir = svcCreateDir,
    .rename = svcRename,
    .delete = svcDelete,
    .move = svcMove,
    .registerBranchDecorator = svcRegisterBranchDecorator,
};

inline fn editorOf(ctx: *anyopaque) *fizzy.Editor {
    return @ptrCast(@alignCast(ctx));
}

fn svcOpen(ctx: *anyopaque, path: []const u8, grouping: u64) anyerror!bool {
    return editorOf(ctx).openFilePath(path, grouping);
}
fn svcCurrentGrouping(ctx: *anyopaque) u64 {
    return editorOf(ctx).currentGroupingID();
}
fn svcNewGrouping(ctx: *anyopaque) u64 {
    return editorOf(ctx).newGroupingID();
}
fn svcClose(ctx: *anyopaque, id: u64) anyerror!void {
    return editorOf(ctx).closeFileID(id);
}
fn svcSave(ctx: *anyopaque) anyerror!void {
    return editorOf(ctx).save();
}
fn svcIsOpen(ctx: *anyopaque, path: []const u8) bool {
    return editorOf(ctx).getFileFromPath(path) != null;
}
fn svcOpenCount(ctx: *anyopaque) usize {
    return editorOf(ctx).open_files.count();
}
fn svcOpenPathAt(ctx: *anyopaque, index: usize) ?[]const u8 {
    const editor = editorOf(ctx);
    if (index >= editor.open_files.count()) return null;
    return editor.open_files.values()[index].path;
}
fn svcCreateFile(_: *anyopaque, path: []const u8) anyerror!void {
    return files.createFilePath(path);
}
fn svcCreateDir(_: *anyopaque, path: []const u8) anyerror!void {
    return files.createDirPath(path);
}
fn svcRename(_: *anyopaque, path: []const u8, new_path: []const u8, kind: std.Io.File.Kind) anyerror!void {
    return files.renamePath(path, new_path, kind);
}
fn svcDelete(_: *anyopaque, path: []const u8) void {
    files.deletePath(path);
}
fn svcMove(_: *anyopaque, path: []const u8, target_dir: []const u8) anyerror!bool {
    return files.moveOnePath(path, target_dir, dvui.currentWindow().arena());
}
fn svcRegisterBranchDecorator(ctx: *anyopaque, decorator: BranchDecorator) anyerror!void {
    return editorOf(ctx).workbench.registerBranchDecorator(decorator);
}
