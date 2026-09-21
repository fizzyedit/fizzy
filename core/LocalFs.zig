//! The local disk as a `vfs.Fs`, so `FileTable` has exactly one read path whether a directory
//! lives on this machine or on a cloud mount.
//!
//! Paths are the OS's own absolute paths — the local mount has no prefix to strip. Every op
//! runs to completion inside its start call (the disk is synchronous here, as it always was)
//! and the result is parked until `pump`, which is the `vfs.Fs` contract. `FileTable` pumps
//! the mount it just asked right away, so a local listing still comes back in the same call
//! that requested it and nothing above notices a difference.
const std = @import("std");
const builtin = @import("builtin");
const vfs = @import("vfs/vfs.zig");

const LocalFs = @This();

/// The browser has no disk. Every op refuses with `Unsupported` — the same outcome the old
/// `Io.Dir.cwd()` calls had on wasm, but decided here rather than by `std.Io.failing`, and
/// without dragging `posix.AT` / `PATH_MAX` into a freestanding build.
const no_disk = builtin.target.cpu.arch == .wasm32;

gpa: std.mem.Allocator,
io: std.Io,
ready: vfs.http.Completions(Completion),

const Completion = union(enum) {
    list: struct { allocator: std.mem.Allocator, cb: vfs.ListDirFn, ctx: ?*anyopaque, result: vfs.Error![]vfs.Entry },
    stat: struct { cb: vfs.StatFn, ctx: ?*anyopaque, result: vfs.Error!vfs.Stat },
    read: struct { allocator: std.mem.Allocator, cb: vfs.ReadFn, ctx: ?*anyopaque, result: vfs.Error![]u8 },
    done: struct { cb: vfs.DoneFn, ctx: ?*anyopaque, result: vfs.Error!void },

    fn discard(self: Completion) void {
        switch (self) {
            .list => |c| if (c.result) |entries| vfs.freeEntries(c.allocator, entries) else |_| {},
            .read => |c| if (c.result) |bytes| c.allocator.free(bytes) else |_| {},
            .stat, .done => {},
        }
    }

    fn deliver(self: Completion) void {
        switch (self) {
            .list => |c| c.cb(c.ctx, c.result),
            .stat => |c| c.cb(c.ctx, c.result),
            .read => |c| c.cb(c.ctx, c.result),
            .done => |c| c.cb(c.ctx, c.result),
        }
    }
};

pub fn init(gpa: std.mem.Allocator, io: std.Io) LocalFs {
    return .{ .gpa = gpa, .io = io, .ready = .init(gpa) };
}

pub fn deinit(self: *LocalFs) void {
    for (self.ready.items.items) |item| item.payload.discard();
    self.ready.deinit();
}

pub fn fs(self: *LocalFs) vfs.Fs {
    return .{ .ptr = self, .vtable = &vtable };
}

const vtable: vfs.Fs.VTable = if (no_disk) .{
    .listDir = NoDisk.listDir,
    .stat = NoDisk.stat,
    .readFile = NoDisk.readFile,
    .writeFile = NoDisk.writeFile,
    .createFile = NoDisk.done,
    .mkdir = NoDisk.done,
    .rename = NoDisk.rename,
    .remove = NoDisk.done,
    .cancel = cancel,
    .pump = pump,
} else .{
    .listDir = listDir,
    .stat = stat,
    .readFile = readFile,
    .writeFile = writeFile,
    .createFile = createFile,
    .mkdir = mkdir,
    .rename = rename,
    .remove = remove,
    .cancel = cancel,
    .pump = pump,
};

const NoDisk = struct {
    fn listDir(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: vfs.ListDirFn, _: ?*anyopaque) vfs.Error!vfs.Job {
        return error.Unsupported;
    }
    fn stat(_: *anyopaque, _: []const u8, _: vfs.StatFn, _: ?*anyopaque) vfs.Error!vfs.Job {
        return error.Unsupported;
    }
    fn readFile(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: vfs.ReadFn, _: ?*anyopaque) vfs.Error!vfs.Job {
        return error.Unsupported;
    }
    fn writeFile(_: *anyopaque, _: []const u8, _: []const u8, _: vfs.DoneFn, _: ?*anyopaque) vfs.Error!vfs.Job {
        return error.Unsupported;
    }
    fn done(_: *anyopaque, _: []const u8, _: vfs.DoneFn, _: ?*anyopaque) vfs.Error!vfs.Job {
        return error.Unsupported;
    }
    fn rename(_: *anyopaque, _: []const u8, _: []const u8, _: vfs.DoneFn, _: ?*anyopaque) vfs.Error!vfs.Job {
        return error.Unsupported;
    }
};

