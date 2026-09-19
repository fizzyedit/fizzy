//! `vfs.http.Transport` over `std.http.Client`, for the desktop builds.
//!
//! Each request runs on its own thread — a blocking `fetch` on the UI thread would stall a
//! frame for a whole round trip — and parks its response under a mutex. `pump` drains them on
//! the caller's thread, which is the transport contract. `wake` (the host's refresh) is called
//! from the worker when a response lands so the next frame runs without waiting for input.
const std = @import("std");
const builtin = @import("builtin");
const vfs = @import("../vfs/vfs.zig");

const NativeTransport = @This();

gpa: std.mem.Allocator,
io: std.Io,
/// Wake the UI when a response is ready. Safe to call from any thread, or absent.
wake: ?*const fn () void = null,
/// Guards `jobs` and every job's `result`/`thread`. Every locked region is O(1) map work —
/// never the fetch itself — so a spinlock is fine, and it needs no `Io` to lock.
mutex: SpinLock = .{},
/// Every request started and not yet delivered or cancelled.
jobs: std.AutoArrayHashMapUnmanaged(u64, *Job) = .empty,
next_id: u64 = 1,

const SpinLock = struct {
    inner: std.atomic.Mutex = .unlocked,

    fn lock(self: *SpinLock) void {
        while (!self.inner.tryLock()) std.Thread.yield() catch {};
    }
    fn unlock(self: *SpinLock) void {
        self.inner.unlock();
    }
};

const Job = struct {
    owner: *NativeTransport,
    id: u64,
    allocator: std.mem.Allocator,
    cb: vfs.http.DoneFn,
    ctx: ?*anyopaque,
    method: vfs.http.Method,
    url: []u8,
    headers: []std.http.Header,
    body: []u8,
    /// Written by the worker under the owner's mutex, read by `pump` under it.
    result: ?vfs.Error!vfs.http.Response = null,
    cancelled: bool = false,
    thread: ?std.Thread = null,

    fn destroy(job: *Job) void {
        const a = job.owner.gpa;
        for (job.headers) |h| {
            a.free(h.name);
            a.free(h.value);
        }
        a.free(job.headers);
        a.free(job.url);
        a.free(job.body);
        if (job.result) |r| {
            if (r) |resp| resp.deinit(job.allocator) else |_| {}
        }
        a.destroy(job);
    }
};

pub fn init(gpa: std.mem.Allocator, io: std.Io, wake: ?*const fn () void) NativeTransport {
    return .{ .gpa = gpa, .io = io, .wake = wake };
}

/// Waits for every worker still running; their responses are dropped.
pub fn deinit(self: *NativeTransport) void {
    var threads: std.ArrayListUnmanaged(std.Thread) = .empty;
    defer threads.deinit(self.gpa);
    {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.jobs.values()) |job| {
            job.cancelled = true;
            if (job.thread) |t| threads.append(self.gpa, t) catch {};
        }
    }
    for (threads.items) |t| t.join();
    for (self.jobs.values()) |job| job.destroy();
    self.jobs.deinit(self.gpa);
}

pub fn transport(self: *NativeTransport) vfs.http.Transport {
    return .{ .ptr = self, .vtable = &vtable };
}

const vtable: vfs.http.Transport.VTable = .{ .request = request, .cancel = cancel, .pump = pump };

fn request(ptr: *anyopaque, allocator: std.mem.Allocator, req: vfs.http.Request, cb: vfs.http.DoneFn, ctx: ?*anyopaque) vfs.Error!vfs.http.Job {
    const self: *NativeTransport = @ptrCast(@alignCast(ptr));
    if (comptime builtin.target.cpu.arch == .wasm32) return error.Unsupported;
    const a = self.gpa;

    const job = try a.create(Job);
    errdefer a.destroy(job);
    job.* = .{
        .owner = self,
        .id = 0,
        .allocator = allocator,
        .cb = cb,
        .ctx = ctx,
        .method = req.method,
        .url = try a.dupe(u8, req.url),
        .headers = &.{},
        .body = &.{},
    };
    errdefer a.free(job.url);
    job.body = try a.dupe(u8, req.body);
    errdefer a.free(job.body);
    const headers = try a.alloc(std.http.Header, req.headers.len);
    var filled: usize = 0;
    errdefer {
        for (headers[0..filled]) |h| {
            a.free(h.name);
            a.free(h.value);
        }
        a.free(headers);
    }
    for (req.headers, 0..) |h, i| {
        headers[i] = .{ .name = try a.dupe(u8, h.name), .value = try a.dupe(u8, h.value) };
        filled = i + 1;
    }
    job.headers = headers;

    self.mutex.lock();
    defer self.mutex.unlock();
    job.id = self.next_id;
    self.next_id += 1;
    try self.jobs.put(a, job.id, job);
    job.thread = std.Thread.spawn(.{}, worker, .{job}) catch |err| {
        _ = self.jobs.swapRemove(job.id);
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.Io,
        };
    };
    return .{ .id = job.id };
}

