//! Documents on a mounted filesystem: opened by reading through the mount and saved by writing
//! through it, so an owner never has to know what a `gdrive://` path is.
//!
//! The disk keeps its own paths — `FileLoadJob` off the main thread, `owner.saveDocument` —
//! because that is what every owner written so far implements, and a mount cannot use either:
//! there is no file for `loadDocument` to open, and `saveDocument` writes the file itself.
//! What a mount needs instead is the pair every owner *can* provide without touching storage:
//! `loadDocumentFromBytes` (already there for the browser picker) and `documentBytes` +
//! `documentWritten`. Both halves complete through the mount's `pump`, so a cloud open or save
//! lands on a later frame while an in-memory mount lands inside the call.
const std = @import("std");
const dvui = @import("dvui");
const sdk = @import("fizzy_sdk");
const core = @import("core");
const fizzy = @import("../fizzy.zig");

const Editor = fizzy.Editor;
const MountIo = @This();

editor: *Editor,
/// Opens in flight, keyed by canonical path (owned by the job). A second open of the same
/// path focuses the first when it lands instead of reading twice.
loads: std.StringArrayHashMapUnmanaged(*Load) = .empty,
/// Saves in flight, keyed by document id. A document with a save pending is not closed by the
/// quit flow until it lands — the bytes are the only copy.
saves: std.AutoArrayHashMapUnmanaged(u64, *Save) = .empty,

pub fn init(editor: *Editor) MountIo {
    return .{ .editor = editor };
}

pub fn deinit(self: *MountIo) void {
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
}

/// Whether `path` is one this file handles. Everything else is the disk's.
pub fn owns(self: *MountIo, path: []const u8) bool {
    return self.editor.app.file_table.isMounted(path);
}

pub fn saving(self: *const MountIo, doc_id: u64) bool {
    return self.saves.contains(doc_id);
}

// ---- open ----------------------------------------------------------------------------------

/// Read `path` through its mount and open it from the bytes. `path` is canonical already.
/// Returns whether a read was started — false when one is already in flight for this path,
/// which then becomes the one to focus.
pub fn open(self: *MountIo, path: []const u8, grouping: u64) !bool {
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
    target.fs.pump();
    return true;
}

const Load = struct {
    io: *MountIo,
    path: []u8,
    grouping: u64,
    job: core.vfs.Job = .{ .id = 0 },
    focus: bool = true,

    fn create(io: *MountIo, path: []const u8, grouping: u64) !*Load {
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

    fn onRead(ctx: ?*anyopaque, result: core.vfs.Error![]u8) void {
        const load: *Load = @ptrCast(@alignCast(ctx.?));
        const io = load.io;
        const editor = io.editor;
        const gpa = editor.app.gpa;
        defer load.destroy();
        _ = io.loads.swapRemove(load.path);

        const bytes = result catch |err| {
            dvui.log.err("Failed to open {s}: {t}", .{ load.path, err });
            dvui.toast(@src(), .{ .message = std.fmt.allocPrint(
                editor.app.arena.allocator(),
                "Could not open {s}.",
                .{std.fs.path.basename(load.path)},
            ) catch "Could not open file." });
            return;
        };
        defer gpa.free(bytes);

        // `openFileFromBytes` takes the path; it wants its own copy to own.
        const path_for_open = gpa.dupe(u8, load.path) catch return;
        const id = editor.openFileFromBytes(path_for_open, bytes, load.grouping) catch |err| {
            if (err != error.AlreadyOpen) dvui.log.err("Failed to open {s}: {t}", .{ load.path, err });
            return;
        };
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
pub fn save(self: *MountIo, doc: sdk.DocHandle, path: []const u8) !void {
    const editor = self.editor;
    const gpa = editor.app.gpa;
    if (self.saves.contains(doc.id)) return error.SaveInProgress;
    const bytes = (try doc.owner.documentBytes(doc, gpa)) orelse return error.OwnerCannotSaveToMount;
    errdefer gpa.free(bytes);

    const job = try Save.create(self, doc.id, path, bytes);
    errdefer job.destroy();
    try self.saves.put(gpa, doc.id, job);
    errdefer _ = self.saves.swapRemove(doc.id);

    const target = editor.app.file_table.resolve(path);
    job.job = try target.fs.writeFile(target.rel, job.bytes, Save.onWritten, job);
    target.fs.pump();
}

const Save = struct {
    io: *MountIo,
    doc_id: u64,
    path: []u8,
    bytes: []u8,
    job: core.vfs.Job = .{ .id = 0 },

    fn create(io: *MountIo, doc_id: u64, path: []const u8, bytes: []u8) !*Save {
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

    fn onWritten(ctx: ?*anyopaque, result: core.vfs.Error!void) void {
        const job: *Save = @ptrCast(@alignCast(ctx.?));
        const io = job.io;
        const editor = io.editor;
        defer job.destroy();
        _ = io.saves.swapRemove(job.doc_id);

        result catch |err| {
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
        editor.app.file_table.noteFileModified(job.path);
        editor.app.host.refresh();
    }
};
