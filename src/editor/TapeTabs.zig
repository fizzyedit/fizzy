//! Tapes played in a tab of their own: a document's track shared as a tape (`fizzy.tracks.export`)
//! opens beside the person's documents, never over them, and plays itself in.
//!
//! The tape's file (its keyframe's one document, as it was when the track began) is mounted
//! under a root of its own (`tape://<n>`) and opened like any file; then each step is applied as
//! its moment comes, by the document's owner (`Plugin.applyStep`, at pace). Each step lands as an
//! entry on the document's history, so the document's transport plays back over what has played:
//! scrub back through it, step through it, as through any document's history.
//!
//! Unlike the demo stage, nothing of the person's is set aside or waits on their unsaved work: the
//! tape is a document among theirs. Closing it ends the playback and the mount. While nothing is
//! playing a frame costs one check of an empty list; while one is, a timer wakes it for the next
//! step and nothing more.
//!
//! **Trimming.** A tape opened to be shared (`OpenOptions.trim`, the transport's share) plays in
//! at once and stays in its tab for the person to trim, as macOS trims a recording: the pane's bar
//! is a `TrimBar`, the document showing wherever its handles are dragged, and play previews the
//! part kept. Share writes that part as a tape of its own (`trimmed`): the document's file where
//! the part begins, the steps from there, timed from its first. Nothing is written until then;
//! cancel closes the tab.
const TapeTabs = @This();

const std = @import("std");
const dvui = @import("dvui");
const fizzy = @import("../fizzy.zig");
const core = fizzy.core;
const sdk = fizzy.sdk;
const app = @import("app");
const automation = app.automation;
const Editor = @import("Editor.zig");

playing: std.ArrayListUnmanaged(*Playback) = .empty,
/// The next playback's number, for its root.
next: u32 = 1,

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
    /// When the document opened: the tape's time 0.
    start_ns: i128 = 0,
    /// When the tape was opened: a document that has not come by `load_limit_ns` after never
    /// will (its load failed), and the playback lets its mount go.
    opened_ns: i128,
    /// Said on the tape's own tab once it shows (`Editor.noteOnDocument`); owned.
    note: ?[]u8 = null,
    /// Being trimmed before it is shared; null for a tape that only plays.
    trim: ?*Trimming = null,
};

/// A tape in its tab, being trimmed (`TrimBar`).
pub const Trimming = struct {
    span: app.history_transport.Trim = .all(0),
    bar: app.TrimBar = .{},
    /// Each step's time and length in the tape, ms, in order.
    at: []u32,
    ms: []u32,
    /// Who made each step, as an index into `names`; empty when not known.
    by: []u8,
    names: [][]u8,
    /// The preview playing the part kept: when its first step played, as frame time.
    playing_since: ?i128 = null,
    /// Pressed on the bar, done at the next frame's top: sharing walks the document's history.
    action: enum { none, share, cancel } = .none,

    fn deinit(self: *Trimming, gpa: std.mem.Allocator) void {
        gpa.free(self.at);
        gpa.free(self.ms);
        gpa.free(self.by);
        for (self.names) |n| gpa.free(n);
        gpa.free(self.names);
    }
};

/// Who made a shared track's steps, for the trim's summary: an author name per step, by index.
pub const Authors = struct {
    by: []const u8,
    names: []const []const u8,
};

pub const OpenOptions = struct {
    /// Said on the tape's tab once it shows.
    note: ?[]const u8 = null,
    /// Open it to be trimmed and shared (the transport's share): played in at once, then trimmed.
    trim: ?Authors = null,
};

const load_limit_ns: i128 = 30 * std.time.ns_per_s;

pub fn deinit(self: *TapeTabs, editor: *Editor) void {
    for (self.playing.items) |p| free(editor, p);
    self.playing.deinit(editor.app.gpa);
}

pub const OpenError = error{
    /// Not a tape fizzy reads, or steps of an owner not loaded or of another format.
    BadTape,
    /// A tape of anything but one document's steps (a demo, a session of several): the demo stage
    /// plays those (`fizzy.demo.playTape`).
    NotOneDocument,
    OutOfMemory,
};

