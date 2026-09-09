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
const runtime = @import("runtime.zig");
const workbench_layout = @import("workbench_layout.zig");
const sdk = @import("fizzy_sdk");

pub const Api = sdk.services.workbench.Api;
pub const BranchDecorator = Api.BranchDecorator;

pub const Workbench = @This();

allocator: std.mem.Allocator,
decorators: std.ArrayListUnmanaged(BranchDecorator) = .empty,

/// Workspaces keyed by tab-grouping id (owned here, not on fizzy Editor).
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


/// A path that has just appeared on disk and should be revealed: parents expanded, row selected,
/// inline rename opened, and the rect handed to any dialog still closing over the top of it.
///
/// Lives on this **instance** rather than as a `files.zig` global on purpose. `files.zig` is
/// compiled twice — once into fizzy, once into the workbench dylib — so its module-level `var`s
/// are two separate objects, and a write from fizzy lands in the copy nobody draws. Instance
/// state does cross that boundary: fizzy passes `&editor.workbench` into the dylib as `arg_c`
/// (`Editor.loadWorkbenchDylib`), so both copies see this exact field.
pending_new_file_path: ?[]u8 = null,


/// Queue `path` to be revealed by the file tree on an upcoming frame, replacing any path already
/// queued. Safe from either copy of the module; the tree consumes it when the row exists.
pub fn setPendingNewFilePath(self: *Workbench, path: []const u8) !void {
    const dup = try self.allocator.dupe(u8, path);
    if (self.pending_new_file_path) |old| self.allocator.free(old);
    self.pending_new_file_path = dup;
}

/// Drop the queued reveal, if any.
pub fn clearPendingNewFilePath(self: *Workbench) void {
    if (self.pending_new_file_path) |old| self.allocator.free(old);
    self.pending_new_file_path = null;
}

pub fn init(allocator: std.mem.Allocator) Workbench {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Workbench) void {
    files.deinitCaches();
    self.decorators.deinit(self.allocator);
    self.clearPendingNewFilePath();
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

/// When the open doc at `closed_index` closes, pick another tab in the same workspace,
/// and shift every OTHER workspace's `open_file_index` down by one if it pointed past
/// the closed slot — `open_files` is a single shared array, so removing an entry moves
/// every workspace's index into it, not just the one that triggered the close.
pub fn adjustOpenFileIndexAfterClose(
    self: *Workbench,
    grouping: u64,
    closed_index: usize,
    replacement_index: ?usize,
) void {
    for (self.workspaces.values()) |*workspace| {
        if (workspace.grouping == grouping and workspace.open_file_index == closed_index) {
            if (replacement_index) |idx| workspace.open_file_index = idx;
        } else if (workspace.open_file_index > closed_index) {
            workspace.open_file_index -= 1;
        }
    }
}

pub fn rebuildWorkspaces(self: *Workbench) !void {
    return workbench_layout.rebuildWorkspaces(self);
}

pub fn drawWorkspaces(self: *Workbench, index: usize) !dvui.App.Result {
    return workbench_layout.drawWorkspaces(self, index);
}

pub fn activeDoc(self: *Workbench) ?sdk.DocHandle {
    if (self.workspaces.get(self.open_workspace_grouping)) |workspace| {
        return runtime.host().docByIndex(workspace.open_file_index);
    }
    return null;
}

pub fn setActiveDocIndex(self: *Workbench, index: usize) void {
    const doc = runtime.host().docByIndex(index) orelse return;
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

/// Build the `workbench-api` service. `host_ctx` is fizzy `*Host`.
pub fn initService(self: *Workbench, host_ctx: *sdk.Host) void {
    self.api = .{ .ctx = host_ctx, .vtable = &service_vtable };
}

/// Register the decorations fizzy ships with. Called once after the editor is
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
    const doc = runtime.host().docFromPath(path) orelse return;
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
// workbench-api — the formal Host service (layout defined in sdk/services/workbench.zig)
// ============================================================================

const service_vtable: Api.VTable = .{
    .currentGrouping = svcCurrentGrouping,
    .newGrouping = svcNewGrouping,
    .registerBranchDecorator = svcRegisterBranchDecorator,
};

fn svcCurrentGrouping(_: *anyopaque) u64 {
    return runtime.workbench().currentGroupingID();
}
fn svcNewGrouping(_: *anyopaque) u64 {
    return runtime.workbench().newGroupingID();
}
fn svcRegisterBranchDecorator(_: *anyopaque, decorator: BranchDecorator) anyerror!void {
    return runtime.workbench().registerBranchDecorator(decorator);
}