fn worker(job: *Job) void {
    const result = perform(job);
    const self = job.owner;
    self.mutex.lock();
    job.result = result;
    if (job.thread) |t| {
        // The job outlives this thread only through `pump` or `deinit`, both of which join or
        // detach it; a completed worker needs no join.
        t.detach();
        job.thread = null;
    }
    self.mutex.unlock();
    if (self.wake) |w| w();
}

fn perform(job: *Job) vfs.Error!vfs.http.Response {
    const self = job.owner;
    var client: std.http.Client = .{ .allocator = self.gpa, .io = self.io };
    defer client.deinit();

    var body: std.Io.Writer.Allocating = .init(job.allocator);
    errdefer body.deinit();

    const method: std.http.Method = switch (job.method) {
        .GET => .GET,
        .POST => .POST,
        .PATCH => .PATCH,
        .PUT => .PUT,
        .DELETE => .DELETE,
    };
    const result = client.fetch(.{
        .location = .{ .url = job.url },
        .method = method,
        .payload = if (job.body.len != 0) job.body else null,
        .extra_headers = job.headers,
        .response_writer = &body.writer,
    }) catch return error.Http;
    const bytes = body.toOwnedSlice() catch return error.OutOfMemory;
    return .{ .status = @intFromEnum(result.status), .body = bytes };
}

fn cancel(ptr: *anyopaque, handle: vfs.http.Job) void {
    const self: *NativeTransport = @ptrCast(@alignCast(ptr));
    self.mutex.lock();
    const job = self.jobs.get(handle.id) orelse {
        self.mutex.unlock();
        return;
    };
    _ = self.jobs.swapRemove(handle.id);
    job.cancelled = true;
    const thread = job.thread;
    job.thread = null;
    self.mutex.unlock();
    // The worker may still be inside `fetch`; wait for it rather than free under its feet.
    if (thread) |t| t.join();
    job.destroy();
}

fn pump(ptr: *anyopaque) void {
    const self: *NativeTransport = @ptrCast(@alignCast(ptr));
    var done: std.ArrayListUnmanaged(*Job) = .empty;
    defer done.deinit(self.gpa);
    {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.jobs.values()) |job| {
            if (job.result != null) done.append(self.gpa, job) catch break;
        }
        for (done.items) |job| _ = self.jobs.swapRemove(job.id);
    }
    // Outside the lock: a callback may start another request.
    for (done.items) |job| {
        const result = job.result.?;
        job.result = null; // ownership of the body passes to the callback
        job.cb(job.ctx, result);
        job.destroy();
    }
}

// ---- test: a loopback server answers, the transport delivers from pump ------------------------

