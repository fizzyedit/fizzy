//! The host reads and writes documents, wherever they live: an owner serializes
//! (`documentBytes`) and hears back (`documentWritten`); the file table's filesystem for the
//! path — the disk, a zip, a drive — does the I/O. One save path for every backend, so an
//! owner never knows what a `gdrive://` path is, and a `.pixi` on a drive saves the way it
//! does on the disk.
//!
//! `owner.saveDocument` (the owner writes the file itself) remains the fallback for an owner
//! that has not adopted the hooks; it can only ever reach the disk. Disk *opens* still go
//! through `FileLoadJob` — a worker thread for large files — which is a performance path, not
//! a second policy: the bytes end up in `loadDocumentFromBytes` either way.
//!
//! Completions arrive through the filesystem's `pump`: the disk's inline (so a local save is
//! done when the call returns, as it always was), a mount's on the host's per-frame pump.
const std = @import("std");
const dvui = @import("dvui");
const sdk = @import("fizzy_sdk");
const core = @import("core");
const fizzy = @import("../fizzy.zig");

const Editor = fizzy.Editor;
const DocumentIo = @This();

editor: *Editor,
/// Opens in flight, keyed by canonical path (owned by the job). A second open of the same
/// path focuses the first when it lands instead of reading twice.
loads: std.StringArrayHashMapUnmanaged(*Load) = .empty,
/// Saves in flight, keyed by document id. A document with a save pending is not closed by the
/// quit flow until it lands — the bytes are the only copy.
saves: std.AutoArrayHashMapUnmanaged(u64, *Save) = .empty,
/// When each open document's file was last modified as of the read that opened it (or the
/// write that last saved it) — the precondition every save carries, so an edit made elsewhere
/// in between is a `Conflict` rather than a silent overwrite. Absent (0) means unconditional.
known_mtime: std.AutoArrayHashMapUnmanaged(u64, i64) = .empty,
/// Documents whose next save overwrites regardless: the user was told of the conflict and
/// chose to save again.
force_next: std.AutoArrayHashMapUnmanaged(u64, void) = .empty,

pub fn init(editor: *Editor) DocumentIo {
    return .{ .editor = editor };
}

pub fn deinit(self: *DocumentIo) void {
    const files = &self.editor.app.file_table;
    for (self.loads.values()) |load| {
        files.resolve(load.path).fs.cancel(load.job);
        load.destroy();
    }
    self.loads.deinit(self.editor.app.gpa);
    for (self.saves.values()) |pending| {
        files.resolve(pending.path).fs.cancel(pending.job);
        pending.destroy();
    }
    self.saves.deinit(self.editor.app.gpa);
    self.known_mtime.deinit(self.editor.app.gpa);
    self.force_next.deinit(self.editor.app.gpa);
}

/// A document is gone; forget what was known about its file.
pub fn documentClosed(self: *DocumentIo, doc_id: u64) void {
    _ = self.known_mtime.swapRemove(doc_id);
    _ = self.force_next.swapRemove(doc_id);
}

/// Whether `path` is one this file handles. Everything else is the disk's.
pub fn owns(self: *DocumentIo, path: []const u8) bool {
    return self.editor.app.file_table.isMounted(path);
}

pub fn saving(self: *const DocumentIo, doc_id: u64) bool {
    return self.saves.contains(doc_id);
}

/// `prefix` is going away (`FileTable.Env.unmounting`): drop every open and save against it.
/// A load just never lands; a save leaves its document dirty, which is the truth.
pub fn unmounting(self: *DocumentIo, prefix: []const u8) void {
    const files = &self.editor.app.file_table;
    var i: usize = 0;
    while (i < self.loads.count()) {
        const load = self.loads.values()[i];
        if (!onPrefix(load.path, prefix)) {
            i += 1;
            continue;
        }
        files.resolve(load.path).fs.cancel(load.job);
        self.loads.swapRemoveAt(i);
        load.destroy();
    }
    i = 0;
    while (i < self.saves.count()) {
        const pending = self.saves.values()[i];
        if (!onPrefix(pending.path, prefix)) {
            i += 1;
            continue;
        }
        files.resolve(pending.path).fs.cancel(pending.job);
        self.saves.swapRemoveAt(i);
        pending.destroy();
    }
}

