//! Fizzy's implementation of the `files` service: create, rename, delete and move, with the open
//! documents kept in step.
//!
//! Both halves have to happen together — a rename that leaves a tab pointing at a path that no
//! longer exists is a dangling document — and only something with both views can do it:
//! `core.FileTable` owns the disk and the invalidation but has never heard of a document, and the
//! document registry has never heard of a directory.
//!
//! This was five methods on `Host`, which meant fizzy's answer was the *only* answer: an app over
//! a virtual or remote filesystem could not offer its plugins the same capability. As a service
//! it is one implementation of a named, versioned interface (`sdk.services.files.Api`), and the
//! plugin asking for it neither knows nor cares which app it got.
const std = @import("std");
const sdk = @import("fizzy_sdk");
const core = @import("core");
const fizzy = @import("../fizzy.zig");

const Host = sdk.Host;
const Editor = fizzy.Editor;

fn editorOf(ctx: *anyopaque) *Editor {
    return @ptrCast(@alignCast(ctx));
}

fn hostOf(ctx: *anyopaque) *Host {
    return &editorOf(ctx).app.host;
}

/// The service value to register. `editor` is the context; the disk and document halves go
/// through `Host`'s public document API, and the one thing that needs the app itself is what
/// a rename leaves behind — the surface and tab keyed by the old path
/// (`Editor.documentPathChanged`), which no plugin-facing API names.
pub fn api(editor: *Editor) sdk.services.files.Api {
    return .{ .ctx = editor, .vtable = &vtable };
}

const vtable: sdk.services.files.Api.VTable = .{
    .createFile = createFile,
    .createDir = createDir,
    .rename = rename,
    .delete = delete,
    .move = move,
};

/// Create an empty file at `path`.
fn createFile(ctx: *anyopaque, path: []const u8) anyerror!void {
    const self = hostOf(ctx);
    const files = self.files orelse return error.NoFileTable;
    const op = try Op.create(editorOf(ctx), .{ .create = {} }, path, null);
    errdefer op.destroy();
    try files.createFile(path, Op.onDone, op);
}

/// Create a directory at `path`. Parents must already exist.
fn createDir(ctx: *anyopaque, path: []const u8) anyerror!void {
    const self = hostOf(ctx);
    const files = self.files orelse return error.NoFileTable;
    const op = try Op.create(editorOf(ctx), .{ .create = {} }, path, null);
    errdefer op.destroy();
    try files.createDir(path, Op.onDone, op);
}

/// Rename `path` to `new_path`, rewriting the path of every open document it names: a file
/// rename rewrites that one document, a directory rename rewrites every document beneath it.
///
/// The document half runs when the filesystem confirms — inside this call for the disk, on a
/// later frame for a cloud mount. A failed rename is logged and leaves both the file and its
/// document exactly as they were, matching the file tree's inline rename.
fn rename(ctx: *anyopaque, path: []const u8, new_path: []const u8, kind: std.Io.File.Kind) anyerror!void {
    const self = hostOf(ctx);
    const files = self.files orelse return error.NoFileTable;
    const op = try Op.create(editorOf(ctx), .{ .rename = kind }, path, new_path);
    errdefer op.destroy();
    try files.rename(path, new_path, Op.onDone, op);
}

/// Delete `path` — a file, or a directory that must be empty — and close whatever the delete
/// just removed from under the editor, once the filesystem confirms.
///
/// Closing goes through `closeDocById`, so an unsaved document still raises the normal
/// unsaved-close dialog rather than having its edits discarded silently: the file being gone
/// is exactly when those edits are the only copy left.
fn delete(ctx: *anyopaque, path: []const u8) void {
    const self = hostOf(ctx);
    const files = self.files orelse return;
    const was_dir = files.isDir(path);
    const op = Op.create(editorOf(ctx), .{ .delete = was_dir }, path, null) catch return;
    files.remove(path, Op.onDone, op) catch |err| {
        op.destroy();
        std.log.err("failed to delete {s}: {t}", .{ path, err });
    };
}

