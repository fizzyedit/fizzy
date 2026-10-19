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
//! demo's documents, reloads the layout from `layout.zon` and reopens what the user had: from its
//! path, or from the bytes `begin` kept of one its path cannot open again (a file the web page
//! fetched, a zip whose folder is the project). A demo will not start over unsaved changes.
//!
//! **Snapshots** (`automation.Stage.capture`) hold what a scene changes as it plays: the mounted
//! files as saved, each open document's state from its owner (`captureDocumentState` — contents,
//! caret, scroll), which is active, the explorer open or shut and its open folders, every plugin's
//! settings, and keyboard focus. Restoring one puts them back in place — documents opened since
//! are closed, the rest restored where they sit — so a seek back within a scene costs no reload.
//! One is taken only while nothing is loading and the palette is shut, and restored only into the
//! scene it came from with its documents still open; otherwise the seek cuts to the keyframe.
//!
//! Demos start from the command palette ("Demo: …"), the Help menu, `FIZZY_DEMO=<name>` natively,
//! or `?demo=<name>` / `?demo=<url of a .zon or .tape>` on the web — see `docs/AUTOMATION.md`.
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
const Popout = @import("Popout.zig");
const Keybinds = @import("Keybinds.zig");
pub const catalog = @import("demos/catalog.zig");

editor: *Editor,
player: automation.Player,
/// Plays live tapes — input on the app as it is (`automation.LiveDriver`). One tape drives the app
/// at a time: a live tape is refused while a demo is loaded, and a demo while a live tape plays.
live: automation.LiveDriver,
/// The `automation` service plugins play live tapes through, over `live`. The only way a live
/// tape starts.
service: automation.Service,
/// What the service's `snapshot` takes: framed here (`frame`) and in the editor's frame end.
snapshot: automation.Snapshot,
/// What the service's `capture` takes: read back from the frame target, and each OS window's, at
/// the frame's very end (`frameEnd`).
picture: automation.Capture,
/// The app's OS windows as this frame left them, named (`frameEnd`): in the frame's arena.
windows: []const automation.Snapshot.Window = &.{},
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
/// Who a live tape plays for (`automation.Api.playAs`): an agent's pointer tape is the agent's.
/// Strings owned here. Null: the live tape is its own author.
live_author: ?sdk.Author = null,

const SavedSettings = struct {
    owner: []u8,
    blob: []u8,
};

const Pending = union(enum) {
    /// A bundled demo, by name.
    name: []u8,
    /// A tape, in either of its forms.
    tape: []u8,

    fn free(self: Pending, gpa: std.mem.Allocator) void {
        switch (self) {
            .name => |n| gpa.free(n),
            .tape => |t| gpa.free(t),
        }
    }
};

const Saved = struct {
    folder: ?[]u8,
    /// Open documents, the active one last so it is focused again.
    docs: []Doc,

    const Doc = struct {
        path: []u8,
        /// What it was opened from, when its path cannot open it again (`reopenable`): a file the
        /// web page fetched or the person uploaded, a zip whose folder is the project. Null: it
        /// reopens from its path.
        bytes: ?[]u8 = null,
    };
};

/// Inert until `attach`: nothing loaded, so nothing in `tick` acts on it.
pub const detached: Demo = .{
    .editor = undefined,
    .player = .{ .gpa = undefined, .stage = undefined },
    .live = .{ .stage = undefined },
    .service = .{ .gpa = undefined, .driver = undefined },
    .snapshot = .{ .gpa = undefined },
    .picture = .{ .gpa = undefined },
};

