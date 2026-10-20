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

/// Whether `path` is under a mount only a recording or a demo makes, which no later session has.
pub fn isSessionMount(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "tape://") or std.mem.startsWith(u8, path, "demo://");
}

/// Bring the panes in line with the documents: every open document sits in exactly one pane's
/// assignment, every pane with nothing assigned is gone (bar the last), and — once — last
/// session's panes are re-seated from the assignments the app kept for them.
pub fn rebuildWorkspaces(wb: *Workbench) !void {
    const host = runtime.host();
    const arena = host.arena();

    // Not while a demo has the window: last session's panes and tabs come back once it has gone
    // (`restorePanes`), not into the middle of it.
    if (!wb.restored and !wb.holding) {
        wb.restored = true;
        // Where the app arranges the panes, it brought them back itself — and carries an
        // arrangement saved before it did over into its own (fizzy's `Workspaces.carryOver`).
        loadPanes(wb);
        for (host.assignedRegionNames()) |region_name| {
            const grouping = Workspace.groupingOfName(region_name) orelse continue;
            // A copy: the assignment is borrowed until the next `assignSurfaces`, and each open
            // below seats a loading placeholder in this pane, which reassigns it.
            const borrowed = host.assignedSurfaces(region_name) orelse continue;
            // The mounts a recording or a demo makes (`tape://`, `demo://`) are gone with the
            // session that made them: quitting mid-tour leaves its files in the assignment, and
            // reopening one only fails. They leave the assignment rather than wait in the pane.
            var ids: std.ArrayList([]const u8) = .empty;
            for (borrowed) |b| {
                const path = sdk.document.pathOfSurfaceId(b) orelse "";
                if (isSessionMount(path)) continue;
                try ids.append(arena, try arena.dupe(u8, b));
            }
            // A pane that was empty when last session ended has nothing to bring back. Seating
            // it would leave an empty pane beside the others with nothing ever coming to it.
            if (ids.items.len == 0) {
                host.assignSurfaces(try arena.dupe(u8, region_name), null) catch {};
                continue;
            }
            if (ids.items.len != borrowed.len) host.assignSurfaces(try arena.dupe(u8, region_name), ids.items) catch {};
            _ = try wb.pane(grouping);
            for (ids.items) |id| {
                const path = sdk.document.pathOfSurfaceId(id) orelse continue;
                if (host.docFromPath(path) != null) continue;
                _ = host.openFile(.{ .path = path, .grouping = grouping }) catch continue;
            }
            // Whatever can come back is on its way: an open that started has put its
            // placeholder in this pane, and one that could not start (the mount holding it not
            // up yet, its plugin not loaded) never arrives. Left expecting, a pane whose every
            // open failed stood empty beside the others for the whole session.
            if (wb.workspaces.getPtr(grouping)) |ws| ws.expecting = false;
        }
    }

    // A document nobody holds lands in the pane it was opened toward: the grouping the app
    // stamped on it, which is the "open to the side" answer or the current pane. Where the app
    // arranges the panes, it seats them too (fizzy's `Workspaces.seat`).
    var i: usize = 0;
    while (wb.places == null and i < host.openDocCount()) : (i += 1) {
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
        // One of the person's, set aside with its pane while a demo has the window: it waits
        // there for them, never seated in the demo's panes.
        if (wb.holding and heldDocument(wb, doc, id)) continue;
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
        // Tabs that can draw, not assignment entries: a pane whose only tabs name documents
        // that never reopened draws nothing, and kept for them it stood empty for good.
        const live = ws.liveTabCount();
        // Holding a tab, by whatever route it came — an open, a restored slot swapped for a
        // placeholder, a drop — the pane is no longer waiting for one: from here, empty means
        // emptied. A pane left expecting after its first tab arrived by a swap rather than
        // `addTab` was never let go when that tab closed, and sat open over its close snapshot.
        if (live > 0) ws.expecting = false;
        if (live > 0 or ws.expecting) {
            // Filled (or about to be) — including one that was on its way out when its
            // document landed, which is a pane to keep, not a hole to finish closing.
            if (wb.places == null) if (wb.paneLeaf(ws.grouping)) |leaf| wb.panes.reopenLeaf(leaf);
            k += 1;
            continue;
        }
        // The app's place slides shut by itself once it is closed, and the pane goes now.
        if (wb.places) |p| {
            p.close(p.ctx, ws.grouping);
        } else if (wb.paneLeaf(ws.grouping) != null) {
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
    // A demo has the window: what it arranges is not the person's (`holdPanes`).
    if (wb.holding) return;
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
    const bytes = wb.allocator.dupeSentinel(u8, data, 0) catch return;
    defer wb.allocator.free(bytes);
    var snap_arena: std.heap.ArenaAllocator = .init(wb.allocator);
    defer snap_arena.deinit();
    var snap_diag: std.zon.parse.Diagnostics = undefined;
    const snap = std.zon.parse.fromSlice(Panes.Snapshot, .{ .gpa = wb.allocator, .arena = snap_arena.allocator(), .source = bytes, .diagnostics = &snap_diag, .ignore_unknown_fields = true }) catch |err| {
        dvui.log.warn("workbench: ignoring {s}: {s}", .{ path, @errorName(err) });
        return;
    };

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
    adoptPanes(wb, loaded);
}

/// Make `loaded` the arrangement, every pane in it a workspace.
fn adoptPanes(wb: *Workbench, loaded: Panes) void {
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

/// Set the person's panes aside while a demo has the window, and save nothing until they are put
/// back (`restorePanes`): the demo plays in a pane of its own, and its splits are not theirs. A
/// second hold keeps the first.
///
/// Their panes go aside whole — the workspaces, what each holds, and the tree they sit in — and
/// their documents stay open behind them, untouched: a document of a held pane is never seated in
/// the demo's (`rebuildWorkspaces`). Nothing is saved while holding, so the arrangement on disk
/// stays theirs: a tree that could not be copied is read back from there. Before the first rebuild
/// has restored last session's panes there is no tree of theirs to copy; that restore waits for
/// the demo to end.
pub fn holdPanes(wb: *Workbench) void {
    if (wb.holding) return;
    wb.holding = true;
    wb.held_open = wb.open_workspace_grouping;
    if (wb.restored) {
        // A copy through a snapshot: a snapshot borrows the pane names from the live tree, which
        // the demo's own pane replaces below.
        if (wb.panes.snapshot(wb.allocator)) |snap| {
            defer snap.deinit(wb.allocator);
            wb.held_panes = Panes.fromSnapshot(wb.allocator, snap) catch |err| blk: {
                dvui.log.err("workbench: could not set the panes aside ({t}); they come back from disk", .{err});
                break :blk null;
            };
        } else |err| dvui.log.err("workbench: could not set the panes aside ({t}); they come back from disk", .{err});
    }
    const host = runtime.host();
    for (wb.workspaces.values()) |*ws| {
        var buf: [32]u8 = undefined;
        const ids = host.assignedSurfaces(Workspace.name(&buf, ws.grouping)) orelse continue;
        const copy = dupeIds(wb.allocator, ids) catch |err| {
            dvui.log.err("workbench: could not set pane {d}'s tabs aside ({t}); they come back from disk", .{ ws.grouping, err });
            continue;
        };
        wb.held_tabs.append(wb.allocator, .{ .grouping = ws.grouping, .ids = copy }) catch |err| {
            dvui.log.err("workbench: could not set pane {d}'s tabs aside ({t}); they come back from disk", .{ ws.grouping, err });
            freeIds(wb.allocator, copy);
        };
    }
    wb.held_workspaces = wb.workspaces;
    wb.workspaces = .empty;
    // The demo's pane: a grouping no pane of theirs has.
    const stage = wb.newGroupingID();
    wb.workspaces.put(wb.allocator, stage, Workspace.init(stage)) catch {};
    wb.open_workspace_grouping = stage;
    onePane(wb);
}

/// Whether `doc` (its tab `id`) is one of the person's, set aside with their panes.
pub fn heldDocument(wb: *const Workbench, doc: sdk.DocHandle, id: []const u8) bool {
    if (wb.held_workspaces.contains(doc.owner.documentGrouping(doc))) return true;
    for (wb.held_tabs.items) |t| for (t.ids) |held| if (std.mem.eql(u8, held, id)) return true;
    return false;
}

fn dupeIds(gpa: std.mem.Allocator, ids: []const []const u8) ![][]u8 {
    const out = try gpa.alloc([]u8, ids.len);
    var n: usize = 0;
    errdefer freeIds(gpa, out[0..n]);
    for (ids, out) |id, *o| {
        o.* = try gpa.dupe(u8, id);
        n += 1;
    }
    return out;
}

fn freeIds(gpa: std.mem.Allocator, ids: [][]u8) void {
    for (ids) |id| gpa.free(id);
    gpa.free(ids);
}

/// One pane, as a demo's keyframe declares the window: the open one, the others closing with
/// their leaves (`rebuildWorkspaces`). Its documents are the keyframe's to open.
pub fn onePane(wb: *Workbench) void {
    var one = Panes.init(wb.allocator);
    one.owns_panel_ids = true;
    one.animated = true;
    const root = one.allocNodeForRoot() catch return;
    var buf: [32]u8 = undefined;
    one.insertTabOwned(root, 0, Workspace.name(&buf, wb.open_workspace_grouping)) catch {
        one.deinit();
        return;
    };
    adoptPanes(wb, one);
}

/// The person's panes again (`holdPanes`), and saving with them: the demo's go, theirs come back
/// holding what they held, in their tree — the copy, or what is on disk where there is none.
/// Before last session's panes were ever restored, one pane, for the next rebuild to restore
/// them into.
pub fn restorePanes(wb: *Workbench) void {
    if (!wb.holding) return;
    wb.holding = false;
    const host = runtime.host();
    for (wb.workspaces.values()) |*ws| {
        var buf: [32]u8 = undefined;
        host.assignSurfaces(Workspace.name(&buf, ws.grouping), null) catch {};
        ws.deinit();
    }
    wb.workspaces.deinit(wb.allocator);
    wb.workspaces = wb.held_workspaces;
    wb.held_workspaces = .empty;
    for (wb.held_tabs.items) |t| {
        var buf: [32]u8 = undefined;
        const ids: []const []const u8 = t.ids;
        host.assignSurfaces(Workspace.name(&buf, t.grouping), ids) catch |err|
            dvui.log.err("workbench: pane {d}'s tabs did not come back ({t})", .{ t.grouping, err });
        freeIds(wb.allocator, t.ids);
    }
    wb.held_tabs.clearAndFree(wb.allocator);
    if (wb.held_panes) |held| {
        wb.held_panes = null;
        adoptPanes(wb, held);
    } else if (wb.restored) {
        loadPanes(wb);
    } else {
        wb.open_workspace_grouping = wb.held_open;
        onePane(wb);
    }
    if (wb.workspaces.contains(wb.held_open)) wb.open_workspace_grouping = wb.held_open;
}

/// The panes as they stand, for a demo's snapshot to put back (`arrange`): which there are, in
/// row order, the one in front, and the tree they sit in as ZON (`Panes.Snapshot`). What each
/// holds is the app's assignment under its name, which the app's layout keeps. All in `arena`.
pub fn arrangement(wb: *Workbench, arena: std.mem.Allocator) !Workbench.Arrangement {
    return .{
        .open = wb.open_workspace_grouping,
        .groupings = try arena.dupe(u64, wb.workspaces.keys()),
        .tree = try panesZon(wb, arena),
    };
}

fn panesZon(wb: *Workbench, gpa: std.mem.Allocator) ![:0]u8 {
    const snap = try wb.panes.snapshot(wb.allocator);
    defer snap.deinit(wb.allocator);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    try std.zon.stringify.serializeMaxDepth(snap, .{}, &aw.writer, 64);
    return aw.toOwnedSliceSentinel(0);
}

/// Put the panes back to `a` (`arrangement`): the panes it had, each a fresh workspace where it is
/// not one now, those it did not have gone, and its tree. Their tabs are the app's assignments,
/// for the caller to put back with the rest of the app's layout. Where the app arranges the panes
/// (`places`) there is no tree of the workbench's to put back: `error.AppArranged` unless the
/// panes are already the same.
pub fn arrange(wb: *Workbench, a: Workbench.Arrangement) !void {
    const same_panes = std.mem.eql(u64, wb.workspaces.keys(), a.groupings);
    if (wb.places != null and !same_panes) return error.AppArranged;
    const same_tree = wb.places != null or (same_panes and blk: {
        const now = try panesZon(wb, wb.allocator);
        defer wb.allocator.free(now);
        break :blk std.mem.eql(u8, now, a.tree);
    });
    if (!same_tree) try replacePanes(wb, a);
    if (wb.workspaces.contains(a.open)) wb.open_workspace_grouping = a.open;
}

fn replacePanes(wb: *Workbench, a: Workbench.Arrangement) !void {
    var arena: std.heap.ArenaAllocator = .init(wb.allocator);
    defer arena.deinit();
    var diag: std.zon.parse.Diagnostics = undefined;
    const snap = try std.zon.parse.fromSlice(Panes.Snapshot, .{ .gpa = wb.allocator, .arena = arena.allocator(), .source = a.tree, .diagnostics = &diag });
    var tree = try Panes.fromSnapshot(wb.allocator, snap);
    errdefer tree.deinit();
    tree.animated = true;

    var panes: std.AutoArrayHashMapUnmanaged(u64, Workspace) = .empty;
    errdefer panes.deinit(wb.allocator);
    try panes.ensureTotalCapacity(wb.allocator, a.groupings.len);
    for (a.groupings) |g| panes.putAssumeCapacity(g, wb.workspaces.get(g) orelse Workspace.init(g));
    for (wb.workspaces.values()) |*ws| {
        if (!panes.contains(ws.grouping)) ws.deinit();
    }
    wb.workspaces.deinit(wb.allocator);
    wb.workspaces = panes;
    adoptPanes(wb, tree);
}

/// Delete the saved arrangement: the app has taken it over (`Workbench.places`).
pub fn forgetPanes(wb: *Workbench) void {
    if (comptime builtin.target.cpu.arch == .wasm32) return;
    const path = panesPath(wb) orelse return;
    defer wb.allocator.free(path);
    std.Io.Dir.cwd().deleteFile(dvui.io, path) catch {};
}

fn panesPath(wb: *Workbench) ?[]u8 {
    if (comptime builtin.target.cpu.arch == .wasm32) return null;
    const dir = runtime.host().pluginInstallDir("workbench") orelse return null;
    defer wb.allocator.free(dir);
    std.Io.Dir.cwd().createDirPath(dvui.io, dir) catch return null;
    return std.fs.path.join(wb.allocator, &.{ dir, panes_file }) catch null;
}
