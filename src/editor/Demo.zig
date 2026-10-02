//! fizzy's stage for demo automation (`app.automation`), and how a demo gets started.
//!
//! The player delivers a tape's input; this decides what fizzy's state *is* to a demo. A keyframe
//! closes every document without saving, mounts the keyframe's files in memory at its root
//! (`demo://<name>`, a `core.vfs.Mem`, so nothing touches disk and every replay starts from the
//! same bytes), makes that the project folder on the explorer's Files view, resets the layout, and
//! opens the files the keyframe names. Seeking back is that, then a replay.
//!
//! A `focused` keyframe (the default) leaves only the documents showing — no bottom panel, the
//! explorer put away — and a demo opens the explorer from the rail when it is about to use it and
//! puts it away after (`catalog.openFile`), as a person short of room would.
//!
//! A demo plays inside the user's own copy of fizzy, so it must not cost them anything: `begin`
//! sets their session aside (project folder, open documents) and flushes any pending layout and
//! settings writes, nothing is persisted while the demo is loaded (`active`), and `end` closes the
//! demo's documents, reloads the layout from `layout.zon` and reopens what the user had. A demo
//! will not start over unsaved changes.
//!
//! Demos start from the command palette ("Demo: …"), the Help menu, `FIZZY_DEMO=<name>` natively,
//! or `?demo=<name>` / `?demo=<url of a .zon tape>` on the web — see `docs/AUTOMATION.md`.
const Demo = @This();

const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const fizzy = @import("../fizzy.zig");
const core = fizzy.core;
const sdk = fizzy.sdk;
const automation = @import("app").automation;
const dvui_adapter = @import("app").keymap.dvui_adapter;
const Editor = @import("Editor.zig");
const Keybinds = @import("Keybinds.zig");
pub const catalog = @import("demos/catalog.zig");

editor: *Editor,
player: automation.Player,
/// A seek is replaying: animation is off until it arrives.
fast: bool = false,
/// The user's session, set aside while a demo is loaded.
saved: ?Saved = null,
/// The current keyframe's files, mounted at `mount`.
mem: ?*core.vfs.Mem = null,
mount: ?[]u8 = null,
/// A demo asked for outside a frame (`FIZZY_DEMO`, a web page's `?demo=`): started on the next.
pending: ?Pending = null,
/// Shutting down: `end` frees, and gives nothing back to a session that is going away.
quitting: bool = false,
/// How a keyframe that reset the layout wants the window arranged, done on the frame after the
/// cut: the reset forgets every region's size, and a split with no size has nothing to open or
/// shut until the shape has drawn it once.
arrange: ?automation.Tape.Keyframe.Layout = null,
/// Every plugin's settings as the demo found them, as ZON, to give back at the end.
settings_saved: std.ArrayListUnmanaged(SavedSettings) = .empty,

const SavedSettings = struct {
    owner: []u8,
    blob: []u8,
};

const Pending = union(enum) {
    /// A bundled demo, by name.
    name: []u8,
    /// A tape's ZON source.
    zon: [:0]u8,

    fn free(self: Pending, gpa: std.mem.Allocator) void {
        switch (self) {
            .name => |n| gpa.free(n),
            .zon => |z| gpa.free(z),
        }
    }
};

const Saved = struct {
    folder: ?[]u8,
    /// Open documents' paths, the active one last so it is focused again.
    docs: [][]u8,
};

/// Inert until `attach`: nothing loaded, so nothing in `tick` acts on it.
pub const detached: Demo = .{ .editor = undefined, .player = .{ .stage = undefined } };

/// Point the player at this stage. `self` must not move afterwards (it is the stage's context).
pub fn attach(self: *Demo, editor: *Editor) void {
    self.* = .{ .editor = editor, .player = .init(.{ .ctx = self, .vtable = &stage_vtable }) };
}

pub fn deinit(self: *Demo) void {
    self.quitting = true;
    self.player.deinit();
    self.unmountFiles();
    if (self.pending) |p| p.free(self.editor.app.gpa);
    self.pending = null;
}

/// Whether a demo is loaded. While one is, fizzy persists nothing the demo changes.
pub fn active(self: *const Demo) bool {
    return self.player.state != .idle;
}

/// Build the bundled demo `name` and play it.
pub fn play(self: *Demo, name: []const u8) !void {
    const entry = catalog.find(name) orelse {
        dvui.log.warn("demo: no demo named '{s}'", .{name});
        return error.NoSuchDemo;
    };
    if (!self.mayStart()) return;
    var script: automation.Script = .init(self.editor.app.gpa, entry.name, entry.title);
    errdefer script.deinit();
    try entry.build(&script);
    self.player.load(try script.finish(), .{});
}

