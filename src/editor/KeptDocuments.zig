//! Open documents carried across a swap: a plugin's across its reload (`PluginReloads`), and the
//! whole app's across a restart (`restart`). They come back in their tabs, as they were, unsaved
//! edits included.
//!
//! Before the old build goes, each document's place (path, pane, preview, which tab its pane
//! showed, which was active) and its state (`Plugin.captureDocumentState`: contents, caret,
//! scroll, dirty) are taken (`capture`).
//!
//! - **A plugin's reload:** unloading detaches the documents rather than closing them. Their tabs
//!   stay in their panes, naming the documents by surface id (`<owner>.doc:<path>`), which the new
//!   build's documents have too. Once the new build is registered, each path is loaded through it
//!   and put back under that id, so the waiting tab shows it again, and its state is restored
//!   (`reattach`). Tab order, splits and selection are untouched, since nothing closed them.
//! - **A restart:** the documents are written to `<config>/session/` (`save`) and the quit asks
//!   nothing, so every tab stays in `layout.zon`. The next launch reads the session once
//!   (`loadSession`, which deletes it). When the workbench reopens last session's tabs, a document
//!   the session holds opens from its state, not the disk (`openKept`). A clean document whose
//!   file changed since (an agent's edit, a pull) opens from disk instead; a dirty one always
//!   comes back as it was, since those edits are the person's.
//!
//! A new build may not read an old build's state (its format changed): the owner refuses it
//! (`restoreDocumentState` fails), the document opens as it is on disk, and any unsaved contents
//! are written to a recovery file the person is told about. A document with unsaved changes whose
//! owner cannot capture it at all stops the swap: the reload leaves the running build in place,
//! and the restart asks about unsaved documents as any quit does.
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
/// A restart's: the tab each pane showed, selected a frame after the documents open
/// (`applySelections`), once the panes they opened into have drawn and can be selected in.
selections: std.ArrayListUnmanaged(Selection) = .empty,

const Selection = struct { region: []u8, surface: []u8 };

const Kept = struct {
    path: []u8,
    /// The plugin that had it open, by id.
    owner: []u8,
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
    /// A clean document's file as it was when captured, so a restart can tell it changed since.
    stamp: Stamp = .{},
};

const Stamp = struct {
    size: u64 = 0,
    mtime_ns: i96 = 0,

    fn of(path: []const u8) ?Stamp {
        // A page has no files to stamp (and no restart to keep one across).
        if (comptime builtin.target.cpu.arch == .wasm32) return null;
        const st = std.Io.Dir.cwd().statFile(dvui.io, path, .{}) catch return null;
        return .{ .size = st.size, .mtime_ns = st.mtime.nanoseconds };
    }
};

pub const CaptureError = error{
    /// A document has unsaved changes and its owner cannot capture them: reloading would lose
    /// them.
    UnsavedNotCarried,
    OutOfMemory,
};

/// Take the open documents as they are now: `plugin`'s, or every one when null. The caller
/// `deinit`s the result.
pub fn capture(editor: *Editor, plugin: ?*sdk.Plugin) CaptureError!KeptDocuments {
    const gpa = editor.app.gpa;
    var self: KeptDocuments = .{ .gpa = gpa };
    errdefer self.deinit();
    const active = editor.activeDoc();
    for (editor.app.open_files.values()) |doc| {
        if (plugin) |p| if (doc.owner != p) continue;
        const owner = doc.owner;
        const path = try gpa.dupe(u8, owner.documentPath(doc));
        errdefer gpa.free(path);
        const owner_id = try gpa.dupe(u8, owner.id);
        errdefer gpa.free(owner_id);
        const dirty = owner.isDirty(doc);
        const state = owner.captureDocumentState(doc, gpa);
        errdefer if (state) |s| gpa.free(s);
        if (dirty and state == null) return error.UnsavedNotCarried;
        const unsaved: ?[]u8 = if (dirty) owner.documentBytes(doc, gpa) catch null else null;
        errdefer if (unsaved) |u| gpa.free(u);
        const sid = sdk.document.surfaceId(editor.app.host.arena(), owner.id, path) catch return error.OutOfMemory;
        if (active) |a| {
            if (a.id == doc.id) self.active = try gpa.dupe(u8, path);
        }
        // Last: from here `self` owns `path`, `owner_id`, `state` and `unsaved`.
        try self.docs.append(gpa, .{
            .path = path,
            .owner = owner_id,
            .grouping = owner.documentGrouping(doc),
            .preview = editor.documentIsPreview(doc.id),
            .selected = editor.surfaceSelected(sid),
            .dirty = dirty,
            .state = state,
            .unsaved = unsaved,
            .stamp = if (dirty) .{} else Stamp.of(path) orelse .{},
        });
    }
    return self;
}

pub fn deinit(self: *KeptDocuments) void {
    for (self.docs.items) |d| freeKept(self.gpa, d);
    self.docs.deinit(self.gpa);
    if (self.active) |a| self.gpa.free(a);
    for (self.selections.items) |sel| {
        self.gpa.free(sel.region);
        self.gpa.free(sel.surface);
    }
    self.selections.deinit(self.gpa);
}

