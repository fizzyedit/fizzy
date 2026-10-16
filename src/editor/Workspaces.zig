//! The workbench's document panes as views of the app's own, behind `FIZZY_WORKSPACES=1`: each
//! pane is a surface, `fizzy.workspace.<grouping>`, that sits in a place like any view — Main
//! shows the first by its keywords, a split of a place holds the next, a float can hold one, and
//! the picker and the view drag move them. What a pane draws is the workbench's own pane
//! (`Workspace.draw`): its tabs, its document slot, its home page. What is gone is the
//! workbench's arrangement of them (`Workbench.panes`): a pane opened beside another is a split
//! of the app's (`Region.splitOn`), and one emptied closes its place as any emptied view's does.
//!
//! The first step of `plans/WORKSPACES_PLAN.md`'s workspaces (step 2): documents still go into
//! panes through the workbench, and its `panes.zon` is not read while this is on.
const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const fizzy = @import("../fizzy.zig");
const sdk = fizzy.sdk;
const app = @import("app");
const Editor = @import("Editor.zig");
const Workbench = Editor.Workbench;
const Layout = app.layout.Layout;

const Workspaces = @This();

/// Each pane's view, by its grouping.
views: std.AutoArrayHashMapUnmanaged(u64, *View) = .empty,

const View = struct {
    editor: *Editor,
    grouping: u64,
    /// The surface id, `fizzy.workspace.<grouping>`.
    id: []u8,
};

pub const id_prefix = "fizzy.workspace.";

/// Whether `FIZZY_WORKSPACES=1` asked for this. Never on the web, which has no environment.
pub fn wanted(gpa: std.mem.Allocator) bool {
    if (comptime builtin.target.cpu.arch == .wasm32) return false;
    const v = std.process.Environ.getAlloc(fizzy.core.platform.processEnviron(), gpa, "FIZZY_WORKSPACES") catch return false;
    defer gpa.free(v);
    return std.mem.eql(u8, v, "1");
}

/// Hand the workbench the app's places to arrange its panes in. Before the workbench registers,
/// so it knows not to offer its one surface of every pane, and with `self` at its final address.
pub fn install(self: *Workspaces, wb: *Workbench) void {
    wb.places = .{ .ctx = self, .beside = beside, .placed = placed, .close = close, .open = open };
    // A document carried beside a view, rather than into a pane, opens a workspace there.
    self.editorOf().app.layout.documents = .{ .ctx = self, .house = house, .alone = alone };
}

pub fn deinit(self: *Workspaces, gpa: std.mem.Allocator) void {
    for (self.views.values()) |v| {
        gpa.free(v.id);
        gpa.destroy(v);
    }
    self.views.deinit(gpa);
}

fn editorOf(self: *Workspaces) *Editor {
    return @alignCast(@fieldParentPtr("workspaces", self));
}

/// The view id of `grouping`'s pane, in `buf`.
fn viewId(buf: []u8, grouping: u64) []const u8 {
    return std.fmt.bufPrint(buf, id_prefix ++ "{d}", .{grouping}) catch id_prefix;
}

/// Bring the views in line with the workbench's panes, once a frame after it has rebuilt them
/// and before anything draws: a view for every pane, none for a pane that has gone, each titled
/// by the document its pane shows. A pane that has no place yet — opened before the layout had
/// drawn, so there was no room to split — is given one beside the first.
pub fn sync(self: *Workspaces) void {
    const editor = self.editorOf();
    const wb = &editor.workbench;
    if (wb.places == null) return;
    const gpa = editor.app.gpa;
    const host = &editor.app.host;

    self.seat();

    var i: usize = 0;
    while (i < self.views.count()) {
        const g = self.views.keys()[i];
        if (wb.workspaces.contains(g)) {
            i += 1;
            continue;
        }
        const v = self.views.values()[i];
        host.unregisterSurface(v.id);
        gpa.free(v.id);
        gpa.destroy(v);
        self.views.orderedRemoveAt(i);
    }

    for (wb.workspaces.keys()) |g| {
        if (self.views.contains(g)) continue;
        self.register(g) catch |err| dvui.log.err("workspaces: no view for pane {d}: {t}", .{ g, err });
    }

    for (wb.workspaces.values()) |*ws| {
        const v = self.views.get(ws.grouping) orelse continue;
        const title = blk: {
            const doc = ws.active orelse break :blk "Workspace";
            const id = sdk.document.surfaceId(host.arena(), doc.owner.id, doc.owner.documentPath(doc)) catch break :blk "Workspace";
            break :blk if (host.surfaceById(id)) |s| s.title else "Workspace";
        };
        const s = host.surfaceById(v.id) orelse continue;
        if (!std.mem.eql(u8, s.title, title)) host.setSurfaceTitle(v.id, title) catch {};
    }

    // Every pane but one is somewhere it was put; the one is where the keywords show it. More
    // than one with nowhere to be would all be Main's, and Main shows one.
    if (editor.app.layout.regions.items.len == 0) return;
    var first: ?u64 = null;
    for (wb.workspaces.keys()) |g| {
        if (self.assigned(g)) continue;
        if (first == null) {
            first = g;
            continue;
        }
        _ = beside(self, g, first.?, .right);
    }
}

