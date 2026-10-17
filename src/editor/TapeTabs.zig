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
const TapeTabs = @This();

const std = @import("std");
const dvui = @import("dvui");
const fizzy = @import("../fizzy.zig");
const core = fizzy.core;
const sdk = fizzy.sdk;
const automation = @import("app").automation;
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

/// Open the tape in `bytes` in a tab of its own and play it, saying `note` on that tab once it
/// shows. The bytes may be let go of at once.
pub fn open(self: *TapeTabs, editor: *Editor, bytes: []const u8, note: ?[]const u8) (OpenError || anyerror)!void {
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
    p.* = .{ .owned = owned, .mem = mem, .root = root, .path = path, .opened_ns = dvui.frameTimeNS(), .note = if (note) |n| try gpa.dupe(u8, n) else null };
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