fn freeKept(gpa: std.mem.Allocator, d: Kept) void {
    gpa.free(d.path);
    gpa.free(d.owner);
    if (d.state) |s| gpa.free(s);
    if (d.unsaved) |u| gpa.free(u);
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
    return loadInto(editor, plugin, d, d.grouping);
}

fn loadInto(editor: *Editor, plugin: *sdk.Plugin, d: Kept, grouping: u64) !sdk.DocHandle {
    const gpa = editor.app.gpa;
    const staging = try sdk.document.allocStaging(plugin, gpa);
    defer staging.deinit(gpa);
    if (d.state != null) {
        try sdk.document.loadBytesIntoStaging(plugin, d.path, "", staging);
    } else try sdk.document.loadIntoStaging(plugin, d.path, staging);
    const id = plugin.documentIdFromBuffer(staging.buf.ptr);
    plugin.setDocumentGroupingOnBuffer(staging.buf.ptr, grouping);
    try editor.insertOpenDoc(staging.buf.ptr, plugin, id);
    return editor.app.docById(id) orelse error.DocumentNotFound;
}

/// What `save` writes as `session.zon`, beside a file per document's state and unsaved contents
/// (named by its index, so no path has to be made safe as a file name).
const Saved = struct {
    version: u32 = session_version,
    active: []const u8 = "",
    docs: []const Doc = &.{},

    const Doc = struct {
        path: []const u8,
        owner: []const u8,
        grouping: u64 = 0,
        preview: bool = false,
        /// Its pane was showing it.
        selected: bool = false,
        dirty: bool = false,
        has_state: bool = false,
        has_unsaved: bool = false,
        size: u64 = 0,
        mtime_ns: i96 = 0,
    };
};

/// A session another version wrote in a shape this one does not read is left alone, not
/// misread: its documents open from disk.
const session_version = 1;

/// `<config>/session`, owned by `gpa`.
pub fn sessionDir(gpa: std.mem.Allocator, config_folder: []const u8) ![]u8 {
    return std.fs.path.join(gpa, &.{ config_folder, "session" });
}

/// Write these documents to `dir`, replacing any session there. Only documents with state are
/// worth keeping: the rest open from disk as any launch does.
pub fn save(self: *const KeptDocuments, dir: []const u8) !void {
    const gpa = self.gpa;
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(dvui.io, dir) catch {};
    try cwd.createDirPath(dvui.io, dir);
    var docs: std.ArrayListUnmanaged(Saved.Doc) = .empty;
    defer docs.deinit(gpa);
    for (self.docs.items) |d| {
        const state = d.state orelse continue;
        const i = docs.items.len;
        try writeBlob(gpa, dir, i, "state", state);
        if (d.unsaved) |u| try writeBlob(gpa, dir, i, "unsaved", u);
        try docs.append(gpa, .{
            .path = d.path,
            .owner = d.owner,
            .grouping = d.grouping,
            .preview = d.preview,
            .selected = d.selected,
            .dirty = d.dirty,
            .has_state = true,
            .has_unsaved = d.unsaved != null,
            .size = d.stamp.size,
            .mtime_ns = d.stamp.mtime_ns,
        });
    }
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try std.zon.stringify.serialize(Saved{ .active = self.active orelse "", .docs = docs.items }, .{}, &aw.writer);
    const file = try std.fs.path.join(gpa, &.{ dir, "session.zon" });
    defer gpa.free(file);
    try cwd.writeFile(dvui.io, .{ .sub_path = file, .data = aw.written() });
}

fn writeBlob(gpa: std.mem.Allocator, dir: []const u8, i: usize, kind: []const u8, bytes: []const u8) !void {
    const name = try std.fmt.allocPrint(gpa, "{d}.{s}", .{ i, kind });
    defer gpa.free(name);
    const file = try std.fs.path.join(gpa, &.{ dir, name });
    defer gpa.free(file);
    try std.Io.Dir.cwd().writeFile(dvui.io, .{ .sub_path = file, .data = bytes });
}

fn readBlob(gpa: std.mem.Allocator, dir: []const u8, i: usize, kind: []const u8) ![]u8 {
    const name = try std.fmt.allocPrint(gpa, "{d}.{s}", .{ i, kind });
    defer gpa.free(name);
    const file = try std.fs.path.join(gpa, &.{ dir, name });
    defer gpa.free(file);
    return std.Io.Dir.cwd().readFileAlloc(dvui.io, file, gpa, .unlimited);
}