/// Every open document in a workspace: one that no pane holds — its load has just landed, or
/// its plugin came back with it — goes into the workspace it was opened toward, the grouping the
/// app stamped on it ("Open to the Side"'s, or the active workspace's). A tab under another
/// owner's id for the same file (a plugin installed since last session) is replaced where it was.
fn seat(self: *Workspaces) void {
    const editor = self.editorOf();
    const wb = &editor.workbench;
    const host = &editor.app.host;
    var i: usize = 0;
    while (i < host.openDocCount()) : (i += 1) {
        const doc = host.docByIndex(i) orelse continue;
        const path = doc.owner.documentPath(doc);
        const id = sdk.document.surfaceId(host.arena(), doc.owner.id, path) catch continue;
        const held = for (wb.workspaces.values()) |*ws| {
            if (ws.hasTab(id)) break true;
        } else false;
        if (held) continue;
        var stale_in: ?u64 = null;
        for (wb.workspaces.values()) |*ws| {
            if (ws.removeTabsForPath(path)) stale_in = ws.grouping;
        }
        // Grouping 0 is the one the person is in, once the first workspace has gone.
        const want = doc.owner.documentGrouping(doc);
        const toward = if (want == 0 and !wb.workspaces.contains(0)) wb.open_workspace_grouping else want;
        const ws = wb.pane(stale_in orelse toward) catch continue;
        ws.addTab(id, false);
    }
}

fn register(self: *Workspaces, grouping: u64) !void {
    const editor = self.editorOf();
    const gpa = editor.app.gpa;
    const v = try gpa.create(View);
    errdefer gpa.destroy(v);
    var buf: [64]u8 = undefined;
    v.* = .{ .editor = editor, .grouping = grouping, .id = try gpa.dupe(u8, viewId(&buf, grouping)) };
    errdefer gpa.free(v.id);
    try self.views.put(gpa, grouping, v);
    errdefer _ = self.views.orderedRemove(grouping);
    try editor.app.host.registerSurface(.{
        .id = v.id,
        .title = "Workspace",
        .keywords = sdk.keywords.ide.main,
        .ctx = v,
        .draw = drawView,
    });
}

fn drawView(ctx: ?*anyopaque) anyerror!dvui.App.Result {
    const v: *View = @ptrCast(@alignCast(ctx.?));
    const ws = v.editor.workbench.workspaces.getPtr(v.grouping) orelse return .ok;
    return ws.draw();
}

/// Whether some place's list names `grouping`'s view: put there by a split, a drop or a session.
fn assigned(self: *Workspaces, grouping: u64) bool {
    const editor = self.editorOf();
    var buf: [64]u8 = undefined;
    const id = viewId(&buf, grouping);
    var it = editor.app.layout.assignments.valueIterator();
    while (it.next()) |ids| for (ids.*) |x| if (std.mem.eql(u8, x, id)) return true;
    return false;
}

fn layoutOf(editor: *Editor) Layout {
    return Layout.init(&editor.app.host, &editor.app.layout, editor.app.gpa, editor.app.host.arena());
}

fn beside(ctx: *anyopaque, grouping: u64, anchor: u64, side: Workbench.Panes.Side) bool {
    const self: *Workspaces = @ptrCast(@alignCast(ctx));
    const editor = self.editorOf();
    var l = layoutOf(editor);
    var abuf: [64]u8 = undefined;
    const place = Layout.ViewDrag.holderOf(&l, viewId(&abuf, anchor)) orelse return false;
    const new = Layout.splitOn(&l, place, switch (side) {
        .left => .left,
        .right => .right,
        .top => .top,
        .bottom => .bottom,
    }) orelse return false;
    var buf: [64]u8 = undefined;
    const id = l.arena.dupe(u8, viewId(&buf, grouping)) catch return false;
    l.state.assign(l.gpa, new, &.{id}) catch return false;
    l.state.markDirty();
    return true;
}

