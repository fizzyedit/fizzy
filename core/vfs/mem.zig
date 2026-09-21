//! In-memory `Fs` backend. Used by unit tests, and as the stand-in a host can mount while it
//! has no cloud session. Answers are ready immediately but still delivered from `pump`, so a
//! consumer exercised against `Mem` sees exactly the timing it will see against Drive.

const std = @import("std");
const Fs = @import("Fs.zig");
const http = @import("http.zig");
const Allocator = std.mem.Allocator;

pub const Mem = struct {
    allocator: Allocator,
    /// Keyed by full path (`/docs/a.txt`). The root `/` is always present.
    nodes: std.StringArrayHashMapUnmanaged(Node) = .empty,
    completions: http.Completions(Completion),
    /// Bumped by every mutation, so a holder (an archive that was unpacked into this) can tell
    /// whether anything changed since it last looked.
    generation: u64 = 0,

    pub const Node = struct {
        kind: Fs.Kind,
        bytes: []u8 = &.{},
        modified_ms: i64 = 0,
    };

    const Completion = union(enum) {
        list: struct { allocator: Allocator, cb: Fs.ListDirFn, ctx: ?*anyopaque, result: Fs.Error![]Fs.Entry },
        stat: struct { cb: Fs.StatFn, ctx: ?*anyopaque, result: Fs.Error!Fs.Stat },
        read: struct { allocator: Allocator, cb: Fs.ReadFn, ctx: ?*anyopaque, result: Fs.Error!Fs.Read },
        done: struct { cb: Fs.DoneFn, ctx: ?*anyopaque, result: Fs.Error!void },

        fn discard(self: Completion) void {
            switch (self) {
                .list => |c| if (c.result) |entries| Fs.freeEntries(c.allocator, entries) else |_| {},
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

    pub fn init(allocator: Allocator) Allocator.Error!Mem {
        var self: Mem = .{
            .allocator = allocator,
            .completions = .init(allocator),
        };
        errdefer self.deinit();
        try self.nodes.put(allocator, try allocator.dupe(u8, "/"), .{ .kind = .dir });
        return self;
    }

    pub fn deinit(self: *Mem) void {
        for (self.nodes.keys(), self.nodes.values()) |path, node| {
            self.allocator.free(path);
            if (node.bytes.len != 0) self.allocator.free(node.bytes);
        }
        self.nodes.deinit(self.allocator);
        for (self.completions.items.items) |item| item.payload.discard();
        self.completions.deinit();
    }

    pub fn fs(self: *Mem) Fs.Fs {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: Fs.Fs.VTable = .{
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

    /// Test convenience: put a file in place synchronously, creating no parents.
    pub fn put(self: *Mem, path: []const u8, bytes: []const u8) Fs.Error!void {
        try self.insert(path, .file, bytes);
    }

    /// Test convenience: a directory, synchronously, creating no parents.
    pub fn putDir(self: *Mem, path: []const u8) Fs.Error!void {
        try self.insert(path, .dir, &.{});
    }

    fn get(self: *Mem, path: []const u8) Fs.Error!*Node {
        return self.nodes.getPtr(path) orelse error.NotFound;
    }

    fn insert(self: *Mem, path: []const u8, kind: Fs.Kind, bytes: []const u8) Fs.Error!void {
        if (Fs.isRoot(path)) return error.Exists;
        const parent = try self.get(Fs.dirname(path));
        if (parent.kind != .dir) return error.NotADirectory;
        if (self.nodes.contains(path)) return error.Exists;
        const key = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(key);
        const copy = try self.allocator.dupe(u8, bytes);
        errdefer self.allocator.free(copy);
        try self.nodes.put(self.allocator, key, .{ .kind = kind, .bytes = copy });
        self.generation += 1;
    }

    fn hasChildren(self: *Mem, dir: []const u8) bool {
        for (self.nodes.keys()) |path| {
            if (!Fs.isRoot(path) and std.mem.eql(u8, Fs.dirname(path), dir)) return true;
        }
        return false;
    }

    fn queue(self: *Mem, completion: Completion) Fs.Error!Fs.Job {
        const id = self.completions.nextId();
        try self.completions.push(id, completion);
        return .{ .id = id };
    }

    fn listImpl(self: *Mem, allocator: Allocator, path: []const u8) Fs.Error![]Fs.Entry {
        const dir = try self.get(path);
        if (dir.kind != .dir) return error.NotADirectory;
        var list: std.ArrayList(Fs.Entry) = .empty;
        errdefer Fs.freeEntries(allocator, list.items);
        for (self.nodes.keys(), self.nodes.values()) |child_path, node| {
            if (Fs.isRoot(child_path) or !std.mem.eql(u8, Fs.dirname(child_path), path)) continue;
            try list.append(allocator, .{
                .name = try allocator.dupe(u8, Fs.basename(child_path)),
                .kind = node.kind,
                .size = node.bytes.len,
                .modified_ms = node.modified_ms,
            });
        }
        return try list.toOwnedSlice(allocator);
    }

    fn listDir(ptr: *anyopaque, allocator: Allocator, path: []const u8, cb: Fs.ListDirFn, ctx: ?*anyopaque) Fs.Error!Fs.Job {
        const self: *Mem = @ptrCast(@alignCast(ptr));
        return self.queue(.{ .list = .{ .allocator = allocator, .cb = cb, .ctx = ctx, .result = self.listImpl(allocator, path) } });
    }

    fn stat(ptr: *anyopaque, path: []const u8, cb: Fs.StatFn, ctx: ?*anyopaque) Fs.Error!Fs.Job {
        const self: *Mem = @ptrCast(@alignCast(ptr));
        const result: Fs.Error!Fs.Stat = if (self.get(path)) |node|
            .{ .kind = node.kind, .size = node.bytes.len, .modified_ms = node.modified_ms }
        else |err|
            err;
        return self.queue(.{ .stat = .{ .cb = cb, .ctx = ctx, .result = result } });
    }

    fn readImpl(self: *Mem, allocator: Allocator, path: []const u8) Fs.Error!Fs.Read {
        const node = try self.get(path);
        if (node.kind != .file) return error.NotAFile;
        return .{ .bytes = try allocator.dupe(u8, node.bytes), .modified_ms = node.modified_ms };
    }

    fn readFile(ptr: *anyopaque, allocator: Allocator, path: []const u8, cb: Fs.ReadFn, ctx: ?*anyopaque) Fs.Error!Fs.Job {
        const self: *Mem = @ptrCast(@alignCast(ptr));
        return self.queue(.{ .read = .{ .allocator = allocator, .cb = cb, .ctx = ctx, .result = self.readImpl(allocator, path) } });
    }

    fn writeImpl(self: *Mem, path: []const u8, bytes: []const u8, opts: Fs.WriteOptions) Fs.Error!void {
        // Create-or-replace, like a disk: a Save As onto a mount writes a file that is not
        // there yet.
        if (!self.nodes.contains(path)) {
            if (opts.if_unmodified_ms) |_| return error.Conflict; // it was there when read
            return self.insert(path, .file, bytes);
        }
        const node = try self.get(path);
        if (node.kind != .file) return error.NotAFile;
        if (opts.if_unmodified_ms) |expected| {
            if (node.modified_ms != expected) return error.Conflict;
        }
        const copy = try self.allocator.dupe(u8, bytes);
        if (node.bytes.len != 0) self.allocator.free(node.bytes);
        node.bytes = copy;
        node.modified_ms += 1;
        self.generation += 1;
    }

    fn writeFile(ptr: *anyopaque, path: []const u8, bytes: []const u8, opts: Fs.WriteOptions, cb: Fs.DoneFn, ctx: ?*anyopaque) Fs.Error!Fs.Job {
        const self: *Mem = @ptrCast(@alignCast(ptr));
        return self.queue(.{ .done = .{ .cb = cb, .ctx = ctx, .result = self.writeImpl(path, bytes, opts) } });
    }

    fn createFile(ptr: *anyopaque, path: []const u8, cb: Fs.DoneFn, ctx: ?*anyopaque) Fs.Error!Fs.Job {
        const self: *Mem = @ptrCast(@alignCast(ptr));
        return self.queue(.{ .done = .{ .cb = cb, .ctx = ctx, .result = self.insert(path, .file, &.{}) } });
    }

    fn mkdir(ptr: *anyopaque, path: []const u8, cb: Fs.DoneFn, ctx: ?*anyopaque) Fs.Error!Fs.Job {
        const self: *Mem = @ptrCast(@alignCast(ptr));
        return self.queue(.{ .done = .{ .cb = cb, .ctx = ctx, .result = self.insert(path, .dir, &.{}) } });
    }

    fn renameImpl(self: *Mem, path: []const u8, new_path: []const u8) Fs.Error!void {
        if (Fs.isRoot(path) or Fs.isRoot(new_path)) return error.Unsupported;
        if (std.mem.eql(u8, path, new_path)) return;
        // Into its own subtree would orphan everything beneath it.
        if (std.mem.startsWith(u8, new_path, path) and new_path[path.len] == '/') return error.Unsupported;
        _ = try self.get(path);
        const new_parent = try self.get(Fs.dirname(new_path));
        if (new_parent.kind != .dir) return error.NotADirectory;
        if (self.nodes.contains(new_path)) return error.Exists;

        // Every key at or beneath `path` gets its prefix swapped. Collected first: the map
        // must not be mutated while its keys are being walked.
        var moving: std.ArrayList([]const u8) = .empty;
        defer moving.deinit(self.allocator);
        for (self.nodes.keys()) |key| {
            if (std.mem.eql(u8, key, path) or (std.mem.startsWith(u8, key, path) and key[path.len] == '/')) {
                try moving.append(self.allocator, key);
            }
        }
        for (moving.items) |old_key| {
            const new_key = try std.mem.concat(self.allocator, u8, &.{ new_path, old_key[path.len..] });
            errdefer self.allocator.free(new_key);
            const kv = self.nodes.fetchOrderedRemove(old_key).?;
            try self.nodes.put(self.allocator, new_key, kv.value);
            self.allocator.free(kv.key);
        }
        self.generation += 1;
    }

    fn rename(ptr: *anyopaque, path: []const u8, new_path: []const u8, cb: Fs.DoneFn, ctx: ?*anyopaque) Fs.Error!Fs.Job {
        const self: *Mem = @ptrCast(@alignCast(ptr));
        return self.queue(.{ .done = .{ .cb = cb, .ctx = ctx, .result = self.renameImpl(path, new_path) } });
    }

    fn removeImpl(self: *Mem, path: []const u8) Fs.Error!void {
        if (Fs.isRoot(path)) return error.Unsupported;
        const node = try self.get(path);
        if (node.kind == .dir and self.hasChildren(path)) return error.NotEmpty;
        const kv = self.nodes.fetchOrderedRemove(path).?;
        self.allocator.free(kv.key);
        if (kv.value.bytes.len != 0) self.allocator.free(kv.value.bytes);
        self.generation += 1;
    }

    fn remove(ptr: *anyopaque, path: []const u8, cb: Fs.DoneFn, ctx: ?*anyopaque) Fs.Error!Fs.Job {
        const self: *Mem = @ptrCast(@alignCast(ptr));
        return self.queue(.{ .done = .{ .cb = cb, .ctx = ctx, .result = self.removeImpl(path) } });
    }

    fn cancel(ptr: *anyopaque, job: Fs.Job) void {
        const self: *Mem = @ptrCast(@alignCast(ptr));
        if (self.completions.remove(job.id)) |completion| completion.discard();
    }

    fn pump(ptr: *anyopaque) void {
        const self: *Mem = @ptrCast(@alignCast(ptr));
        self.completions.drain({}, struct {
            fn f(_: void, c: Completion) void {
                c.deliver();
            }
        }.f);
    }
};

// ---------------------------------------------------------------------------------------------

/// Test helper: the last result a callback saw, so a test can `pump()` and inspect.
const Sink = struct {
    allocator: Allocator,
    entries: ?[]Fs.Entry = null,
    bytes: ?[]u8 = null,
    stat: ?Fs.Stat = null,
    modified_ms: i64 = 0,
    err: ?Fs.Error = null,
    calls: usize = 0,

    fn reset(self: *Sink) void {
        if (self.entries) |e| Fs.freeEntries(self.allocator, e);
        if (self.bytes) |b| self.allocator.free(b);
        self.* = .{ .allocator = self.allocator };
    }

    fn onList(ctx: ?*anyopaque, result: Fs.Error![]Fs.Entry) void {
        const self: *Sink = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        self.entries = result catch |err| {
            self.err = err;
            return;
        };
    }
    fn onStat(ctx: ?*anyopaque, result: Fs.Error!Fs.Stat) void {
        const self: *Sink = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        self.stat = result catch |err| {
            self.err = err;
            return;
        };
    }
    fn onRead(ctx: ?*anyopaque, result: Fs.Error!Fs.Read) void {
        const self: *Sink = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        const r = result catch |err| {
            self.err = err;
            return;
        };
        self.bytes = r.bytes;
        self.modified_ms = r.modified_ms;
    }
    fn onDone(ctx: ?*anyopaque, result: Fs.Error!void) void {
        const self: *Sink = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        result catch |err| {
            self.err = err;
        };
    }
};

test "memory fs: list, read, write, mkdir, rename, remove" {
    const allocator = std.testing.allocator;
    var store = try Mem.init(allocator);
    defer store.deinit();
    const fs = store.fs();
    var sink: Sink = .{ .allocator = allocator };
    defer sink.reset();

    _ = try fs.mkdir("/docs", Sink.onDone, &sink);
    _ = try fs.createFile("/docs/hello.txt", Sink.onDone, &sink);
    // Nothing is delivered before pump — even though Mem already knows the answer.
    try std.testing.expectEqual(@as(usize, 0), sink.calls);
    fs.pump();
    try std.testing.expectEqual(@as(usize, 2), sink.calls);
    try std.testing.expect(sink.err == null);

    _ = try fs.writeFile("/docs/hello.txt", "hello world", .{}, Sink.onDone, &sink);
    fs.pump();
    sink.reset();
    _ = try fs.readFile(allocator, "/docs/hello.txt", Sink.onRead, &sink);
    fs.pump();
    try std.testing.expectEqualStrings("hello world", sink.bytes.?);

    sink.reset();
    _ = try fs.listDir(allocator, "/docs", Sink.onList, &sink);
    fs.pump();
    try std.testing.expectEqual(@as(usize, 1), sink.entries.?.len);
    try std.testing.expectEqualStrings("hello.txt", sink.entries.?[0].name);
    try std.testing.expectEqual(Fs.Kind.file, sink.entries.?[0].kind);
    try std.testing.expectEqual(@as(u64, 11), sink.entries.?[0].size);

    sink.reset();
    _ = try fs.stat("/docs/hello.txt", Sink.onStat, &sink);
    fs.pump();
    try std.testing.expectEqual(@as(u64, 11), sink.stat.?.size);

    // Move the directory: its contents come along.
    sink.reset();
    _ = try fs.rename("/docs", "/notes", Sink.onDone, &sink);
    fs.pump();
    try std.testing.expect(sink.err == null);
    sink.reset();
    _ = try fs.stat("/notes/hello.txt", Sink.onStat, &sink);
    fs.pump();
    try std.testing.expect(sink.stat != null);

    sink.reset();
    _ = try fs.remove("/notes", Sink.onDone, &sink);
    fs.pump();
    try std.testing.expectEqual(Fs.Error.NotEmpty, sink.err.?);
    sink.reset();
    _ = try fs.remove("/notes/hello.txt", Sink.onDone, &sink);
    _ = try fs.remove("/notes", Sink.onDone, &sink);
    fs.pump();
    try std.testing.expect(sink.err == null);
    sink.reset();
    _ = try fs.listDir(allocator, "/", Sink.onList, &sink);
    fs.pump();
    try std.testing.expectEqual(@as(usize, 0), sink.entries.?.len);
}

test "memory fs: rename into its own subtree is refused; writeFile creates" {
    const allocator = std.testing.allocator;
    var store = try Mem.init(allocator);
    defer store.deinit();
    const fs = store.fs();
    var sink: Sink = .{ .allocator = allocator };
    defer sink.reset();
    _ = try fs.mkdir("/a", Sink.onDone, &sink);
    _ = try fs.rename("/a", "/a/b", Sink.onDone, &sink);
    fs.pump();
    try std.testing.expectEqual(Fs.Error.Unsupported, sink.err.?);
    sink.reset();
    _ = try fs.writeFile("/a/new.txt", "fresh", .{}, Sink.onDone, &sink);
    fs.pump();
    try std.testing.expect(sink.err == null);
    sink.reset();
    _ = try fs.readFile(allocator, "/a/new.txt", Sink.onRead, &sink);
    fs.pump();
    try std.testing.expectEqualStrings("fresh", sink.bytes.?);
}

test "memory fs: a write with a stale modified time is a conflict, nothing written" {
    const allocator = std.testing.allocator;
    var store = try Mem.init(allocator);
    defer store.deinit();
    const fs = store.fs();
    var sink: Sink = .{ .allocator = allocator };
    defer sink.reset();
    try store.put("/f.txt", "v1");
    _ = try fs.readFile(allocator, "/f.txt", Sink.onRead, &sink);
    fs.pump();
    const seen = sink.modified_ms;
    // Someone else writes in between.
    _ = try fs.writeFile("/f.txt", "v2", .{}, Sink.onDone, &sink);
    fs.pump();
    sink.reset();
    _ = try fs.writeFile("/f.txt", "mine", .{ .if_unmodified_ms = seen }, Sink.onDone, &sink);
    fs.pump();
    try std.testing.expectEqual(Fs.Error.Conflict, sink.err.?);
    sink.reset();
    _ = try fs.readFile(allocator, "/f.txt", Sink.onRead, &sink);
    fs.pump();
    try std.testing.expectEqualStrings("v2", sink.bytes.?);
    // With the current time it goes through.
    const now_ms = sink.modified_ms;
    sink.reset();
    _ = try fs.writeFile("/f.txt", "mine", .{ .if_unmodified_ms = now_ms }, Sink.onDone, &sink);
    fs.pump();
    try std.testing.expect(sink.err == null);
}

test "memory fs: cancelling a later job from inside a callback skips it" {
    const allocator = std.testing.allocator;
    var store = try Mem.init(allocator);
    defer store.deinit();
    const fs = store.fs();
    const Chain = struct {
        fs: Fs.Fs,
        later: Fs.Job = .{ .id = 0 },
        later_calls: usize = 0,
        fn first(ctx: ?*anyopaque, _: Fs.Error![]Fs.Entry) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.fs.cancel(self.later);
        }
        fn second(ctx: ?*anyopaque, _: Fs.Error![]Fs.Entry) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.later_calls += 1;
        }
    };
    var chain: Chain = .{ .fs = fs };
    _ = try fs.listDir(allocator, "/", Chain.first, &chain);
    chain.later = try fs.listDir(allocator, "/", Chain.second, &chain);
    fs.pump();
    try std.testing.expectEqual(@as(usize, 0), chain.later_calls);
}

test "memory fs: cancel drops the callback" {
    const allocator = std.testing.allocator;
    var store = try Mem.init(allocator);
    defer store.deinit();
    const fs = store.fs();
    var sink: Sink = .{ .allocator = allocator };
    defer sink.reset();

    const job = try fs.listDir(allocator, "/", Sink.onList, &sink);
    fs.cancel(job);
    fs.pump();
    try std.testing.expectEqual(@as(usize, 0), sink.calls);
}

test "memory fs: errors arrive through the callback" {
    const allocator = std.testing.allocator;
    var store = try Mem.init(allocator);
    defer store.deinit();
    const fs = store.fs();
    var sink: Sink = .{ .allocator = allocator };
    defer sink.reset();

    _ = try fs.readFile(allocator, "/missing", Sink.onRead, &sink);
    fs.pump();
    try std.testing.expectEqual(Fs.Error.NotFound, sink.err.?);
    sink.reset();
    _ = try fs.createFile("/nope/x", Sink.onDone, &sink);
    fs.pump();
    try std.testing.expectEqual(Fs.Error.NotFound, sink.err.?);
}
