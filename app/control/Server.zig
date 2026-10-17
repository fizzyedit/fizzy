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

const has_wake_pipe = builtin.os.tag != .windows;
/// The most a request body may hold. A command's arguments can be a whole drawing, but not this.
pub const max_body = 64 * 1024 * 1024;

gpa: std.mem.Allocator,
io: Io,
socket_path: []const u8,
/// Wakes the app so its next frame drains the queue. Safe from any thread.
wake: *const fn () void,
thread: ?std.Thread = null,
listener: ?Io.net.Server = null,
/// The connections being served, under `lock`, so `stop` can end their reads and wait for them.
conns: std.ArrayListUnmanaged(*Conn) = .empty,
stopping: std.atomic.Value(bool) = .init(false),
/// A pipe `stop` writes to, which wakes the thread waiting to accept (`run`). Connecting to the
/// socket's path would reach whoever listens there now, which is not always this server: a fizzy
/// taking over from this one (a restart's handover, on the same profile) has made the path its
/// own. Not on Windows, whose sockets are handles, not descriptors to poll beside a pipe: there
/// `stop` connects.
wake_pipe: if (has_wake_pipe) [2]std.c.fd_t else void = if (has_wake_pipe) .{ -1, -1 } else {},
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

pub fn start(self: *Server) !void {
    // Windows has AF_UNIX from 10 1803, and std offers it only to a target whose minimum is that
    // (`std.Io.net.has_unix_sockets`); fizzy's build sets it.
    if (!Io.net.has_unix_sockets) return error.UnixSocketsUnsupported;
    self.thread = try std.Thread.spawn(.{}, run, .{self});
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
    // Whatever the UI thread will never answer now, answered: its connection's thread is waiting.
    {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        for (self.pending.items) |r| r.answer(self, .service_unavailable, "text/plain", "fizzy is closing\n");
        self.pending.clearRetainingCapacity();
        // Only the ones still open: shutting down a closed descriptor is a panic in std.
        for (self.conns.items) |c| if (!c.done.load(.acquire)) c.stream.shutdown(self.io, .both) catch {};
    }
    if (has_wake_pipe and self.wake_pipe[1] >= 0) {
        _ = std.c.write(self.wake_pipe[1], "x", 1);
    } else if (Io.net.UnixAddress.init(self.socket_path)) |addr| {
        // No pipe: a thread in `accept` wakes when someone connects, so be that someone.
        if (addr.connect(self.io)) |s| s.close(self.io) else |_| {}
    } else |_| {}
    if (self.thread) |t| t.join();
    self.thread = null;
    if (has_wake_pipe) for (&self.wake_pipe) |*fd| if (fd.* >= 0) {
        _ = std.c.close(fd.*);
        fd.* = -1;
    };
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
    const addr = Io.net.UnixAddress.init(self.socket_path) catch {
        std.log.err("control: the socket path is too long for the OS: {s}", .{self.socket_path});
        return;
    };
    // A socket left by a fizzy that did not quit cleanly, or one a fizzy this one takes over from
    // still holds: this run's now. The other leaves it alone at its stop (`socket_inode`).
    Io.Dir.deleteFileAbsolute(self.io, self.socket_path) catch {};
    self.listener = addr.listen(self.io, .{}) catch |err| {
        std.log.err("control: could not listen on {s}: {t}", .{ self.socket_path, err });
        return;
    };
    if (comptime builtin.os.tag != .windows) {
        // This user only. The umask usually says so already; a shared machine's may not.
        var buf: [Io.net.UnixAddress.max_len + 1]u8 = undefined;
        if (std.fmt.bufPrintZ(&buf, "{s}", .{self.socket_path})) |z| _ = std.c.chmod(z, 0o600) else |_| {}
    }
    // Not on Windows, where the socket is a reparse point `statFile` cannot open: this server
    // leaves its socket behind at `stop`, and the next one deletes it before listening (above).
    if (comptime builtin.os.tag != .windows) {
        if (Io.Dir.cwd().statFile(self.io, self.socket_path, .{})) |st| self.socket_inode = st.inode else |_| {}
    }
    if (has_wake_pipe) {
        if (std.c.pipe(&self.wake_pipe) != 0) self.wake_pipe = .{ -1, -1 };
    }
    while (!self.stopping.load(.acquire)) {
        if (has_wake_pipe and self.wake_pipe[0] >= 0) {
            // Until someone connects, or `stop` writes to the pipe.
            var fds = [_]std.posix.pollfd{
                .{ .fd = self.listener.?.socket.handle, .events = std.posix.POLL.IN, .revents = 0 },
                .{ .fd = self.wake_pipe[0], .events = std.posix.POLL.IN, .revents = 0 },
            };
            _ = std.posix.poll(&fds, -1) catch continue;
            if (fds[1].revents != 0 or self.stopping.load(.acquire)) return;
        }
        const stream = self.listener.?.accept(self.io) catch continue;
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
    self.serve(conn.stream);
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

fn serve(self: *Server, stream: Io.net.Stream) void {
    var read_buf: [64 * 1024]u8 = undefined;
    var write_buf: [16 * 1024]u8 = undefined;
    var reader = stream.reader(self.io, &read_buf);
    var writer = stream.writer(self.io, &write_buf);
    var http: std.http.Server = .init(&reader.interface, &writer.interface);
    while (!self.stopping.load(.acquire)) {
        var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var head = http.receiveHead() catch return;
        // Copied before the body is read: reading it invalidates the head's strings.
        var req: Request = .{
            .method = head.head.method,
            .target = arena.dupe(u8, head.head.target) catch return,
            .content_type = if (head.head.content_type) |t| arena.dupe(u8, t) catch return else null,
            .body = "",
        };
        if (head.head.content_length) |n| if (n > max_body) {
            head.respond("request body too large\n", .{ .status = .payload_too_large, .keep_alive = false }) catch {};
            return;
        };
        var body_buf: [4096]u8 = undefined;
        const body_reader = head.readerExpectContinue(&body_buf) catch return;
        req.body = body_reader.allocRemaining(arena, .limited(max_body)) catch |err| switch (err) {
            error.StreamTooLong => {
                head.respond("request body too large\n", .{ .status = .payload_too_large, .keep_alive = false }) catch {};
                return;
            },
            else => return,
        };
        {
            self.lock.lockUncancelable(self.io);
            defer self.lock.unlock(self.io);
            // `stop` answers what is queued before it joins: nothing may be queued after.
            if (self.stopping.load(.acquire)) return;
            self.pending.append(self.gpa, &req) catch return;
        }
        self.wake();
        req.done.wait(self.io) catch return;
        const body = req.response.body orelse "out of memory\n";
        defer if (req.response.body) |b| self.gpa.free(b);
        head.respond(body, .{
            .status = req.response.status,
            .extra_headers = &.{.{ .name = "content-type", .value = req.response.content_type }},
        }) catch return;
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
        // The server's thread may not be listening yet: wait for its socket rather than be
        // refused, which std traces as unexpected on Windows.
        for (0..200) |_| {
            if (Io.Dir.cwd().access(self.io, self.path, .{})) |_| break else |_| {}
            self.io.sleep(.fromMilliseconds(5), .awake) catch {};
        }
        const stream = for (0..200) |_| {
            break addr.connect(self.io) catch {
                self.io.sleep(.fromMilliseconds(5), .awake) catch {};
                continue;
            };
        } else return;
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
