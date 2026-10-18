//! The control server's transport: HTTP/1.1 on a Unix socket only this user can open, served by
//! threads of its own (plans/CONTROL_SERVER_PLAN.md). Nothing here touches the app: a request is
//! handed to the UI thread (`take`, once a frame), and the connection's thread waits until it is
//! answered (`Request.answer`), then writes the response.
//!
//! Each connection has a thread of its own, so a client holding a connection open never makes
//! another wait, and keep-alive works as curl and every HTTP library expect. The UI thread answers
//! requests in the order they arrived. Idle, the server costs a thread blocked in `accept`.
//!
//! Lifted from the agent plugin's socket server (`fizzyedit/agent` `src/Server.zig`), which kept a
//! private ZON-lines wire behind a token; here the socket's permissions are the authorization.
//!
//! std-only, with a unit-test root of its own (`build/app.zig`).
const Server = @This();

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

/// The most a request body may hold. A command's arguments can be a whole drawing, but not this.
pub const max_body = 64 * 1024 * 1024;

gpa: std.mem.Allocator,
io: Io,
socket_path: []const u8,
/// Wakes the app so its next frame drains the queue. Safe from any thread.
wake: *const fn () void,
/// The accept loop (`run`), an `Io` task so `stop` can cancel its blocked `accept`: std interrupts
/// it on every OS (a signal on POSIX, a cancelled wait on Windows). Closing the listener under it
/// instead is `unreachable` in std's Windows `accept`, and connecting to the path to wake it
/// reaches whoever listens there now, which after a restart's handover is the next fizzy.
accept_task: ?Io.Future(void) = null,
/// Set by `start` before the accept task exists, so the task and `stop` only ever read it.
listener: ?Io.net.Server = null,
/// The connections being served, under `lock`, so `stop` can end their reads and wait for them.
conns: std.ArrayListUnmanaged(*Conn) = .empty,
stopping: std.atomic.Value(bool) = .init(false),
/// The socket file this server made, by inode: `stop` removes the path only while it is still
/// this one, not the socket a fizzy taking over has made there since.
socket_inode: ?Io.File.INode = null,
/// Requests waiting for the UI thread, under `lock`.
lock: Io.Mutex = .init,
pending: std.ArrayListUnmanaged(*Request) = .empty,

const Conn = struct {
    stream: Io.net.Stream,
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    /// A request of this connection's is queued or being answered, under `lock`: `stop` leaves its
    /// socket open so the answer ("fizzy is closing") can still be written.
    waiting: bool = false,
};

/// One request on its way through the UI thread. Everything in it lives in the connection's
/// arena until it is answered.
pub const Request = struct {
    method: std.http.Method,
    /// The path and query, as sent: `/commands/text.insert?x=1`.
    target: []const u8,
    content_type: ?[]const u8,
    body: []const u8,
    /// Set by `answer`. `body` is `gpa`-owned and the connection's thread frees it.
    response: Response = .{},
    done: Io.Event = .unset,

    /// The path without its query.
    pub fn path(self: *const Request) []const u8 {
        return self.target[0 .. std.mem.indexOfScalar(u8, self.target, '?') orelse self.target.len];
    }

    /// Answer, from the UI thread. `body` is copied with the server's `gpa`.
    pub fn answer(self: *Request, server: *Server, status: std.http.Status, content_type: []const u8, body: []const u8) void {
        self.response = .{
            .status = status,
            .content_type = content_type,
            .body = server.gpa.dupe(u8, body) catch null,
        };
        if (self.response.body == null) self.response.status = .internal_server_error;
        self.done.set(server.io);
    }
};

pub const Response = struct {
    status: std.http.Status = .internal_server_error,
    /// Static: a string literal, never freed.
    content_type: []const u8 = "text/plain",
    body: ?[]u8 = null,
};

/// Listen, then serve on a thread of its own. Everything that can fail happens here, on the
/// caller's thread, so a server that returns is one that listens.
pub fn start(self: *Server) !void {
    // Windows has AF_UNIX from 10 1803, and std offers it only to a target whose minimum is that
    // (`std.Io.net.has_unix_sockets`); fizzy's build sets it.
    if (!Io.net.has_unix_sockets) return error.UnixSocketsUnsupported;
    const addr = try Io.net.UnixAddress.init(self.socket_path);
    // A socket left by a fizzy that did not quit cleanly, or one a fizzy this one takes over from
    // still holds: this run's now. The other leaves it alone at its stop (`socket_inode`).
    Io.Dir.deleteFileAbsolute(self.io, self.socket_path) catch {};
    self.listener = try addr.listen(self.io, .{});
    errdefer {
        self.listener.?.deinit(self.io);
        self.listener = null;
    }
    if (comptime builtin.os.tag != .windows) {
        // This user only. The umask usually says so already; a shared machine's may not.
        try Io.Dir.cwd().setFilePermissions(self.io, self.socket_path, .fromMode(0o600), .{});
        // Not on Windows, where the socket is a reparse point `statFile` cannot open: there this
        // server leaves its socket behind at `stop`, and the next one deletes it (above).
        if (Io.Dir.cwd().statFile(self.io, self.socket_path, .{})) |st| self.socket_inode = st.inode else |_| {}
    }
    self.accept_task = try self.io.concurrent(run, .{self});
}

