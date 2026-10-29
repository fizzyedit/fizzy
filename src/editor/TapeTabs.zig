//! Tapes played in a tab of their own: a document's track shared as a tape (`fizzy.tracks.export`)
//! opens beside the person's documents, never over them, and plays itself in.
//!
//! The tape's file (its keyframe's one document, as it was when the track began) is mounted
//! under a root of its own (`tape://<n>`) and opened like any file; then each step is applied as
//! its moment comes, by the document's owner (`Plugin.applyStep`, at pace). Each step lands as an
//! entry on the document's history, so the document's transport plays back over what has played:
//! scrub back through it, step through it, as through any document's history. Gone back while it
//! plays, the playback holds; back at the end, it plays on. Its transport's play button pauses it.
//!
//! Unlike the demo stage, nothing of the person's is set aside or waits on their unsaved work: the
//! tape is a document among theirs. Closing it ends the playback and the mount. While nothing is
//! playing a frame costs one check of an empty list; while one is, a timer wakes it for the next
//! step and nothing more.
const TapeTabs = @This();

const std = @import("std");
const dvui = @import("dvui");
const fizzy = @import("../fizzy.zig");
const core = fizzy.core;
const sdk = fizzy.sdk;
const app = @import("app");
const automation = app.automation;
const Editor = @import("Editor.zig");

playing: std.ArrayList(*Playback) = .empty,
/// The next playback's number, for its root.
next: u32 = 1,
/// A tape waiting for the plugins its documents need (`openWhenReady`): its bytes, owned.
waiting: ?Waiting = null,

const Waiting = struct {
    bytes: []u8,
    /// The plugins its documents belong to, owned.
    owners: [][]u8,
    /// Which of `owners` the store has been asked to load (on the web): asked once, so a build
    /// that fails is not fetched again every look.
    asked: []bool,
    /// The frame it was first looked at; null before.
    since_ns: ?i128,
    /// Played with nothing else in view (a page that is only the tape, `?tape=`).
    alone: bool,

    fn deinit(self: Waiting, gpa: std.mem.Allocator) void {
        gpa.free(self.bytes);
        for (self.owners) |o| gpa.free(o);
        gpa.free(self.owners);
        gpa.free(self.asked);
    }
};

/// How long a tape waits for its plugins before saying it cannot be played.
const wait_limit_ns: i128 = 60 * std.time.ns_per_s;

const Playback = struct {
    owned: automation.Tape.Owned,
    mem: *core.vfs.Mem,
    /// `tape://<n>`: the tape's mount.
    root: []u8,
    /// The document's path under it.
    path: []u8,
    /// The document once it opened; null while it loads.
    doc_id: ?u64 = null,
    /// The next op to apply.
    op: usize = 0,
    /// When the document opened: the tape's time 0, moved on by each pause.
    start_ns: i128 = 0,
    /// Since when the person has held the tape back: they went back along its document's history
    /// (its transport), so its steps wait rather than land over where they went. Null: playing.
    held_ns: ?i128 = null,
    /// The person paused it, with its transport's play button (`setPaused`).
    paused: bool = false,
    /// When the tape was opened: a document that has not come by `load_limit_ns` after never
    /// will (its load failed), and the playback lets its mount go.
    opened_ns: i128,
    /// Said on the tape's own tab once it shows (`Editor.noteOnDocument`); owned.
    note: ?[]u8 = null,
};

pub const OpenOptions = struct {
    /// Said on the tape's tab once it shows.
    note: ?[]const u8 = null,
};

const load_limit_ns: i128 = 30 * std.time.ns_per_s;

pub fn deinit(self: *TapeTabs, editor: *Editor) void {
    for (self.playing.items) |p| free(editor, p);
    self.playing.deinit(editor.app.gpa);
    if (self.waiting) |w| w.deinit(editor.app.gpa);
    self.waiting = null;
}

