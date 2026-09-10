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

const Host = sdk.Host;

fn hostOf(ctx: *anyopaque) *Host {
    return @ptrCast(@alignCast(ctx));
}

/// The service value to register. `host` is both the context and the state: everything below
/// works through `Host`'s public document API, so nothing here reaches into `Editor`.
pub fn api(host: *Host) sdk.services.files.Api {
    return .{ .ctx = host, .vtable = &vtable };
}

const vtable: sdk.services.files.Api.VTable = .{
    .createFile = createFile,
    .createDir = createDir,
    .rename = rename,
    .delete = delete,
    .move = move,
};

/// Create an empty file at absolute `path`.
fn createFile(ctx: *anyopaque, path: []const u8) anyerror!void {
    const self = hostOf(ctx);
    const files = self.files orelse return error.NoFileTable;
    try files.createFile(path);
}

/// Create a directory at absolute `path`. Parents must already exist.
fn createDir(ctx: *anyopaque, path: []const u8) anyerror!void {
    const self = hostOf(ctx);
    const files = self.files orelse return error.NoFileTable;
    try files.createDir(path);
}

/// Rename `path` to `new_path`, rewriting the path of every open document it names: a file
/// rename rewrites that one document, a directory rename rewrites every document beneath it.
///
/// Logs and continues on a filesystem failure, matching the file tree's inline rename — a failed
/// rename leaves both the file and its document exactly as they were.
fn rename(ctx: *anyopaque, path: []const u8, new_path: []const u8, kind: std.Io.File.Kind) anyerror!void {
    const self = hostOf(ctx);
    const files = self.files orelse return error.NoFileTable;
    files.rename(path, new_path) catch {
        std.log.err("failed to rename {s} to {s}", .{ path, new_path });
        return;
    };

    switch (kind) {
        .file => {
            const doc = self.docFromPath(path) orelse return;
            try doc.owner.setDocumentPath(doc, new_path);
        },
        .directory => {
            var i: usize = 0;
            while (i < self.openDocCount()) : (i += 1) {
                const doc = self.docByIndex(i) orelse continue;
                const doc_path = doc.owner.documentPath(doc);
                if (!isStrictPathDescendant(doc_path, path)) continue;
                // The suffix below the renamed directory, not just the basename: a document in
                // `old/a/b.md` belongs at `new/a/b.md`, and taking the basename would flatten it
                // into `new/b.md`.
                const suffix = doc_path[path.len..];
                const moved = try std.mem.concat(self.allocator, u8, &.{ new_path, suffix });
                defer self.allocator.free(moved);
                doc.owner.setDocumentPath(doc, moved) catch {
                    std.log.err("failed to update open document path to {s}", .{moved});
                };
            }
        },
        else => {},
    }
}

/// Delete `path` from disk — a file, or a directory that must be empty — and close whatever the
/// delete just removed from under the editor.
///
/// Closing goes through `closeDocById`, so an unsaved document still raises the normal
/// unsaved-close dialog rather than having its edits discarded silently: the file being gone
/// from disk is exactly when those edits are the only copy left.
fn delete(ctx: *anyopaque, path: []const u8) void {
    const self = hostOf(ctx);
    const files = self.files orelse return;
    const was_dir = files.isDir(path);
    files.remove(path) catch {
        std.log.err("failed to delete {s}", .{path});
        return;
    };

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

/// Move `path` into `target_dir`, keeping its basename. False when it is already there (not an
/// error — a drop onto the folder a file is already in is a no-op, not a failure).
fn move(ctx: *anyopaque, path: []const u8, target_dir: []const u8) anyerror!bool {
    const self = hostOf(ctx);
    const base = std.fs.path.basename(path);
    const new_path = try std.fs.path.join(self.allocator, &.{ target_dir, base });
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
    return child[ancestor.len] == std.fs.path.sep;
}