/// Requests the UI thread should answer now. On the UI thread, each frame; each must be answered.
pub fn take(self: *Server, out: *std.ArrayListUnmanaged(*Request)) void {
    self.lock.lockUncancelable(self.io);
    defer self.lock.unlock(self.io);
    out.appendSlice(self.gpa, self.pending.items) catch return;
    self.pending.clearRetainingCapacity();
}

pub fn stop(self: *Server) void {
    self.stopping.store(true, .release);
    {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        // Whatever the UI thread will never answer now, answered: its connection's thread is
        // waiting, and writes it before it sees `stopping` and ends.
        for (self.pending.items) |r| r.answer(self, .service_unavailable, "text/plain", "fizzy is closing\n");
        self.pending.clearRetainingCapacity();
        // The rest are reading their next request: end those reads. Only the ones still open,
        // since shutting down a closed descriptor is a panic in std.
        for (self.conns.items) |c| if (!c.done.load(.acquire) and !c.waiting) c.stream.shutdown(self.io, .both) catch {};
    }
    if (self.accept_task) |*t| t.cancel(self.io);
    self.accept_task = null;
    // No more are accepted: wait for each connection's thread, its read ended above.
    for (self.conns.items) |c| {
        if (c.thread) |t| t.join();
        self.gpa.destroy(c);
    }
    self.conns.deinit(self.gpa);
    if (self.listener) |*l| l.deinit(self.io);
    self.listener = null;
    if (self.socket_inode) |ours| {
        if (Io.Dir.cwd().statFile(self.io, self.socket_path, .{})) |st| {
            if (st.inode == ours) Io.Dir.deleteFileAbsolute(self.io, self.socket_path) catch {};
        } else |_| {}
    }
    self.pending.deinit(self.gpa);
}

fn run(self: *Server) void {
    var listener = self.listener.?;
    while (!self.stopping.load(.acquire)) {
        const stream = listener.accept(self.io) catch |err| switch (err) {
            error.Canceled => return,
            // Out of descriptors, say: let it pass rather than spin. Cancelable, like `accept`.
            else => {
                self.io.sleep(.fromMilliseconds(50), .awake) catch return;
                continue;
            },
        };
        if (self.stopping.load(.acquire)) {
            stream.close(self.io);
            return;
        }
        const conn = self.gpa.create(Conn) catch {
            stream.close(self.io);
            continue;
        };
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        conn.* = .{ .stream = stream };
        self.reap();
        self.conns.append(self.gpa, conn) catch {
            stream.close(self.io);
            self.gpa.destroy(conn);
            continue;
        };
        conn.thread = std.Thread.spawn(.{}, serveConn, .{ self, conn }) catch {
            _ = self.conns.pop();
            stream.close(self.io);
            self.gpa.destroy(conn);
            continue;
        };
    }
}

fn serveConn(self: *Server, conn: *Conn) void {
    self.serve(conn);
    // Closed under `lock`, with `done`, so `stop` never shuts down a descriptor already closed.
    self.lock.lockUncancelable(self.io);
    defer self.lock.unlock(self.io);
    conn.stream.close(self.io);
    conn.done.store(true, .release);
}

/// Join and free connections whose clients have gone. Under `lock`.
fn reap(self: *Server) void {
    var i: usize = 0;
    while (i < self.conns.items.len) {
        const c = self.conns.items[i];
        if (!c.done.load(.acquire)) {
            i += 1;
            continue;
        }
        if (c.thread) |t| t.join();
        self.gpa.destroy(c);
        _ = self.conns.swapRemove(i);
    }
}

/// Answer without reading the body, then close: nothing after it on the stream can be trusted to
/// be the next request.
fn refuse(head: *std.http.Server.Request, status: std.http.Status, message: []const u8) void {
    // Answered without a `100 Continue` first: the client is not told to send what is refused.
    head.head.expect = null;
    head.respond(message, .{ .status = status, .keep_alive = false }) catch {};
}

