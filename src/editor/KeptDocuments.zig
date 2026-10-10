//! A plugin's open documents, carried across its reload (`PluginReloads`): a rebuilt plugin comes
//! back with every document it had open, in its own tab, as it was, unsaved edits included.
//!
//! Before the old build unloads, each document's place (path, pane, preview, which tab its pane
//! showed, which was active) and its state (`Plugin.captureDocumentState`: contents, caret,
//! scroll, dirty) are taken (`capture`). Unloading then detaches the documents rather than
//! closing them: their tabs stay in their panes, naming the documents by surface id
//! (`<owner>.doc:<path>`), which the new build's documents have too. Once the new build is
//! registered, each path is loaded through it and put back under that id, so the waiting tab
//! shows it again, and its state is restored (`reattach`). Tab order, splits and selection are
//! untouched, since nothing closed them.
//!
//! A new build may not read an old build's state (its format changed): the owner refuses it
//! (`restoreDocumentState` fails), the document opens as it is on disk, and any unsaved contents
//! are written to a recovery file the person is told about. A document with unsaved changes whose
//! owner cannot capture it at all stops the reload, which then leaves the running build in place.
const KeptDocuments = @This();

const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const Editor = @import("Editor.zig");
const sdk = Editor.sdk;

gpa: std.mem.Allocator,
docs: std.ArrayListUnmanaged(Kept) = .empty,
/// The path of the document that was active, when it was one of these.
active: ?[]u8 = null,

const Kept = struct {
    path: []u8,
    grouping: u64,
    preview: bool,
    /// Its pane was showing it.
    selected: bool,
    dirty: bool,
    /// `captureDocumentState`, when the owner has the hook.
    state: ?[]u8,
    /// Unsaved contents (`documentBytes`), kept only for a dirty document: what a recovery file
    /// holds if the new build cannot read `state`.
    unsaved: ?[]u8,
};

pub const CaptureError = error{
    /// A document has unsaved changes and its owner cannot capture them: reloading would lose
    /// them.
    UnsavedNotCarried,
    OutOfMemory,
};

/// Take `plugin`'s open documents as they are now. The caller `deinit`s the result.
pub fn capture(editor: *Editor, plugin: *sdk.Plugin) CaptureError!KeptDocuments {
    const gpa = editor.app.gpa;
    var self: KeptDocuments = .{ .gpa = gpa };
    errdefer self.deinit();
    const active = editor.activeDoc();
    for (editor.app.open_files.values()) |doc| {
        if (doc.owner != plugin) continue;
        const path = try gpa.dupe(u8, plugin.documentPath(doc));
        errdefer gpa.free(path);
        const dirty = plugin.isDirty(doc);
        const state = plugin.captureDocumentState(doc, gpa);
        errdefer if (state) |s| gpa.free(s);
        if (dirty and state == null) return error.UnsavedNotCarried;
        const unsaved: ?[]u8 = if (dirty) plugin.documentBytes(doc, gpa) catch null else null;
        errdefer if (unsaved) |u| gpa.free(u);
        const sid = sdk.document.surfaceId(editor.app.host.arena(), plugin.id, path) catch return error.OutOfMemory;
        if (active) |a| {
            if (a.id == doc.id) self.active = try gpa.dupe(u8, path);
        }
        // Last: from here `self` owns `path`, `state` and `unsaved`.
        try self.docs.append(gpa, .{
            .path = path,
            .grouping = plugin.documentGrouping(doc),
            .preview = editor.documentIsPreview(doc.id),
            .selected = editor.surfaceSelected(sid),
            .dirty = dirty,
            .state = state,
            .unsaved = unsaved,
        });
    }
    return self;
}

pub fn deinit(self: *KeptDocuments) void {
    for (self.docs.items) |d| {
        self.gpa.free(d.path);
        if (d.state) |s| self.gpa.free(s);
        if (d.unsaved) |u| self.gpa.free(u);
    }
    self.docs.deinit(self.gpa);
    if (self.active) |a| self.gpa.free(a);
}

