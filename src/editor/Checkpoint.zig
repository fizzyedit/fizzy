//! Unsaved work that survives a crash (plans/RESTART_AND_CRASHES_PLAN.md, step 4). While a
//! document has unsaved changes, every open document is written as a restart writes them
//! (`KeptDocuments`) to `<config>/checkpoint/`, every few seconds after the person has done
//! something and at least every half minute regardless (an agent's edits come with no input). A
//! clean quit empties it, so one found at launch means the last run ended without one: a crash, a
//! kill, a power cut. Its documents then open from it, unsaved changes and all, the way a restart's
//! session opens (`Editor.session`).
//!
//! The state is captured on the UI thread, since only the owners can capture it, and written on a
//! thread of its own, so a large document never costs a frame its write. Each checkpoint is a new
//! generation of files in the same folder (`KeptDocuments.saveGeneration`), counted from when
//! `session.zon` is renamed over the last: a crash mid-write leaves the last whole one. The folder
//! is never swapped: the settings watcher watches the config folder, and a folder that appears
//! and is renamed away before it is watched made it log an error on Linux (inotify's NOENT).
const Checkpoint = @This();

const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const Editor = @import("Editor.zig");
const KeptDocuments = @import("KeptDocuments.zig");

/// The soonest a checkpoint follows the last one, after input.
const after_input_ns: i96 = 3 * std.time.ns_per_s;
/// The longest unsaved work goes without one.
const at_most_ns: i96 = 30 * std.time.ns_per_s;
/// How often the documents are looked at for unsaved changes: a dirty flag each, no capture.
const look_ns: i96 = std.time.ns_per_s;

pub const supported = builtin.target.cpu.arch != .wasm32;

/// When the last checkpoint was taken.
last_ns: i96 = 0,
/// When the documents were last looked at.
looked_ns: i96 = 0,
/// Whether they had unsaved changes then.
unsaved: bool = false,
/// Input arrived since the last checkpoint.
touched: bool = false,
/// A checkpoint is on disk from this run.
written: bool = false,
/// The write in flight, if any.
job: ?*Job = null,
/// Said once that a document's unsaved changes cannot be kept, not every few seconds.
warned: bool = false,
/// The last checkpoint's generation in this run (`KeptDocuments.saveGeneration`).
generation: u32 = 0,

const Job = struct {
    kept: KeptDocuments,
    dir: []u8,
    generation: u32,
    thread: std.Thread = undefined,
    done: std.atomic.Value(bool) = .init(false),
    ok: bool = false,
};

/// `<config>/checkpoint`, owned by `gpa`.
pub fn dir(gpa: std.mem.Allocator, config_folder: []const u8) ![]u8 {
    return std.fs.path.join(gpa, &.{ config_folder, "checkpoint" });
}

/// At launch: the documents a run that did not end cleanly left, read once (the folder is
/// deleted). Null when the last run quit cleanly, or `skip` (a restart's session, which is newer,
/// was found) — the checkpoint is deleted either way.
pub fn recover(gpa: std.mem.Allocator, config_folder: []const u8, skip: bool) ?KeptDocuments {
    if (comptime !supported) return null;
    const path = dir(gpa, config_folder) catch return null;
    defer gpa.free(path);
    const next = std.fmt.allocPrint(gpa, "{s}.new", .{path}) catch return null;
    defer gpa.free(next);
    const cwd = std.Io.Dir.cwd();
    if (skip) {
        cwd.deleteTree(dvui.io, path) catch {};
        cwd.deleteTree(dvui.io, next) catch {};
        return null;
    }
    // An older build wrote the next checkpoint here before swapping it in.
    cwd.deleteTree(dvui.io, next) catch {};
    // Without its `session.zon`, the first checkpoint was cut off mid-write: of no use to anyone.
    if (!complete(path)) {
        cwd.deleteTree(dvui.io, path) catch {};
        return null;
    }
    var kept = KeptDocuments.loadSession(gpa, path) orelse return null;
    if (kept.docs.items.len == 0) {
        kept.deinit();
        return null;
    }
    return kept;
}

fn complete(path: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const zon = std.fmt.bufPrint(&buf, "{s}/session.zon", .{path}) catch return false;
    std.Io.Dir.cwd().access(dvui.io, zon, .{}) catch return false;
    return true;
}