/// A new workspace holding the documents `ids` (`Layout.State.documents`), for the layout to
/// place as it lands any view: each moved out of the pane it was in, or opened in it when it is
/// not open yet, the first shown. Its view is registered at once, so the place it lands in can
/// select it this frame. Null, and no workspace, when none went in.
fn house(ctx: *anyopaque, ids: []const []const u8) ?[]const u8 {
    const self: *Workspaces = @ptrCast(@alignCast(ctx));
    const editor = self.editorOf();
    const wb = &editor.workbench;
    const host = &editor.app.host;
    const g = wb.newGroupingID();
    const gop = wb.workspaces.getOrPut(wb.allocator, g) catch return null;
    if (!gop.found_existing) gop.value_ptr.* = Editor.Workspace.init(g);
    // Empty until a load lands, not emptied: the rebuild keeps it.
    gop.value_ptr.expecting = true;

    var landed = false;
    // The first last, so it is the one shown: a document shows as it goes in.
    var i = ids.len;
    while (i > 0) {
        i -= 1;
        const id = ids[i];
        if (host.surfaceById(id) == null) {
            const path = sdk.document.pathOfSurfaceId(id) orelse continue;
            landed = (host.openFile(.{ .path = path, .grouping = g }) catch false) or landed;
            continue;
        }
        for (wb.workspaces.values()) |*ws| if (ws.grouping != g) ws.removeTab(id);
        const ws = wb.workspaces.getPtr(g) orelse return null;
        ws.addTab(id, true);
        landed = true;
    }
    if (!landed) {
        if (wb.workspaces.getPtr(g)) |ws| ws.deinit();
        _ = wb.workspaces.orderedRemove(g);
        return null;
    }
    self.register(g) catch return null;
    return self.views.get(g).?.id;
}

fn open(ctx: *anyopaque, grouping: u64, side: Workbench.Panes.Side) bool {
    const self: *Workspaces = @ptrCast(@alignCast(ctx));
    var l = layoutOf(self.editorOf());
    var buf: [64]u8 = undefined;
    const place = Layout.ViewDrag.holderOf(&l, viewId(&buf, grouping)) orelse return false;
    return Layout.splitOn(&l, place, switch (side) {
        .left => .left,
        .right => .right,
        .top => .top,
        .bottom => .bottom,
    }) != null;
}

/// The view of the workspace whose only tab is document `id`, if one is.
fn alone(ctx: *anyopaque, id: []const u8) ?[]const u8 {
    const self: *Workspaces = @ptrCast(@alignCast(ctx));
    for (self.editorOf().workbench.workspaces.values()) |*ws| {
        if (ws.tabCount() != 1 or !ws.hasTab(id)) continue;
        const v = self.views.get(ws.grouping) orelse return null;
        return v.id;
    }
    return null;
}

fn placed(ctx: *anyopaque, grouping: u64) bool {
    const self: *Workspaces = @ptrCast(@alignCast(ctx));
    if (self.assigned(grouping)) return true;
    // Unput, it is shown by the keywords only while no other pane is.
    for (self.editorOf().workbench.workspaces.keys()) |g| {
        if (g != grouping and !self.assigned(g)) return false;
    }
    return true;
}

fn close(ctx: *anyopaque, grouping: u64) void {
    const self: *Workspaces = @ptrCast(@alignCast(ctx));
    const editor = self.editorOf();
    var l = layoutOf(editor);
    var buf: [64]u8 = undefined;
    const id = l.arena.dupe(u8, viewId(&buf, grouping)) catch return;
    if (Layout.ViewDrag.withdraw(&l, id)) return;
    // A place that cannot close keeps the room, but not a list naming a view that is going.
    for (editor.app.host.assignedRegionNames()) |name| {
        const ids = editor.app.host.assignedSurfaces(name) orelse continue;
        var kept: std.ArrayListUnmanaged([]const u8) = .empty;
        var found = false;
        for (ids) |x| {
            if (std.mem.eql(u8, x, id)) found = true else kept.append(l.arena, x) catch return;
        }
        if (found) l.state.assign(l.gpa, l.arena.dupe(u8, name) catch return, kept.items) catch {};
    }
}
