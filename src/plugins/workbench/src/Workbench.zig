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
const sdk = @import("sdk");

pub const Api = sdk.services.workbench.Api;
pub const BranchDecorator = Api.BranchDecorator;

pub const Workbench = @This();

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

/// Positions to reveal once their (not-yet-open) path finishes loading, set by
/// `revealPosition` when the target isn't open yet. Polled once per frame in
/// `drawWorkspaces` against `host.docFromPath` and cleared once applied. Rare/short-lived
/// (usually at most one pending reveal at a time from a single goto-definition click), so a
/// linear per-frame scan is fine — not worth threading through `Editor.zig`'s load-completion
/// callback for this.
pending_reveals: std.ArrayListUnmanaged(PendingReveal) = .empty,

const PendingReveal = struct {
    path: []u8,
    line: u32,
    character: u32,
};

pub fn init(allocator: std.mem.Allocator) Workbench {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Workbench) void {
    self.decorators.deinit(self.allocator);
    for (self.pending_reveals.items) |pr| self.allocator.free(pr.path);
    self.pending_reveals.deinit(self.allocator);
}

/// Called once per frame from `drawWorkspaces`. Applies and clears any pending reveal whose
/// target document has finished loading.
pub fn pollPendingReveals(self: *Workbench) void {
    if (self.pending_reveals.items.len == 0) return;
    var i: usize = 0;
    while (i < self.pending_reveals.items.len) {
        const pr = self.pending_reveals.items[i];
        if (runtime.host().docFromPath(pr.path)) |doc| {
            doc.owner.revealPosition(doc, pr.line, pr.character);
            self.allocator.free(pr.path);
            _ = self.pending_reveals.swapRemove(i);
        } else {
            i += 1;
        }
    }
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

pub fn drawWorkspaces(self: *Workbench, panel: workbench_layout.PanelPanedState, index: usize) !dvui.App.Result {
    self.pollPendingReveals();
    return workbench_layout.drawWorkspaces(self, panel, index);
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
    .revealPosition = svcRevealPosition,
};

inline fn hostOf(ctx: *anyopaque) *sdk.Host {
    return @ptrCast(@alignCast(ctx));
}

fn svcOpen(ctx: *anyopaque, path: []const u8, grouping: u64) anyerror!bool {
    return hostOf(ctx).openFilePath(path, grouping);
}
fn svcCurrentGrouping(_: *anyopaque) u64 {
    return runtime.workbench().currentGroupingID();
}
fn svcNewGrouping(_: *anyopaque) u64 {
    return runtime.workbench().newGroupingID();
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
    return runtime.workbench().registerBranchDecorator(decorator);
}
fn svcRevealPosition(ctx: *anyopaque, path: []const u8, line: u32, character: u32, open_side: bool) anyerror!bool {
    const host = hostOf(ctx);
    if (host.docFromPath(path)) |doc| {
        doc.owner.revealPosition(doc, line, character);
        // `revealPosition` alone only sets `pending_cursor` on the (possibly background-tab)
        // document — nothing else about this path made it the *visible* one. Without this,
        // jumping to a definition already open in a non-active tab/pane silently sets the
        // caret there and stops: the tab never gets focus, so the document is never drawn to
        // consume `pending_cursor`, and the jump looks like a no-op. `open_side` is ignored
        // here — an already-open target just gets focused wherever it already lives, the same
        // way the file tree's "Open to the side" doesn't move an already-open file either.
        if (host.docIndex(doc.id)) |idx| host.setActiveDocIndex(idx);
        return true;
    }

    // No plugin claims this extension at all — `openFilePath` would just reject it below, so
    // fail fast instead of queuing a pending reveal that could never resolve.
    if (host.pluginForExtension(std.fs.path.extension(path)) == null) return false;

    const wb = runtime.workbench();
    const owned_path = try wb.allocator.dupe(u8, path);
    errdefer wb.allocator.free(owned_path);
    try wb.pending_reveals.append(wb.allocator, .{ .path = owned_path, .line = line, .character = character });
    // `openFilePath` returning `false` here (as opposed to an actual error) only ever means
    // "a load for this exact path is already in flight" — the "already open" case was ruled
    // out by `docFromPath` above, and "no owner plugin" by the check above. Either way the
    // file WILL finish loading and `pollPendingReveals` will pick it up once it does, so the
    // just-queued reveal must stay queued rather than being dropped on a plain `false` (which
    // previously discarded the goto-definition target whenever a load for it happened to
    // already be in progress, silently landing on "opened the file, caret never moved").
    // `open_side`: mint a fresh grouping so the load lands in a new split instead of the
    // current one — mirrors the file tree's "Open to the side" menu action exactly.
    const target_grouping = if (open_side) wb.newGroupingID() else wb.currentGroupingID();
    _ = host.openFilePath(path, target_grouping) catch |err| {
        wb.pending_reveals.items.len -= 1;
        wb.allocator.free(owned_path);
        return err;
    };
    return true;
}
