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
const core = @import("core");
const icons = @import("icons");
const files = @import("files.zig");
const Workspace = @import("Workspace.zig");
const runtime = @import("runtime.zig");
const workbench_layout = @import("workbench_layout.zig");
const sdk = @import("fizzy_sdk");

pub const Api = sdk.services.workbench.Api;
pub const BranchDecorator = Api.BranchDecorator;

pub const Workbench = @This();

/// The split tree the panes live in. `core.widgets.DockLayout`, one panel per leaf.
pub const Panes = core.widgets.DockLayout;

allocator: std.mem.Allocator,
decorators: std.ArrayListUnmanaged(BranchDecorator) = .empty,

/// The panes, keyed by grouping, in row order. What each one *holds* is not here: it is the
/// app's assignment under the pane's name (`Workspace.name`), which is also how last session's
/// panes are found again.
workspaces: std.AutoArrayHashMapUnmanaged(u64, Workspace) = .empty,
/// Where each pane sits: a split tree whose leaves each hold one pane, by its region name
/// (`Workspace.name`). `workspaces` is *which* panes exist and what they hold; this is their
/// arrangement — which is beside which, and how the room is shared. Saved to `panes.zon` in the
/// plugin's own directory whenever it changes (`workbench_layout.savePanes`).
panes: Panes,
panes_dirty: bool = false,
open_workspace_grouping: u64 = 0,
grouping_id_counter: u64 = 0,
/// The tab being dragged this frame, by surface id, for the pane it lands in. Borrowed from the
/// registry entry, which outlives a drag.
dragging_surface: ?[]const u8 = null,
tab_drag_from_tree_path: ?[]u8 = null,
file_tree_data_id: ?dvui.Id = null,
/// Last session's panes are re-seated on the first rebuild, not at init: the load path is not
/// up yet when the workbench is constructed.
restored: bool = false,

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
    var panes = Panes.init(allocator);
    panes.owns_panel_ids = true;
    panes.animated = true;
    return .{ .allocator = allocator, .panes = panes };
}

pub fn deinit(self: *Workbench) void {
    files.deinitCaches();
    self.decorators.deinit(self.allocator);
    self.clearPendingNewFilePath();
}

pub fn initDefaultWorkspace(self: *Workbench) !void {
    self.workspaces = .empty;
    try self.workspaces.put(self.allocator, 0, Workspace.init(0));
    // The saved arrangement, if any, replaces this on the first rebuild — the load path is not
    // up yet here. Until then: one pane, filling the tree.
    const root = try self.panes.allocNodeForRoot();
    var buf: [32]u8 = undefined;
    try self.panes.insertTabOwned(root, 0, Workspace.name(&buf, 0));
}

/// The pane for `grouping`, created if it is new. A pane is a workspace and a leaf in the
/// tree; the region itself exists once the pane has drawn. A new pane opens beside the current
/// one, on its right — that is what "open to the side" means — sliding open from nothing.
pub fn pane(self: *Workbench, grouping: u64) !*Workspace {
    const gop = try self.workspaces.getOrPut(self.allocator, grouping);
    if (!gop.found_existing) gop.value_ptr.* = Workspace.init(grouping);
    if (grouping > self.grouping_id_counter) self.grouping_id_counter = grouping;
    try self.seatPane(grouping);
    return gop.value_ptr;
}

/// The tree leaf holding `grouping`'s pane, or null while it has none.
pub fn paneLeaf(self: *Workbench, grouping: u64) ?Panes.NodeIndex {
    var buf: [32]u8 = undefined;
    return self.panes.findPanel(Workspace.name(&buf, grouping));
}

/// Give `grouping` a leaf if it has none: the root when the tree is empty, else a split off the
/// current pane's right edge (or off the last pane, when the current one is gone).
fn seatPane(self: *Workbench, grouping: u64) !void {
    if (self.paneLeaf(grouping) != null) return;
    const root = &self.panes.nodes.items[self.panes.root];
    if (root.* == .leaf and root.leaf.tabs.items.len == 0) {
        var buf: [32]u8 = undefined;
        const pane_name = try self.allocator.dupe(u8, Workspace.name(&buf, grouping));
        errdefer self.allocator.free(pane_name);
        try self.panes.insertTab(self.panes.root, 0, pane_name);
        self.panes_dirty = true;
        return;
    }
    const anchor = if (self.paneLeaf(self.open_workspace_grouping)) |_| self.open_workspace_grouping else blk: {
        const last = self.panes.lastLeaf(self.panes.root);
        break :blk Workspace.groupingOfName(self.panes.nodes.items[last].leaf.tabs.items[0]) orelse self.open_workspace_grouping;
    };
    try self.paneBeside(grouping, anchor, .right);
}

