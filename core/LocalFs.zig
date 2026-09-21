//! The local disk as a `vfs.Fs`, so `FileTable` has exactly one read path whether a directory
//! lives on this machine or on a cloud mount.
//!
//! Paths are the OS's own absolute paths — the local mount has no prefix to strip. Every op
//! but a read runs to completion inside its start call (the disk is synchronous here, as it
//! always was) and the result is parked until `pump`, which is the `vfs.Fs` contract.
//! `FileTable` pumps the mount it just asked right away, so a local listing still comes back
//! in the same call that requested it and nothing above notices a difference.
//!
//! A read is the one op worth overlapping: a cold index of a large vault is hundreds of
//! thousands of small files, each ~120 µs of waiting when nothing else is in flight. `readFile`
//! goes through `io.async`, which the host's threaded `Io` runs on its pool and a
//! single-threaded `Io` (tests, or a saturated pool) runs inline — one implementation, and
//! the caller that issues a window of reads and pumps gets the overlap where it exists.
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
/// Reads in flight on `io.async`, by job id. Guarded by `lock`; the futures themselves are
/// awaited from `pump` only once their task has set `done`.
reads: std.AutoArrayHashMapUnmanaged(u64, *ReadJob) = .empty,
lock: SpinLock = .{},

const SpinLock = struct {
    inner: std.atomic.Mutex = .unlocked,
    fn acquire(self: *SpinLock) void {
        // The browser has one thread and no disk; nothing contends.
        if (no_disk) return;
        while (!self.inner.tryLock()) std.Thread.yield() catch {};
    }
    fn release(self: *SpinLock) void {
        if (no_disk) return;
        self.inner.unlock();
    }
};

const ReadJob = struct {
    owner: *LocalFs,
    id: u64,
    allocator: std.mem.Allocator,
    cb: vfs.ReadFn,
    ctx: ?*anyopaque,
    path: []u8,
    future: std.Io.Future(vfs.Error!vfs.Read) = undefined,
    done: std.atomic.Value(bool) = .init(false),
    cancelled: bool = false,

    fn run(job: *ReadJob) vfs.Error!vfs.Read {
        defer job.done.store(true, .release);
        return job.owner.readImpl(job.allocator, job.path);
    }
};

