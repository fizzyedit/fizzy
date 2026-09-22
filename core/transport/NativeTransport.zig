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
/// One client for every request: its connection pool is what makes the second request to a
/// host cheap (a per-request client re-read the CA bundle and re-did the TLS handshake every
/// time). `fetch` is safe from several threads at once; the pool is locked inside.
client: std.http.Client,
/// Wake the UI when a response is ready. Safe to call from any thread, or absent.
wake: ?*const fn () void = null,
/// Guards `jobs` and every job's `result`/`thread`. Every locked region is O(1) map work —
/// never the fetch itself — so a spinlock is fine, and it needs no `Io` to lock.
mutex: SpinLock = .{},
/// Every request started and not yet delivered or cancelled.
jobs: std.AutoArrayHashMapUnmanaged(u64, *Job) = .empty,
/// Cancelled while the worker was still inside `fetch` (which has no timeout). The worker
/// owns them from then on and destroys them when it returns — waiting for it here would stall
/// the UI thread for a round trip, or forever.
orphans: std.AutoArrayHashMapUnmanaged(u64, *Job) = .empty,
/// The job whose callback `pump` is inside; a cancel of it from that callback is a no-op.
delivering: ?*Job = null,
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
    /// `deinit` will join this thread and destroy the job; the worker must then leave both.
    joined_by_deinit: bool = false,
    /// Finished and picked up by the `pump` in progress, which will deliver or (if cancelled
    /// meanwhile by an earlier callback of the same batch) skip and destroy it.
    in_batch: bool = false,
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
    return .{ .gpa = gpa, .io = io, .client = .{ .allocator = gpa, .io = io }, .wake = wake };
}

/// Waits for every worker still running (the one place that does — the transport's memory
/// is about to go away under them); their responses are dropped.
pub fn deinit(self: *NativeTransport) void {
    var threads: std.ArrayListUnmanaged(std.Thread) = .empty;
    defer threads.deinit(self.gpa);
    {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.jobs.values()) |job| {
            job.cancelled = true;
            job.joined_by_deinit = true;
            if (job.thread) |t| threads.append(self.gpa, t) catch {};
        }
        for (self.orphans.values()) |job| {
            job.joined_by_deinit = true;
            if (job.thread) |t| threads.append(self.gpa, t) catch {};
        }
    }
    for (threads.items) |t| t.join();
    for (self.jobs.values()) |job| job.destroy();
    for (self.orphans.values()) |job| job.destroy();
    self.jobs.deinit(self.gpa);
    self.orphans.deinit(self.gpa);
    self.client.deinit();
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
    const wake = self.wake;
    self.mutex.lock();
    if (job.joined_by_deinit) {
        // `deinit` holds the thread handle and will join it, then destroy the job.
        job.result = result;
        self.mutex.unlock();
        return;
    }
    if (job.cancelled) {
        // Ours now (see `cancel`): nobody is listening. Free the response and the job; the
        // thread detaches itself since no one will join it.
        _ = self.orphans.swapRemove(job.id);
        if (job.thread) |t| t.detach();
        job.thread = null;
        self.mutex.unlock();
        if (result) |resp| resp.deinit(job.allocator) else |_| {}
        job.destroy();
        return;
    }
    job.result = result;
    if (job.thread) |t| {
        // A completed worker needs no join; `pump` frees the job.
        t.detach();
        job.thread = null;
    }
    self.mutex.unlock();
    if (wake) |w| w();
}

