//! fizzy's stage for demo automation (`app.automation`), and how a demo gets started.
//!
//! The player delivers a tape's input; this decides what fizzy's state *is* to a demo. A keyframe
//! closes every document of the demo's without saving, mounts the keyframe's files in memory at its root
//! (`demo://<name>`, a `core.vfs.Mem`, so nothing touches disk and every replay starts from the
//! same bytes), makes that the project folder on the explorer's Files view, resets the layout, and
//! opens the files the keyframe names. Seeking back is that, then a replay.
//!
//! A `focused` keyframe (the default) leaves only the documents showing — no bottom panel, the
//! explorer put away — and a demo opens the explorer from the rail when it is about to use it and
//! puts it away after (`catalog.openFile`), as a person short of room would.
//!
//! A demo plays inside the person's own copy of fizzy, on a stage of its own, so it costs them
//! nothing and waits for nothing: `begin` sets their session aside — their panes, which the
//! workbench holds whole (`Workbench.holdPanes`), the documents in them, which stay open behind
//! them untouched (hidden, never closed, saved, reloaded or put back by a snapshot), the project
//! folder, the explorer's open folders and the keyboard focus — and flushes any pending layout and
//! settings writes. Nothing is persisted while the demo is loaded (`active`). The demo's documents
//! are only its own: its mounted files (`demo://…`) and any it makes. `end` closes those, reloads
//! the layout from `layout.zon`, and gives the person back their panes, their documents as they
//! left them (unsaved edits and history with them), their folder and their focus.
//!
//! **Snapshots** (`automation.Stage.capture`) hold what a scene changes as it plays: the mounted
//! files as saved, each of the demo's open documents' state from its owner (`captureDocumentState` — contents,
//! caret, scroll), which is active, the explorer open or shut and its open folders, every plugin's
//! settings, keyboard focus, and how the window was arranged: the app's places (what each holds,
//! its splits, its size, shut or not, which view it shows), the floats, the seed tree, and the
//! documents' panes. Restoring one puts them back in place — documents opened since are closed,
//! the rest restored where they sit, a split or a float made since undone — so a seek back within
//! a scene costs no reload and no replay from the keyframe. One is taken only while nothing is
//! loading and the palette is shut, and restored only into the scene it came from with its
//! documents still open; otherwise the seek cuts to the keyframe.
//!
//! Demos start from the command palette ("Demo: …"), the Help menu, `FIZZY_DEMO=<name>` natively,
//! or `?demo=<name>` / `?demo=<url of a .zon or .tape>` on the web — see `docs/AUTOMATION.md`.
const Demo = @This();

const std = @import("std");
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
/// The app's own settings a tape can change, as the demo found them: only the window's material
/// (`fizzy.windowMaterial`) so far. A copy of the whole would not do: some hold strings it owns.
material_saved: ?core.material.Kind = null,
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
    /// The person's open documents, by id: set aside, open all along. Every other document is the
    /// demo's (`ownsDocument`).
    docs: []const u64,
    /// The one they were in.
    active: ?u64,
    /// The explorer's open folders, and whether its root had opened (`Workbench.file_tree_root_opened`).
    branches: []const dvui.Id,
    root_opened: ?usize,
    focus: dvui.Id,
    focus_subwindow: dvui.Id,
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
    // Numbered from somewhere of this run's own, not 1: a screen's number (`fizzy.screen`'s `seq`)
    // kept from an earlier run is then not some other screen of this one (`since`).
    self.snapshot.taken = @as(u32, @truncate(@as(u96, @bitCast(std.Io.Clock.real.now(dvui.io).nanoseconds)))) & 0x3fff_ffff;
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

/// A demo plays on a stage of its own (`begin`), so the person's work, saved or not, never stops
/// one: only another tape driving the app does.
fn mayStart(self: *Demo) bool {
    return self.startable() == .started;
}