const TestServer = struct {
    io: std.Io,
    server: std.Io.net.Server,
    thread: ?std.Thread = null,
    /// What the last request looked like, for the test to check.
    seen_method: [8]u8 = undefined,
    seen_method_len: usize = 0,
    seen_auth: [64]u8 = undefined,
    seen_auth_len: usize = 0,
    seen_body: [256]u8 = undefined,
    seen_body_len: usize = 0,
    requests: usize = 0,

    fn start(io: std.Io) !*TestServer {
        const ts = try std.testing.allocator.create(TestServer);
        errdefer std.testing.allocator.destroy(ts);
        const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        ts.* = .{ .io = io, .server = try addr.listen(io, .{ .reuse_address = true }) };
        ts.thread = try std.Thread.spawn(.{}, serve, .{ts});
        return ts;
    }

    fn port(ts: *const TestServer) u16 {
        return ts.server.socket.address.getPort();
    }

    /// Two requests, then done: one the test checks, one the transport is cancelled on.
    fn serve(ts: *TestServer) void {
        var n: usize = 0;
        while (n < 2) : (n += 1) {
            const stream = ts.server.accept(ts.io) catch return;
            defer stream.close(ts.io);
            var in_buf: [4096]u8 = undefined;
            var out_buf: [4096]u8 = undefined;
            var reader = stream.reader(ts.io, &in_buf);
            var writer = stream.writer(ts.io, &out_buf);
            var http_server = std.http.Server.init(&reader.interface, &writer.interface);
            var req = http_server.receiveHead() catch return;
            ts.requests += 1;
            const m = @tagName(req.head.method);
            @memcpy(ts.seen_method[0..m.len], m);
            ts.seen_method_len = m.len;
            var it = req.iterateHeaders();
            while (it.next()) |h| {
                if (std.ascii.eqlIgnoreCase(h.name, "authorization")) {
                    @memcpy(ts.seen_auth[0..h.value.len], h.value);
                    ts.seen_auth_len = h.value.len;
                }
            }
            var body_buf: [256]u8 = undefined;
            const body_reader = req.readerExpectNone(&body_buf);
            const got = body_reader.readSliceShort(&ts.seen_body) catch 0;
            ts.seen_body_len = got;
            req.respond("pong", .{ .status = .created, .keep_alive = false }) catch return;
        }
    }

    fn stop(ts: *TestServer) void {
        // Unblock `accept` if the second request never came.
        ts.server.deinit(ts.io);
        if (ts.thread) |t| t.join();
        std.testing.allocator.destroy(ts);
    }
};

const Sink = struct {
    calls: usize = 0,
    status: u16 = 0,
    body: ?[]u8 = null,
    err: ?vfs.Error = null,
    allocator: std.mem.Allocator,
    fn onDone(ctx: ?*anyopaque, result: vfs.Error!vfs.http.Response) void {
        const self: *Sink = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        const resp = result catch |err| {
            self.err = err;
            return;
        };
        self.status = resp.status;
        self.body = resp.body;
    }
};

test "a request round-trips through a loopback server and lands from pump" {
    if (builtin.target.cpu.arch == .wasm32) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    const ts = try TestServer.start(io);
    defer ts.stop();

    var nt = NativeTransport.init(a, io, null);
    defer nt.deinit();
    const t = nt.transport();

    const url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/files?x=1", .{ts.port()});
    defer a.free(url);
    var sink: Sink = .{ .allocator = a };
    defer if (sink.body) |b| a.free(b);
    _ = try t.request(a, .{
        .method = .PATCH,
        .url = url,
        .headers = &.{.{ .name = "Authorization", .value = "Bearer tok" }},
        .body = "{\"trashed\":true}",
    }, Sink.onDone, &sink);

    // Never delivered from the worker: only from pump, on this thread.
    var spins: usize = 0;
    while (sink.calls == 0) : (spins += 1) {
        if (spins > 5000) return error.NoResponse;
        t.pump();
        std.Io.sleep(io, .fromMicroseconds(1000), .awake) catch {};
    }
    if (sink.err) |e| {
        std.debug.print("transport error: {t} (server saw {d} requests)\n", .{ e, ts.requests });
        return e;
    }
    try std.testing.expectEqual(@as(u16, 201), sink.status);
    try std.testing.expectEqualStrings("pong", sink.body.?);
    try std.testing.expectEqualStrings("PATCH", ts.seen_method[0..ts.seen_method_len]);
    try std.testing.expectEqualStrings("Bearer tok", ts.seen_auth[0..ts.seen_auth_len]);
    try std.testing.expectEqualStrings("{\"trashed\":true}", ts.seen_body[0..ts.seen_body_len]);

    // A cancelled request never calls back and leaks nothing, even if it already completed.
    var sink2: Sink = .{ .allocator = a };
    const job = try t.request(a, .{ .method = .GET, .url = url }, Sink.onDone, &sink2);
    t.cancel(job);
    t.pump();
    try std.testing.expectEqual(@as(usize, 0), sink2.calls);
}