fn perform(job: *Job) vfs.Error!vfs.http.Response {
    const self = job.owner;
    var body: std.Io.Writer.Allocating = .init(job.allocator);
    errdefer body.deinit();

    const method: std.http.Method = switch (job.method) {
        .GET => .GET,
        .POST => .POST,
        .PATCH => .PATCH,
        .PUT => .PUT,
        .DELETE => .DELETE,
    };
    const result = self.client.fetch(.{
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
    if (self.delivering == job) {
        // Its own callback is what is cancelling it; `pump` destroys it once that returns.
        self.mutex.unlock();
        return;
    }
    _ = self.jobs.swapRemove(handle.id);
    job.cancelled = true;
    if (job.in_batch) {
        // `pump` is walking a batch this job is in; it skips and frees a cancelled one.
        self.mutex.unlock();
        return;
    }
    if (job.result == null) {
        // Still inside `fetch`. Never wait for that here (D9): hand the job to its worker.
        self.orphans.put(self.gpa, job.id, job) catch {};
        self.mutex.unlock();
        return;
    }
    // Finished: the worker is gone (detached) and nothing else holds the job.
    self.mutex.unlock();
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
            if (job.result != null and !job.in_batch) {
                job.in_batch = true;
                done.append(self.gpa, job) catch break;
            }
        }
    }
    // Outside the lock: a callback may start another request, or cancel a later job of this
    // batch — which is then skipped here rather than delivered.
    for (done.items) |job| {
        self.mutex.lock();
        const cancelled = job.cancelled;
        if (!cancelled) {
            _ = self.jobs.swapRemove(job.id);
            self.delivering = job;
        }
        self.mutex.unlock();
        if (!cancelled) {
            const result = job.result.?;
            job.result = null; // ownership of the body passes to the callback
            job.cb(job.ctx, result);
            self.mutex.lock();
            self.delivering = null;
            self.mutex.unlock();
        }
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
            ts.seen_method_len = @min(m.len, ts.seen_method.len);
            @memcpy(ts.seen_method[0..ts.seen_method_len], m[0..ts.seen_method_len]);
            var it = req.iterateHeaders();
            while (it.next()) |h| {
                if (std.ascii.eqlIgnoreCase(h.name, "authorization")) {
                    ts.seen_auth_len = @min(h.value.len, ts.seen_auth.len);
                    @memcpy(ts.seen_auth[0..ts.seen_auth_len], h.value[0..ts.seen_auth_len]);
                }
            }
            // Only where there *is* a body. For a method that cannot have one (the cancelled
            // GET this test makes second), `readerExpectNone` hands back `Reader.ending` — a
            // shared sentinel built by `@constCast` over a const global — and reading from it
            // writes `seek` straight through that const pointer. Windows enforces the read-only
            // page and the server thread dies with a segfault mid-test; macOS and Linux happen
            // not to, which is why this only ever failed on one runner.
            ts.seen_body_len = 0;
            if (req.head.method.requestHasBody()) {
                var body_buf: [256]u8 = undefined;
                const body_reader = req.readerExpectNone(&body_buf);
                ts.seen_body_len = body_reader.readSliceShort(&ts.seen_body) catch 0;
            }
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

test "cancel returns at once while the server is still holding the connection" {
    if (builtin.target.cpu.arch == .wasm32) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    // A listener that accepts and then never answers.
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try addr.listen(io, .{ .reuse_address = true });
    const Hold = struct {
        fn run(s: *std.Io.net.Server, held_io: std.Io, release: *std.atomic.Value(bool)) void {
            const stream = s.accept(held_io) catch return;
            while (!release.load(.acquire)) std.Io.sleep(held_io, .fromMicroseconds(1000), .awake) catch {};
            stream.close(held_io);
        }
    };
    var release: std.atomic.Value(bool) = .init(false);
    const holder = try std.Thread.spawn(.{}, Hold.run, .{ &server, io, &release });

    var nt = NativeTransport.init(a, io, null);
    const t = nt.transport();
    const url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/", .{server.socket.address.getPort()});
    defer a.free(url);
    var sink: Sink = .{ .allocator = a };
    const job = try t.request(a, .{ .method = .GET, .url = url }, Sink.onDone, &sink);
    std.Io.sleep(io, .fromMicroseconds(20_000), .awake) catch {};

    const before = std.Io.Clock.boot.now(io).nanoseconds;
    t.cancel(job);
    const took_ms = @divTrunc(std.Io.Clock.boot.now(io).nanoseconds - before, std.time.ns_per_ms);
    try std.testing.expect(took_ms < 100);
    try std.testing.expectEqual(@as(usize, 0), sink.calls);

    // Let the worker finish and free the orphan, then tear down.
    release.store(true, .release);
    holder.join();
    nt.deinit();
    server.deinit(io);
}