/// Fold the dozens of `std.Io` error names into the handful a consumer can act on.
fn mapErr(err: anyerror) vfs.Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.FileNotFound => error.NotFound,
        error.NotDir => error.NotADirectory,
        error.IsDir => error.NotAFile,
        error.PathAlreadyExists => error.Exists,
        error.DirNotEmpty => error.NotEmpty,
        error.AccessDenied, error.PermissionDenied => error.Forbidden,
        else => error.Io,
    };
}

fn queue(self: *LocalFs, completion: Completion) vfs.Error!vfs.Job {
    const id = self.ready.nextId();
    try self.ready.push(id, completion);
    return .{ .id = id };
}

fn listImpl(self: *LocalFs, allocator: std.mem.Allocator, path: []const u8) vfs.Error![]vfs.Entry {
    const io = self.io;
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .access_sub_paths = true, .iterate = true }) catch |err| return mapErr(err);
    defer dir.close(io);

    var entries: std.ArrayListUnmanaged(vfs.Entry) = .empty;
    errdefer {
        for (entries.items) |e| allocator.free(e.name);
        entries.deinit(allocator);
    }

    // A symlink (or anything else exotic) is reported as whatever it behaves as, so a consumer
    // only ever sees files and directories. The stat wants an absolute path but doesn't keep it,
    // so it's built in a stack buffer: an allocation per entry on a listing that can be hundreds
    // of thousands long is exactly the cost this table exists to avoid.
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var iter = dir.iterate();
    while (iter.next(io) catch |err| return mapErr(err)) |entry| {
        const kind: vfs.Kind = switch (entry.kind) {
            .directory => .dir,
            .file => .file,
            else => blk: {
                const abs = std.fmt.bufPrint(&path_buf, "{s}" ++ std.fs.path.sep_str ++ "{s}", .{ path, entry.name }) catch break :blk .file;
                break :blk if (isDirAbsolute(io, abs)) .dir else .file;
            },
        };
        const name = try allocator.dupe(u8, entry.name);
        errdefer allocator.free(name);
        try entries.append(allocator, .{ .name = name, .kind = kind });
    }
    return try entries.toOwnedSlice(allocator);
}

fn listDir(ptr: *anyopaque, allocator: std.mem.Allocator, path: []const u8, cb: vfs.ListDirFn, ctx: ?*anyopaque) vfs.Error!vfs.Job {
    const self: *LocalFs = @ptrCast(@alignCast(ptr));
    return self.queue(.{ .list = .{ .allocator = allocator, .cb = cb, .ctx = ctx, .result = self.listImpl(allocator, path) } });
}

fn statImpl(self: *LocalFs, path: []const u8) vfs.Error!vfs.Stat {
    const st = std.Io.Dir.cwd().statFile(self.io, path, .{}) catch |err| return mapErr(err);
    return .{
        .kind = if (st.kind == .directory) .dir else .file,
        .size = st.size,
        .modified_ms = @intCast(@divTrunc(st.mtime.nanoseconds, std.time.ns_per_ms)),
    };
}

fn stat(ptr: *anyopaque, path: []const u8, cb: vfs.StatFn, ctx: ?*anyopaque) vfs.Error!vfs.Job {
    const self: *LocalFs = @ptrCast(@alignCast(ptr));
    return self.queue(.{ .stat = .{ .cb = cb, .ctx = ctx, .result = self.statImpl(path) } });
}

/// Same ceiling the text plugin applies to a document: a listing tool has no business pulling a
/// multi-gigabyte file into memory because someone clicked it.
const max_read_bytes: usize = 1 << 30;

fn readImpl(self: *LocalFs, allocator: std.mem.Allocator, path: []const u8) vfs.Error![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(self.io, path, allocator, .limited(max_read_bytes)) catch |err| mapErr(err);
}