fn serve(self: *Server, conn: *Conn) void {
    var read_buf: [64 * 1024]u8 = undefined;
    var write_buf: [16 * 1024]u8 = undefined;
    var reader = conn.stream.reader(self.io, &read_buf);
    var writer = conn.stream.writer(self.io, &write_buf);
    var http: std.http.Server = .init(&reader.interface, &writer.interface);
    while (!self.stopping.load(.acquire)) {
        var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var head = http.receiveHead() catch return;
        if (head.head.expect) |e| if (!std.ascii.eqlIgnoreCase(e, "100-continue"))
            return refuse(&head, .expectation_failed, "only Expect: 100-continue is understood\n");
        if (head.head.content_length) |n| if (n > max_body)
            return refuse(&head, .payload_too_large, "request body too large\n");
        // std reads no body for GET and HEAD, so one sent would be taken for the next request.
        const sends_body = (head.head.content_length orelse 0) > 0 or head.head.transfer_encoding != .none;
        if (sends_body and !head.head.method.requestHasBody())
            return refuse(&head, .bad_request, "a GET or HEAD takes no body\n");
        // Copied before the body is read: reading it invalidates the head's strings.
        var req: Request = .{
            .method = head.head.method,
            .target = arena.dupe(u8, head.head.target) catch return,
            .content_type = if (head.head.content_type) |t| arena.dupe(u8, t) catch return else null,
            .body = "",
        };
        var body_buf: [4096]u8 = undefined;
        const body_reader = head.readerExpectContinue(&body_buf) catch return;
        req.body = body_reader.allocRemaining(arena, .limited(max_body)) catch |err| switch (err) {
            error.StreamTooLong => return refuse(&head, .payload_too_large, "request body too large\n"),
            else => return,
        };
        {
            self.lock.lockUncancelable(self.io);
            defer self.lock.unlock(self.io);
            // `stop` answers what is queued before it joins: nothing may be queued after.
            if (self.stopping.load(.acquire)) return;
            self.pending.append(self.gpa, &req) catch return;
            conn.waiting = true;
        }
        self.wake();
        // Uncancelable: `&req` is queued, and an early return would leave the UI thread writing
        // into a frame that is gone.
        req.done.waitUncancelable(self.io);
        const body = req.response.body orelse "out of memory\n";
        defer if (req.response.body) |b| self.gpa.free(b);
        const sent = head.respond(body, .{
            .status = req.response.status,
            .extra_headers = &.{.{ .name = "content-type", .value = req.response.content_type }},
        });
        {
            self.lock.lockUncancelable(self.io);
            defer self.lock.unlock(self.io);
            conn.waiting = false;
        }
        sent catch return;
        if (!head.head.keep_alive) return;
    }
}

// ---- tests ---------------------------------------------------------------------------------

fn noWake() void {}

const TestClient = struct {
    io: Io,
    path: []const u8,
    request: []const u8,
    reply: [8192]u8 = undefined,
    reply_len: usize = 0,

    fn run(self: *TestClient) void {
        const addr = Io.net.UnixAddress.init(self.path) catch return;
        // `start` has returned, so the server listens.
        const stream = addr.connect(self.io) catch return;
        defer stream.close(self.io);
        var wbuf: [1024]u8 = undefined;
        var w = stream.writer(self.io, &wbuf);
        w.interface.writeAll(self.request) catch return;
        w.interface.flush() catch return;
        var rbuf: [1024]u8 = undefined;
        var r = stream.reader(self.io, &rbuf);
        self.reply_len = r.interface.readSliceShort(&self.reply) catch 0;
    }
};

test "a request reaches the UI thread and its answer goes back" {
    if (!Io.net.has_unix_sockets) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir);
    const path = try std.fs.path.join(gpa, &.{ dir, "c.sock" });
    defer gpa.free(path);

    var server: Server = .{ .gpa = gpa, .io = io, .socket_path = path, .wake = noWake };
    try server.start();
    defer server.stop();

    var client: TestClient = .{
        .io = io,
        .path = path,
        .request = "POST /commands/test.echo?x=1 HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\n" ++
            "Content-Length: 11\r\nConnection: close\r\n\r\n{\"line\":12}",
    };
    const thread = try std.Thread.spawn(.{}, TestClient.run, .{&client});

    // The UI thread's side: take what came, answer it.
    var taken: std.ArrayListUnmanaged(*Request) = .empty;
    defer taken.deinit(gpa);
    var waited: usize = 0;
    while (taken.items.len == 0 and waited < 2000) : (waited += 1) {
        server.take(&taken);
        if (taken.items.len == 0) io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expectEqual(@as(usize, 1), taken.items.len);
    const req = taken.items[0];
    try std.testing.expectEqual(std.http.Method.POST, req.method);
    try std.testing.expectEqualStrings("/commands/test.echo", req.path());
    try std.testing.expectEqualStrings("application/json", req.content_type.?);
    try std.testing.expectEqualStrings("{\"line\":12}", req.body);
    req.answer(&server, .ok, "application/json", "{\"ok\":true}");
    thread.join();

    const reply = client.reply[0..client.reply_len];
    try std.testing.expect(std.mem.startsWith(u8, reply, "HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, reply, "content-type: application/json\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, reply, "\r\n\r\n{\"ok\":true}"));

    // Only this user may open it.
    if (builtin.os.tag == .windows) return;
    const st = try Io.Dir.cwd().statFile(io, path, .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), st.permissions.toMode() & 0o777);
}