const Completion = union(enum) {
    list: struct { allocator: std.mem.Allocator, cb: vfs.ListDirFn, ctx: ?*anyopaque, result: vfs.Error![]vfs.Entry },
    stat: struct { cb: vfs.StatFn, ctx: ?*anyopaque, result: vfs.Error!vfs.Stat },
    read: struct { allocator: std.mem.Allocator, cb: vfs.ReadFn, ctx: ?*anyopaque, result: vfs.Error!vfs.Read },
    done: struct { cb: vfs.DoneFn, ctx: ?*anyopaque, result: vfs.Error!void },

    fn discard(self: Completion) void {
        switch (self) {
            .list => |c| if (c.result) |entries| vfs.freeEntries(c.allocator, entries) else |_| {},
            .read => |c| if (c.result) |r| c.allocator.free(r.bytes) else |_| {},
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
    // Every read still running finishes on its own; wait for it, drop what it read.
    for (self.reads.values()) |job| {
        if (job.future.await(self.io)) |r| job.allocator.free(r.bytes) else |_| {}
        self.gpa.free(job.path);
        self.gpa.destroy(job);
    }
    self.reads.deinit(self.gpa);
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
    fn writeFile(_: *anyopaque, _: []const u8, _: []const u8, _: vfs.WriteOptions, _: vfs.DoneFn, _: ?*anyopaque) vfs.Error!vfs.Job {
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

fn readImpl(self: *LocalFs, allocator: std.mem.Allocator, path: []const u8) vfs.Error!vfs.Read {
    const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, path, allocator, .limited(max_read_bytes)) catch |err| return mapErr(err);
    errdefer allocator.free(bytes);
    const st = self.statImpl(path) catch return .{ .bytes = bytes };
    return .{ .bytes = bytes, .modified_ms = st.modified_ms };
}

fn readFile(ptr: *anyopaque, allocator: std.mem.Allocator, path: []const u8, cb: vfs.ReadFn, ctx: ?*anyopaque) vfs.Error!vfs.Job {
    const self: *LocalFs = @ptrCast(@alignCast(ptr));
    const job = try self.gpa.create(ReadJob);
    errdefer self.gpa.destroy(job);
    const owned_path = try self.gpa.dupe(u8, path);
    errdefer self.gpa.free(owned_path);
    self.lock.acquire();
    const id = self.ready.nextId();
    self.lock.release();
    job.* = .{ .owner = self, .id = id, .allocator = allocator, .cb = cb, .ctx = ctx, .path = owned_path };
    self.lock.acquire();
    defer self.lock.release();
    try self.reads.put(self.gpa, id, job);
    // Registered before it starts, so a task that finishes inline is already there for `pump`
    // to find. `concurrent` rather than `async`: a queued-but-not-yet-running task is what
    // overlaps the disk; when no thread is available (single-threaded `Io`) the read simply
    // happens here.
    job.future = self.io.concurrent(ReadJob.run, .{job}) catch blk: {
        var f: std.Io.Future(vfs.Error!vfs.Read) = .{ .any_future = null, .result = undefined };
        f.result = ReadJob.run(job);
        break :blk f;
    };
    return .{ .id = id };
}

fn writeImpl(self: *LocalFs, path: []const u8, bytes: []const u8, opts: vfs.WriteOptions) vfs.Error!void {
    if (opts.if_unmodified_ms) |expected| {
        const st = self.statImpl(path) catch |err| return if (err == error.NotFound) error.Conflict else err;
        if (st.modified_ms != expected) return error.Conflict;
    }
    std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = bytes }) catch |err| return mapErr(err);
}

fn writeFile(ptr: *anyopaque, path: []const u8, bytes: []const u8, opts: vfs.WriteOptions, cb: vfs.DoneFn, ctx: ?*anyopaque) vfs.Error!vfs.Job {
    const self: *LocalFs = @ptrCast(@alignCast(ptr));
    return self.queue(.{ .done = .{ .cb = cb, .ctx = ctx, .result = self.writeImpl(path, bytes, opts) } });
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
    self.lock.acquire();
    const read = self.reads.get(job.id);
    if (read) |r| r.cancelled = true;
    self.lock.release();
    if (read != null) return; // delivered as nothing by the next pump
    if (self.ready.remove(job.id)) |completion| completion.discard();
}

fn pump(ptr: *anyopaque) void {
    const self: *LocalFs = @ptrCast(@alignCast(ptr));
    // Reads that have landed, collected under the lock and delivered outside it: a callback may
    // start another read or cancel one.
    var done: std.ArrayListUnmanaged(*ReadJob) = .empty;
    defer done.deinit(self.gpa);
    {
        self.lock.acquire();
        defer self.lock.release();
        var i: usize = 0;
        while (i < self.reads.count()) {
            const job = self.reads.values()[i];
            if (job.done.load(.acquire)) {
                done.append(self.gpa, job) catch break;
                self.reads.swapRemoveAt(i);
            } else i += 1;
        }
    }
    for (done.items) |job| {
        const result = job.future.await(self.io);
        if (job.cancelled) {
            if (result) |r| job.allocator.free(r.bytes) else |_| {}
        } else {
            job.cb(job.ctx, result);
        }
        self.gpa.free(job.path);
        self.gpa.destroy(job);
    }
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

test "a read lands through pump" {
    if (no_disk) return error.SkipZigTest;
    const t = std.testing;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "hello" });
    const abs = try tmp.dir.realPathFileAlloc(io, "a.txt", t.allocator);
    defer t.allocator.free(abs);
    var local = LocalFs.init(t.allocator, io);
    defer local.deinit();
    const Sink = struct {
        got: ?[]u8 = null,
        fn onRead(ctx: ?*anyopaque, result: vfs.Error!vfs.Read) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.got = (result catch return).bytes;
        }
    };
    var sink: Sink = .{};
    _ = try local.fs().readFile(t.allocator, abs, Sink.onRead, &sink);
    var spins: usize = 0;
    while (sink.got == null and spins < 200_000) : (spins += 1) {
        local.fs().pump();
        std.Thread.yield() catch {};
    }
    defer if (sink.got) |g| t.allocator.free(g);
    try t.expectEqualStrings("hello", sink.got orelse return error.NeverLanded);
}