fn readFile(ptr: *anyopaque, allocator: std.mem.Allocator, path: []const u8, cb: vfs.ReadFn, ctx: ?*anyopaque) vfs.Error!vfs.Job {
    const self: *LocalFs = @ptrCast(@alignCast(ptr));
    return self.queue(.{ .read = .{ .allocator = allocator, .cb = cb, .ctx = ctx, .result = self.readImpl(allocator, path) } });
}

fn writeFile(ptr: *anyopaque, path: []const u8, bytes: []const u8, cb: vfs.DoneFn, ctx: ?*anyopaque) vfs.Error!vfs.Job {
    const self: *LocalFs = @ptrCast(@alignCast(ptr));
    const result: vfs.Error!void = std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = bytes }) catch |err| mapErr(err);
    return self.queue(.{ .done = .{ .cb = cb, .ctx = ctx, .result = result } });
}

fn createImpl(self: *LocalFs, path: []const u8) vfs.Error!void {
    var handle = std.Io.Dir.createFileAbsolute(self.io, path, .{ .exclusive = true }) catch |err| return mapErr(err);
    handle.close(self.io);
}

fn createFile(ptr: *anyopaque, path: []const u8, cb: vfs.DoneFn, ctx: ?*anyopaque) vfs.Error!vfs.Job {
    const self: *LocalFs = @ptrCast(@alignCast(ptr));
    return self.queue(.{ .done = .{ .cb = cb, .ctx = ctx, .result = self.createImpl(path) } });
}

fn mkdir(ptr: *anyopaque, path: []const u8, cb: vfs.DoneFn, ctx: ?*anyopaque) vfs.Error!vfs.Job {
    const self: *LocalFs = @ptrCast(@alignCast(ptr));
    const result: vfs.Error!void = std.Io.Dir.createDirAbsolute(self.io, path, .default_dir) catch |err| mapErr(err);
    return self.queue(.{ .done = .{ .cb = cb, .ctx = ctx, .result = result } });
}

fn rename(ptr: *anyopaque, path: []const u8, new_path: []const u8, cb: vfs.DoneFn, ctx: ?*anyopaque) vfs.Error!vfs.Job {
    const self: *LocalFs = @ptrCast(@alignCast(ptr));
    const result: vfs.Error!void = std.Io.Dir.renameAbsolute(path, new_path, self.io) catch |err| mapErr(err);
    return self.queue(.{ .done = .{ .cb = cb, .ctx = ctx, .result = result } });
}

fn removeImpl(self: *LocalFs, path: []const u8) vfs.Error!void {
    if (isDirAbsolute(self.io, path)) {
        std.Io.Dir.deleteDirAbsolute(self.io, path) catch |err| return mapErr(err);
    } else {
        std.Io.Dir.deleteFileAbsolute(self.io, path) catch |err| return mapErr(err);
    }
}

fn remove(ptr: *anyopaque, path: []const u8, cb: vfs.DoneFn, ctx: ?*anyopaque) vfs.Error!vfs.Job {
    const self: *LocalFs = @ptrCast(@alignCast(ptr));
    return self.queue(.{ .done = .{ .cb = cb, .ctx = ctx, .result = self.removeImpl(path) } });
}

fn cancel(ptr: *anyopaque, job: vfs.Job) void {
    const self: *LocalFs = @ptrCast(@alignCast(ptr));
    if (self.ready.remove(job.id)) |completion| completion.discard();
}

fn pump(ptr: *anyopaque) void {
    const self: *LocalFs = @ptrCast(@alignCast(ptr));
    self.ready.drain({}, struct {
        fn f(_: void, c: Completion) void {
            c.deliver();
        }
    }.f);
}

pub fn existsAbsolute(io: std.Io, abs: []const u8) bool {
    if (no_disk) return false;
    std.Io.Dir.accessAbsolute(io, abs, .{}) catch return false;
    return true;
}

pub fn isDirAbsolute(io: std.Io, abs: []const u8) bool {
    if (no_disk) return false;
    const st = std.Io.Dir.cwd().statFile(io, abs, .{}) catch return false;
    return st.kind == .directory;
}