/// Point the player and the live driver at this stage. `self` must not move afterwards (it is
/// the stage's context, and the service's).
pub fn attach(self: *Demo, editor: *Editor) void {
    const gpa = editor.app.gpa;
    const stage: automation.Stage = .{ .ctx = self, .vtable = &stage_vtable };
    self.* = .{
        .editor = editor,
        .player = .init(gpa, stage),
        .live = .init(stage),
        .service = .{ .gpa = gpa, .driver = &self.live, .other = .{ .ctx = self, .driving = demoLoaded }, .on_author = .{ .ctx = self, .set = liveAuthorSet }, .snapshots = &self.snapshot, .captures = &self.picture },
        .snapshot = .init(gpa),
        .picture = .init(gpa),
    };
    self.service.bind();
    self.snapshot.windows = .{ .ctx = self, .list = listWindows };
    // A seek's catch-up frames draw nothing where the backend can drop them (the web's).
    self.player.set_unseen = core.FrameTarget.setUnseen;
}

fn demoLoaded(ctx: *anyopaque) bool {
    return from(ctx).active();
}

pub fn deinit(self: *Demo) void {
    self.setLiveAuthor(null);
    self.quitting = true;
    self.snapshot.deinit();
    self.picture.deinit();
    self.live.deinit();
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
    script.check = automation.Input.check;
    try entry.build(&script);
    self.player.load(try script.finish(), .{});
}

/// Play a tape — a fetched `.zon` or `.tape`, or a recording. Either form; the bytes say which.
/// One that opens on no keyframe is a live tape, played on the app as it is (`live`).
pub fn playTape(self: *Demo, bytes: []const u8) !void {
    const gpa = self.editor.app.gpa;
    var owned = loadDemoTape(gpa, bytes) catch |err| switch (err) {
        error.NoKeyframeAtStart => {
            var check = automation.Input.check;
            check.live = true;
            const live = automation.Tape.load(gpa, bytes, check) catch |e| {
                dvui.log.err("demo: could not read the live tape: {t}", .{e});
                return e;
            };
            if (self.active()) {
                var refused = live;
                refused.deinit();
                dvui.log.warn("demo: a live tape cannot play while a demo is loaded", .{});
                return error.Busy;
            }
            return self.live.play(live);
        },
        else => {
            dvui.log.err("demo: could not read the tape: {t}", .{err});
            return err;
        },
    };
    if (!self.mayStart()) return owned.deinit();
    self.player.load(owned, .{});
}

/// `bytes` as a demo's tape, checked as fizzy plays one: its chords in the keymap's spelling, its
/// steps ones a loaded plugin applies (`stepsCheck`).
pub fn loadDemoTape(gpa: std.mem.Allocator, bytes: []const u8) !automation.Tape.Owned {
    var check = automation.Input.check;
    check.steps = stepsCheck;
    return automation.Tape.load(gpa, bytes, check);
}

/// `FIZZY_DEMO` naming a tape file (`.zon` or `.tape`) rather than a bundled demo: read in the
/// app's `main`, while the working directory is still the one it was launched from, and played
/// once the editor is up (`Editor.postInit`). Owned by the allocator it was read with.
pub var env_tape: ?[]u8 = null;

/// Read `FIZZY_DEMO`'s tape, if it names one (`env_tape`). Natively; before anything changes the
/// working directory.
pub fn readEnvTape(gpa: std.mem.Allocator, io: std.Io) void {
    const raw = std.c.getenv("FIZZY_DEMO") orelse return;
    const name = std.mem.span(raw);
    if (!std.mem.endsWith(u8, name, ".zon") and !std.mem.endsWith(u8, name, ".tape")) return;
    env_tape = std.Io.Dir.cwd().readFileAlloc(io, name, gpa, .limited(64 << 20)) catch |err| {
        std.log.err("FIZZY_DEMO: could not read {s}: {t}", .{ name, err });
        return;
    };
}

/// Start the bundled demo `name` on the next frame — for callers outside one.
pub fn playSoon(self: *Demo, name: []const u8) void {
    const gpa = self.editor.app.gpa;
    self.queue(.{ .name = gpa.dupe(u8, name) catch return });
}

/// Start a tape on the next frame — for callers outside one.
pub fn playTapeSoon(self: *Demo, bytes: []const u8) void {
    const gpa = self.editor.app.gpa;
    self.queue(.{ .tape = gpa.dupe(u8, bytes) catch return });
}