/// Play the tape in `bytes` once the plugins its documents belong to are loaded: at once when they
/// are; else, where the app can fetch them from the store on its own (the web, where a link to a
/// tape is how one is shared), asking the store for each and waiting, up to `wait_limit_ns`. One
/// document's tape plays in a tab of its own (`open`), anything else on the demo stage. `alone`:
/// nothing else in view, the tape the page (`Editor.show_only_document`). The bytes are copied.
pub fn openWhenReady(self: *TapeTabs, editor: *Editor, bytes: []const u8, alone: bool) !void {
    const gpa = editor.app.gpa;
    // Read for its owners alone: whether they apply its steps is asked once they are loaded.
    var check = automation.Input.check;
    check.steps = struct {
        fn any(_: []const u8, _: u32) bool {
            return true;
        }
    }.any;
    var owned = automation.Tape.load(gpa, bytes, check) catch return error.BadTape;
    defer owned.deinit();
    var owners: std.ArrayList([]u8) = .empty;
    errdefer {
        for (owners.items) |o| gpa.free(o);
        owners.deinit(gpa);
    }
    for (owned.tape.keyframes) |kf| for (kf.files) |f| {
        if (f.owner.len == 0) continue;
        for (owners.items) |o| {
            if (std.mem.eql(u8, o, f.owner)) break;
        } else try owners.append(gpa, try gpa.dupe(u8, f.owner));
    };
    if (self.waiting) |w| w.deinit(gpa);
    self.waiting = null;
    const asked = try gpa.alloc(bool, owners.items.len);
    errdefer gpa.free(asked);
    @memset(asked, false);
    const copy = try gpa.dupe(u8, bytes);
    errdefer gpa.free(copy);
    // Looked at from the next frame's top (`tick`): the page can call this between frames.
    self.waiting = .{ .bytes = copy, .owners = try owners.toOwnedSlice(gpa), .asked = asked, .since_ns = null, .alone = alone };
    editor.app.host.refresh();
}

/// The waiting tape's next look: played once every owner is loaded; meanwhile each missing one
/// asked of the store (on the web), and a wake set to look again.
fn wait(self: *TapeTabs, editor: *Editor) void {
    const w = if (self.waiting) |*waiting| waiting else return;
    const since = w.since_ns orelse since: {
        w.since_ns = core.MotionClock.wallFrameNs();
        break :since w.since_ns.?;
    };
    const gpa = editor.app.gpa;
    var missing: ?[]const u8 = null;
    // A plugin asked for whose load has ended without it: it failed, and will not come.
    var failed = false;
    for (w.owners, w.asked) |o, *asked| {
        if (editor.app.host.pluginById(o) != null) continue;
        missing = o;
        if (comptime @import("builtin").target.cpu.arch == .wasm32) {
            if (asked.*) {
                if (!app.store.Store.isInstalling(o)) failed = true;
                continue;
            }
            // The catalog first, on a page that has not opened the store; then the plugin, for
            // this visit: playing a tape installs nothing.
            app.store.Store.wantCatalog();
            asked.* = app.store.Store.loadForVisit(o);
        }
    }
    if (missing) |o| {
        const native = comptime @import("builtin").target.cpu.arch != .wasm32;
        if (native or failed or core.MotionClock.wallFrameNs() - since > wait_limit_ns) {
            dvui.log.warn("tape: it needs the plugin '{s}', which is not loaded", .{o});
            core.dialogs.toast(@src(), .{ .message = dvui.currentWindow().arena().print("This tape needs the {s} plugin", .{o}) catch "This tape needs a plugin that is not loaded" });
            w.deinit(gpa);
            self.waiting = null;
            return;
        }
        // The store's catalog, or the plugin, lands in a moment: look again then.
        dvui.timer(dvui.Id.extendId(null, @src(), 0), 250_000);
        return;
    }
    const ready = w.*;
    self.waiting = null;
    defer ready.deinit(gpa);
    self.open(editor, ready.bytes, .{}) catch |err| switch (err) {
        // Anything but one document's tape, or steps of a format its owner does not write: the
        // demo stage plays it, or says why it cannot.
        error.NotOneDocument, error.BadTape => editor.demo.playTapeSoon(ready.bytes),
        else => {
            dvui.log.warn("tape: could not play it: {t}", .{err});
            return;
        },
    };
    if (ready.alone) editor.show_only_document = true;
}