/// Open a new pane for `grouping` on `side` of `anchor`'s pane — a drop on a pane's edge. The
/// workspace is created too, so `pane()` afterwards finds both.
pub fn paneBeside(self: *Workbench, grouping: u64, anchor: u64, side: Panes.Side) !void {
    if (self.paneLeaf(grouping) != null) return;
    const anchor_leaf = self.paneLeaf(anchor) orelse return error.NoSuchPane;
    var buf: [32]u8 = undefined;
    const pane_name = try self.allocator.dupe(u8, Workspace.name(&buf, grouping));
    errdefer self.allocator.free(pane_name);
    try self.panes.splitLeaf(anchor_leaf, side, pane_name);
    self.panes_dirty = true;
    const gop = try self.workspaces.getOrPut(self.allocator, grouping);
    if (!gop.found_existing) gop.value_ptr.* = Workspace.init(grouping);
    gop.value_ptr.expecting = true;
    if (grouping > self.grouping_id_counter) self.grouping_id_counter = grouping;
}

/// Send an emptied pane's leaf sliding shut. The workspace itself leaves once the leaf has
/// gone (`workbench_layout.rebuildWorkspaces`).
pub fn closePane(self: *Workbench, grouping: u64) void {
    const leaf = self.paneLeaf(grouping) orelse return;
    self.panes.closeLeaf(leaf);
}

pub fn deinitWorkspaces(self: *Workbench) void {
    for (self.workspaces.values()) |*workspace| workspace.deinit();
    self.workspaces.deinit(self.allocator);
    self.panes.deinit();
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

/// A document closed by the user: its tab leaves every pane. Not called at shutdown, where the
/// assignments are what bring the session back.
pub fn documentClosed(self: *Workbench, doc: sdk.DocHandle) void {
    const id = sdk.document.surfaceId(runtime.host().arena(), doc.owner.id, doc.owner.documentPath(doc)) catch return;
    for (self.workspaces.values()) |*ws| {
        ws.removeTab(id);
        // The pane's cached handle is refreshed by its draw; until then it still names this
        // document, owner pointer included. A plugin reload closes its documents and frees
        // that owner before anything draws, and the infobar asks `activeDoc()` first.
        if (ws.active) |active| {
            if (active.id == doc.id) ws.active = null;
        }
    }
}

/// A document's path changed under it (an explorer rename, a Save As): its tab is keyed by
/// the surface id the old path spelled, so the pane holding it swaps that id for the new one
/// in place — same slot, same selection. Without this the tab is orphaned: `documentOf` finds
/// no document at the old path and skips drawing it, `active` goes null, and every command that
/// starts from `activeDoc()` — Save first among them — quietly does nothing.
pub fn documentRenamed(self: *Workbench, doc: sdk.DocHandle, old_id: []const u8) void {
    const host = runtime.host();
    const arena = host.arena();
    const new_id = sdk.document.surfaceId(arena, doc.owner.id, doc.owner.documentPath(doc)) catch return;
    for (self.workspaces.values()) |*ws| {
        var buf: [32]u8 = undefined;
        const region_name = Workspace.name(&buf, ws.grouping);
        const existing = host.assignedSurfaces(region_name) orelse continue;
        var ids: std.ArrayListUnmanaged([]const u8) = .empty;
        var found = false;
        for (existing) |e| {
            const keep = if (std.mem.eql(u8, e, old_id)) blk: {
                found = true;
                break :blk new_id;
            } else e;
            ids.append(arena, keep) catch return;
        }
        if (!found) continue;
        host.assignSurfaces(region_name, ids.items) catch |err| {
            dvui.log.err("pane {d}: {s}", .{ ws.grouping, @errorName(err) });
            continue;
        };
        // Selection is by id too. Only the pane showing this document re-selects, and only
        // within itself — this is not a focus change, so `open_workspace_grouping` stays.
        if (ws.active) |active| {
            if (active.id == doc.id) host.selectInRegion(region_name, new_id);
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
    const workspace = self.workspaces.get(self.open_workspace_grouping) orelse return null;
    return workspace.active;
}

/// Focus a document: the pane holding it becomes the active pane and it becomes that pane's tab.
/// A document in no pane yet — its load landed this frame, and the app focuses it before
/// `rebuildWorkspaces` has run — is seated now, in the pane it was opened toward, so the focus
/// has somewhere to land instead of quietly doing nothing.
pub fn setActiveDocIndex(self: *Workbench, index: usize) void {
    const doc = runtime.host().docByIndex(index) orelse return;
    const id = sdk.document.surfaceId(runtime.host().arena(), doc.owner.id, doc.owner.documentPath(doc)) catch return;
    for (self.workspaces.values()) |*ws| {
        if (!ws.hasTab(id)) continue;
        self.focusIn(ws, doc, id);
        return;
    }
    const ws = self.pane(doc.owner.documentGrouping(doc)) catch return;
    ws.addTab(id, true);
    self.focusIn(ws, doc, id);
}

fn focusIn(self: *Workbench, ws: *Workspace, doc: sdk.DocHandle, id: []const u8) void {
    var buf: [32]u8 = undefined;
    runtime.host().selectInRegion(Workspace.name(&buf, ws.grouping), id);
    self.open_workspace_grouping = ws.grouping;
    ws.active = doc;
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
    core.icon.icon(@src(), "explorer_dirty", icons.tvg.lucide.@"circle-small", .{
        .stroke_color = .{ .color = dvui.themeGet().color(.window, .text) },
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