/// Play a tape from ZON source — a fetched `.zon`, or a recording.
pub fn playZon(self: *Demo, source: [:0]const u8) !void {
    if (!self.mayStart()) return;
    const owned = automation.Tape.parse(self.editor.app.gpa, source) catch |err| {
        dvui.log.err("demo: could not read the tape: {t}", .{err});
        return err;
    };
    self.player.load(owned, .{});
}

/// Start the bundled demo `name` on the next frame — for callers outside one.
pub fn playSoon(self: *Demo, name: []const u8) void {
    const gpa = self.editor.app.gpa;
    self.queue(.{ .name = gpa.dupe(u8, name) catch return });
}

/// Start a tape from ZON source on the next frame — for callers outside one.
pub fn playZonSoon(self: *Demo, source: []const u8) void {
    const gpa = self.editor.app.gpa;
    self.queue(.{ .zon = gpa.dupeZ(u8, source) catch return });
}

/// The caller is outside a frame, so it wakes the loop itself (`Host.refresh`).
fn queue(self: *Demo, p: Pending) void {
    if (self.pending) |old| old.free(self.editor.app.gpa);
    self.pending = p;
}

/// A demo replaces the open documents, so it waits for unsaved work to be saved or closed. A
/// demo's own documents are not anyone's work: one demo may replace another.
fn mayStart(self: *Demo) bool {
    for (self.editor.app.open_files.values()) |doc| {
        if (!doc.owner.isDirty(doc)) continue;
        if (std.mem.startsWith(u8, doc.owner.documentPath(doc), "demo://")) continue;
        dvui.toast(@src(), .{ .message = "Save or close your changes first — a demo replaces the open files while it plays." });
        return false;
    }
    return true;
}

/// Once a frame, before anything reads events.
pub fn frame(self: *Demo) void {
    if (self.pending) |p| {
        self.pending = null;
        defer p.free(self.editor.app.gpa);
        switch (p) {
            .name => |name| self.play(name) catch {},
            .zon => |source| self.playZon(source) catch {},
        }
    }
    if (self.arrange) |layout| {
        self.arrange = null;
        switch (layout) {
            .keep => {},
            // The app's default: the explorer open on the demo's folder, even on a window narrow
            // enough to fold it away.
            .reset => self.editor.explorer.open(self.editor),
            // The documents and nothing else: the room is the editor's until the demo asks for
            // the explorer from the rail.
            .focused => {
                self.editor.explorer.close(self.editor);
                if (self.editor.regionFor(sdk.keywords.ide.panel)) |panel| {
                    if (!panel.isClosed()) panel.close();
                }
            },
        }
    }
    self.player.frame();
}

// ---- the stage -----------------------------------------------------------------------------

const stage_vtable: automation.Stage.VTable = .{
    .begin = begin,
    .end = end,
    .keyframe = keyframe,
    .idle = idle,
    .command = command,
    .chordFor = chordFor,
    .commandTitle = commandTitle,
    .fastForward = fastForward,
};

fn from(ctx: *anyopaque) *Demo {
    return @ptrCast(@alignCast(ctx));
}

fn begin(ctx: *anyopaque, _: *const automation.Tape) void {
    const self = from(ctx);
    const editor = self.editor;
    // Whatever was waiting to be written goes now, so the copy on disk is the user's own and
    // `end` can reload it.
    editor.flushLayout();
    editor.flushSettings();
    self.saveSettings();

    const gpa = editor.app.gpa;
    var docs: std.ArrayList([]u8) = .empty;
    const active_id = if (editor.activeDoc()) |d| d.id else null;
    var active_path: ?[]u8 = null;
    for (editor.app.open_files.values()) |doc| {
        const path = doc.owner.documentPath(doc);
        if (path.len == 0 or std.mem.startsWith(u8, path, "demo://")) continue;
        const copy = gpa.dupe(u8, path) catch continue;
        if (active_id == doc.id) active_path = copy else docs.append(gpa, copy) catch gpa.free(copy);
    }
    if (active_path) |p| docs.append(gpa, p) catch gpa.free(p);
    self.saved = .{
        .folder = if (editor.app.folder) |f| gpa.dupe(u8, f) catch null else null,
        .docs = docs.toOwnedSlice(gpa) catch &.{},
    };
}