pub const OpenError = error{
    /// Not a tape fizzy reads, or steps of an owner not loaded or of another format.
    BadTape,
    /// A tape of anything but one document's steps (a demo, a session of several): the demo stage
    /// plays those (`fizzy.demo.playTape`).
    NotOneDocument,
    OutOfMemory,
};

/// Open the tape in `bytes` in a tab of its own and play it. The bytes may be let go of at once.
pub fn open(self: *TapeTabs, editor: *Editor, bytes: []const u8, opts: OpenOptions) (OpenError || anyerror)!void {
    const gpa = editor.app.gpa;
    var check = automation.Input.check;
    check.steps = @import("Demo.zig").stepsCheck;
    var owned = automation.Tape.load(gpa, bytes, check) catch return error.BadTape;
    errdefer owned.deinit();
    const tape = owned.tape;
    if (tape.keyframes.len != 1 or tape.keyframes[0].files.len != 1) return error.NotOneDocument;
    for (tape.ops[1..]) |op| switch (op.do) {
        .step, .wait => {},
        else => return error.NotOneDocument,
    };
    const file = tape.keyframes[0].files[0];

    // A root nothing holds: not a mount, and no document open under it (one a crash's recovery
    // or a restart brought back from an earlier run).
    const root = root: while (true) : (self.next += 1) {
        const r = try gpa.print("tape://{d}", .{self.next});
        if (!editor.app.file_table.isMounted(r) and !openUnder(editor, r)) break :root r;
        gpa.free(r);
    };
    errdefer gpa.free(root);
    const path = try core.paths.join(gpa, root, file.path);
    errdefer gpa.free(path);
    const mem = try gpa.create(core.vfs.Mem);
    errdefer gpa.destroy(mem);
    mem.* = try .init(gpa);
    errdefer mem.deinit();
    const at = try gpa.print("/{s}", .{file.path});
    defer gpa.free(at);
    try mem.put(at, file.text);
    try editor.app.host.mount(root, mem.fs());
    errdefer editor.app.host.unmount(root);

    const p = try gpa.create(Playback);
    errdefer gpa.destroy(p);
    p.* = .{ .owned = owned, .mem = mem, .root = root, .path = path, .opened_ns = dvui.frameTimeNS(), .note = if (opts.note) |n| try gpa.dupe(u8, n) else null };
    errdefer if (p.note) |n| gpa.free(n);
    _ = try editor.openFilePath(path, editor.workbench.currentGroupingID());
    // Last, once nothing above can fail: the list owns it from here.
    try self.playing.append(gpa, p);
    self.next += 1;
    dvui.refresh(null, @src(), null);
}

/// Once a frame, before anything draws: each tape's steps whose moment has come. Returns at once
/// with nothing playing.
pub fn tick(self: *TapeTabs, editor: *Editor) void {
    if (self.waiting != null) self.wait(editor);
    if (self.playing.items.len == 0) return;
    const now = dvui.frameTimeNS();
    var i: usize = 0;
    while (i < self.playing.items.len) {
        const p = self.playing.items[i];
        const doc = editor.docFromPath(p.path);
        if (doc == null) {
            // Closed after it opened, or never came: the playback is over. Still loading: wait.
            if (p.doc_id != null or now - p.opened_ns > load_limit_ns) {
                free(editor, p);
                _ = self.playing.swapRemove(i);
                continue;
            }
            i += 1;
            continue;
        }
        if (p.doc_id == null) {
            p.doc_id = doc.?.id;
            p.start_ns = now;
        }
        // Its panes come with its first draw.
        if (p.note) |n| if (editor.noteOnDocument(doc.?.id, n)) {
            editor.app.gpa.free(n);
            p.note = null;
        };
        advance(editor, p, doc.?, now);
        i += 1;
    }
}