/// Once a frame.
pub fn tick(self: *Checkpoint, editor: *Editor) void {
    if (comptime !supported) return;
    if (dvui.events().len > 0) self.touched = true;
    if (self.job) |job| if (job.done.load(.acquire)) {
        job.thread.join();
        if (job.ok) self.written = true;
        self.freeJob(editor, job);
    };
    const now = std.Io.Clock.awake.now(dvui.io).nanoseconds;
    // Looked up every frame, which keeps a pending timer alive (dvui drops one nobody asks after).
    const timer_id = dvui.currentWindow().data().id.update("checkpoint");
    const timer_free = dvui.timerDoneOrNone(timer_id);

    if (now - self.looked_ns >= look_ns) {
        self.looked_ns = now;
        self.unsaved = for (editor.app.open_files.values()) |doc| {
            if (doc.owner.isDirty(doc)) break true;
        } else false;
        if (!self.unsaved) {
            // Everything saved (or closed): nothing to recover, so no checkpoint to recover it from.
            if (self.written and self.job == null) self.remove(editor);
            self.touched = false;
        } else if (self.job == null and self.due(now)) {
            self.last_ns = now;
            self.touched = false;
            self.start(editor) catch |err| {
                if (!self.warned) dvui.log.warn("checkpoint: unsaved work is not kept against a crash ({t})", .{err});
                self.warned = true;
            };
        }
    }

    // fizzy draws a frame only when something happens: one is asked for when the next look is due,
    // or input that came just after a look would wait for the next unrelated event to be kept.
    if (timer_free) if (self.nextLook()) |at| {
        const micros = @divFloor(@max(at - now, std.time.ns_per_ms), std.time.ns_per_us);
        dvui.timer(timer_id, @intCast(@min(micros, std.math.maxInt(i32))));
    };
}

/// Whether unsaved work should be written now: not within a few seconds of the last checkpoint,
/// and then after input, when there is none yet, or when the last is half a minute old.
fn due(self: *const Checkpoint, now: i96) bool {
    const since = now - self.last_ns;
    if (since < after_input_ns) return false;
    return self.touched or !self.written or since >= at_most_ns;
}

/// When the documents should next be looked at, or null when nothing could need keeping.
fn nextLook(self: *const Checkpoint) ?i96 {
    if (self.touched or self.job != null or (self.unsaved and !self.written)) return self.looked_ns + look_ns;
    if (self.unsaved) return self.last_ns + at_most_ns;
    return null;
}

fn start(self: *Checkpoint, editor: *Editor) !void {
    const gpa = editor.app.gpa;
    // A document whose owner cannot capture its unsaved changes (no state hook) fails the
    // capture, as it stops a restart from keeping documents: then there is no checkpoint.
    var kept = try KeptDocuments.capture(editor, null);
    errdefer kept.deinit();
    const path = try dir(gpa, editor.app.config_folder);
    errdefer gpa.free(path);
    const job = try gpa.create(Job);
    errdefer gpa.destroy(job);
    self.generation += 1;
    job.* = .{ .kept = kept, .dir = path, .generation = self.generation };
    job.thread = try std.Thread.spawn(.{}, write, .{job});
    self.job = job;
}

/// The worker: the next generation, written in place.
fn write(job: *Job) void {
    defer job.done.store(true, .release);
    job.kept.saveGeneration(job.dir, job.generation) catch return;
    job.ok = true;
}

fn freeJob(self: *Checkpoint, editor: *Editor, job: *Job) void {
    job.kept.deinit();
    editor.app.gpa.free(job.dir);
    editor.app.gpa.destroy(job);
    self.job = null;
}

/// Empty the checkpoint: its files go, and the folder stays, for the same reason it is never
/// swapped (a folder that vanishes under the settings watcher as it is noticed). Empty, it is
/// nothing to recover; the next launch deletes it before any watcher starts (`recover`).
fn remove(self: *Checkpoint, editor: *Editor) void {
    const path = dir(editor.app.gpa, editor.app.config_folder) catch return;
    defer editor.app.gpa.free(path);
    self.written = false;
    var d = std.Io.Dir.cwd().openDir(dvui.io, path, .{ .iterate = true }) catch return;
    defer d.close(dvui.io);
    // `session.zon` first: without it, what is left is not a checkpoint.
    d.deleteFile(dvui.io, "session.zon") catch {};
    var it = d.iterate();
    while (it.next(dvui.io) catch null) |entry| {
        if (entry.kind == .file) d.deleteFile(dvui.io, entry.name) catch {};
    }
}

/// A clean quit: wait for a write in flight, then empty the checkpoint, so the next launch
/// recovers nothing. Whatever the quit decided about unsaved documents (saved, discarded, kept
/// for a restart) stands.
pub fn deinit(self: *Checkpoint, editor: *Editor) void {
    if (comptime !supported) return;
    if (self.job) |job| {
        job.thread.join();
        self.freeJob(editor, job);
    }
    self.remove(editor);
}