fn onPrefix(path: []const u8, prefix: []const u8) bool {
    return std.mem.startsWith(u8, path, prefix) and (path.len == prefix.len or path[prefix.len] == '/');
}

// ---- open ----------------------------------------------------------------------------------

/// Read `path` through its mount and open it from the bytes. `path` is canonical already.
/// Returns whether a read was started — false when one is already in flight for this path,
/// which then becomes the one to focus.
pub fn open(self: *DocumentIo, path: []const u8, grouping: u64) !bool {
    const editor = self.editor;
    if (self.loads.get(path)) |existing| {
        existing.focus = true;
        return false;
    }
    // Resolve the owner up front, as the disk path does: a file nothing claims is refused
    // here rather than after a round trip.
    if (editor.app.host.pluginForExtension(std.fs.path.extension(path)) == null) {
        dvui.log.warn("No plugin handles file: {s}", .{path});
        return false;
    }
    const load = try Load.create(self, path, grouping);
    errdefer load.destroy();
    try self.loads.put(editor.app.gpa, load.path, load);
    errdefer _ = self.loads.swapRemove(load.path);

    const target = editor.app.file_table.resolve(path);
    load.job = try target.fs.readFile(editor.app.gpa, target.rel, Load.onRead, load);
    // Delivered from the host's per-frame pump, never inside this call: an open can be asked
    // for mid-draw, and its completion registers a document.
    return true;
}

const Load = struct {
    io: *DocumentIo,
    path: []u8,
    grouping: u64,
    job: core.vfs.Job = .{ .id = 0 },
    focus: bool = true,

    fn create(io: *DocumentIo, path: []const u8, grouping: u64) !*Load {
        const gpa = io.editor.app.gpa;
        const load = try gpa.create(Load);
        errdefer gpa.destroy(load);
        load.* = .{ .io = io, .path = try gpa.dupe(u8, path), .grouping = grouping };
        return load;
    }

    fn destroy(load: *Load) void {
        const gpa = load.io.editor.app.gpa;
        gpa.free(load.path);
        gpa.destroy(load);
    }

    fn onRead(ctx: ?*anyopaque, result: core.vfs.Error!core.vfs.Read) void {
        const load: *Load = @ptrCast(@alignCast(ctx.?));
        const io = load.io;
        const editor = io.editor;
        const gpa = editor.app.gpa;
        defer load.destroy();
        _ = io.loads.swapRemove(load.path);

        const read = result catch |err| {
            dvui.log.err("Failed to open {s}: {t}", .{ load.path, err });
            dvui.toast(@src(), .{ .message = std.fmt.allocPrint(
                editor.app.arena.allocator(),
                "Could not open {s}.",
                .{std.fs.path.basename(load.path)},
            ) catch "Could not open file." });
            return;
        };
        const bytes = read.bytes;
        defer gpa.free(bytes);

        // `openFileFromBytes` takes the path; it wants its own copy to own.
        const path_for_open = gpa.dupe(u8, load.path) catch return;
        const id = editor.openFileFromBytes(path_for_open, bytes, load.grouping) catch |err| {
            if (err != error.AlreadyOpen) dvui.log.err("Failed to open {s}: {t}", .{ load.path, err });
            return;
        };
        if (read.modified_ms != 0) io.known_mtime.put(gpa, id, read.modified_ms) catch {};
        if (load.focus) {
            if (editor.app.open_files.getIndex(id)) |idx| editor.workbench.setActiveDocIndex(idx);
            editor.pending_composite_warmup = true;
        }
        editor.app.host.refresh();
    }
};