/// Whether a demo can start now (`.started`), and if not why, told to the person as a toast too.
pub fn startable(self: *Demo) sdk.services.demos.Api.Play {
    if (self.live.playing()) {
        core.dialogs.toast(@src(), .{ .message = "Something is driving fizzy right now — the demo can start once it has finished." });
        return .busy;
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
    const taken = self.snapshot.taken;
    self.snapshot.endFrame();
    // What the snapshot just written shows: every command run up to now (`fizzy.screen`).
    if (self.snapshot.taken != taken) {
        self.editor.command_runs_at_snapshot = self.editor.app.host.command_runs;
    }
    if (main != null) self.picture.endFrame(sources);
}

/// `fizzy.window:<what>:<title>` (no title, `fizzy.window:<what>`), and a number after where a
/// window before it has the name.
fn windowTag(arena: std.mem.Allocator, before: []const automation.Snapshot.Window, what: []const u8, title: []const u8) ![]const u8 {
    const base = if (title.len > 0) try arena.print("fizzy.window:{s}:{s}", .{ what, title }) else try arena.print("fizzy.window:{s}", .{what});
    var tag = base;
    var n: usize = 2;
    while (for (before) |w| {
        if (std.mem.eql(u8, w.tag, tag)) break true;
    } else false) : (n += 1) tag = try arena.print("{s}:{d}", .{ base, n });
    return tag;
}

fn listWindows(ctx: *anyopaque, _: std.mem.Allocator) []const automation.Snapshot.Window {
    return from(ctx).windows;
}

// ---- the stage -----------------------------------------------------------------------------

const stage_vtable: automation.Stage.VTable = .{
    .begin = begin,
    .end = end,
    .keep = keep,
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
    core.dialogs.toast(@src(), .{ .message = "This tape's steps no longer fit its document: it stopped here." });
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
    // The one they are in, before their panes go: the demo's has none.
    // (Not a document of a demo kept before (`keep`): that one closes with the next keyframe.)
    const in_front = if (editor.activeDoc()) |d|
        (if (std.mem.startsWith(u8, d.owner.documentPath(d), "demo://")) null else d.id)
    else
        null;
    // Their panes go aside whole, the demo playing in one of its own.
    editor.workbench.holdPanes();

    // Their documents stay open behind them, hidden: no place shows them while the demo has the
    // window, and nothing of the demo's closes, saves or restores them (`ownsDocument`). A demo's
    // left open by the last (one whose close failed) is not theirs.
    const gpa = editor.app.gpa;
    var docs: std.ArrayList(u64) = .empty;
    for (editor.app.open_files.values()) |doc| {
        if (std.mem.startsWith(u8, doc.owner.documentPath(doc), "demo://")) continue;
        docs.append(gpa, doc.id) catch continue;
    }
    const held = docs.toOwnedSlice(gpa) catch &.{};
    const branches: []const dvui.Id = if (gpa.alloc(dvui.Id, editor.workbench.open_branches.count())) |out| blk: {
        var it = editor.workbench.open_branches.keyIterator();
        for (out) |*b| b.* = it.next().?.*;
        break :blk out;
    } else |_| &.{};
    // Nor is a demo's folder: one demo straight after another finds the last one's folder still
    // open — giving the user theirs back by closing it is deferred to the next frame
    // (`App.closeProjectFolder`) — and must not give it to them at its end.
    const folder = editor.app.folder orelse "";
    self.saved = .{
        .folder = if (folder.len > 0 and !std.mem.startsWith(u8, folder, "demo://")) gpa.dupe(u8, folder) catch null else null,
        .docs = held,
        .active = in_front orelse if (held.len > 0) held[held.len - 1] else null,
        .branches = branches,
        .root_opened = editor.workbench.file_tree_root_opened,
        .focus = dvui.focusedWidgetId() orelse .zero,
        .focus_subwindow = dvui.focusedSubwindowId(),
    };
    for (held) |id| self.hideDocument(id, true);
}

/// Whether `doc` is the demo's: one it opened or made, not one of the person's — open at `begin`,
/// or landing since in a pane of theirs (an open on its way as the demo started, a document their
/// plugin's reload brought back), which the workbench holds (`Workbench.holdsDocument`).
pub fn ownsDocument(self: *const Demo, doc: sdk.DocHandle) bool {
    const saved = self.saved orelse return true;
    if (std.mem.findScalar(u64, saved.docs, doc.id) != null) return false;
    return !self.editor.workbench.holdsDocument(doc);
}

/// Hide the person's document `id` from every place while the demo has the window, or show it.
/// One whose surface is made again meanwhile (a rename) is hidden by `Editor.registerDocSurface`.
fn hideDocument(self: *Demo, id: u64, hidden: bool) void {
    const ds = self.editor.doc_surfaces.get(id) orelse return;
    self.editor.app.host.setSurfaceHidden(ds.id, hidden);
}

fn end(ctx: *anyopaque) void {
    const self = from(ctx);
    const editor = self.editor;
    const gpa = editor.app.gpa;
    self.fast = false;
    if (self.quitting) {
        for (editor.app.open_files.keys()) |id| self.hideDocument(id, false);
        self.freeSaved();
        self.freeSavedSettings();
        editor.workbench.restorePanes();
        return;
    }
    self.restoreSettings();
    self.closeDemoDocuments();
    self.unmountFiles();

    // The layout as the user left it: `begin` flushed it, and nothing has been written since.
    editor.app.layout.resetLayout(gpa);
    editor.loadSavedLayout();
    editor.app.layout.dirty = false;
    editor.command_palette.finishClose();
    // Their panes, each holding what it held: after the layout's reload, which would otherwise
    // put back only what the file had of them.
    editor.workbench.restorePanes();

    const saved = self.saved orelse return;
    // What is open now is all theirs: the demo's have closed.
    for (editor.app.open_files.keys()) |id| self.hideDocument(id, false);
    if (saved.folder) |f| {
        editor.setProjectFolder(f) catch |err| dvui.log.warn("demo: could not reopen {s}: {t}", .{ f, err });
    } else {
        editor.app.host.closeProjectFolder();
    }
    editor.workbench.open_branches.clearRetainingCapacity();
    for (saved.branches) |id| editor.workbench.setBranchOpen(id, true);
    editor.workbench.file_tree_root_opened = saved.root_opened;
    if (saved.active) |id| {
        if (editor.app.open_files.getIndex(id)) |index| editor.workbench.setActiveDocIndex(index);
    }
    if (saved.focus != .zero) dvui.focusWidget(saved.focus, saved.focus_subwindow, null);
    self.freeSaved();
    dvui.refresh(null, @src(), null);
}

/// The demo is let go and the app stays as it is (`Player.keep`): its documents, folder (still
/// mounted in memory), layout and focus are now simply the app's. What was never the demo's comes
/// back: the person's settings, and their documents, unhidden and seated as tabs in the pane the
/// demo has open (`Workbench.keepPanes`) beside the demo's. Persistence resumes (`active`) with
/// what is on screen.
fn keep(ctx: *anyopaque) void {
    const self = from(ctx);
    const editor = self.editor;
    self.fast = false;
    if (self.quitting) return end(ctx);
    self.restoreSettings();
    editor.workbench.keepPanes();
    for (editor.app.open_files.keys()) |id| self.hideDocument(id, false);
    self.freeSaved();
    editor.app.layout.dirty = true;
    dvui.refresh(null, @src(), null);
}

fn freeSaved(self: *Demo) void {
    const gpa = self.editor.app.gpa;
    const saved = self.saved orelse return;
    if (saved.folder) |f| gpa.free(f);
    gpa.free(saved.docs);
    gpa.free(saved.branches);
    self.saved = null;
}

/// Put fizzy into `kf` outright: nothing the demo did before survives.
fn keyframe(ctx: *anyopaque, kf: *const automation.Tape.Keyframe) void {
    const self = from(ctx);
    const editor = self.editor;
    const gpa = editor.app.gpa;

    editor.command_palette.finishClose();
    self.closeDemoDocuments();
    // One pane: a split a later moment made is gone at a cut, as on the first pass.
    editor.workbench.onePane();
    self.applySettings(kf.settings);
    // The app's settings a tape changes are the person's again at a cut: a keyframe declares its
    // state outright, and declares none of them.
    if (self.material_saved) |m| editor.app.settings.window_material = m;

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

/// `s` with the person's own values where the demo has set them aside: what the settings file is
/// written with while a demo plays (`Editor.composeSettingsText`).
pub fn personsSettings(self: *const Demo, s: *Editor.Settings) void {
    if (self.material_saved) |m| s.window_material = m;
}

fn saveSettings(self: *Demo) void {
    const editor = self.editor;
    const gpa = editor.app.gpa;
    self.material_saved = editor.app.settings.window_material;
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
    if (self.material_saved) |m| editor.app.settings.window_material = m;
    self.material_saved = null;
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
        while (std.mem.findScalarPos(u8, f.path, i, '/')) |slash| : (i = slash + 1) {
            const dir = try gpa.print("/{s}", .{f.path[0..slash]});
            defer gpa.free(dir);
            mem.putDir(dir) catch |err| switch (err) {
                error.Exists => {},
                else => return err,
            };
        }
        const path = try gpa.print("/{s}", .{f.path});
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

/// Close every document of the demo's, discarding changes: none is the person's, whose are set
/// aside (`ownsDocument`). Loads still on their way are dropped too, or they would land in the
/// next keyframe.
fn closeDemoDocuments(self: *Demo) void {
    const editor = self.editor;
    editor.cancelAllLoadingJobs();
    while (editor.doc_io.loads.count() > 0) editor.doc_io.cancel(editor.doc_io.loads.keys()[0]);
    while (editor.openings.entries.count() > 0) editor.openings.drop(editor, editor.openings.entries.keys()[0]);
    var i = editor.app.open_files.count();
    while (i > 0) {
        i -= 1;
        // A close can take others with it (an archive's, its mount's files).
        if (i >= editor.app.open_files.count()) continue;
        const doc = editor.app.open_files.values()[i];
        if (!self.ownsDocument(doc)) continue;
        editor.rawCloseFileID(doc.id) catch |err| dvui.log.warn("demo: could not close a document of its own: {t}", .{err});
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
    material: core.material.Kind,
    focus: dvui.Id,
    focus_subwindow: dvui.Id,
    /// How the window was arranged: the app's places as `layout.zon` would remember them
    /// (`Editor.collectSavedRegions`, ZON, by name), its seed tree (ZON, null with none), each
    /// place's widget state and view, and the documents' panes.
    regions: [:0]const u8,
    tree: ?[:0]const u8,
    places: []const Place,
    panes: Editor.Workbench.Arrangement,

    const Node = struct { path: []const u8, kind: @FieldType(core.vfs.Mem.Node, "kind"), bytes: []const u8 };
    const Doc = struct { path: []const u8, grouping: u64, state: []const u8 };
    /// A place as it was drawn: how wide (`_size`; zero is shut), where it opens back to (`_open`),
    /// whether it was opened on a window too narrow for it (`_peek`), and the view it showed. The
    /// explorer's place keeps only its view: a restore opens or shuts the explorer itself
    /// (`explorer_closed`), and a document pane only its view, the tab in front: its size is the
    /// panes' tree.
    const Place = struct {
        id: dvui.Id,
        key: u64,
        view: ?[]const u8,
        sized: bool,
        size: ?f32,
        open: ?f32,
        peek: ?bool,
    };
};

/// The app's places and seed tree as `Snapshot.regions` and `Snapshot.tree` hold them.
const Arrangement = struct { regions: []const fizzy.backend.SavedRegion };

/// The app's places as ZON, by name, in `gpa`: what a snapshot compares and puts back.
fn regionsZon(editor: *Editor, gpa: std.mem.Allocator) ![:0]u8 {
    const regions = editor.collectSavedRegions(gpa);
    defer gpa.free(regions);
    // By name: the layout's maps hand them over in no order of their own.
    std.mem.sort(fizzy.backend.SavedRegion, regions, {}, struct {
        fn less(_: void, a: fizzy.backend.SavedRegion, b: fizzy.backend.SavedRegion) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.less);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    try std.zon.stringify.serializeMaxDepth(Arrangement{ .regions = regions }, .{}, &aw.writer, 16);
    return aw.toOwnedSliceSentinel(0);
}

/// The seed tree as ZON, in `gpa`; null where the shape has none.
fn treeZon(editor: *Editor, gpa: std.mem.Allocator) !?[:0]u8 {
    const dock = &(editor.app.layout.dock orelse return null);
    const snap = try dock.snapshot(gpa);
    defer snap.deinit(gpa);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    // `serializeMaxDepth`: a snapshot tree is a recursive type, which `serialize` refuses.
    try std.zon.stringify.serializeMaxDepth(snap, .{}, &aw.writer, 64);
    return try aw.toOwnedSliceSentinel(0);
}

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
        .material = editor.app.settings.window_material,
        .focus = dvui.focusedWidgetId() orelse .zero,
        .focus_subwindow = dvui.focusedSubwindowId(),
        .regions = "",
        .tree = null,
        .places = &.{},
        .panes = undefined,
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
        if (!self.ownsDocument(doc)) continue;
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

    snap.regions = try regionsZon(editor, a);
    snap.tree = try treeZon(editor, a);
    const explorer = if (editor.regionFor(sdk.keywords.ide.sidebar)) |r| r.name else "";
    const regions = editor.app.layout.regions.items;
    const places = try a.alloc(Snapshot.Place, regions.len);
    var n: usize = 0;
    for (regions) |r| {
        if (r.name.len == 0 or r.id == .zero) continue;
        const view = editor.app.host.selectionForKey(r.selectionKey());
        places[n] = .{
            .id = r.id,
            .key = r.selectionKey(),
            .view = if (view) |v| try a.dupe(u8, v) else null,
            .sized = !r.by_name and !std.mem.eql(u8, r.name, explorer),
            .size = dvui.dataGet(null, r.id, "_size", f32),
            .open = dvui.dataGet(null, r.id, "_open", f32),
            .peek = dvui.dataGet(null, r.id, "_peek", bool),
        };
        n += 1;
    }
    snap.places = places[0..n];
    snap.panes = try editor.workbench.arrangement(a);
    return true;
}

/// Put the window back to how `snap` found it (`Snapshot.regions` and on): the app's places, the
/// floats, the seed tree, the documents' panes and each place's size and view. What is the same
/// already is left alone, so a restore within one arrangement touches nothing of it. An error —
/// having changed nothing — when it could not be read back: everything that can fail is done
/// before anything changes.
fn restoreArrangement(editor: *Editor, snap: *const Snapshot) !void {
    const gpa = editor.app.gpa;
    const state = &editor.app.layout;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var diag: std.zon.parse.Diagnostics = undefined;

    // The app's places as the snapshot had them, where they differ from now.
    const regions: ?[]const fizzy.backend.SavedRegion = blk: {
        const now = try regionsZon(editor, gpa);
        defer gpa.free(now);
        if (std.mem.eql(u8, now, snap.regions)) break :blk null;
        break :blk (try std.zon.parse.fromSlice(Arrangement, .{ .gpa = gpa, .arena = arena.allocator(), .source = snap.regions, .diagnostics = &diag })).regions;
    };
    // Its seed tree, built, where it differs: null for none at all.
    const same_tree = blk: {
        const now = try treeZon(editor, gpa);
        defer if (now) |t| gpa.free(t);
        if (now == null or snap.tree == null) break :blk now == null and snap.tree == null;
        break :blk std.mem.eql(u8, now.?, snap.tree.?);
    };
    var dock: ?core.widgets.DockLayout = null;
    if (!same_tree) if (snap.tree) |source| {
        const tree = try std.zon.parse.fromSlice(core.widgets.DockLayout.Snapshot, .{ .gpa = gpa, .arena = arena.allocator(), .source = source, .diagnostics = &diag });
        dock = try core.widgets.DockLayout.fromSnapshot(gpa, tree);
        dock.?.animated = true;
    };
    errdefer if (dock) |*d| d.deinit();
    // The panes: all or nothing, and the last thing that can fail.
    try editor.workbench.arrange(snap.panes);

    if (regions) |saved| {
        state.clearArrangement(gpa);
        // The floats it had stay as they were, bottom to top, as far as they still are: re-made,
        // a float draws afresh from nothing, and one moved has an OS window of its own to follow.
        // From the first that differs (moved, restacked, flying shut, or not the snapshot's) they
        // go, and come back from it in its order (`applySavedRegions`).
        var floats: std.ArrayList(fizzy.backend.SavedRegion) = .empty;
        for (saved) |r| if (r.floating != null) try floats.append(arena.allocator(), r);
        std.mem.sort(fizzy.backend.SavedRegion, floats.items, {}, struct {
            fn less(_: void, a: fizzy.backend.SavedRegion, b: fizzy.backend.SavedRegion) bool {
                return a.floating.?.z < b.floating.?.z;
            }
        }.less);
        var kept: usize = 0;
        for (state.floats.items.items) |f| {
            if (kept == floats.items.len or f.closing) break;
            const was = floats.items[kept];
            const at = was.floating.?;
            if (!std.mem.eql(u8, was.name, f.name) or at.x != f.rect.x or at.y != f.rect.y or at.w != f.rect.w or at.h != f.rect.h) break;
            kept += 1;
        }
        while (state.floats.items.items.len > kept) state.floats.removeAt(state.floats.items.items.len - 1);
        editor.applySavedRegions(saved);
    }
    if (!same_tree) {
        state.deinitDock();
        state.pending_dock = dock;
    }

    // Each place drawn as it was. One drawn now that it did not have — a split made since — is
    // forgotten too, or a split of that name made again would open at the size this one was left.
    for (state.regions.items) |r| {
        if (r.by_name or r.id == .zero) continue;
        const had = for (snap.places) |p| {
            if (p.id == r.id) break true;
        } else false;
        if (!had) @import("app").layout.Layout.State.forgetWidgetSize(r.id);
    }
    for (snap.places) |p| {
        if (p.sized) {
            putData(f32, p.id, "_size", p.size);
            // At rest at that size, not easing toward it.
            putData(f32, p.id, "_shown", p.size);
            dvui.dataRemove(null, p.id, "_ease");
            putData(f32, p.id, "_open", p.open);
            putData(bool, p.id, "_peek", p.peek);
        }
        const now = editor.app.host.selectionForKey(p.key);
        if (p.view) |v| {
            if (now == null or !std.mem.eql(u8, now.?, v)) editor.app.host.setSelectionForKey(p.key, v);
        } else if (now != null) {
            editor.app.host.clearSelectionForKey(p.key);
        }
    }
}

/// `value` under `id`'s `key`, or nothing there where it is null.
fn putData(comptime T: type, id: dvui.Id, key: []const u8, value: ?T) void {
    if (value) |v| {
        if (dvui.dataGet(null, id, key, T) != v) dvui.dataSet(null, id, key, v);
    } else dvui.dataRemove(null, id, key);
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
    // Every document it held still open.
    for (snap.docs) |d| _ = openDoc(editor, d.path) orelse return false;
    // The window as it was, before anything else is put back: it can fail, and fails changing
    // nothing.
    restoreArrangement(editor, snap) catch |err| {
        dvui.log.warn("demo: could not put the window's layout back: {t}", .{err});
        return false;
    };

    // What has started since — loads, documents opened after it — goes.
    editor.command_palette.finishClose();
    editor.cancelAllLoadingJobs();
    while (editor.doc_io.loads.count() > 0) editor.doc_io.cancel(editor.doc_io.loads.keys()[0]);
    while (editor.openings.entries.count() > 0) editor.openings.drop(editor, editor.openings.entries.keys()[0]);
    var i = editor.app.open_files.count();
    while (i > 0) {
        i -= 1;
        const doc = editor.app.open_files.values()[i];
        if (!self.ownsDocument(doc)) continue;
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
        if (doc.owner.documentGrouping(doc) != d.grouping) doc.owner.setDocumentGrouping(doc, d.grouping);
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
    editor.app.settings.window_material = snap.material;

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

/// The model a snapshot holds (the demo's own documents, never the person's), less what may differ between passes — scroll, focus, and which
/// folders the explorer shows open, whose root opens on its own when its listing lands:
/// documents' fingerprints from their owners, which is active, the explorer shut or not, the
/// window's arrangement (`layoutPrint`), and the files as saved.
fn fingerprint(ctx: *anyopaque) u64 {
    const self = from(ctx);
    const editor = self.editor;
    var h = std.hash.Wyhash.init(0xde40);
    for (editor.app.open_files.values()) |doc| {
        if (!self.ownsDocument(doc)) continue;
        h.update(doc.owner.documentPath(doc));
        const print: u64 = doc.owner.documentFingerprint(doc) orelse 0;
        h.update(std.mem.asBytes(&print));
    }
    if (editor.activeDoc()) |d| h.update(d.owner.documentPath(d));
    h.update(std.mem.asBytes(&editor.explorer.closed));
    h.update(std.mem.asBytes(&editor.app.settings.window_material));
    const layout = layoutPrint(editor);
    h.update(std.mem.asBytes(&layout));
    if (self.mem) |mem| {
        for (mem.nodes.keys(), mem.nodes.values()) |path, node| {
            h.update(path);
            h.update(node.bytes);
        }
    }
    return h.final();
}

/// How the window is arranged, for a seek to land on what playing reached and a chapter to start in
/// the window the last one left: each of the app's places by name, shut or not and what it shows,
/// how many panes the documents have, and the floats not flying shut. The explorer's own place opening and
/// shutting is left out: the fingerprint has the explorer shut or not on its own.
/// Places are taken in any order: the same arrangement drawn in another order is the same.
pub fn layoutPrint(editor: *Editor) u64 {
    const state = &editor.app.layout;
    const explorer = if (editor.regionFor(sdk.keywords.ide.sidebar)) |r| r.name else "";
    var print: u64 = 0;
    for (state.regions.items) |r| {
        // A plugin's own places — the documents' panes — are its to arrange, and named afresh
        // each time one opens: counted below, and their documents' panes checked on restore.
        if (r.by_name) continue;
        var h = std.hash.Wyhash.init(0x1a70);
        h.update(r.name);
        if (!std.mem.eql(u8, r.name, explorer)) h.update(std.mem.asBytes(&r.isClosed()));
        h.update(editor.app.host.selectionForKey(r.selectionKey()) orelse "");
        print +%= h.final();
    }
    var h = std.hash.Wyhash.init(print);
    h.update(std.mem.asBytes(&editor.workbench.workspaces.count()));
    // One flying shut is already gone from the layout, as `layout.zon` has it.
    var floats: usize = 0;
    for (state.floats.items.items) |f| floats += @intFromBool(!f.closing);
    h.update(std.mem.asBytes(&floats));
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