fn testSocket(gpa: std.mem.Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(dir);
    return std.fs.path.join(gpa, &.{ dir, "c.sock" });
}

test "a request still queued at quit is answered: fizzy is closing" {
    if (!Io.net.has_unix_sockets) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testSocket(gpa, &tmp);
    defer gpa.free(path);

    var server: Server = .{ .gpa = gpa, .io = io, .socket_path = path, .wake = noWake };
    try server.start();
    var client: TestClient = .{ .io = io, .path = path, .request = "POST /commands/x HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n" };
    const thread = try std.Thread.spawn(.{}, TestClient.run, .{&client});
    // Queued, and never taken: the app is quitting.
    var waited: usize = 0;
    while (waited < 2000) : (waited += 1) {
        server.lock.lockUncancelable(io);
        const n = server.pending.items.len;
        server.lock.unlock(io);
        if (n == 1) break;
        io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    server.stop();
    thread.join();
    const reply = client.reply[0..client.reply_len];
    try std.testing.expect(std.mem.startsWith(u8, reply, "HTTP/1.1 503 Service Unavailable\r\n"));
    try std.testing.expect(std.mem.endsWith(u8, reply, "fizzy is closing\n"));
}

test "what cannot be served is refused before its body, and never reaches the app" {
    if (!Io.net.has_unix_sockets) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testSocket(gpa, &tmp);
    defer gpa.free(path);

    var server: Server = .{ .gpa = gpa, .io = io, .socket_path = path, .wake = noWake };
    try server.start();
    defer server.stop();
    const cases = [_]struct { request: []const u8, status: []const u8 }{
        // Too large: refused without a `100 Continue` that would invite the bytes.
        .{ .request = "POST /x HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 999999999\r\n\r\n", .status = "HTTP/1.1 413 " },
        .{ .request = "POST /x HTTP/1.1\r\nHost: x\r\nExpect: something-else\r\nContent-Length: 2\r\n\r\n{}", .status = "HTTP/1.1 417 " },
        // A body on a GET would otherwise be read as the next request.
        .{ .request = "GET / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello", .status = "HTTP/1.1 400 " },
    };
    for (cases) |case| {
        var client: TestClient = .{ .io = io, .path = path, .request = case.request };
        client.run();
        const reply = client.reply[0..client.reply_len];
        try std.testing.expect(std.mem.startsWith(u8, reply, case.status));
        try std.testing.expect(std.mem.indexOf(u8, reply, "100 Continue") == null);
    }
    var taken: std.ArrayListUnmanaged(*Request) = .empty;
    defer taken.deinit(gpa);
    server.take(&taken);
    try std.testing.expectEqual(@as(usize, 0), taken.items.len);
}

test "a socket path the OS cannot hold fails at start, not later" {
    if (!Io.net.has_unix_sockets) return error.SkipZigTest;
    const long = "/" ++ "d" ** (Io.net.UnixAddress.max_len + 8);
    var server: Server = .{ .gpa = std.testing.allocator, .io = std.testing.io, .socket_path = long, .wake = noWake };
    try std.testing.expectError(error.NameTooLong, server.start());
}

test "a server that took over the path keeps it when the old one stops" {
    if (!Io.net.has_unix_sockets) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testSocket(gpa, &tmp);
    defer gpa.free(path);

    // A restart's handover: the new fizzy listens on the profile's socket while the old runs.
    var old: Server = .{ .gpa = gpa, .io = io, .socket_path = path, .wake = noWake };
    try old.start();
    var new: Server = .{ .gpa = gpa, .io = io, .socket_path = path, .wake = noWake };
    try new.start();
    defer new.stop();
    // The old one stops without waking, or deleting, the new one's socket.
    old.stop();

    var client: TestClient = .{ .io = io, .path = path, .request = "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n" };
    const thread = try std.Thread.spawn(.{}, TestClient.run, .{&client});
    var taken: std.ArrayListUnmanaged(*Request) = .empty;
    defer taken.deinit(gpa);
    var waited: usize = 0;
    while (taken.items.len == 0 and waited < 2000) : (waited += 1) {
        new.take(&taken);
        if (taken.items.len == 0) io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expectEqual(@as(usize, 1), taken.items.len);
    taken.items[0].answer(&new, .ok, "text/plain", "new");
    thread.join();
    try std.testing.expect(std.mem.endsWith(u8, client.reply[0..client.reply_len], "\r\n\r\nnew"));
}