fn end(ctx: *anyopaque) void {
    const self = from(ctx);
    const editor = self.editor;
    const gpa = editor.app.gpa;
    self.fast = false;
    if (self.quitting) {
        self.freeSaved();
        self.freeSavedSettings();
        return;
    }
    self.restoreSettings();
    self.closeAllDocuments();
    self.unmountFiles();

    // The layout as the user left it: `begin` flushed it, and nothing has been written since.
    editor.app.layout.resetLayout(gpa);
    editor.loadSavedLayout();
    editor.app.layout.dirty = false;
    editor.command_palette.finishClose();

    const saved = self.saved orelse return;
    if (saved.folder) |f| {
        editor.setProjectFolder(f) catch |err| dvui.log.warn("demo: could not reopen {s}: {t}", .{ f, err });
    } else {
        editor.app.host.closeProjectFolder();
    }
    for (saved.docs) |path| {
        _ = editor.openFilePath(path, editor.workbench.currentGroupingID()) catch |err|
            dvui.log.warn("demo: could not reopen {s}: {t}", .{ path, err });
    }
    self.freeSaved();
    dvui.refresh(null, @src(), null);
}

fn freeSaved(self: *Demo) void {
    const gpa = self.editor.app.gpa;
    const saved = self.saved orelse return;
    if (saved.folder) |f| gpa.free(f);
    for (saved.docs) |d| gpa.free(d);
    gpa.free(saved.docs);
    self.saved = null;
}

/// Put fizzy into `kf` outright: nothing the demo did before survives.
fn keyframe(ctx: *anyopaque, kf: *const automation.Tape.Keyframe) void {
    const self = from(ctx);
    const editor = self.editor;
    const gpa = editor.app.gpa;

    editor.command_palette.finishClose();
    self.closeAllDocuments();
    self.applySettings(kf.settings);

    // Fresh bytes every time: a replay must not see what the last pass typed or saved.
    self.unmountFiles();
    self.mountFiles(kf) catch |err| {
        dvui.log.err("demo: could not mount {s}: {t}", .{ kf.root, err });
        return;
    };

    // The tree as if never seen: folders closed, the root opening on its own.
    editor.explorer.open_branches.clearRetainingCapacity();
    editor.workbench.file_tree_root_opened = null;
    editor.setProjectFolder(kf.root) catch |err| dvui.log.err("demo: could not open {s}: {t}", .{ kf.root, err });
    editor.app.host.setSelectionFor(sdk.keywords.ide.sidebar, Editor.workbench_files_view);
    switch (kf.layout) {
        .keep => {},
        .reset, .focused => {
            editor.app.layout.resetLayout(gpa);
            self.arrange = kf.layout;
            dvui.refresh(null, @src(), null);
        },
    }

    for (kf.open) |rel| {
        const path = core.paths.join(gpa, kf.root, rel) catch continue;
        defer gpa.free(path);
        _ = editor.openFilePath(path, editor.workbench.currentGroupingID()) catch |err|
            dvui.log.warn("demo: could not open {s}: {t}", .{ path, err });
    }
}

// ---- settings --------------------------------------------------------------------------------

/// A plugin's live settings as one ZON struct, field by field through its schema.
fn settingsBlob(gpa: std.mem.Allocator, arena: std.mem.Allocator, schema: *const sdk.Host.SettingsSchema) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try out.writer.writeAll(".{");
    for (schema.fields, 0..) |field, i| {
        const text = schema.access.getZonText(schema.value, i, arena);
        if (text.len == 0) continue;
        try out.writer.print(" .{s} = {s},", .{ field.key, text });
    }
    try out.writer.writeAll(" }");
    return out.toOwnedSlice();
}

fn saveSettings(self: *Demo) void {
    const editor = self.editor;
    const gpa = editor.app.gpa;
    for (editor.app.host.settings_schemas.items) |*schema| {
        const blob = settingsBlob(gpa, editor.app.arena.allocator(), schema) catch continue;
        const owner = gpa.dupe(u8, schema.owner.id) catch {
            gpa.free(blob);
            continue;
        };
        self.settings_saved.append(gpa, .{ .owner = owner, .blob = blob }) catch {
            gpa.free(owner);
            gpa.free(blob);
        };
    }
}

/// Put the keyframe's settings in place — through the schema, so the plugin hears about it as it
/// would from the settings pane. Nothing is written to disk while a demo is loaded.
fn applySettings(self: *Demo, overrides: []const automation.Tape.Setting) void {
    const host = &self.editor.app.host;
    for (overrides) |o| {
        const schema = schemaFor(host, o.owner) orelse {
            dvui.log.warn("demo: no settings for '{s}'", .{o.owner});
            continue;
        };
        const i = for (schema.fields, 0..) |f, i| {
            if (std.mem.eql(u8, f.key, o.key)) break i;
        } else {
            dvui.log.warn("demo: '{s}' has no setting '{s}'", .{ o.owner, o.key });
            continue;
        };
        if (!schema.access.setZonText(schema.value, i, o.value)) {
            dvui.log.warn("demo: '{s}' is not a value for {s}.{s}", .{ o.value, o.owner, o.key });
            continue;
        }
        schema.access.persist(schema.value, schema.owner);
    }
}

