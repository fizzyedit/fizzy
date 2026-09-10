//! The `files` service: creating, renaming, deleting and moving what is on disk, with the open
//! documents kept in step.
//!
//! **A service rather than methods on `Host`, and that is the point.** These five operations were
//! `Host` members, which made fizzy's implementation the only possible one: an app backed by a
//! virtual filesystem, a remote workspace or a database had no way to offer its plugins the same
//! capability, because the contract said "the host does this" rather than "someone might".
//!
//! Now the application registers an implementation and a plugin asks for it. The two properties
//! that follow are the ones the whole service mechanism exists for:
//!
//!   * **Optional.** `getServiceTyped` returns null when no app registered one, and a plugin that
//!     cannot find it should offer what it can rather than fail to load — a file tree without
//!     rename is still a file tree. Nothing here is a load-time dependency.
//!   * **Replaceable.** An app supplies its own semantics without fizzy knowing they exist, and
//!     without a fingerprint bump, because a service's shape is checked by `service_version`
//!     rather than by the SDK-wide hash.
//!
//! Paths are absolute. Renaming or deleting something a document is open on is expected, not
//! exceptional: an implementation is responsible for rewriting or closing those documents, since
//! only it knows what it has open.
const std = @import("std");

pub const Api = struct {
    /// Bump whenever this struct's layout changes: `getServiceTyped` refuses a provider whose
    /// version differs rather than reinterpreting one shape as another across `dlopen`.
    pub const service_version: u32 = 1;
    pub const service_name = "files";

    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Create an empty file at `path`.
        createFile: *const fn (ctx: *anyopaque, path: []const u8) anyerror!void,
        /// Create a directory at `path`. Parents must already exist.
        createDir: *const fn (ctx: *anyopaque, path: []const u8) anyerror!void,
        /// Rename `path` to `new_path`, rewriting the path of every open document it names — the
        /// one document for a file, everything beneath it for a directory.
        rename: *const fn (ctx: *anyopaque, path: []const u8, new_path: []const u8, kind: std.Io.File.Kind) anyerror!void,
        /// Delete `path` (a file, or an empty directory) and close whatever that removed from
        /// under the editor. An unsaved document still raises the app's normal unsaved-close
        /// prompt: the file being gone from disk is exactly when those edits are the only copy.
        delete: *const fn (ctx: *anyopaque, path: []const u8) void,
        /// Move `path` into `target_dir`, keeping its basename. False when it is already there —
        /// a drop onto the folder a file is already in is a no-op, not a failure.
        move: *const fn (ctx: *anyopaque, path: []const u8, target_dir: []const u8) anyerror!bool,
    };

    pub fn createFile(self: Api, path: []const u8) !void {
        return self.vtable.createFile(self.ctx, path);
    }
    pub fn createDir(self: Api, path: []const u8) !void {
        return self.vtable.createDir(self.ctx, path);
    }
    pub fn rename(self: Api, path: []const u8, new_path: []const u8, kind: std.Io.File.Kind) !void {
        return self.vtable.rename(self.ctx, path, new_path, kind);
    }
    pub fn delete(self: Api, path: []const u8) void {
        self.vtable.delete(self.ctx, path);
    }
    pub fn move(self: Api, path: []const u8, target_dir: []const u8) !bool {
        return self.vtable.move(self.ctx, path, target_dir);
    }
};