/// Bring each document back through `plugin` (the new build), into the tab waiting for it.
pub fn reattach(self: *KeptDocuments, editor: *Editor, plugin: *sdk.Plugin) void {
    var host = &editor.app.host;
    for (self.docs.items) |d| {
        const doc = load(editor, plugin, d) catch |err| {
            dvui.log.err("reload: could not reopen {s}: {t}", .{ d.path, err });
            if (d.unsaved) |u| recover(editor, d.path, u);
            // Its tab waits for nothing now.
            if (sdk.document.surfaceId(host.arena(), plugin.id, d.path)) |sid| editor.workbench.tabClosed(sid) else |_| {}
            continue;
        };
        const restored = if (d.state) |s| plugin.restoreDocumentState(doc, s) else true;
        if (!restored) {
            // The new build does not read the old one's state: the document is as on disk.
            dvui.log.warn("reload: {s} reopened as saved; the new build could not read its state", .{d.path});
            if (d.unsaved) |u| recover(editor, d.path, u);
        }
        if (d.preview) editor.setDocumentPreview(doc.id, true);
        if (d.selected) {
            const sid = sdk.document.surfaceId(host.arena(), plugin.id, d.path) catch continue;
            var buf: [32]u8 = undefined;
            host.selectInRegion(Editor.Workspace.name(&buf, d.grouping), sid);
        }
    }
    if (self.active) |path| {
        for (editor.app.open_files.values(), 0..) |doc, i| {
            if (doc.owner == plugin and std.mem.eql(u8, plugin.documentPath(doc), path)) {
                editor.workbench.setActiveDocIndex(i);
                break;
            }
        }
    }
}

/// The new build never came (it failed to load or register): nothing typed is lost, written to
/// recovery files, and the tabs waiting for the documents go.
pub fn abandon(self: *KeptDocuments, editor: *Editor, plugin_id: []const u8) void {
    for (self.docs.items) |d| {
        if (d.unsaved) |u| recover(editor, d.path, u);
        const sid = sdk.document.surfaceId(editor.app.host.arena(), plugin_id, d.path) catch continue;
        editor.workbench.tabClosed(sid);
    }
    editor.rebuildWorkspaces() catch {};
}

/// Open `d.path` through `plugin`, now, in its pane. One with state to restore starts empty, since
/// the state fills it (and an untitled one has nothing on disk to read); only one without is read
/// from disk.
fn load(editor: *Editor, plugin: *sdk.Plugin, d: Kept) !sdk.DocHandle {
    const gpa = editor.app.gpa;
    const staging = try sdk.document.allocStaging(plugin, gpa);
    defer staging.deinit(gpa);
    if (d.state != null) {
        try sdk.document.loadBytesIntoStaging(plugin, d.path, "", staging);
    } else try sdk.document.loadIntoStaging(plugin, d.path, staging);
    const id = plugin.documentIdFromBuffer(staging.buf.ptr);
    plugin.setDocumentGroupingOnBuffer(staging.buf.ptr, d.grouping);
    try editor.insertOpenDoc(staging.buf.ptr, plugin, id);
    return editor.app.docById(id) orelse error.DocumentNotFound;
}

/// Unsaved contents the new build could not take, written beside fizzy's config so nothing typed
/// is lost, and the person told where.
fn recover(editor: *Editor, path: []const u8, unsaved: []const u8) void {
    // A page has no folder to keep them in (and no reload to lose them to: a web plugin is a
    // side module, never swapped).
    if (comptime builtin.target.cpu.arch == .wasm32) {
        dvui.log.err("reload: the unsaved contents of {s} could not be kept", .{path});
        return;
    }
    const gpa = editor.app.gpa;
    const dir = std.fs.path.join(gpa, &.{ editor.app.config_folder, "recovered" }) catch return;
    defer gpa.free(dir);
    std.Io.Dir.cwd().createDirPath(dvui.io, dir) catch {};
    const name = std.fmt.allocPrint(gpa, "{d}-{s}", .{ std.Io.Clock.real.now(dvui.io).toSeconds(), std.fs.path.basename(path) }) catch return;
    defer gpa.free(name);
    const out = std.fs.path.join(gpa, &.{ dir, name }) catch return;
    defer gpa.free(out);
    std.Io.Dir.cwd().writeFile(dvui.io, .{ .sub_path = out, .data = unsaved }) catch |err| {
        dvui.log.err("reload: could not keep the unsaved contents of {s}: {t}", .{ path, err });
        return;
    };
    dvui.log.warn("reload: the unsaved contents of {s} are in {s}", .{ path, out });
    dvui.toast(@src(), .{ .message = std.fmt.allocPrint(editor.app.arena.allocator(), "Unsaved changes to {s} were kept in {s}", .{ std.fs.path.basename(path), out }) catch "Unsaved changes were kept in fizzy's recovered folder." });
}