/// The session a restart left in `dir`, read once: the directory is deleted whether or not it
/// could be read, so a later launch never applies it again. Null when there is none.
pub fn loadSession(gpa: std.mem.Allocator, dir: []const u8) ?KeptDocuments {
    const cwd = std.Io.Dir.cwd();
    defer cwd.deleteTree(dvui.io, dir) catch {};
    const file = std.fs.path.join(gpa, &.{ dir, "session.zon" }) catch return null;
    defer gpa.free(file);
    const text = cwd.readFileAllocOptions(dvui.io, file, gpa, .limited(1 << 20), .of(u8), 0) catch return null;
    defer gpa.free(text);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const saved = std.zon.parse.fromSliceAlloc(Saved, arena.allocator(), text, null, .{ .ignore_unknown_fields = true }) catch |err| {
        dvui.log.warn("restart: the last session could not be read ({t}); documents open from disk", .{err});
        return null;
    };
    if (saved.version != session_version) return null;
    var self: KeptDocuments = .{ .gpa = gpa };
    for (saved.docs, 0..) |d, i| {
        const kept = readKept(gpa, dir, i, d) catch |err| {
            dvui.log.warn("restart: could not keep {s} ({t}); it opens from disk", .{ d.path, err });
            continue;
        };
        self.docs.append(gpa, kept) catch {
            freeKept(gpa, kept);
            break;
        };
    }
    if (saved.active.len > 0) self.active = gpa.dupe(u8, saved.active) catch null;
    return self;
}

fn readKept(gpa: std.mem.Allocator, dir: []const u8, i: usize, d: Saved.Doc) !Kept {
    const path = try gpa.dupe(u8, d.path);
    errdefer gpa.free(path);
    const owner = try gpa.dupe(u8, d.owner);
    errdefer gpa.free(owner);
    const state: ?[]u8 = if (d.has_state) try readBlob(gpa, dir, i, "state") else null;
    errdefer if (state) |s| gpa.free(s);
    const unsaved: ?[]u8 = if (d.has_unsaved) try readBlob(gpa, dir, i, "unsaved") else null;
    return .{
        .path = path,
        .owner = owner,
        .grouping = d.grouping,
        .preview = d.preview,
        .selected = d.selected,
        .dirty = d.dirty,
        .state = state,
        .unsaved = unsaved,
        .stamp = .{ .size = d.size, .mtime_ns = d.mtime_ns },
    };
}

/// Open `path` from the session, into pane `grouping`, when the session holds it: from its kept
/// state, restored, with no disk read. Null when it does not (or a clean document's file changed
/// since), and the caller opens it from disk as any launch does. A document the session held but
/// could not bring back is opened from disk too, its unsaved contents kept in a recovery file.
pub fn openKept(self: *KeptDocuments, editor: *Editor, path: []const u8, grouping: u64) ?sdk.DocHandle {
    const i = for (self.docs.items, 0..) |d, i| {
        if (std.mem.eql(u8, d.path, path)) break i;
    } else return null;
    const d = self.docs.swapRemove(i);
    defer freeKept(self.gpa, d);
    if (!d.dirty) {
        const now = Stamp.of(d.path) orelse return null;
        if (now.size != d.stamp.size or now.mtime_ns != d.stamp.mtime_ns) return null;
    }
    const plugin = editor.app.host.pluginById(d.owner) orelse {
        dvui.log.warn("restart: {s} was open in '{s}', which is not loaded now; it opens from disk", .{ d.path, d.owner });
        if (d.unsaved) |u| recover(editor, d.path, u);
        return null;
    };
    const doc = loadInto(editor, plugin, d, grouping) catch |err| {
        dvui.log.err("restart: could not reopen {s}: {t}", .{ d.path, err });
        if (d.unsaved) |u| recover(editor, d.path, u);
        return null;
    };
    const restored = if (d.state) |s| plugin.restoreDocumentState(doc, s) else true;
    if (!restored) {
        dvui.log.warn("restart: {s} reopened as saved; this build could not read its state", .{d.path});
        if (d.unsaved) |u| recover(editor, d.path, u);
    }
    if (d.preview) editor.setDocumentPreview(doc.id, true);
    if (d.selected) self.keepSelection(plugin.id, d.path, grouping) catch {};
    if (self.active) |a| if (std.mem.eql(u8, a, d.path)) {
        if (editor.app.open_files.getIndex(doc.id)) |idx| editor.workbench.setActiveDocIndex(idx);
    };
    return doc;
}

fn keepSelection(self: *KeptDocuments, owner_id: []const u8, path: []const u8, grouping: u64) !void {
    var buf: [32]u8 = undefined;
    const region = try self.gpa.dupe(u8, Editor.Workspace.name(&buf, grouping));
    errdefer self.gpa.free(region);
    const surface = try sdk.document.surfaceId(self.gpa, owner_id, path);
    errdefer self.gpa.free(surface);
    try self.selections.append(self.gpa, .{ .region = region, .surface = surface });
}

/// Last session's documents no tab asked for (its pane was lost, its owner refused it): nothing
/// typed is lost, written to recovery files. What is left is the panes' selections.
pub fn finishDocuments(self: *KeptDocuments, editor: *Editor) void {
    for (self.docs.items) |d| {
        if (d.unsaved) |u| recover(editor, d.path, u);
        freeKept(self.gpa, d);
    }
    self.docs.clearRetainingCapacity();
}

/// Show in each pane the tab it showed, now that the panes have drawn. Then the session is done:
/// the caller drops it.
pub fn applySelections(self: *KeptDocuments, editor: *Editor) void {
    for (self.selections.items) |sel| editor.app.host.selectInRegion(sel.region, sel.surface);
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
