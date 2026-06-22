//! The Workbench is the file-management home of the editor. This plugin owns the
//! file tree (`files.zig`), the open/load flow (`FileLoadJob.zig`), and the
//! workspace/tabs/splits system (`Workspace.zig`). It exposes its capabilities to
//! other plugins through the `workbench-api` Host service (`Workbench.Api`) so they
//! never reach into the editor globals.
//!
//! Per-branch decorations let any plugin draw a right-justified icon on a file row
//! (e.g. the built-in "unsaved" dot). Decorators run inside the row's hbox after
//! the label, so an expanding label pushes them to the right edge.
const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const files = @import("files.zig");
const Workspace = @import("Workspace.zig");
const Globals = @import("Globals.zig");
const workbench_layout = @import("workbench_layout.zig");
const sdk = @import("sdk");

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

/// Workspaces keyed by tab-grouping id (owned here, not on the shell Editor).
workspaces: std.AutoArrayHashMapUnmanaged(u64, Workspace) = .empty,
open_workspace_grouping: u64 = 0,
grouping_id_counter: u64 = 0,
tab_drag_from_tree_path: ?[]u8 = null,
file_tree_data_id: ?dvui.Id = null,

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

pub fn initDefaultWorkspace(self: *Workbench) !void {
    self.workspaces = .empty;
    try self.workspaces.put(self.allocator, 0, Workspace.init(0));
}

pub fn deinitWorkspaces(self: *Workbench) void {
    for (self.workspaces.values()) |*workspace| workspace.deinit();
    self.workspaces.deinit(self.allocator);
}

pub fn currentGroupingID(self: *Workbench) u64 {
    return self.open_workspace_grouping;
}

pub fn newGroupingID(self: *Workbench) u64 {
    self.grouping_id_counter += 1;
    return self.grouping_id_counter;
}

pub fn clearFileTreeTabDragDropState(self: *Workbench) void {
    if (self.tab_drag_from_tree_path) |p| {
        self.allocator.free(p);
        self.tab_drag_from_tree_path = null;
    }
}

pub fn clearFileTreeDataId(self: *Workbench) void {
    self.file_tree_data_id = null;
}

/// Explorer peek/collapse hides the workspace subtree; clear latched center flags.
pub fn clearAllWorkspaceCenter(self: *Workbench) void {
    for (self.workspaces.values()) |*ws| {
        ws.center = false;
    }
}

/// When the open doc at `closed_index` closes, pick another tab in the same workspace.
pub fn adjustOpenFileIndexAfterClose(
    self: *Workbench,
    grouping: u64,
    closed_index: usize,
    replacement_index: ?usize,
) void {
    const workspace = self.workspaces.getPtr(grouping) orelse return;
    if (workspace.open_file_index == closed_index) {
        if (replacement_index) |idx| workspace.open_file_index = idx;
    }
}

pub fn rebuildWorkspaces(self: *Workbench) !void {
    return workbench_layout.rebuildWorkspaces(self);
}

pub fn drawWorkspaces(self: *Workbench, panel: workbench_layout.PanelPanedState, index: usize) !dvui.App.Result {
    return workbench_layout.drawWorkspaces(self, panel, index);
}

pub fn activeDoc(self: *Workbench) ?sdk.DocHandle {
    if (self.workspaces.get(self.open_workspace_grouping)) |workspace| {
        return Globals.host.docByIndex(workspace.open_file_index);
    }
    return null;
}

pub fn setActiveDocIndex(self: *Workbench, index: usize) void {
    const doc = Globals.host.docByIndex(index) orelse return;
    const grouping = doc.owner.documentGrouping(doc);
    if (self.workspaces.getPtr(grouping)) |workspace| {
        self.open_workspace_grouping = grouping;
        workspace.open_file_index = index;
    }
}

pub fn activeWorkspaceCanvasRectPhysical(self: *Workbench) ?dvui.Rect.Physical {
    const workspace = self.workspaces.getPtr(self.open_workspace_grouping) orelse return null;
    return workspace.canvas_rect_physical;
}

/// Build the `workbench-api` service. `host_ctx` is the shell `*Host`.
pub fn initService(self: *Workbench, host_ctx: *sdk.Host) void {
    self.api = .{ .ctx = host_ctx, .vtable = &service_vtable };
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
    const doc = Globals.host.docFromPath(path) orelse return;
    if (doc.owner.showsSaveStatusIndicator(doc)) return;
    if (!doc.owner.isDirty(doc)) return;
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

inline fn hostOf(ctx: *anyopaque) *sdk.Host {
    return @ptrCast(@alignCast(ctx));
}

fn svcOpen(ctx: *anyopaque, path: []const u8, grouping: u64) anyerror!bool {
    return hostOf(ctx).openFilePath(path, grouping);
}
fn svcCurrentGrouping(_: *anyopaque) u64 {
    return Globals.workbench.currentGroupingID();
}
fn svcNewGrouping(_: *anyopaque) u64 {
    return Globals.workbench.newGroupingID();
}
fn svcClose(ctx: *anyopaque, id: u64) anyerror!void {
    return hostOf(ctx).closeDocById(id);
}
fn svcSave(ctx: *anyopaque) anyerror!void {
    return hostOf(ctx).save();
}
fn svcIsOpen(ctx: *anyopaque, path: []const u8) bool {
    return hostOf(ctx).docFromPath(path) != null;
}
fn svcOpenCount(ctx: *anyopaque) usize {
    return hostOf(ctx).openDocCount();
}
fn svcOpenPathAt(ctx: *anyopaque, index: usize) ?[]const u8 {
    const doc = hostOf(ctx).docByIndex(index) orelse return null;
    return doc.owner.documentPath(doc);
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
fn svcRegisterBranchDecorator(_: *anyopaque, decorator: BranchDecorator) anyerror!void {
    return Globals.workbench.registerBranchDecorator(decorator);
}