/// Open the tape in `bytes` in a tab of its own and play it, or play it in at once and trim it
/// (`opts.trim`). The bytes may be let go of at once.
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
        const r = try std.fmt.allocPrint(gpa, "tape://{d}", .{self.next});
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
    const at = try std.fmt.allocPrint(gpa, "/{s}", .{file.path});
    defer gpa.free(at);
    try mem.put(at, file.text);
    try editor.app.host.mount(root, mem.fs());
    errdefer editor.app.host.unmount(root);

    const p = try gpa.create(Playback);
    errdefer gpa.destroy(p);
    p.* = .{ .owned = owned, .mem = mem, .root = root, .path = path, .opened_ns = dvui.frameTimeNS(), .note = if (opts.note) |n| try gpa.dupe(u8, n) else null };
    errdefer if (p.note) |n| gpa.free(n);
    if (opts.trim) |authors| p.trim = try trimming(gpa, tape, authors);
    errdefer if (p.trim) |t| {
        t.deinit(gpa);
        gpa.destroy(t);
    };
    _ = try editor.openFilePath(path, editor.workbench.currentGroupingID());
    // Last, once nothing above can fail: the list owns it from here.
    try self.playing.append(gpa, p);
    self.next += 1;
    dvui.refresh(null, @src(), null);
}

/// Once a frame, before anything draws: each tape's steps whose moment has come. Returns at once
/// with nothing playing.
pub fn tick(self: *TapeTabs, editor: *Editor) void {
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
        if (p.trim) |t| switch (t.action) {
            .none => preview(t, doc.?, now),
            .cancel => {
                // Nothing of it was written: the tab goes, and the playback with it next frame.
                editor.rawCloseFileID(doc.?.id) catch {};
                t.action = .none;
            },
            .share => {
                t.action = .none;
                share(editor, p, t, doc.?);
            },
        };
        advance(editor, p, doc.?, now);
        i += 1;
    }
}

/// Write the part kept as a tape in the config folder's `tapes/`, and end the trim: the tab is the
/// tape's from here, its transport back.
fn share(editor: *Editor, p: *Playback, t: *Trimming, doc: sdk.DocHandle) void {
    const gpa = editor.app.gpa;
    const bytes = trimmed(editor, p, t, doc, gpa) catch |err| {
        dvui.log.warn("share: could not trim {s}: {t}", .{ p.path, err });
        _ = editor.noteOnDocument(doc.id, "Could not share");
        return;
    };
    defer gpa.free(bytes);
    const arena = dvui.currentWindow().arena();
    if (comptime @import("builtin").target.cpu.arch != .wasm32) {
        const saved = editor.keepTape(arena, doc, bytes, "") catch |err| {
            dvui.log.warn("share: could not keep the tape: {t}", .{err});
            _ = editor.noteOnDocument(doc.id, "Could not save the tape");
            return;
        };
        _ = editor.noteOnDocument(doc.id, std.fmt.allocPrint(arena, "Saved {s}", .{std.fs.path.basename(saved)}) catch "Saved the tape");
    }
    t.deinit(gpa);
    gpa.destroy(t);
    p.trim = null;
    // The handles moved the document about; as it stands now is the tab's, so closing it asks
    // nothing.
    editor.writeDocument(doc) catch |err| dvui.log.warn("tape: could not keep {s}: {t}", .{ p.path, err });
}