// ---- save ----------------------------------------------------------------------------------

/// Serialize `doc` and write it through the mount at `path` — the document's own path, or a
/// new one for Save As, which the owner adopts when the write lands. The owner is told only
/// on success; a failed write leaves it dirty, which is the truth.
pub fn save(self: *DocumentIo, doc: sdk.DocHandle, path: []const u8) !void {
    const editor = self.editor;
    const gpa = editor.app.gpa;
    if (self.saves.contains(doc.id)) return error.SaveInProgress;
    const bytes = (try doc.owner.documentBytes(doc, gpa)) orelse return error.OwnerCannotSaveToMount;
    errdefer gpa.free(bytes);

    const job = try Save.create(self, doc.id, path, bytes);
    errdefer job.destroy();
    // The precondition: the file as it was when this document read (or last wrote) it. A
    // Save As to another path has no such history; nor does a save the user chose to force.
    const same_path = std.mem.eql(u8, path, doc.owner.documentPath(doc));
    if (same_path and self.force_next.swapRemove(doc.id) == false) {
        if (self.known_mtime.get(doc.id)) |mtime| job.if_unmodified_ms = mtime;
    }
    try self.saves.put(gpa, doc.id, job);
    errdefer _ = self.saves.swapRemove(doc.id);

    const target = editor.app.file_table.resolve(path);
    // Our own write must not read as an outside change to the folder watcher.
    if (target.mount == null) {
        if (editor.document_watcher) |*w| w.markPendingBaseline(doc.id);
    }
    job.job = try target.fs.writeFile(target.rel, job.bytes, .{ .if_unmodified_ms = job.if_unmodified_ms }, Save.onWritten, job);
    // The disk answers inside the call, as every disk mutation does; a mount on the frame pump.
    if (target.mount == null) target.fs.pump();
}