/// One mutation in flight, with what its completion has to do to the open documents. Owns
/// copies of the paths: the caller's may be arena strings that do not outlive the frame, and
/// a cloud mount answers on a later one.
const Op = struct {
    editor: *Editor,
    what: What,
    path: []u8,
    new_path: ?[]u8,

    const What = union(enum) {
        create,
        rename: std.Io.File.Kind,
        /// Whether the deleted path was a directory, decided before it was gone.
        delete: bool,
    };

    fn create(editor: *Editor, what: What, path: []const u8, new_path: ?[]const u8) !*Op {
        const gpa = editor.app.host.allocator;
        const op = try gpa.create(Op);
        errdefer gpa.destroy(op);
        const path_copy = try gpa.dupe(u8, path);
        errdefer gpa.free(path_copy);
        const new_copy: ?[]u8 = if (new_path) |np| try gpa.dupe(u8, np) else null;
        op.* = .{ .editor = editor, .what = what, .path = path_copy, .new_path = new_copy };
        return op;
    }

    fn destroy(op: *Op) void {
        const gpa = op.editor.app.host.allocator;
        gpa.free(op.path);
        if (op.new_path) |np| gpa.free(np);
        gpa.destroy(op);
    }

    fn onDone(ctx: ?*anyopaque, result: core.vfs.Error!void) void {
        const op: *Op = @ptrCast(@alignCast(ctx.?));
        defer op.destroy();
        result catch |err| {
            switch (op.what) {
                .create => std.log.err("failed to create {s}: {t}", .{ op.path, err }),
                .rename => std.log.err("failed to rename {s} to {s}: {t}", .{ op.path, op.new_path.?, err }),
                .delete => std.log.err("failed to delete {s}: {t}", .{ op.path, err }),
            }
            return;
        };
        switch (op.what) {
            .create => {},
            .rename => |kind| op.documentsRenamed(kind),
            .delete => |was_dir| op.documentsDeleted(was_dir),
        }
    }

    fn documentsRenamed(op: *Op, kind: std.Io.File.Kind) void {
        const self = &op.editor.app.host;
        const path = op.path;
        const new_path = op.new_path.?;
        switch (kind) {
            .file => {
                const doc = self.docFromPath(path) orelse return;
                doc.owner.setDocumentPath(doc, new_path) catch |err| {
                    std.log.err("failed to update open document path to {s}: {t}", .{ new_path, err });
                    return;
                };
                op.editor.documentPathChanged(doc);
            },
            .directory => {
                var i: usize = 0;
                while (i < self.openDocCount()) : (i += 1) {
                    const doc = self.docByIndex(i) orelse continue;
                    const doc_path = doc.owner.documentPath(doc);
                    if (!isStrictPathDescendant(doc_path, path)) continue;
                    // The suffix below the renamed directory, not just the basename: a document
                    // in `old/a/b.md` belongs at `new/a/b.md`, and taking the basename would
                    // flatten it into `new/b.md`.
                    const suffix = doc_path[path.len..];
                    const moved = std.mem.concat(self.allocator, u8, &.{ new_path, suffix }) catch continue;
                    defer self.allocator.free(moved);
                    doc.owner.setDocumentPath(doc, moved) catch {
                        std.log.err("failed to update open document path to {s}", .{moved});
                        continue;
                    };
                    op.editor.documentPathChanged(doc);
                }
            },
            else => {},
        }
    }

    fn documentsDeleted(op: *Op, was_dir: bool) void {
        const self = &op.editor.app.host;
        const path = op.path;
        if (!was_dir) {
            // `docFromPath` collapses lexical spellings of the same file, which a manual compare
            // against `documentPath` would not.
            const doc = self.docFromPath(path) orelse return;
            self.closeDocById(doc.id) catch |err| {
                std.log.err("failed to close deleted document {s}: {t}", .{ path, err });
            };
            return;
        }

        // Ids first: closing mutates the open-document list this walks.
        var ids: std.ArrayListUnmanaged(u64) = .empty;
        defer ids.deinit(self.allocator);
        var i: usize = 0;
        while (i < self.openDocCount()) : (i += 1) {
            const doc = self.docByIndex(i) orelse continue;
            if (!isStrictPathDescendant(doc.owner.documentPath(doc), path)) continue;
            ids.append(self.allocator, doc.id) catch break;
        }
        for (ids.items) |id| {
            self.closeDocById(id) catch |err| {
                std.log.err("failed to close deleted document: {t}", .{err});
            };
        }
    }
};

/// Move `path` into `target_dir`, keeping its basename. False when it is already there (not an
/// error — a drop onto the folder a file is already in is a no-op, not a failure).
fn move(ctx: *anyopaque, path: []const u8, target_dir: []const u8) anyerror!bool {
    const self = hostOf(ctx);
    const base = std.fs.path.basename(path);
    const new_path = try core.paths.join(self.allocator, target_dir, base);
    defer self.allocator.free(new_path);
    if (std.mem.eql(u8, path, new_path)) return false;

    const kind: std.Io.File.Kind = if (self.files) |f|
        (if (f.isDir(path)) .directory else .file)
    else
        .file;
    try rename(ctx, path, new_path, kind);
    return true;
}

/// Whether `child` sits strictly below `ancestor`, comparing whole path components so that
/// `src/files2` is not treated as living inside `src/files`.
fn isStrictPathDescendant(child: []const u8, ancestor: []const u8) bool {
    if (child.len <= ancestor.len) return false;
    if (!std.mem.startsWith(u8, child, ancestor)) return false;
    // A mount's paths are `/`-separated whatever the OS; the disk's use the native separator.
    return child[ancestor.len] == std.fs.path.sep or child[ancestor.len] == '/';
}