/// Apply `p`'s steps due by `now`, and wake for the next. Played out, the document is written to
/// its own mount: it is as the tape left it, so closing it asks nothing (an edit of the person's
/// after that would).
fn advance(editor: *Editor, p: *Playback, doc: sdk.DocHandle, now: i128) void {
    const ops = p.owned.tape.ops;
    if (p.op == ops.len) return;
    // To be trimmed, it plays in at once: the whole of it is there to trim.
    const elapsed_ms: u64 = if (p.trim != null) std.math.maxInt(u64) else @intCast(@max(0, @divTrunc(now - p.start_ns, std.time.ns_per_ms)));
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

fn trimming(gpa: std.mem.Allocator, tape: automation.Tape, authors: Authors) !*Trimming {
    var n: usize = 0;
    for (tape.ops) |op| n += @intFromBool(op.do == .step);
    const t = try gpa.create(Trimming);
    errdefer gpa.destroy(t);
    const at = try gpa.alloc(u32, n);
    errdefer gpa.free(at);
    const ms = try gpa.alloc(u32, n);
    errdefer gpa.free(ms);
    var i: usize = 0;
    for (tape.ops) |op| if (op.do == .step) {
        at[i] = op.at;
        ms[i] = op.ms;
        i += 1;
    };
    const by = try gpa.dupe(u8, if (authors.by.len == n) authors.by else &.{});
    errdefer gpa.free(by);
    const names = try gpa.alloc([]u8, authors.names.len);
    var made: usize = 0;
    errdefer {
        for (names[0..made]) |nm| gpa.free(nm);
        gpa.free(names);
    }
    for (authors.names, names) |a, *nm| {
        nm.* = try gpa.dupe(u8, a);
        made += 1;
    }
    t.* = .{ .span = .all(n), .at = at, .ms = ms, .by = by, .names = names };
    return t;
}

/// The tape at `path` being trimmed, and the summary its bar shows: how many steps the part kept
/// holds, how long it plays, whose they are. Null for a tape that only plays, or one still
/// playing in.
pub fn trimOf(self: *const TapeTabs, doc_id: u64, arena: std.mem.Allocator) ?struct { *Trimming, []const u8 } {
    for (self.playing.items) |p| {
        if (p.doc_id != doc_id) continue;
        const t = p.trim orelse return null;
        if (p.op < p.owned.tape.ops.len) return null;
        return .{ t, summary(arena, t) };
    }
    return null;
}

fn summary(arena: std.mem.Allocator, t: *const Trimming) []const u8 {
    const from = t.span.from;
    const to = t.span.to;
    if (to <= from) return "";
    const ms: u64 = t.at[to - 1] + t.ms[to - 1] - t.at[from];
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    w.print("{d} step{s}, ", .{ to - from, if (to - from == 1) "" else "s" }) catch {};
    const secs = (ms + 500) / 1000;
    if (secs < 60) w.print("{d} s", .{secs}) catch {} else w.print("{d} min {d} s", .{ secs / 60, secs % 60 }) catch {};
    if (t.by.len == t.at.len and t.names.len > 0) {
        // Whose, each once, in the order they first come.
        var seen: [8]u8 = undefined;
        var count: usize = 0;
        for (t.by[from..to]) |b| {
            if (std.mem.indexOfScalar(u8, seen[0..count], b) != null) continue;
            if (count == seen.len) break;
            seen[count] = b;
            count += 1;
        }
        w.writeAll(", by ") catch {};
        for (seen[0..count], 0..) |b, i| {
            if (i > 0) w.writeAll(if (i == count - 1) " and " else ", ") catch {};
            w.writeAll(t.names[b]) catch {};
        }
    }
    return out.written();
}

/// The bar on a trimmed tape's pane, drawn by the pane in place of its transport; what was
/// pressed is done at the next frame's top (`tick`).
pub fn drawTrim(doc: sdk.DocHandle, t: *Trimming, text: []const u8, area: dvui.Rect.Physical, id_extra: usize) void {
    const pressed = t.bar.draw(doc, area, id_extra, &t.span, text, t.playing_since != null);
    if (pressed.grabbed) t.playing_since = null;
    if (pressed.play) {
        if (t.playing_since != null) t.playing_since = null else play(doc, t);
        dvui.refresh(null, @src(), null);
    }
    if (pressed.cancel) t.action = .cancel;
    if (pressed.share) t.action = .share;
    if (t.action != .none) dvui.refresh(null, @src(), null);
}

/// Start the preview from the playhead, or from the part's start when the playhead is outside it
/// or at its end.
fn play(doc: sdk.DocHandle, t: *Trimming) void {
    const line = doc.owner.historyLine(doc, dvui.currentWindow().arena()) orelse return;
    var head = line.at;
    if (head < t.span.from or head >= t.span.to) {
        head = t.span.from;
        _ = doc.owner.historyGoTo(doc, if (head == 0) 0 else line.entries[head - 1].id);
    }
    const into: i128 = t.at[head] -| t.at[t.span.from];
    t.playing_since = dvui.frameTimeNS() - into * std.time.ns_per_ms;
}

/// The preview's next frame: the document goes to the last step of the part whose moment has
/// come, and a timer wakes it for the one after. Ends at the part's end.
fn preview(t: *Trimming, doc: sdk.DocHandle, now: i128) void {
    const since = t.playing_since orelse return;
    const elapsed: i128 = @divTrunc(now - since, std.time.ns_per_ms);
    const first = t.at[t.span.from];
    var stop = t.span.from;
    while (stop < t.span.to and @as(i128, t.at[stop] - first) <= elapsed) stop += 1;
    const line = doc.owner.historyLine(doc, dvui.currentWindow().arena()) orelse return;
    if (line.entries.len != t.span.n) {
        t.playing_since = null;
        return;
    }
    if (stop != line.at) _ = doc.owner.historyGoTo(doc, if (stop == 0) 0 else line.entries[stop - 1].id);
    if (stop >= t.span.to) {
        t.playing_since = null;
        return;
    }
    const wait_ms: i128 = @as(i128, t.at[stop] - first) - elapsed;
    dvui.timer(dvui.Id.extendId(null, @src(), @intFromPtr(t)), @intCast(@min(@max(wait_ms, 0) * 1000 + 1, std.math.maxInt(i32))));
}

pub const TrimError = error{ NotTheTape, NoBytes, NotReturned, OutOfMemory };

/// The part of `p`'s tape that `t` keeps, as a tape of its own (binary, deflated, owned by `gpa`):
/// its keyframe the document's file where the part begins, written by its owner with the document
/// taken back there and brought forward again in the same call, unheard by its track and the
/// activity feed; then the part's steps, timed from its first.
fn trimmed(editor: *Editor, p: *Playback, t: *const Trimming, doc: sdk.DocHandle, gpa: std.mem.Allocator) TrimError![]u8 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tape = p.owned.tape;
    const file = tape.keyframes[0].files[0];
    const line = doc.owner.historyLine(doc, arena) orelse return error.NotTheTape;
    if (line.entries.len != t.span.n) return error.NotTheTape;
    const stopId = struct {
        fn of(l: sdk.Plugin.HistoryLine, i: usize) u64 {
            return if (i == 0) 0 else l.entries[i - 1].id;
        }
    }.of;

    const bytes = bytes: {
        const host = &editor.app.host;
        const tracks = if (editor.app.tracks) |*tr| tr else null;
        const was_track_muted = if (tracks) |tr| tr.muted else 0;
        if (tracks) |tr| tr.muted = doc.id;
        defer if (tracks) |tr| {
            tr.muted = was_track_muted;
        };
        const was_muted = host.activity_muted;
        host.activity_muted = true;
        defer host.activity_muted = was_muted;
        const now = line.at;
        const moved = now != t.span.from;
        if (moved and !doc.owner.historyGoTo(doc, stopId(line, t.span.from))) return error.NotTheTape;
        const written = doc.owner.documentBytes(doc, file.path, arena) catch null;
        if (moved and !doc.owner.historyGoTo(doc, stopId(line, now))) return error.NotReturned;
        break :bytes written orelse return error.NoBytes;
    };

    const files = try arena.dupe(automation.Tape.File, tape.keyframes[0].files);
    files[0].text = bytes;
    const keyframes = try arena.dupe(automation.Tape.Keyframe, tape.keyframes);
    keyframes[0].files = files;
    const ops = try arena.alloc(automation.Tape.Op, t.span.to - t.span.from + 2);
    ops[0] = .{ .at = 0, .do = .{ .keyframe = 0 } };
    ops[1] = .{ .at = 0, .do = .{ .wait = .{ .until = .idle } } };
    var i: usize = 0;
    var out: usize = 2;
    const first = t.at[t.span.from];
    for (tape.ops) |op| if (op.do == .step) {
        if (i >= t.span.from and i < t.span.to) {
            ops[out] = op;
            ops[out].at = op.at - first;
            out += 1;
        }
        i += 1;
    };
    return automation.binary.encode(gpa, .{ .name = tape.name, .title = tape.title, .ops = ops, .keyframes = keyframes }, .{ .deflate = true }) catch error.OutOfMemory;
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

fn free(editor: *Editor, p: *Playback) void {
    const gpa = editor.app.gpa;
    editor.app.host.unmount(p.root);
    p.mem.deinit();
    gpa.destroy(p.mem);
    gpa.free(p.root);
    gpa.free(p.path);
    if (p.note) |n| gpa.free(n);
    if (p.trim) |t| {
        t.deinit(gpa);
        gpa.destroy(t);
    }
    p.owned.deinit();
    gpa.destroy(p);
}