const Save = struct {
    io: *DocumentIo,
    doc_id: u64,
    path: []u8,
    bytes: []u8,
    job: core.vfs.Job = .{ .id = 0 },
    /// The write came back `NotFound` once and the file has been created since.
    created: bool = false,
    if_unmodified_ms: ?i64 = null,

    fn create(io: *DocumentIo, doc_id: u64, path: []const u8, bytes: []u8) !*Save {
        const gpa = io.editor.app.gpa;
        const save_job = try gpa.create(Save);
        errdefer gpa.destroy(save_job);
        save_job.* = .{ .io = io, .doc_id = doc_id, .path = try gpa.dupe(u8, path), .bytes = bytes };
        return save_job;
    }

    fn destroy(job: *Save) void {
        const gpa = job.io.editor.app.gpa;
        gpa.free(job.path);
        gpa.free(job.bytes);
        gpa.destroy(job);
    }

    fn onCreated(ctx: ?*anyopaque, result: core.vfs.Error!void) void {
        const job: *Save = @ptrCast(@alignCast(ctx.?));
        const io = job.io;
        const editor = io.editor;
        result catch |err| {
            _ = io.saves.swapRemove(job.doc_id);
            dvui.log.err("Failed to create {s}: {t}", .{ job.path, err });
            job.destroy();
            return;
        };
        const target = editor.app.file_table.resolve(job.path);
        job.job = target.fs.writeFile(target.rel, job.bytes, .{}, Save.onWritten, job) catch {
            _ = io.saves.swapRemove(job.doc_id);
            job.destroy();
            return;
        };
        if (target.mount == null) target.fs.pump();
    }

    fn onWritten(ctx: ?*anyopaque, result: core.vfs.Error!void) void {
        const job: *Save = @ptrCast(@alignCast(ctx.?));
        const io = job.io;
        const editor = io.editor;
        // The retry path below re-queues the job; only a final outcome frees it.
        var keep = false;
        defer if (!keep) job.destroy();
        _ = io.saves.swapRemove(job.doc_id);

        result catch |err| {
            if (err == error.Conflict) {
                // Someone else's edit is on the drive. Nothing was written; the document
                // stays dirty, and the next save from the user goes through regardless.
                io.force_next.put(editor.app.gpa, job.doc_id, {}) catch {};
                dvui.log.warn("{s} changed on the drive since it was opened", .{job.path});
                dvui.toast(@src(), .{ .message = std.fmt.allocPrint(
                    editor.app.arena.allocator(),
                    "{s} changed on the drive since you opened it. Save again to overwrite it, or Save As to keep both.",
                    .{std.fs.path.basename(job.path)},
                ) catch "The file changed on the drive since you opened it. Save again to overwrite." });
                return;
            }
            if (err == error.NotFound and !job.created) {
                // Save As onto a mount: the file is not there yet. Create it, then write again
                // — the backend's `writeFile` is replace, not create.
                job.created = true;
                keep = true;
                io.saves.put(editor.app.gpa, job.doc_id, job) catch {
                    keep = false;
                    return;
                };
                const target = editor.app.file_table.resolve(job.path);
                job.job = target.fs.createFile(target.rel, Save.onCreated, job) catch {
                    _ = io.saves.swapRemove(job.doc_id);
                    keep = false;
                    return;
                };
                if (target.mount == null) target.fs.pump();
                return;
            }
            dvui.log.err("Failed to save {s}: {t}", .{ job.path, err });
            dvui.toast(@src(), .{ .message = std.fmt.allocPrint(
                editor.app.arena.allocator(),
                "Could not save {s}.",
                .{std.fs.path.basename(job.path)},
            ) catch "Could not save file." });
            return;
        };
        // The document may have been closed while the write was in flight; the bytes still
        // landed, there is just nobody left to tell.
        const doc = editor.app.docById(job.doc_id) orelse return;
        const renamed = !std.mem.eql(u8, doc.owner.documentPath(doc), job.path);
        doc.owner.documentWritten(doc, job.path) catch |err| {
            dvui.log.err("Owner rejected the saved state of {s}: {t}", .{ job.path, err });
            return;
        };
        if (renamed) editor.documentPathChanged(doc);
        if (!io.owns(job.path)) {
            if (editor.document_watcher) |*w| w.noteSaved(job.doc_id);
        }
        // What we just wrote is now the known state; the backend's own modified time is not
        // known until the next read, so a stat is asked for and the precondition waits on it.
        _ = io.known_mtime.swapRemove(job.doc_id);
        const target = editor.app.file_table.resolve(job.path);
        const probe = MtimeProbe.create(io, job.doc_id) catch null;
        if (probe) |p| {
            _ = target.fs.stat(target.rel, MtimeProbe.onStat, p) catch p.destroy();
            if (target.mount == null) target.fs.pump();
        }
        editor.app.file_table.noteFileModified(job.path);
        editor.app.host.refresh();
    }
};

/// After a write: ask the backend when the file is now modified, so the next save's
/// precondition is the write we made rather than the read before it.
const MtimeProbe = struct {
    io: *DocumentIo,
    doc_id: u64,

    fn create(io: *DocumentIo, doc_id: u64) !*MtimeProbe {
        const p = try io.editor.app.gpa.create(MtimeProbe);
        p.* = .{ .io = io, .doc_id = doc_id };
        return p;
    }
    fn destroy(p: *MtimeProbe) void {
        p.io.editor.app.gpa.destroy(p);
    }
    fn onStat(ctx: ?*anyopaque, result: core.vfs.Error!core.vfs.Stat) void {
        const p: *MtimeProbe = @ptrCast(@alignCast(ctx.?));
        defer p.destroy();
        const st = result catch return;
        if (st.modified_ms == 0) return;
        // Only if no newer save has started meanwhile (its own probe will answer).
        if (p.io.saves.contains(p.doc_id)) return;
        p.io.known_mtime.put(p.io.editor.app.gpa, p.doc_id, st.modified_ms) catch {};
    }
};
