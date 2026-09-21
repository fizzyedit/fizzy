//! A filesystem-like interface over cloud storage, addressed by path and completed later.
//!
//! **Paths, not ids.** A consumer (fizzy's file table, its documents, its explorer) already
//! speaks paths everywhere; an id-addressed API would force a second code path into each of
//! them. So every op here takes a `/`-rooted, `/`-separated path *within the mount* — the host
//! strips its own mount prefix (`gdrive://<account>`) before calling — and a backend that is
//! really id-addressed (Drive) keeps the path→id map to itself.
//!
//! **Async, not blocking.** wasm32-freestanding is single-threaded and cannot wait on `fetch`,
//! so `readFile() -> []u8` is unimplementable on the one target this library exists for.
//! Every op starts a `Job` and completes through a callback; completions are delivered only
//! from `pump()`, on the calling thread, so a consumer sees them at a moment of its choosing
//! (once per frame, in fizzy's case) and never from a foreign thread or mid-call. A backend
//! that can answer immediately (`Mem`) still defers to `pump` — the caller gets one shape.
//!
//! Callbacks own what they receive: a listing or a byte slice was allocated with the allocator
//! passed at start and is the callback's to free (`freeEntries`, `allocator.free`).
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{
    NotFound,
    NotADirectory,
    NotAFile,
    NotEmpty,
    Exists,
    /// The backend does not implement this op (or refuses it for this path, e.g. removing `/`).
    Unsupported,
    /// Exists, but has no bytes to read — a Google Doc or Sheet.
    NotBinary,
    /// The bearer token was rejected. The host should refresh it and retry.
    Unauthorized,
    /// The token is fine but this op is not allowed — a read-only share, a scope too narrow.
    Forbidden,
    /// Any other transport-level failure.
    Http,
    /// Any other failure of the storage itself — a local disk's I/O error, a full quota.
    Io,
    InvalidJson,
    Cancelled,
    /// `writeFile` with `if_unmodified_ms`: the file changed since then. Nothing was written.
    Conflict,
    OutOfMemory,
};

pub const Kind = enum { file, dir };

/// One child of a listed directory. Names only; the caller joins them onto the directory path.
pub const Entry = struct {
    name: []const u8,
    kind: Kind,
    size: u64 = 0,
    /// Milliseconds since the Unix epoch; 0 when the backend has no idea.
    modified_ms: i64 = 0,
};

pub const Stat = struct {
    kind: Kind,
    size: u64 = 0,
    modified_ms: i64 = 0,
};

/// What `readFile` hands back: the bytes, and when the file was last modified as of that read
/// — the value to pass back as `WriteOptions.if_unmodified_ms` so a later write cannot clobber
/// an edit made elsewhere in between. 0 when the backend cannot say.
pub const Read = struct {
    bytes: []u8,
    modified_ms: i64 = 0,
};

pub const WriteOptions = struct {
    /// Refuse (`error.Conflict`) if the file's modification time is not this one — a
    /// compare-and-swap on the file. Null writes unconditionally.
    if_unmodified_ms: ?i64 = null,
};

pub fn freeEntries(allocator: Allocator, entries: []Entry) void {
    for (entries) |entry| allocator.free(entry.name);
    allocator.free(entries);
}

/// A started op. Opaque to the caller; only meaningful to the backend that issued it.
pub const Job = struct {
    id: u64,
};

pub const ListDirFn = *const fn (ctx: ?*anyopaque, result: Error![]Entry) void;
pub const StatFn = *const fn (ctx: ?*anyopaque, result: Error!Stat) void;
pub const ReadFn = *const fn (ctx: ?*anyopaque, result: Error!Read) void;
pub const DoneFn = *const fn (ctx: ?*anyopaque, result: Error!void) void;

