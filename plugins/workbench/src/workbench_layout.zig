//! Workspace map maintenance, and drawing the document panes as a split tree.
const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const core = @import("core");
const sdk = @import("fizzy_sdk");
const runtime = @import("runtime.zig");
const Workbench = @import("Workbench.zig");
const Workspace = @import("Workspace.zig");
const Panes = Workbench.Panes;

/// Where the arrangement is kept, inside the plugin's own directory.
const panes_file = "panes.zon";

/// Bring the panes in line with the documents: every open document sits in exactly one pane's
/// assignment, every pane with nothing assigned is gone (bar the last), and — once — last
/// session's panes are re-seated from the assignments the app kept for them.
pub fn rebuildWorkspaces(wb: *Workbench) !void {
    const host = runtime.host();
    const arena = host.arena();

    if (!wb.restored) {
        wb.restored = true;
        loadPanes(wb);
        for (host.assignedRegionNames()) |region_name| {
            const grouping = Workspace.groupingOfName(region_name) orelse continue;
            _ = try wb.pane(grouping);
            const ids = host.assignedSurfaces(region_name) orelse continue;
            for (ids) |id| {
                const path = sdk.document.pathOfSurfaceId(id) orelse continue;
                if (host.docFromPath(path) != null) continue;
                _ = host.openFilePath(path, grouping) catch continue;
            }
        }
    }

    // A document nobody holds lands in the pane it was opened toward: the grouping the app
    // stamped on it, which is the "open to the side" answer or the current pane.
    var i: usize = 0;
    while (i < host.openDocCount()) : (i += 1) {
        const doc = host.docByIndex(i) orelse continue;
        const id = try sdk.document.surfaceId(arena, doc.owner.id, doc.owner.documentPath(doc));
        var held = false;
        for (wb.workspaces.values()) |*ws| {
            if (ws.hasTab(id)) {
                held = true;
                break;
            }
        }
        if (held) continue;
        // The same file under another owner's id (a plugin installed since last session) would
        // otherwise sit beside it as a tab that never opens.
        const path = doc.owner.documentPath(doc);
        var stale_in: ?u64 = null;
        for (wb.workspaces.values()) |*ws| {
            if (ws.removeTabsForPath(path)) stale_in = ws.grouping;
        }
        const target = try wb.pane(stale_in orelse doc.owner.documentGrouping(doc));
        target.addTab(id, false);
    }

    // An empty extra pane eases shut, then leaves: its leaf is sent closing, the tree drops
    // the leaf once the slide is over, and only then does the workspace go. Dropping it here
    // is why a document split once jumped closed while opening still slid.
    var k: usize = 0;
    while (k < wb.workspaces.count()) {
        if (wb.workspaces.count() == 1) break;
        const ws = &wb.workspaces.values()[k];
        if (ws.tabCount() > 0 or ws.expecting) {
            // Filled (or about to be) — including one that was on its way out when its
            // document landed, which is a pane to keep, not a hole to finish closing.
            if (wb.paneLeaf(ws.grouping)) |leaf| wb.panes.reopenLeaf(leaf);
            k += 1;
            continue;
        }
        if (wb.paneLeaf(ws.grouping) != null) {
            wb.closePane(ws.grouping);
            k += 1;
            continue;
        }
        var buf: [32]u8 = undefined;
        host.assignSurfaces(Workspace.name(&buf, ws.grouping), null) catch {};
        const gone = ws.grouping;
        ws.deinit();
        _ = wb.workspaces.orderedRemove(gone);
        if (wb.open_workspace_grouping == gone) wb.open_workspace_grouping = wb.workspaces.keys()[0];
    }
    if (!wb.workspaces.contains(wb.open_workspace_grouping) and wb.workspaces.count() > 0) {
        wb.open_workspace_grouping = wb.workspaces.keys()[0];
    }
}

/// Draw every workspace in its place in the tree, a draggable sash between each pair.
///
/// `core.widgets.DockingWidget` over `Workbench.panes`: a tree of splits, each a share
/// of its parent, so a divider moves exactly its own two children and nothing else — and the
/// same widget the app's regions are moving onto, so a document split and a sidebar split are
/// one mechanism. A pane opening or closing slides (`DockLayout.animated`); the widget only
/// draws leaves, and each leaf is a workspace drawing its own tabs (`header = .none`).
///
/// The `index` parameter stays because it is on the host vtable, and is the first pane to draw.
pub fn drawWorkspaces(wb: *Workbench, index: usize) !dvui.App.Result {
    const count = wb.workspaces.count();
    if (index >= count) return .ok;

    var dock = core.widgets.dockspace(@src(), .{
        .layout = &wb.panes,
        .header = .none,
    }, .{ .expand = .both });
    var result: dvui.App.Result = .ok;
    while (dock.panel()) |p| {
        defer p.end();
        const grouping = Workspace.groupingOfName(p.id) orelse continue;
        const ws = wb.workspaces.getPtr(grouping) orelse continue;
        const r = try ws.draw();
        if (r != .ok) result = r;
    }
    if (dock.changed) wb.panes_dirty = true;
    dock.deinit();
    if (wb.panes_dirty) savePanes(wb);
    if (result != .ok) return result;

    return .ok;
}