/// The caller is outside a frame, so it wakes the loop itself (`Host.refresh`).
fn queue(self: *Demo, p: Pending) void {
    if (self.pending) |old| old.free(self.editor.app.gpa);
    self.pending = p;
}

/// A demo replaces the open documents, so it waits for unsaved work to be saved or closed. A
/// demo's own documents are not anyone's work: one demo may replace another.
fn mayStart(self: *Demo) bool {
    return self.startable() == .started;
}

/// Whether a demo can start now (`.started`), and if not why, told to the person as a toast too.
pub fn startable(self: *Demo) sdk.services.demos.Api.Play {
    if (self.live.playing()) {
        dvui.toast(@src(), .{ .message = "Something is driving fizzy right now — the demo can start once it has finished." });
        return .busy;
    }
    for (self.editor.app.open_files.values()) |doc| {
        if (!doc.owner.isDirty(doc)) continue;
        if (std.mem.startsWith(u8, doc.owner.documentPath(doc), "demo://")) continue;
        dvui.toast(@src(), .{ .message = "Save or close your changes first — a demo replaces the open files while it plays." });
        return .unsaved;
    }
    return .started;
}

/// Once a frame, before anything reads events.
pub fn frame(self: *Demo) void {
    if (self.pending) |p| {
        self.pending = null;
        defer p.free(self.editor.app.gpa);
        switch (p) {
            .name => |name| self.play(name) catch {},
            .tape => |bytes| self.playTape(bytes) catch {},
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
    self.snapshot.beginFrame();
    self.live.frame();
    self.player.frame();
}

// ---- windows -------------------------------------------------------------------------------

/// The main window's picture this frame: the frame target (`core.FrameTarget.picture`).
pub const Picture = struct { target: dvui.Texture.Target, w: u32, h: u32 };

/// At the very end of the frame, after everything has drawn into every window — dialogs, floats
/// and menus taken into theirs (`Popout.endFrame`), the frame onto the main window: each OS window
/// named for a tape or an agent to aim into (`fizzy.window:<what>`), and the snapshot and the
/// picture asked for written. Nothing while nobody is looking.
pub fn frameEnd(self: *Demo, main: ?Picture) void {
    const naming = core.anchor.wanted();
    const taking = automation.Snapshot.taking();
    if (!naming and !taking and !self.picture.wanted()) return;
    // dvui's dialogs drawn, for the snapshot to have them, where the frame target has not drawn
    // them already (a backend with no targets leaves them to `Window.end`).
    if (taking) dvui.currentWindow().drawRetained(.{});
    const arena = dvui.currentWindow().arena();
    var shown_buf: [16]Popout.Shown = undefined;
    const shown = Popout.windowsShown(&shown_buf);
    const windows = arena.alloc(automation.Snapshot.Window, shown.len + 1) catch return;
    const sources = arena.alloc(automation.Capture.Source, shown.len + 1) catch return;
    windows[0] = .{ .tag = "fizzy.window:main", .title = "fizzy", .rect = dvui.windowRectPixels() };
    if (main) |m| sources[0] = .{ .tag = windows[0].tag, .target = m.target, .w = m.w, .h = m.h };
    for (shown, 1..) |w, i| {
        const what = switch (w.kind) {
            .float => "float",
            .dialog => "dialog",
            .menu => "menu",
        };
        windows[i] = .{
            .tag = windowTag(arena, windows[0..i], what, w.title) catch return,
            .title = w.title,
            .rect = w.part,
            .subwindow = w.subwindow,
            // A float's window shows a band of the frame of its own: what opens in it is there.
            .area = w.kind == .float,
        };
        // On the OS's material, which a picture has none of: its base, opaque, as it reads.
        sources[i] = .{ .tag = windows[i].tag, .target = w.target, .w = w.w, .h = w.h, .at = w.in_main, .backing = Editor.windowBase(1) };
    }
    self.windows = windows;
    defer self.windows = &.{};
    if (naming) for (windows) |w| core.anchor.markRect(w.subwindow orelse .zero, w.rect, true, "{s}", .{w.tag});
    self.snapshot.endFrame();
    if (main != null) self.picture.endFrame(sources);
}

/// `fizzy.window:<what>:<title>` (no title, `fizzy.window:<what>`), and a number after where a
/// window before it has the name.
fn windowTag(arena: std.mem.Allocator, before: []const automation.Snapshot.Window, what: []const u8, title: []const u8) ![]const u8 {
    const base = if (title.len > 0) try std.fmt.allocPrint(arena, "fizzy.window:{s}:{s}", .{ what, title }) else try std.fmt.allocPrint(arena, "fizzy.window:{s}", .{what});
    var tag = base;
    var n: usize = 2;
    while (for (before) |w| {
        if (std.mem.eql(u8, w.tag, tag)) break true;
    } else false) : (n += 1) tag = try std.fmt.allocPrint(arena, "{s}:{d}", .{ base, n });
    return tag;
}

fn listWindows(ctx: *anyopaque, _: std.mem.Allocator) []const automation.Snapshot.Window {
    return from(ctx).windows;
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
    .capture = capture,
    .restore = restore,
    .release = release,
    .fingerprint = fingerprint,
    .step = step,
};

/// A live tape played by nobody in particular, or a demo with no name.
const tape_author: sdk.Author = .{ .kind = .tape, .plugin = "fizzy", .label = "a tape" };

/// Whose frame this is when a tape drives it: the live tape's author (`live_author`, else the
/// tape itself), or the demo being played or sought through. Null when no tape drives: a real
/// press or key stops either before the frame's input is consumed, so the frame is the person's.
pub fn author(self: *const Demo) ?sdk.Author {
    if (self.live.playing()) return self.live_author orelse tape_author;
    switch (self.player.state) {
        .playing, .seeking => {},
        else => return null,
    }
    const tape = (self.player.owned orelse return tape_author).tape;
    return .{
        .kind = .tape,
        .plugin = "fizzy",
        .session = std.hash.Wyhash.hash(0, tape.name),
        .label = if (tape.title.len > 0) tape.title else tape.name,
    };
}

fn liveAuthorSet(ctx: *anyopaque, who: ?sdk.Author) void {
    from(ctx).setLiveAuthor(who);
}

/// Play the next live tape for `who` (`automation.Api.playAs`); null, for no one in particular.
pub fn setLiveAuthor(self: *Demo, who: ?sdk.Author) void {
    const gpa = self.editor.app.gpa;
    if (self.live_author) |a| {
        gpa.free(a.plugin);
        gpa.free(a.label);
    }
    self.live_author = null;
    const a = who orelse return;
    const plugin = gpa.dupe(u8, a.plugin) catch return;
    const label = gpa.dupe(u8, a.label) catch {
        gpa.free(plugin);
        return;
    };
    self.live_author = .{ .kind = a.kind, .plugin = plugin, .session = a.session, .label = label };
}

/// What a tape's steps need of fizzy (`Tape.Check.steps`): the owner they name, loaded, writing
/// steps in the format they were recorded in.
pub fn stepsCheck(owner: []const u8, format: u32) bool {
    const plugin = fizzy.editor().app.host.pluginById(owner) orelse return false;
    return plugin.step_format != 0 and plugin.step_format == format and plugin.vtable.applyStep != null;
}

/// A step of a document the keyframe opened, applied by its owner (`Tape.Step`).
fn step(ctx: *anyopaque, st: automation.Tape.Step, ms: u32) void {
    const self = from(ctx);
    const editor = self.editor;
    const root = self.mount orelse return;
    const path = core.paths.join(editor.app.gpa, root, st.file) catch return;
    defer editor.app.gpa.free(path);
    const doc = editor.docFromPath(path) orelse {
        dvui.log.warn("demo: a step of {s}, which is not open", .{path});
        return;
    };
    if (doc.owner.applyStep(doc, st.effect, st.motion, ms)) return;
    // The document no longer is what the step was made on: every step after would miss too, so
    // the tape stops where the viewer can see it went wrong.
    self.player.pause();
    dvui.toast(@src(), .{ .message = "This tape's steps no longer fit its document: it stopped here." });
}

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
    var docs: std.ArrayList(Saved.Doc) = .empty;
    const active_id = if (editor.activeDoc()) |d| d.id else null;
    var active_doc: ?Saved.Doc = null;
    for (editor.app.open_files.values()) |doc| {
        const path = doc.owner.documentPath(doc);
        if (path.len == 0 or std.mem.startsWith(u8, path, "demo://")) continue;
        // Never saved (`untitled-1`): no file, and clean, since `mayStart` refused unsaved work, so
        // nothing to give back. Opened from its bytes it would come back as a file of that name.
        if (!reopenable(editor, path) and !doc.owner.documentHasRecognizedSaveExtension(doc)) continue;
        var saved: Saved.Doc = .{ .path = gpa.dupe(u8, path) catch continue };
        if (!reopenable(editor, path)) {
            saved.bytes = doc.owner.documentBytes(doc, path, gpa) catch null;
            if (saved.bytes == null) dvui.log.warn("demo: {s} cannot be opened again after the demo: its owner gives no bytes for it", .{path});
        }
        if (active_id == doc.id) active_doc = saved else docs.append(gpa, saved) catch freeSavedDoc(gpa, saved);
    }
    if (active_doc) |d| docs.append(gpa, d) catch freeSavedDoc(gpa, d);
    // Nor is a demo's folder: one demo straight after another finds the last one's folder still
    // open — giving the user theirs back by closing it is deferred to the next frame
    // (`App.closeProjectFolder`) — and must not give it to them at its end.
    const folder = editor.app.folder orelse "";
    self.saved = .{
        .folder = if (folder.len > 0 and !std.mem.startsWith(u8, folder, "demo://")) gpa.dupe(u8, folder) catch null else null,
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
    // What was opened from bytes first: a zip among them mounts again, so the folder and the
    // files opened from inside it can be opened after it.
    for (saved.docs) |d| {
        const bytes = d.bytes orelse continue;
        const path = gpa.dupe(u8, d.path) catch continue;
        _ = editor.openFileFromBytes(path, bytes, editor.workbench.currentGroupingID()) catch |err|
            dvui.log.warn("demo: could not reopen {s}: {t}", .{ d.path, err });
    }
    if (saved.folder) |f| {
        editor.setProjectFolder(f) catch |err| dvui.log.warn("demo: could not reopen {s}: {t}", .{ f, err });
    } else {
        editor.app.host.closeProjectFolder();
    }
    for (saved.docs) |d| {
        if (d.bytes != null) continue;
        _ = editor.openFilePath(d.path, editor.workbench.currentGroupingID()) catch |err|
            dvui.log.warn("demo: could not reopen {s}: {t}", .{ d.path, err });
    }
    // The active one last, whichever way it came back.
    if (saved.docs.len > 0) {
        if (openIndex(editor, saved.docs[saved.docs.len - 1].path)) |index| editor.workbench.setActiveDocIndex(index);
    }
    self.freeSaved();
    dvui.refresh(null, @src(), null);
}

fn freeSaved(self: *Demo) void {
    const gpa = self.editor.app.gpa;
    const saved = self.saved orelse return;
    if (saved.folder) |f| gpa.free(f);
    for (saved.docs) |d| freeSavedDoc(gpa, d);
    gpa.free(saved.docs);
    self.saved = null;
}

fn freeSavedDoc(gpa: std.mem.Allocator, d: Saved.Doc) void {
    gpa.free(d.path);
    if (d.bytes) |b| gpa.free(b);
}

/// Whether `path` opens again from where it is: a file on a mount (one the demo closes comes back
/// when what mounted it does), or on disk. The web has no disk: what is not on a mount there was
/// fetched or uploaded.
fn reopenable(editor: *Editor, path: []const u8) bool {
    if (editor.app.file_table.isMounted(path)) return true;
    if (comptime builtin.target.cpu.arch == .wasm32) return false;
    std.Io.Dir.cwd().access(dvui.io, path, .{}) catch return false;
    return true;
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
    editor.workbench.open_branches.clearRetainingCapacity();
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
    const self = from(ctx);
    const editor = self.editor;
    return editor.loading_jobs.count() == 0 and
        !editor.openings.loading() and
        editor.doc_io.loads.count() == 0 and
        // The demo's files answer from `pump`: a folder listed and not yet delivered is the
        // explorer still filling in.
        !(if (self.mem) |mem| mem.busy() else false);
}

/// With no arguments, as a menu row or a shortcut runs it — a command that needs some opens the
/// palette to ask, as it would for a person. With arguments, through `Host.callCommand`, as the
/// palette does once they are given; what it returns is not the demo's business.
fn command(ctx: *anyopaque, id: []const u8, args: []const u8) void {
    const host = &from(ctx).editor.app.host;
    // A tape's command is the tape's (or, for a live tape played for someone, theirs).
    const outer = host.act(from(ctx).author() orelse tape_author);
    defer host.endAct(outer);
    if (args.len == 0) {
        host.runCommand(id) catch |err| dvui.log.warn("demo: command {s} failed: {t}", .{ id, err });
        return;
    }
    var arena: std.heap.ArenaAllocator = .init(from(ctx).editor.app.gpa);
    defer arena.deinit();
    switch (host.callCommand(id, args, arena.allocator())) {
        .ok => {},
        .unknown => dvui.log.warn("demo: no command {s}", .{id}),
        .disabled => dvui.log.warn("demo: command {s} is disabled", .{id}),
        .bad_args, .failed => |msg| dvui.log.warn("demo: command {s} {s} failed: {s}", .{ id, args, msg }),
    }
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

// ---- snapshots ---------------------------------------------------------------------------------

/// A moment of a scene, for a seek to come back to (see the file comment). Everything in `arena`.
const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    /// The scene's folder: a snapshot is restored only into the scene it came from.
    root: []const u8,
    /// The mounted files as they were saved, in the order `Mem` holds them (parents first).
    nodes: []const Node,
    /// Open documents, in the order they were opened, and which was active.
    docs: []const Doc,
    active: ?usize,
    explorer_closed: bool,
    branches: []const dvui.Id,
    /// Whether the tree had opened its root on its own yet (`Workbench.file_tree_root_opened`),
    /// put back with `branches`: a root shut because the tree had not been drawn yet would stay
    /// shut, the tree believing it had already opened it.
    root_opened: ?usize,
    settings: []const SavedSettings,
    focus: dvui.Id,
    focus_subwindow: dvui.Id,

    const Node = struct { path: []const u8, kind: @FieldType(core.vfs.Mem.Node, "kind"), bytes: []const u8 };
    const Doc = struct { path: []const u8, grouping: u64, state: []const u8 };
};

fn capture(ctx: *anyopaque) ?*anyopaque {
    const self = from(ctx);
    const editor = self.editor;
    const gpa = editor.app.gpa;
    if (!idle(ctx) or editor.command_palette.open) return null;
    const root = self.mount orelse return null;
    const mem = self.mem orelse return null;

    const snap = gpa.create(Snapshot) catch return null;
    snap.* = .{
        .arena = .init(gpa),
        .root = undefined,
        .nodes = &.{},
        .docs = &.{},
        .active = null,
        .explorer_closed = editor.explorer.closed,
        .branches = &.{},
        .root_opened = editor.workbench.file_tree_root_opened,
        .settings = &.{},
        .focus = dvui.focusedWidgetId() orelse .zero,
        .focus_subwindow = dvui.focusedSubwindowId(),
    };
    const ok = fill(self, snap, root, mem) catch false;
    if (!ok) {
        release(ctx, snap);
        return null;
    }
    return snap;
}

/// Everything but the flags `capture` set. False when a document's owner cannot say what it holds.
fn fill(self: *Demo, snap: *Snapshot, root: []const u8, mem: *core.vfs.Mem) !bool {
    const editor = self.editor;
    const a = snap.arena.allocator();
    snap.root = try a.dupe(u8, root);

    const nodes = try a.alloc(Snapshot.Node, mem.nodes.count());
    for (mem.nodes.keys(), mem.nodes.values(), nodes) |path, node, *out| {
        out.* = .{ .path = try a.dupe(u8, path), .kind = node.kind, .bytes = try a.dupe(u8, node.bytes) };
    }
    snap.nodes = nodes;

    const active_id = if (editor.activeDoc()) |d| d.id else null;
    var docs: std.ArrayList(Snapshot.Doc) = .empty;
    for (editor.app.open_files.values()) |doc| {
        const state = doc.owner.captureDocumentState(doc, a) orelse return false;
        if (active_id == doc.id) snap.active = docs.items.len;
        try docs.append(a, .{
            .path = try a.dupe(u8, doc.owner.documentPath(doc)),
            .grouping = doc.owner.documentGrouping(doc),
            .state = state,
        });
    }
    snap.docs = docs.items;

    const branches = try a.alloc(dvui.Id, editor.workbench.open_branches.count());
    var it = editor.workbench.open_branches.keyIterator();
    var i: usize = 0;
    while (it.next()) |id| : (i += 1) branches[i] = id.*;
    snap.branches = branches;

    var settings: std.ArrayList(SavedSettings) = .empty;
    for (editor.app.host.settings_schemas.items) |*schema| {
        const blob = try settingsBlob(a, editor.app.arena.allocator(), schema);
        try settings.append(a, .{ .owner = try a.dupe(u8, schema.owner.id), .blob = blob });
    }
    snap.settings = settings.items;
    return true;
}

/// Put fizzy back to `snap` where it stands (see the file comment). False — having changed
/// nothing — when it is another scene's, or a document it held is no longer open as it was.
fn restore(ctx: *anyopaque, raw: *anyopaque) bool {
    const self = from(ctx);
    const editor = self.editor;
    const snap: *Snapshot = @ptrCast(@alignCast(raw));
    const root = self.mount orelse return false;
    const mem = self.mem orelse return false;
    if (!std.mem.eql(u8, root, snap.root)) return false;
    // Every document it held still open, in its pane.
    for (snap.docs) |d| {
        const doc = openDoc(editor, d.path) orelse return false;
        if (doc.owner.documentGrouping(doc) != d.grouping) return false;
    }

    // What has started since — loads, documents opened after it — goes.
    editor.command_palette.finishClose();
    editor.cancelAllLoadingJobs();
    while (editor.doc_io.loads.count() > 0) editor.doc_io.cancel(editor.doc_io.loads.keys()[0]);
    while (editor.openings.entries.count() > 0) editor.openings.drop(editor, editor.openings.entries.keys()[0]);
    var i = editor.app.open_files.count();
    while (i > 0) {
        i -= 1;
        const doc = editor.app.open_files.values()[i];
        const path = doc.owner.documentPath(doc);
        const kept = for (snap.docs) |d| {
            if (std.mem.eql(u8, d.path, path)) break true;
        } else false;
        if (!kept) editor.rawCloseFileID(editor.app.open_files.keys()[i]) catch {};
    }

    restoreFiles(mem, snap.nodes) catch |err| {
        dvui.log.err("demo: could not put the files back: {t}", .{err});
    };
    for (snap.docs) |d| {
        const doc = openDoc(editor, d.path) orelse continue;
        if (!doc.owner.restoreDocumentState(doc, d.state)) dvui.log.warn("demo: could not put {s} back", .{d.path});
    }
    if (snap.active) |a| {
        if (openIndex(editor, snap.docs[a].path)) |index| editor.workbench.setActiveDocIndex(index);
    }

    if (snap.explorer_closed != editor.explorer.closed) {
        if (snap.explorer_closed) editor.explorer.close(editor) else editor.explorer.open(editor);
    }
    editor.workbench.open_branches.clearRetainingCapacity();
    for (snap.branches) |id| editor.workbench.setBranchOpen(id, true);
    editor.workbench.file_tree_root_opened = snap.root_opened;

    for (snap.settings) |saved| {
        const schema = schemaFor(&editor.app.host, saved.owner) orelse continue;
        const now = settingsBlob(editor.app.gpa, editor.app.arena.allocator(), schema) catch continue;
        defer editor.app.gpa.free(now);
        if (!std.mem.eql(u8, now, saved.blob)) schema.access.applyBlob(schema.value, schema.owner, saved.blob);
    }

    if (snap.focus != .zero) dvui.focusWidget(snap.focus, snap.focus_subwindow, null);
    dvui.refresh(null, @src(), null);
    return true;
}

fn release(ctx: *anyopaque, raw: *anyopaque) void {
    const snap: *Snapshot = @ptrCast(@alignCast(raw));
    snap.arena.deinit();
    from(ctx).editor.app.gpa.destroy(snap);
}

/// The model a snapshot holds, less what may differ between passes — scroll, focus, and which
/// folders the explorer shows open, whose root opens on its own when its listing lands:
/// documents' fingerprints from their owners, which is active, the explorer shut or not, and the
/// files as saved.
fn fingerprint(ctx: *anyopaque) u64 {
    const self = from(ctx);
    const editor = self.editor;
    var h = std.hash.Wyhash.init(0xde40);
    for (editor.app.open_files.values()) |doc| {
        h.update(doc.owner.documentPath(doc));
        const print: u64 = doc.owner.documentFingerprint(doc) orelse 0;
        h.update(std.mem.asBytes(&print));
    }
    if (editor.activeDoc()) |d| h.update(d.owner.documentPath(d));
    h.update(std.mem.asBytes(&editor.explorer.closed));
    if (self.mem) |mem| {
        for (mem.nodes.keys(), mem.nodes.values()) |path, node| {
            h.update(path);
            h.update(node.bytes);
        }
    }
    return h.final();
}

fn openDoc(editor: *Editor, path: []const u8) ?sdk.DocHandle {
    const i = openIndex(editor, path) orelse return null;
    return editor.app.open_files.values()[i];
}

fn openIndex(editor: *Editor, path: []const u8) ?usize {
    for (editor.app.open_files.values(), 0..) |doc, i| {
        if (std.mem.eql(u8, doc.owner.documentPath(doc), path)) return i;
    }
    return null;
}

/// Make `mem` hold exactly `nodes`: in place when only bytes differ (the usual case — a save),
/// rebuilt when files came or went.
fn restoreFiles(mem: *core.vfs.Mem, nodes: []const Snapshot.Node) !void {
    const same_set = mem.nodes.count() == nodes.len and for (nodes) |n| {
        if (!mem.nodes.contains(n.path)) break false;
    } else true;
    if (same_set) {
        for (nodes) |n| {
            const node = mem.nodes.getPtr(n.path).?;
            if (std.mem.eql(u8, node.bytes, n.bytes)) continue;
            const copy = try mem.allocator.dupe(u8, n.bytes);
            if (node.bytes.len != 0) mem.allocator.free(node.bytes);
            node.bytes = copy;
            mem.generation += 1;
        }
        return;
    }
    for (mem.nodes.keys(), mem.nodes.values()) |path, node| {
        mem.allocator.free(path);
        if (node.bytes.len != 0) mem.allocator.free(node.bytes);
    }
    mem.nodes.clearRetainingCapacity();
    for (nodes) |n| {
        const key = try mem.allocator.dupe(u8, n.path);
        errdefer mem.allocator.free(key);
        const copy = try mem.allocator.dupe(u8, n.bytes);
        try mem.nodes.put(mem.allocator, key, .{ .kind = n.kind, .bytes = copy });
    }
    mem.generation += 1;
}