/// Give each plugin its settings back — only those that changed, so a plugin the demo never
/// touched is not told its settings moved.
fn restoreSettings(self: *Demo) void {
    const editor = self.editor;
    const gpa = editor.app.gpa;
    for (self.settings_saved.items) |saved| {
        const schema = schemaFor(&editor.app.host, saved.owner) orelse continue;
        const now = settingsBlob(gpa, editor.app.arena.allocator(), schema) catch continue;
        defer gpa.free(now);
        if (!std.mem.eql(u8, now, saved.blob)) schema.access.applyBlob(schema.value, schema.owner, saved.blob);
    }
    self.freeSavedSettings();
}

fn freeSavedSettings(self: *Demo) void {
    const gpa = self.editor.app.gpa;
    for (self.settings_saved.items) |saved| {
        gpa.free(saved.owner);
        gpa.free(saved.blob);
    }
    self.settings_saved.clearAndFree(gpa);
}

fn schemaFor(host: *sdk.Host, owner: []const u8) ?*sdk.Host.SettingsSchema {
    for (host.settings_schemas.items) |*schema| {
        if (std.mem.eql(u8, schema.owner.id, owner)) return schema;
    }
    return null;
}

// ---- files -----------------------------------------------------------------------------------

fn mountFiles(self: *Demo, kf: *const automation.Tape.Keyframe) !void {
    const gpa = self.editor.app.gpa;
    const mem = try gpa.create(core.vfs.Mem);
    errdefer gpa.destroy(mem);
    mem.* = try .init(gpa);
    errdefer mem.deinit();
    for (kf.files) |f| {
        // `Mem` makes no parents of its own; every directory on the way is put first.
        var i: usize = 0;
        while (std.mem.indexOfScalarPos(u8, f.path, i, '/')) |slash| : (i = slash + 1) {
            const dir = try std.fmt.allocPrint(gpa, "/{s}", .{f.path[0..slash]});
            defer gpa.free(dir);
            mem.putDir(dir) catch |err| switch (err) {
                error.Exists => {},
                else => return err,
            };
        }
        const path = try std.fmt.allocPrint(gpa, "/{s}", .{f.path});
        defer gpa.free(path);
        try mem.put(path, f.text);
    }
    const root = try gpa.dupe(u8, kf.root);
    errdefer gpa.free(root);
    try self.editor.app.host.mount(root, mem.fs());
    self.mem = mem;
    self.mount = root;
}

fn unmountFiles(self: *Demo) void {
    const gpa = self.editor.app.gpa;
    if (self.mount) |m| {
        self.editor.app.host.unmount(m);
        gpa.free(m);
        self.mount = null;
    }
    if (self.mem) |mem| {
        mem.deinit();
        gpa.destroy(mem);
        self.mem = null;
    }
}

/// Close every document, discarding changes — they are the demo's, or `mayStart` refused.
/// Loads still on their way are dropped too, or they would land in the next keyframe.
fn closeAllDocuments(self: *Demo) void {
    const editor = self.editor;
    editor.cancelAllLoadingJobs();
    while (editor.doc_io.loads.count() > 0) editor.doc_io.cancel(editor.doc_io.loads.keys()[0]);
    while (editor.openings.entries.count() > 0) editor.openings.drop(editor, editor.openings.entries.keys()[0]);
    while (editor.app.open_files.count() > 0) {
        const id = editor.app.open_files.keys()[editor.app.open_files.count() - 1];
        editor.rawCloseFileID(id) catch break;
    }
}

fn idle(ctx: *anyopaque) bool {
    const editor = from(ctx).editor;
    return editor.loading_jobs.count() == 0 and
        editor.openings.entries.count() == 0 and
        editor.doc_io.loads.count() == 0;
}

fn command(ctx: *anyopaque, id: []const u8) void {
    from(ctx).editor.app.host.runCommand(id) catch |err| dvui.log.warn("demo: command {s} failed: {t}", .{ id, err });
}

fn chordFor(ctx: *anyopaque, id: []const u8) ?@import("app").keymap.chord.Stroke {
    const kb = Keybinds.menuKeybindFor(from(ctx).editor, id);
    const c = dvui_adapter.fromKeybind(kb) orelse return null;
    return .{ .first = c };
}

fn commandTitle(ctx: *anyopaque, id: []const u8) ?[]const u8 {
    const c = from(ctx).editor.app.host.command(id) orelse return null;
    return c.title;
}

fn fastForward(ctx: *anyopaque, on: bool) void {
    from(ctx).fast = on;
}