/// Write the arrangement to the plugin's directory. Skipped on the web, and when the host has
/// no plugin directory to offer.
fn savePanes(wb: *Workbench) void {
    wb.panes_dirty = false;
    if (comptime builtin.target.cpu.arch == .wasm32) return;
    const path = panesPath(wb) orelse return;
    defer wb.allocator.free(path);
    const snap = wb.panes.snapshot(wb.allocator) catch return;
    defer snap.deinit(wb.allocator);

    var aw: std.Io.Writer.Allocating = .init(wb.allocator);
    defer aw.deinit();
    // `serializeMaxDepth`: a snapshot tree is a recursive type, which `serialize` refuses.
    std.zon.stringify.serializeMaxDepth(snap, .{}, &aw.writer, 64) catch return;
    std.Io.Dir.cwd().writeFile(dvui.io, .{ .sub_path = path, .data = aw.written() }) catch |err| {
        dvui.log.warn("workbench: could not save {s}: {s}", .{ path, @errorName(err) });
    };
}

/// Read the saved arrangement back, if there is one, and give every pane in it a workspace.
/// A leaf naming a pane that is not a pane is dropped; a tree with nothing left in it is
/// ignored and the default single pane stays.
fn loadPanes(wb: *Workbench) void {
    if (comptime builtin.target.cpu.arch == .wasm32) return;
    const path = panesPath(wb) orelse return;
    defer wb.allocator.free(path);
    const data = std.Io.Dir.cwd().readFileAlloc(dvui.io, path, wb.allocator, .limited(1 << 20)) catch return;
    defer wb.allocator.free(data);
    const bytes = wb.allocator.dupeZ(u8, data) catch return;
    defer wb.allocator.free(bytes);
    const snap = std.zon.parse.fromSliceAlloc(Panes.Snapshot, wb.allocator, bytes, null, .{ .ignore_unknown_fields = true }) catch |err| {
        dvui.log.warn("workbench: ignoring {s}: {s}", .{ path, @errorName(err) });
        return;
    };
    defer std.zon.parse.free(wb.allocator, snap);

    var loaded = Panes.fromSnapshot(wb.allocator, snap) catch return;
    loaded.animated = true;
    // Drop anything that is not a pane name, and any float — panes do not float (yet).
    for (loaded.floats.items) |f| loaded.removePanel(loaded.nodes.items[f.leaf].leaf.tabs.items[0]);
    var i: usize = 0;
    while (i < loaded.nodes.items.len) : (i += 1) {
        const n = loaded.nodes.items[i];
        if (n != .leaf) continue;
        var j: usize = 0;
        while (j < n.leaf.tabs.items.len) {
            if (Workspace.groupingOfName(n.leaf.tabs.items[j]) == null) {
                loaded.removePanel(n.leaf.tabs.items[j]);
                continue;
            }
            j += 1;
        }
    }
    if (!loaded.contains(blk: {
        var buf: [32]u8 = undefined;
        break :blk Workspace.name(&buf, 0);
    }) and loaded.nodes.items[loaded.root] == .leaf and loaded.nodes.items[loaded.root].leaf.tabs.items.len == 0) {
        loaded.deinit();
        return;
    }

    wb.panes.deinit();
    wb.panes = loaded;
    for (wb.panes.nodes.items) |n| {
        if (n != .leaf) continue;
        for (n.leaf.tabs.items) |t| {
            const grouping = Workspace.groupingOfName(t) orelse continue;
            const gop = wb.workspaces.getOrPut(wb.allocator, grouping) catch continue;
            if (!gop.found_existing) gop.value_ptr.* = Workspace.init(grouping);
            if (grouping > wb.grouping_id_counter) wb.grouping_id_counter = grouping;
        }
    }
    if (wb.workspaces.count() > 0 and wb.paneLeaf(wb.open_workspace_grouping) == null) {
        wb.open_workspace_grouping = wb.workspaces.keys()[0];
    }
}

fn panesPath(wb: *Workbench) ?[]u8 {
    if (comptime builtin.target.cpu.arch == .wasm32) return null;
    const dir = runtime.host().pluginInstallDir("workbench") orelse return null;
    defer wb.allocator.free(dir);
    std.Io.Dir.cwd().createDirPath(dvui.io, dir) catch return null;
    return std.fs.path.join(wb.allocator, &.{ dir, panes_file }) catch null;
}