/// Apply `p`'s steps due by `now`, and wake for the next. Played out, the document is written to
/// its own mount: it is as the tape left it, so closing it asks nothing (an edit of the person's
/// after that would).
fn advance(editor: *Editor, p: *Playback, doc: sdk.DocHandle, now: i128) void {
    const ops = p.owned.tape.ops;
    if (p.op == ops.len) return;
    // Gone back along what has played: held there, as a recorder's playhead stops where it is put,
    // until the person comes back to the end, and it plays on from there. A step landing now would
    // take the place of all they went back over.
    if (doc.owner.historyLine(doc, dvui.currentWindow().arena())) |line| {
        if (p.paused or line.at < line.entries.len) {
            if (p.held_ns == null) p.held_ns = now;
            return;
        }
    }
    if (p.held_ns) |since| {
        p.start_ns += now - since;
        p.held_ns = null;
    }
    const elapsed_ms: u64 = @intCast(@max(0, @divTrunc(now - p.start_ns, std.time.ns_per_ms)));
    while (p.op < ops.len and ops[p.op].at <= elapsed_ms) : (p.op += 1) {
        const op = ops[p.op];
        switch (op.do) {
            .step => |st| if (!doc.owner.applyStep(doc, st.effect, st.motion, op.ms)) {
                // The document is not what the step was made on (the person edited it): the rest
                // would miss too, so the playback stops here, its document theirs.
                p.op = ops.len;
                _ = editor.noteOnDocument(doc.id, "Tape stopped: the document changed");
                return;
            },
            else => {},
        }
    }
    if (p.op == ops.len) {
        editor.writeDocument(doc) catch |err| dvui.log.warn("tape: could not keep {s} as played: {t}", .{ p.path, err });
        return;
    }
    const wait_ms: u64 = ops[p.op].at - elapsed_ms;
    dvui.timer(dvui.Id.extendId(null, @src(), @intFromPtr(p)), @intCast(@min(wait_ms * 1000 + 1, std.math.maxInt(i32))));
}

fn openUnder(editor: *Editor, root: []const u8) bool {
    for (editor.app.open_files.values()) |d| {
        const path = d.owner.documentPath(d);
        if (std.mem.startsWith(u8, path, root) and path.len > root.len and path[root.len] == '/') return true;
    }
    return false;
}

/// Whether the document at `path` is a tape still to play out in its tab (loading, or steps to go).
pub fn isPlaying(self: *const TapeTabs, path: []const u8) bool {
    for (self.playing.items) |p| if (std.mem.eql(u8, p.path, path) and p.op < p.owned.tape.ops.len) return true;
    return false;
}

/// Whether the tape in the document at `path` is landing its steps now: neither played out, nor
/// held (gone back along, or paused). Its transport's play button pauses it.
pub fn landing(self: *const TapeTabs, path: []const u8) bool {
    for (self.playing.items) |p| if (std.mem.eql(u8, p.path, path)) return p.op < p.owned.tape.ops.len and !p.paused and p.held_ns == null;
    return false;
}

/// Pause the tape in the document at `path`, or play it on (`paused` false) from where it stands.
pub fn setPaused(self: *TapeTabs, path: []const u8, paused: bool) void {
    for (self.playing.items) |p| if (std.mem.eql(u8, p.path, path)) {
        p.paused = paused;
        dvui.refresh(null, @src(), null);
    };
}

/// How far the tape in the document at `path` has played, 0 to 1, by its ops applied: its
/// transport's grip fills as it plays (`HistoryTransport.DrawOptions.progress`). Null when the
/// document is no tape's.
pub fn progress(self: *const TapeTabs, path: []const u8) ?f32 {
    for (self.playing.items) |p| if (std.mem.eql(u8, p.path, path)) {
        const n = p.owned.tape.ops.len;
        return if (n == 0) 1 else @as(f32, @floatFromInt(p.op)) / @as(f32, @floatFromInt(n));
    };
    return null;
}

fn free(editor: *Editor, p: *Playback) void {
    const gpa = editor.app.gpa;
    editor.app.host.unmount(p.root);
    p.mem.deinit();
    gpa.destroy(p.mem);
    gpa.free(p.root);
    gpa.free(p.path);
    if (p.note) |n| gpa.free(n);
    p.owned.deinit();
    gpa.destroy(p);
}