/// Host-owned backend. Function pointers keep this wasm-safe (no std.http, no OS filesystem).
///
/// Starting an op can fail synchronously only for reasons known before any work happens
/// (out of memory, an op the backend never supports); everything else — including
/// `NotFound` — arrives through the callback. A caller therefore handles each error in exactly
/// one place.
pub const Fs = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        listDir: *const fn (ptr: *anyopaque, allocator: Allocator, path: []const u8, cb: ListDirFn, ctx: ?*anyopaque) Error!Job,
        stat: *const fn (ptr: *anyopaque, path: []const u8, cb: StatFn, ctx: ?*anyopaque) Error!Job,
        readFile: *const fn (ptr: *anyopaque, allocator: Allocator, path: []const u8, cb: ReadFn, ctx: ?*anyopaque) Error!Job,
        /// `bytes` must stay valid until the callback runs. Create-or-replace, like a disk.
        writeFile: *const fn (ptr: *anyopaque, path: []const u8, bytes: []const u8, opts: WriteOptions, cb: DoneFn, ctx: ?*anyopaque) Error!Job,
        /// Create an empty file. Parents must exist.
        createFile: *const fn (ptr: *anyopaque, path: []const u8, cb: DoneFn, ctx: ?*anyopaque) Error!Job,
        /// Create a directory. Parents must exist.
        mkdir: *const fn (ptr: *anyopaque, path: []const u8, cb: DoneFn, ctx: ?*anyopaque) Error!Job,
        /// Rename and/or move: `new_path` may differ from `path` in its final segment, its
        /// parent, or both. Directories move with their contents.
        rename: *const fn (ptr: *anyopaque, path: []const u8, new_path: []const u8, cb: DoneFn, ctx: ?*anyopaque) Error!Job,
        /// Remove a file or an empty directory.
        remove: *const fn (ptr: *anyopaque, path: []const u8, cb: DoneFn, ctx: ?*anyopaque) Error!Job,
        /// Forget a job. Its callback will not run. Cancelling a completed or unknown job is a no-op.
        cancel: *const fn (ptr: *anyopaque, job: Job) void,
        /// Deliver every completion that has arrived since the last call, on this thread.
        pump: *const fn (ptr: *anyopaque) void,
    };

    pub fn listDir(self: Fs, allocator: Allocator, path: []const u8, cb: ListDirFn, ctx: ?*anyopaque) Error!Job {
        return self.vtable.listDir(self.ptr, allocator, path, cb, ctx);
    }
    pub fn stat(self: Fs, path: []const u8, cb: StatFn, ctx: ?*anyopaque) Error!Job {
        return self.vtable.stat(self.ptr, path, cb, ctx);
    }
    pub fn readFile(self: Fs, allocator: Allocator, path: []const u8, cb: ReadFn, ctx: ?*anyopaque) Error!Job {
        return self.vtable.readFile(self.ptr, allocator, path, cb, ctx);
    }
    pub fn writeFile(self: Fs, path: []const u8, bytes: []const u8, opts: WriteOptions, cb: DoneFn, ctx: ?*anyopaque) Error!Job {
        return self.vtable.writeFile(self.ptr, path, bytes, opts, cb, ctx);
    }
    pub fn createFile(self: Fs, path: []const u8, cb: DoneFn, ctx: ?*anyopaque) Error!Job {
        return self.vtable.createFile(self.ptr, path, cb, ctx);
    }
    pub fn mkdir(self: Fs, path: []const u8, cb: DoneFn, ctx: ?*anyopaque) Error!Job {
        return self.vtable.mkdir(self.ptr, path, cb, ctx);
    }
    pub fn rename(self: Fs, path: []const u8, new_path: []const u8, cb: DoneFn, ctx: ?*anyopaque) Error!Job {
        return self.vtable.rename(self.ptr, path, new_path, cb, ctx);
    }
    pub fn remove(self: Fs, path: []const u8, cb: DoneFn, ctx: ?*anyopaque) Error!Job {
        return self.vtable.remove(self.ptr, path, cb, ctx);
    }
    pub fn cancel(self: Fs, job: Job) void {
        self.vtable.cancel(self.ptr, job);
    }
    pub fn pump(self: Fs) void {
        self.vtable.pump(self.ptr);
    }
};

// ---------------------------------------------------------------------------------------------
// Path helpers shared by backends. A mount path is `/`-rooted and `/`-separated, never has a
// trailing slash (except the root itself) and never contains `.` or `..` segments — the host
// normalises before calling, and a backend may assume it.

/// `"/a/b/c"` → `"/a/b"`; `"/a"` → `"/"`; `"/"` → `"/"`.
pub fn dirname(path: []const u8) []const u8 {
    if (path.len <= 1) return "/";
    const i = std.mem.lastIndexOfScalar(u8, path, '/') orelse return "/";
    return if (i == 0) "/" else path[0..i];
}

/// `"/a/b/c"` → `"c"`; `"/"` → `""`.
pub fn basename(path: []const u8) []const u8 {
    if (path.len <= 1) return "";
    const i = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[i + 1 ..];
}

/// Owned. `join("/", "a")` → `"/a"`; `join("/a", "b")` → `"/a/b"`.
pub fn join(allocator: Allocator, dir: []const u8, name: []const u8) Allocator.Error![]u8 {
    if (isRoot(dir)) return std.fmt.allocPrint(allocator, "/{s}", .{name});
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, name });
}

pub fn isRoot(path: []const u8) bool {
    return path.len == 0 or (path.len == 1 and path[0] == '/');
}

/// Segments of `"/a/b/c"` in order: `a`, `b`, `c`. The root yields nothing.
pub const Segments = struct {
    rest: []const u8,

    pub fn next(self: *Segments) ?[]const u8 {
        while (self.rest.len > 0 and self.rest[0] == '/') self.rest = self.rest[1..];
        if (self.rest.len == 0) return null;
        const end = std.mem.indexOfScalar(u8, self.rest, '/') orelse self.rest.len;
        const seg = self.rest[0..end];
        self.rest = self.rest[end..];
        return seg;
    }
};

pub fn segments(path: []const u8) Segments {
    return .{ .rest = path };
}

test "path helpers" {
    try std.testing.expectEqualStrings("/a/b", dirname("/a/b/c"));
    try std.testing.expectEqualStrings("/", dirname("/a"));
    try std.testing.expectEqualStrings("/", dirname("/"));
    try std.testing.expectEqualStrings("c", basename("/a/b/c"));
    try std.testing.expectEqualStrings("", basename("/"));
    const j = try join(std.testing.allocator, "/", "a");
    defer std.testing.allocator.free(j);
    try std.testing.expectEqualStrings("/a", j);
    var it = segments("/a/b");
    try std.testing.expectEqualStrings("a", it.next().?);
    try std.testing.expectEqualStrings("b", it.next().?);
    try std.testing.expect(it.next() == null);
    var root_it = segments("/");
    try std.testing.expect(root_it.next() == null);
}
