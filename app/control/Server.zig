//! The control server's transport: HTTP/1.1 on a Unix socket only this user can open, served by
//! `Io` tasks of its own (plans/CONTROL_SERVER_PLAN.md). Nothing here touches the app: a request is
//! handed to the UI thread (`take`, once a frame), and the connection's task waits until it is
//! answered (`Request.answer`), then writes the response.
//!
//! Each connection is a task of its own (`Io.concurrent`, a thread each), so a client holding a
//! connection open never makes another wait, and keep-alive works as curl and every HTTP library
//! expect. The UI thread answers requests in the order they arrived. Idle, the server costs a task
//! blocked in `accept`. Tasks, not plain threads, because `stop` must end a read or a write blocked
//! on a client that went quiet, and std interrupts a task's blocked call on every OS (`cancel`),
//! where neither `shutdown` nor closing the socket interrupts a blocked write on Windows (closing it
//! is `unreachable` in std there).
//!
//! Lifted from the agent plugin's socket server (`fizzyedit/agent` `src/Server.zig`), which kept a
//! private ZON-lines wire behind a token; here the socket's permissions are the authorization.
//!
//! std-only, with a unit-test root of its own (`build/app.zig`).
const Server = @This();

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

pub const Link = @import("Link.zig");

/// The most a request body may hold. A command's arguments can be a whole drawing, but not this.
pub const max_body = 64 * 1024 * 1024;
/// The most a stream may fall behind: a client that reads no faster than events come is closed
/// rather than kept buffering without end.
pub const max_backlog = 8 * 1024 * 1024;
/// How long a stream may stay quiet before a keep-alive comment: how a client that went away
/// without closing is noticed.
pub const keep_alive_ms = 15_000;
/// The longest socket path the OS takes, without its terminating zero. std's
/// `UnixAddress.max_len` says 108 everywhere but Windows, where Darwin's `sockaddr_un` holds 104:
/// a path between them passes `UnixAddress.init` and then overruns the copy in `listen`.
pub const max_path = if (builtin.target.os.tag == .windows) 107 else @sizeOf(std.posix.sockaddr.un) - @offsetOf(std.posix.sockaddr.un, "path") - 1;

/// Where an app whose config folder is `config_folder` listens: `control/control.sock` in it, a folder
/// of its own only this user can open (`start` makes it). When that is longer than the OS takes
/// (`max_path`, a deep profile), a folder in `runtime_dir` (`$TMPDIR`, `$XDG_RUNTIME_DIR`, else
/// `/tmp`) named by a hash of the config folder: per config folder still, and just as private.
pub fn socketPath(gpa: std.mem.Allocator, config_folder: []const u8, runtime_dir: ?[]const u8) ![]u8 {
    const preferred = try std.fs.path.join(gpa, &.{ config_folder, "control", "control.sock" });
    if (preferred.len <= max_path) return preferred;
    gpa.free(preferred);
    var name: [32]u8 = undefined;
    const folder = try std.mem.print(&name, "fizzy-control-{x:0>16}", .{std.hash.Wyhash.hash(0, config_folder)});
    return std.fs.path.join(gpa, &.{ runtime_dir orelse "/tmp", folder, "control.sock" });
}

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
/// Requests the UI thread took and has not answered yet (a command answering in a later frame),
/// under `lock`: `stop` answers them too.
outstanding: std.ArrayListUnmanaged(*Request) = .empty,
/// Connections streaming events (`publish`), under `lock`.
streams: std.ArrayListUnmanaged(*Stream) = .empty,
/// How many: read without the lock, so a frame with no stream takes none (`streamsNaming`'s
/// callers ask this first).
stream_count: std.atomic.Value(usize) = .init(0),

/// A connection that asked for events: what it wants, and what is waiting to be written to it.
pub const Stream = struct {
    /// Event names or prefixes ending in `*` (`fizzy.document.*`), from `?topics=a,b`; `*` alone
    /// takes everything. In the connection's arena.
    topics: []const []const u8,
    /// Under the server's `lock`: whole SSE messages, appended by `publish`, written and emptied
    /// by the connection's thread. `gpa`-owned.
    backlog: std.ArrayListUnmanaged(u8) = .empty,
    /// It fell more than `max_backlog` behind: nothing more is buffered for it, and it ends once its
    /// write returns (at once on POSIX, where `publish` shuts the socket down) or at `stop`.
    overrun: bool = false,
    ready: Io.Event = .unset,
    conn: *Conn,
    /// Sent an event published to the streams naming it since it joined (`publishNamed`): one
    /// that has not is sent the next, changed or not.
    greeted: bool = false,
    /// Asked for changes on a base (`?diff=1`): sent a change when it has the base it is on, the
    /// whole event otherwise (`publishNamed`).
    diff: bool = false,
    /// What it was last sent (`publishNamed`'s `seq`), for the next change to be on.
    seq: u32 = 0,

    /// Add the message to what is waiting to be written, under the server's `lock`. Too far behind,
    /// and the stream is closed instead.
    fn queue(self: *Stream, server: *Server, name: []const u8, json: []const u8) void {
        const fits = self.backlog.items.len + name.len + json.len + 16 <= max_backlog;
        if (fits) {
            if (self.backlog.print(server.gpa, "event: {s}\ndata: {s}\n\n", .{ name, json })) |_| {
                self.ready.set(server.io);
                return;
            } else |_| {}
        }
        // Too far behind: shut down, which ends a blocked write on POSIX (not on Windows, where the
        // task ends when its write returns or `stop` cancels it). Nothing more is buffered either way.
        self.overrun = true;
        if (!self.conn.done.load(.acquire)) self.conn.stream.shutdown(server.io, .both) catch {};
        self.ready.set(server.io);
    }

    fn wants(self: *const Stream, name: []const u8) bool {
        return self.matches(name, true);
    }

    /// Wants `name` by naming it, or a prefix of it: not by asking for everything (`*`). For an
    /// event too heavy to send everyone (`publishNamed`).
    fn names(self: *const Stream, name: []const u8) bool {
        return self.matches(name, false);
    }

    fn matches(self: *const Stream, name: []const u8, everything: bool) bool {
        for (self.topics) |t| {
            if (!everything and std.mem.eql(u8, t, "*")) continue;
            if (t.len > 0 and t[t.len - 1] == '*') {
                if (std.mem.startsWith(u8, name, t[0 .. t.len - 1])) return true;
            } else if (std.mem.eql(u8, t, name)) return true;
        }
        return false;
    }
};

const Conn = struct {
    stream: Io.net.Stream,
    task: ?Io.Future(void) = null,
    done: std.atomic.Value(bool) = .init(false),
    /// A request of this connection's is queued or being answered, under `lock`: `stop` leaves its
    /// socket open so the answer ("fizzy is closing") can still be written.
    waiting: bool = false,
    /// It streams events, under `lock`.
    streaming: bool = false,
};

/// One request on its way through the UI thread. Everything in it lives in the connection's
/// arena until it is answered.
pub const Request = struct {
    method: std.http.Method,
    /// The path and query, as sent: `/commands/text.insert?x=1`.
    target: []const u8,
    content_type: ?[]const u8,
    /// The `Mcp-Session-Id` header, as sent (`routes`, `mcp.Sessions`).
    mcp_session: ?[]const u8 = null,
    /// The `Upgrade` header, as sent: what the client asks the connection to become (`/remote`).
    upgrade: ?[]const u8 = null,
    /// The `Mcp-Session-Id` to answer with, formatted by the routes (`mcp.formatSession`).
    mcp_session_reply: ?[16]u8 = null,
    body: []const u8,
    /// Set by `answer`. `body` is `gpa`-owned and the connection's thread frees it.
    response: Response = .{},
    done: Io.Event = .unset,
    conn: *Conn,
    /// The connection's, which its thread does not touch while it waits for `done`.
    arena: std.mem.Allocator,
    /// Set by `answerStream`.
    stream: Stream = undefined,

    /// The path without its query.
    pub fn path(self: *const Request) []const u8 {
        return self.target[0 .. std.mem.findScalar(u8, self.target, '?') orelse self.target.len];
    }

    /// Answer by streaming events to this connection from now on, from the UI thread. The stream
    /// is registered here, before the answer: what is published from now on is buffered for it
    /// while its headers go out, and `take` counts it in the same frame.
    pub fn answerStream(self: *Request, server: *Server) void {
        const topics = topicsOf(self.arena, self.target) catch
            return self.answer(server, .internal_server_error, "text/plain", "out of memory\n");
        self.stream = .{ .topics = topics, .conn = self.conn, .diff = wantsDiff(self.target) };
        const added = added: {
            server.lock.lockUncancelable(server.io);
            defer server.lock.unlock(server.io);
            server.streams.append(server.gpa, &self.stream) catch break :added false;
            server.stream_count.store(server.streams.items.len, .release);
            self.conn.streaming = true;
            break :added true;
        };
        // Answered outside the lock, which `answer` takes.
        if (!added) return self.answer(server, .internal_server_error, "text/plain", "out of memory\n");
        self.response = .{ .stream = true, .status = .ok };
        server.settle(self);
        self.done.set(server.io);
    }

    /// Answer by handing the connection to `link` from now on (`101 Switching Protocols`, then the
    /// peer's bytes into `link` and what the app queues on it out), from the UI thread. The link
    /// is the app's to free once `isGone`.
    pub fn answerUpgrade(self: *Request, server: *Server, link: *Link) void {
        self.response = .{ .status = .switching_protocols, .upgrade = link };
        server.settle(self);
        self.done.set(server.io);
    }

    /// Answer, from the UI thread. `body` is copied with the server's `gpa`.
    pub fn answer(self: *Request, server: *Server, status: std.http.Status, content_type: []const u8, body: []const u8) void {
        self.response = .{
            .status = status,
            .content_type = content_type,
            .body = server.gpa.dupe(u8, body) catch null,
        };
        if (self.response.body == null) self.response.status = .internal_server_error;
        server.settle(self);
        self.done.set(server.io);
    }
};

pub const Response = struct {
    /// Answered by turning the connection into `link`'s bytes (`answerUpgrade`).
    upgrade: ?*Link = null,
    /// Answered by turning the connection into an event stream (`GET /events`): the status and
    /// body are not sent, the connection stays open and `publish` writes to it.
    stream: bool = false,
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
    if (self.socket_path.len > max_path) return error.NameTooLong;
    const addr = try Io.net.UnixAddress.init(self.socket_path);
    // Its folder, this user's only: the socket is unreachable to others from the moment it exists,
    // before its own permissions are set below. A link in its place is refused, not followed: its
    // target may be a folder shared with others, which the mode would then be set on.
    if (std.fs.path.dirname(self.socket_path)) |dir| {
        try Io.Dir.cwd().createDirPath(self.io, dir);
        if (comptime builtin.target.os.tag != .windows) {
            const st = try Io.Dir.cwd().statFile(self.io, dir, .{ .follow_symlinks = false });
            if (st.kind != .directory) return error.NotAFolder;
            try Io.Dir.cwd().setFilePermissions(self.io, dir, .fromMode(0o700), .{ .follow_symlinks = false });
        }
    }
    // A socket left by a fizzy that did not quit cleanly, or one a fizzy this one takes over from
    // still holds: this run's now. The other leaves it alone at its stop (`socket_inode`).
    Io.Dir.deleteFileAbsolute(self.io, self.socket_path) catch {};
    self.listener = try addr.listen(self.io, .{});
    errdefer {
        self.listener.?.deinit(self.io);
        self.listener = null;
        Io.Dir.deleteFileAbsolute(self.io, self.socket_path) catch {};
    }
    if (comptime builtin.target.os.tag != .windows) {
        // This user only. The umask usually says so already; a shared machine's may not.
        try Io.Dir.cwd().setFilePermissions(self.io, self.socket_path, .fromMode(0o600), .{});
        // Not on Windows, where the socket is a reparse point `statFile` cannot open: there this
        // server leaves its socket behind at `stop`, and the next one deletes it (above).
        if (Io.Dir.cwd().statFile(self.io, self.socket_path, .{})) |st| self.socket_inode = st.inode else |_| {}
    }
    self.accept_task = try self.io.concurrent(run, .{self});
}

/// Requests the UI thread should answer now, each of which must be answered, and how many
/// connections stream events. On the UI thread, each frame.
pub fn take(self: *Server, out: *std.ArrayListUnmanaged(*Request)) usize {
    self.lock.lockUncancelable(self.io);
    defer self.lock.unlock(self.io);
    // Out of memory: left queued for the next frame, never dropped unanswered.
    self.outstanding.ensureUnusedCapacity(self.gpa, self.pending.items.len) catch return self.streams.items.len;
    out.appendSlice(self.gpa, self.pending.items) catch return self.streams.items.len;
    self.outstanding.appendSliceAssumeCapacity(self.pending.items);
    self.pending.clearRetainingCapacity();
    return self.streams.items.len;
}

/// `req` is answered: no longer `outstanding`.
fn settle(self: *Server, req: *Request) void {
    self.lock.lockUncancelable(self.io);
    defer self.lock.unlock(self.io);
    for (self.outstanding.items, 0..) |r, i| if (r == req) {
        _ = self.outstanding.swapRemove(i);
        return;
    };
}

/// Whether any stream wants the event `name`: the caller skips building a message nobody reads.
pub fn wants(self: *Server, name: []const u8) bool {
    self.lock.lockUncancelable(self.io);
    defer self.lock.unlock(self.io);
    for (self.streams.items) |st| if (!st.overrun and st.wants(name)) return true;
    return false;
}

/// Send the event `name`, its payload already JSON on one line, to every stream that wants it.
/// The message is built once and copied to each. From any thread.
pub fn publish(self: *Server, name: []const u8, json: []const u8) void {
    // A line break would end the `event:` line early, and let a name forge messages of its own.
    if (std.mem.findAny(u8, name, "\r\n") != null) return;
    self.lock.lockUncancelable(self.io);
    defer self.lock.unlock(self.io);
    for (self.streams.items) |st| {
        if (!st.overrun and st.wants(name)) st.queue(self, name, json);
    }
}

/// `publish`, to the streams that name the event (or a prefix of it) only, not those asking for
/// everything: for an event too heavy for those (`fizzy.screen`, the whole screen each frame it
/// changes). `changed`: to every such stream; otherwise only to those not yet sent it since
/// joining, which want the state as it is.
///
/// `whole` is the event in full, numbered `seq`. A stream that asked for changes (`?diff=1`) and
/// was last sent `delta.since` is sent `delta.json` instead, what changed since: the rest, `whole`,
/// which a change-taking stream takes as its new base.
pub fn publishNamed(self: *Server, name: []const u8, whole: []const u8, seq: u32, delta: ?Delta, changed: bool) void {
    if (std.mem.findAny(u8, name, "\r\n") != null) return;
    self.lock.lockUncancelable(self.io);
    defer self.lock.unlock(self.io);
    for (self.streams.items) |st| {
        if (st.overrun or !st.names(name)) continue;
        if (!changed and st.greeted) continue;
        const json = if (delta) |d| if (st.diff and st.greeted and st.seq == d.since) d.json else whole else whole;
        st.greeted = true;
        st.seq = seq;
        st.queue(self, name, json);
    }
}

pub const Delta = struct { since: u32, json: []const u8 };

/// The streams naming the event `name` (`publishNamed`), and how many of them have not been sent
/// it since joining.
pub fn streamsNaming(self: *Server, name: []const u8) struct { naming: usize, new: usize, diffing: usize } {
    self.lock.lockUncancelable(self.io);
    defer self.lock.unlock(self.io);
    var naming: usize = 0;
    var new: usize = 0;
    var diffing: usize = 0;
    for (self.streams.items) |st| {
        if (st.overrun or !st.names(name)) continue;
        naming += 1;
        if (!st.greeted) new += 1;
        if (st.diff) diffing += 1;
    }
    return .{ .naming = naming, .new = new, .diffing = diffing };
}

pub fn stop(self: *Server) void {
    self.stopping.store(true, .release);
    // The connections whose requests this answers ("fizzy is closing"): each writes it and ends.
    // Queued, or taken and still to be answered (a command answering later).
    var answered: std.ArrayListUnmanaged(*Conn) = .empty;
    defer answered.deinit(self.gpa);
    // Moved out whole, not copied: running out of memory here must not drop one unanswered, whose
    // task would then wait for good.
    var queued: std.ArrayListUnmanaged(*Request) = .empty;
    defer queued.deinit(self.gpa);
    var taken: std.ArrayListUnmanaged(*Request) = .empty;
    defer taken.deinit(self.gpa);
    {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        std.mem.swap(std.ArrayListUnmanaged(*Request), &queued, &self.pending);
        std.mem.swap(std.ArrayListUnmanaged(*Request), &taken, &self.outstanding);
    }
    for ([_][]const *Request{ queued.items, taken.items }) |owed| for (owed) |r| {
        answered.append(self.gpa, r.conn) catch {};
        r.answer(self, .service_unavailable, "text/plain", "the control server is stopping\n");
    };
    if (self.accept_task) |*t| t.cancel(self.io);
    self.accept_task = null;
    // No more are accepted, so `conns` holds still. Every other task, reading its next request or
    // streaming, blocked on a quiet client or not, is cancelled.
    for (self.conns.items) |c| {
        if (c.task) |*t| {
            if (std.mem.findScalar(*Conn, answered.items, c) != null) t.await(self.io) else t.cancel(self.io);
        }
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
    self.outstanding.deinit(self.gpa);
    self.streams.deinit(self.gpa);
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
        conn.task = self.io.concurrent(serveConn, .{ self, conn }) catch {
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
    // The sending side first: a client reading to the end then sees it end. Windows' AF_UNIX
    // otherwise sometimes never tells a client still reading that the socket closed.
    conn.stream.shutdown(self.io, .send) catch {};
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
        // Done, so this returns at once.
        if (c.task) |*t| t.await(self.io);
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
            .mcp_session = headerValue(&head, arena, "mcp-session-id") catch return,
            .upgrade = headerValue(&head, arena, "upgrade") catch return,
            .body = "",
            .conn = conn,
            .arena = arena,
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
        if (req.response.stream) return self.serveStream(&head, &req.stream);
        if (req.response.upgrade) |link| {
            self.lock.lockUncancelable(self.io);
            conn.waiting = false;
            self.lock.unlock(self.io);
            return self.serveLink(link, conn.stream, &reader.interface, &writer.interface, req.upgrade orelse "");
        }
        const body = req.response.body orelse "out of memory\n";
        defer if (req.response.body) |b| self.gpa.free(b);
        const headers = [_]std.http.Header{
            .{ .name = "content-type", .value = req.response.content_type },
            .{ .name = "mcp-session-id", .value = if (req.mcp_session_reply) |*id| id else "" },
        };
        const sent = head.respond(body, .{
            .status = req.response.status,
            .extra_headers = headers[0..if (req.mcp_session_reply != null) 2 else 1],
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

/// The request's header `name` (lowercase), copied into `arena`, or null.
fn headerValue(head: *std.http.Server.Request, arena: std.mem.Allocator, name: []const u8) error{OutOfMemory}!?[]const u8 {
    var it = head.iterateHeaders();
    while (it.next()) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return try arena.dupe(u8, h.value);
    return null;
}

/// The connection is `link`'s from here: the `101`, then what the peer sends into the link while a
/// task of its own writes what the app queues on it. Ends when the peer goes, the app closes the
/// link, or the server stops; the link is finished last, whichever, and not touched after.
fn serveLink(self: *Server, link: *Link, stream: Io.net.Stream, reader: *Io.Reader, writer: *Io.Writer, token: []const u8) void {
    defer link.finish();
    link.lock.lockUncancelable(self.io);
    link.stream = stream;
    link.lock.unlock(self.io);
    // Cleared before `finish`, under the lock `abort` shuts the socket down in: the connection
    // closes it as soon as this returns.
    defer {
        link.lock.lockUncancelable(self.io);
        link.stream = null;
        link.lock.unlock(self.io);
    }
    writer.print("HTTP/1.1 101 Switching Protocols\r\nconnection: Upgrade\r\nupgrade: {s}\r\n\r\n", .{token}) catch return;
    writer.flush() catch return;
    var sender = self.io.concurrent(writeLink, .{ self, link, stream, writer }) catch return;
    defer sender.cancel(self.io);
    while (!self.stopping.load(.acquire)) {
        const bytes = reader.peekGreedy(1) catch return;
        link.push(bytes) catch return;
        reader.toss(bytes.len);
    }
}

/// Write what the app queues on `link` until it closes it or a write fails, then shut the socket
/// down, which ends the read that `serveLink` is blocked in.
fn writeLink(self: *Server, link: *Link, stream: Io.net.Stream, writer: *Io.Writer) void {
    while (true) {
        // Read first: what was queued before `close` is still written.
        const closing = link.closing.load(.acquire);
        if (link.drain() catch break) |bytes| {
            defer link.gpa.free(bytes);
            writer.writeAll(bytes) catch break;
            writer.flush() catch break;
            continue;
        }
        if (closing) break;
        link.out_ready.wait(self.io) catch break;
    }
    stream.shutdown(self.io, .both) catch {};
}

/// Write events to the connection until the client goes, falls too far behind, or the server
/// stops. `stream` was registered by `answerStream`; it is removed here, whatever happens.
fn serveStream(self: *Server, head: *std.http.Server.Request, stream: *Stream) void {
    defer {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        for (self.streams.items, 0..) |st, i| if (st == stream) {
            _ = self.streams.swapRemove(i);
            self.stream_count.store(self.streams.items.len, .release);
            break;
        };
        stream.backlog.deinit(self.gpa);
    }
    // No buffer of its own: `BodyWriter.flush` sends only the connection's, so whatever the body
    // writer held would wait. Its writes go straight into the connection's buffer instead.
    var body = head.respondStreaming(&.{}, .{ .respond_options = .{
        .keep_alive = false,
        .transfer_encoding = .none,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "text/event-stream" },
            .{ .name = "cache-control", .value = "no-cache" },
        },
    } }) catch return;
    body.flush() catch return;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(self.gpa);
    while (true) {
        const quiet = if (stream.ready.waitTimeout(self.io, .{ .duration = .{ .raw = .fromMilliseconds(keep_alive_ms), .clock = .awake } })) |_| false else |err| switch (err) {
            error.Timeout => true,
            error.Canceled => return,
        };
        {
            self.lock.lockUncancelable(self.io);
            defer self.lock.unlock(self.io);
            if (self.stopping.load(.acquire) or stream.overrun) return;
            // Taken whole: `publish` goes on appending to an empty list while this one is written.
            std.mem.swap(std.ArrayListUnmanaged(u8), &out, &stream.backlog);
            stream.ready.reset();
        }
        if (out.items.len > 0) {
            body.writer.writeAll(out.items) catch return;
        } else if (quiet) {
            body.writer.writeAll(": keep-alive\n\n") catch return;
        } else continue;
        body.flush() catch return;
        out.clearRetainingCapacity();
    }
}

/// `?diff=1`: the stream wants changes on a base where an event offers them (`publishNamed`).
fn wantsDiff(target: []const u8) bool {
    const query = target[(std.mem.findScalar(u8, target, '?') orelse return false) + 1 ..];
    var params = std.mem.tokenizeScalar(u8, query, '&');
    while (params.next()) |param| if (std.mem.eql(u8, param, "diff=1") or std.mem.eql(u8, param, "diff=true")) return true;
    return false;
}

/// `?topics=a,b` as a list; everything when absent or empty.
fn topicsOf(arena: std.mem.Allocator, target: []const u8) ![]const []const u8 {
    const query = target[(std.mem.findScalar(u8, target, '?') orelse return &.{"*"}) + 1 ..];
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    var params = std.mem.tokenizeScalar(u8, query, '&');
    while (params.next()) |param| {
        const eq = std.mem.findScalar(u8, param, '=') orelse continue;
        if (!std.mem.eql(u8, param[0..eq], "topics")) continue;
        const value = std.Uri.percentDecodeInPlace(try arena.dupe(u8, param[eq + 1 ..]));
        var names = std.mem.tokenizeScalar(u8, value, ',');
        while (names.next()) |n| try list.append(arena, std.mem.trim(u8, n, " "));
    }
    return if (list.items.len == 0) &.{"*"} else list.items;
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
        // As an HTTP client does: the head, then `Content-Length` bytes when it says, else to the
        // end (a stream). Never to the end when it need not: whether Windows' AF_UNIX tells a
        // reader the other side closed is not something to test here.
        while (self.reply_len < self.reply.len) {
            const n = r.interface.readSliceShort(self.reply[self.reply_len..][0..1]) catch return;
            if (n == 0) return;
            self.reply_len += 1;
            if (std.mem.endsWith(u8, self.reply[0..self.reply_len], "\r\n\r\n")) break;
        }
        const head = self.reply[0..self.reply_len];
        const key = "content-length: ";
        if (std.ascii.findIgnoreCase(head, key)) |i| {
            const end = std.mem.findPos(u8, head, i, "\r\n") orelse return;
            const len = std.fmt.parseInt(usize, head[i + key.len .. end], 10) catch return;
            const want = @min(len, self.reply.len - self.reply_len);
            r.interface.readSliceAll(self.reply[self.reply_len..][0..want]) catch return;
            self.reply_len += want;
        } else {
            self.reply_len += r.interface.readSliceShort(self.reply[self.reply_len..]) catch 0;
        }
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
    // In a folder of its own that `start` makes, as the app's is (`control/control.sock`).
    const path = try std.fs.path.join(gpa, &.{ dir, "control", "c.sock" });
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
        _ = server.take(&taken);
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
    try std.testing.expect(std.mem.find(u8, reply, "content-type: application/json\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, reply, "\r\n\r\n{\"ok\":true}"));

    // Only this user may open it.
    if (builtin.target.os.tag == .windows) return;
    const st = try Io.Dir.cwd().statFile(io, path, .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), st.permissions.toMode() & 0o777);
    // And its folder: nobody else reaches it, even before the socket's own mode is set.
    const folder = try Io.Dir.cwd().statFile(io, std.fs.path.dirname(path).?, .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o700), folder.permissions.toMode() & 0o777);
}

fn testSocket(gpa: std.mem.Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(dir);
    return std.fs.path.join(gpa, &.{ dir, "c.sock" });
}

test "a request still queued at quit is answered: the server is stopping" {
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
    try std.testing.expect(std.mem.endsWith(u8, reply, "the control server is stopping\n"));
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
        try std.testing.expect(std.mem.find(u8, reply, "100 Continue") == null);
    }
    var taken: std.ArrayListUnmanaged(*Request) = .empty;
    defer taken.deinit(gpa);
    _ = server.take(&taken);
    try std.testing.expectEqual(@as(usize, 0), taken.items.len);
}

test "a config folder too deep for a socket path listens in a runtime folder instead" {
    const gpa = std.testing.allocator;
    const short = try socketPath(gpa, "/home/me/.config/fizzy", "/run/user/1000");
    defer gpa.free(short);
    // Joined as the OS joins paths: `\` between them on Windows.
    const want = try std.fs.path.join(gpa, &.{ "/home/me/.config/fizzy", "control", "control.sock" });
    defer gpa.free(want);
    try std.testing.expectEqualStrings(want, short);
    // Between Darwin's 104 and std's 108, the length that crashed `listen`: not used as it is.
    const deep = "/" ++ @as([max_path - "/control/control.sock".len + 2]u8, @splat('d'));
    const fallback = try socketPath(gpa, deep, "/tmp/me");
    defer gpa.free(fallback);
    try std.testing.expect(fallback.len <= max_path);
    const folder = try std.fs.path.join(gpa, &.{ "/tmp/me", "fizzy-control-" });
    defer gpa.free(folder);
    try std.testing.expect(std.mem.startsWith(u8, fallback, folder));
    // Per config folder: another deep one gets another folder.
    const other = try socketPath(gpa, deep ++ "x", "/tmp/me");
    defer gpa.free(other);
    try std.testing.expect(!std.mem.eql(u8, fallback, other));
}

test "a socket path the OS cannot hold fails at start, not later" {
    if (!Io.net.has_unix_sockets) return error.SkipZigTest;
    // Longer than the OS takes but within std's limit: refused here, not overrun in `listen`.
    const long = "/" ++ @as([max_path]u8, @splat('d'));
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
        _ = new.take(&taken);
        if (taken.items.len == 0) io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expectEqual(@as(usize, 1), taken.items.len);
    taken.items[0].answer(&new, .ok, "text/plain", "new");
    thread.join();
    try std.testing.expect(std.mem.endsWith(u8, client.reply[0..client.reply_len], "\r\n\r\nnew"));
}

test "a stream gets the events it asked for, once each, until the server stops" {
    if (!Io.net.has_unix_sockets) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testSocket(gpa, &tmp);
    defer gpa.free(path);

    var server: Server = .{ .gpa = gpa, .io = io, .socket_path = path, .wake = noWake };
    try server.start();
    errdefer server.stop();
    var client: TestClient = .{ .io = io, .path = path, .request = "GET /events?topics=fizzy.document.*,chat.turn_ended HTTP/1.1\r\nHost: x\r\n\r\n" };
    const thread = try std.Thread.spawn(.{}, TestClient.run, .{&client});

    var taken: std.ArrayListUnmanaged(*Request) = .empty;
    defer taken.deinit(gpa);
    var streams: usize = 0;
    var waited: usize = 0;
    while (streams == 0 and waited < 2000) : (waited += 1) {
        streams = server.take(&taken);
        for (taken.items) |r| r.answerStream(&server);
        taken.clearRetainingCapacity();
        if (streams == 0) io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expectEqual(@as(usize, 1), streams);
    server.publish("fizzy.document.saved", "{\"path\":\"/a\"}");
    server.publish("fizzy.folder.opened", "{\"path\":\"/p\"}");
    server.publish("chat.turn_ended", "{}");
    // Let the stream write before the stop ends it.
    io.sleep(.fromMilliseconds(50), .awake) catch {};
    server.stop();
    thread.join();

    const reply = client.reply[0..client.reply_len];
    try std.testing.expect(std.mem.startsWith(u8, reply, "HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(std.mem.find(u8, reply, "content-type: text/event-stream\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, reply, "\r\n\r\nevent: fizzy.document.saved\ndata: {\"path\":\"/a\"}\n\nevent: chat.turn_ended\ndata: {}\n\n"));
}

test "topics come from the query, and none means everything" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{"*"}), try topicsOf(a, "/events"));
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{"*"}), try topicsOf(a, "/events?topics="));
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "fizzy.document.*", "x.y" }), try topicsOf(a, "/events?a=1&topics=fizzy.document.%2A,%20x.y"));
    const st: Stream = .{ .topics = &.{ "fizzy.document.*", "x.y" }, .conn = undefined };
    try std.testing.expect(st.wants("fizzy.document.saved"));
    // Named, or by a prefix: what `publishNamed` sends to. Everything (`*`) is not naming it.
    try std.testing.expect(st.names("fizzy.document.saved"));
    const all: Stream = .{ .topics = &.{"*"}, .conn = undefined };
    try std.testing.expect(all.wants("fizzy.screen"));
    try std.testing.expect(!all.names("fizzy.screen"));
    const fizzy_all: Stream = .{ .topics = &.{ "*", "fizzy.*" }, .conn = undefined };
    try std.testing.expect(fizzy_all.names("fizzy.screen"));
    try std.testing.expect(st.wants("x.y"));
    try std.testing.expect(!st.wants("x.yz"));
    try std.testing.expect(!st.wants("fizzy.folder.opened"));
}

/// Connects, asks for events, then reads nothing until `release`: a paused `curl | less`.
const StalledClient = struct {
    io: Io,
    path: []const u8,
    release: Io.Event = .unset,

    fn run(self: *StalledClient) void {
        const addr = Io.net.UnixAddress.init(self.path) catch return;
        const stream = addr.connect(self.io) catch return;
        defer stream.close(self.io);
        var wbuf: [256]u8 = undefined;
        var w = stream.writer(self.io, &wbuf);
        w.interface.writeAll("GET /events HTTP/1.1\r\nHost: x\r\n\r\n") catch return;
        w.interface.flush() catch return;
        self.release.waitUncancelable(self.io);
    }
};

fn openStreams(server: *Server) usize {
    server.lock.lockUncancelable(server.io);
    defer server.lock.unlock(server.io);
    return server.streams.items.len;
}

fn answerStreams(server: *Server, want: usize) !void {
    var taken: std.ArrayListUnmanaged(*Request) = .empty;
    defer taken.deinit(server.gpa);
    var waited: usize = 0;
    while (openStreams(server) < want and waited < 2000) : (waited += 1) {
        _ = server.take(&taken);
        for (taken.items) |r| r.answerStream(server);
        taken.clearRetainingCapacity();
        if (openStreams(server) < want) server.io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expectEqual(want, openStreams(server));
}

test "a client that stops reading neither holds up the quit nor buffers without end" {
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
    var client: StalledClient = .{ .io = io, .path = path };
    const thread = try std.Thread.spawn(.{}, StalledClient.run, .{&client});
    defer {
        client.release.set(io);
        thread.join();
    }
    try answerStreams(&server, 1);
    // Until its task blocks writing and the backlog passes the cap; how much the socket takes first
    // is the OS's (Windows grows its buffers), so publish until then, up to far more than any.
    const chunk = "\"" ++ @as([64 * 1024]u8, @splat('x')) ++ "\"";
    var published: usize = 0;
    while (!overrun(&server) and published < 256 * 1024 * 1024) : (published += chunk.len) server.publish("e", chunk);
    try std.testing.expect(overrun(&server));
    // Buffered no further: the backlog stays under the cap whatever else is published.
    for (0..64) |_| server.publish("e", chunk);
    server.lock.lockUncancelable(io);
    const kept = if (server.streams.items.len > 0) server.streams.items[0].backlog.items.len else 0;
    server.lock.unlock(io);
    try std.testing.expect(kept <= max_backlog);
    // And the quit (the deferred `stop`) returns, its write blocked or not.
}

fn overrun(server: *Server) bool {
    server.lock.lockUncancelable(server.io);
    defer server.lock.unlock(server.io);
    // Gone already counts: on POSIX the shutdown ended it at once.
    return server.streams.items.len == 0 or server.streams.items[0].overrun;
}

test "a stopped server ends a stream whose client stopped reading" {
    if (!Io.net.has_unix_sockets) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testSocket(gpa, &tmp);
    defer gpa.free(path);

    var server: Server = .{ .gpa = gpa, .io = io, .socket_path = path, .wake = noWake };
    try server.start();
    // A failed expectation still stops it, so the test binary is not left running.
    errdefer server.stop();
    var client: StalledClient = .{ .io = io, .path = path };
    const thread = try std.Thread.spawn(.{}, StalledClient.run, .{&client});
    defer {
        client.release.set(io);
        thread.join();
    }
    try answerStreams(&server, 1);
    // Enough to block its write, not enough to overrun.
    const chunk = "\"" ++ @as([64 * 1024]u8, @splat('x')) ++ "\"";
    for (0..16) |_| server.publish("e", chunk);
    io.sleep(.fromMilliseconds(50), .awake) catch {};
    // Returns: the stream's socket is shut down under its blocked write.
    server.stop();
}

test "an event published as the stream is answered is not lost" {
    if (!Io.net.has_unix_sockets) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testSocket(gpa, &tmp);
    defer gpa.free(path);

    var server: Server = .{ .gpa = gpa, .io = io, .socket_path = path, .wake = noWake };
    try server.start();
    var client: TestClient = .{ .io = io, .path = path, .request = "GET /events HTTP/1.1\r\nHost: x\r\n\r\n" };
    const thread = try std.Thread.spawn(.{}, TestClient.run, .{&client});
    var taken: std.ArrayListUnmanaged(*Request) = .empty;
    defer taken.deinit(gpa);
    var waited: usize = 0;
    while (taken.items.len == 0 and waited < 2000) : (waited += 1) {
        _ = server.take(&taken);
        if (taken.items.len == 0) io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    // Registered by the answer itself, on this thread: the publish right after reaches it even
    // though its connection has not written the headers yet.
    taken.items[0].answerStream(&server);
    server.publish("first", "1");
    io.sleep(.fromMilliseconds(50), .awake) catch {};
    server.stop();
    thread.join();
    try std.testing.expect(std.mem.endsWith(u8, client.reply[0..client.reply_len], "\r\n\r\nevent: first\ndata: 1\n\n"));
}

test "a stopped server ends a keep-alive connection waiting for its next request" {
    if (!Io.net.has_unix_sockets) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testSocket(gpa, &tmp);
    defer gpa.free(path);

    var server: Server = .{ .gpa = gpa, .io = io, .socket_path = path, .wake = noWake };
    try server.start();
    errdefer server.stop();
    // Asks once, keeps the connection, and sends nothing more until `release`.
    const Idle = struct {
        io: Io,
        path: []const u8,
        got: usize = 0,
        release: Io.Event = .unset,
        fn run(self: *@This()) void {
            const addr = Io.net.UnixAddress.init(self.path) catch return;
            const stream = addr.connect(self.io) catch return;
            defer stream.close(self.io);
            var wbuf: [256]u8 = undefined;
            var w = stream.writer(self.io, &wbuf);
            w.interface.writeAll("GET / HTTP/1.1\r\nHost: x\r\n\r\n") catch return;
            w.interface.flush() catch return;
            var rbuf: [256]u8 = undefined;
            var r = stream.reader(self.io, &rbuf);
            var reply: [256]u8 = undefined;
            // The answer below is 2 bytes, after a head of known shape: read to its end.
            while (self.got < reply.len) {
                const n = r.interface.readSliceShort(reply[self.got..][0..1]) catch return;
                if (n == 0) return;
                self.got += 1;
                if (std.mem.endsWith(u8, reply[0..self.got], "\r\n\r\nhi")) break;
            }
            self.release.waitUncancelable(self.io);
        }
    };
    var client: Idle = .{ .io = io, .path = path };
    const thread = try std.Thread.spawn(.{}, Idle.run, .{&client});
    defer {
        client.release.set(io);
        thread.join();
    }
    var taken: std.ArrayListUnmanaged(*Request) = .empty;
    defer taken.deinit(gpa);
    var waited: usize = 0;
    while (taken.items.len == 0 and waited < 2000) : (waited += 1) {
        _ = server.take(&taken);
        if (taken.items.len == 0) io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expectEqual(@as(usize, 1), taken.items.len);
    taken.items[0].answer(&server, .ok, "text/plain", "hi");
    // Its task is back reading the next request when the server stops: that read ends.
    io.sleep(.fromMilliseconds(50), .awake) catch {};
    server.stop();
}

/// A client that asks for `GET /remote` to become a byte stream: reads the `101`, writes `ping`
/// right behind its request, reads four bytes, then reads to the end unless `leave`, which closes
/// the socket as soon as it has the head.
const UpgradePeer = struct {
    io: Io,
    path: []const u8,
    leave: bool = false,
    head: [160]u8 = undefined,
    head_len: usize = 0,
    reply: [4]u8 = undefined,
    ended: bool = false,

    fn run(self: *UpgradePeer) void {
        const addr = Io.net.UnixAddress.init(self.path) catch return;
        const stream = addr.connect(self.io) catch return;
        defer stream.close(self.io);
        var wbuf: [256]u8 = undefined;
        var w = stream.writer(self.io, &wbuf);
        w.interface.writeAll("GET /remote HTTP/1.1\r\nHost: x\r\nConnection: Upgrade\r\nUpgrade: fizzy-remote-view/1\r\n\r\nping") catch return;
        w.interface.flush() catch return;
        var rbuf: [256]u8 = undefined;
        var r = stream.reader(self.io, &rbuf);
        while (self.head_len < self.head.len) {
            const n = r.interface.readSliceShort(self.head[self.head_len..][0..1]) catch return;
            if (n == 0) return;
            self.head_len += 1;
            if (std.mem.endsWith(u8, self.head[0..self.head_len], "\r\n\r\n")) break;
        }
        if (self.leave) return;
        r.interface.readSliceAll(&self.reply) catch return;
        var more: [1]u8 = undefined;
        self.ended = if (r.interface.readSliceShort(&more)) |n| n == 0 else |_| true;
    }
};

/// Frames, as the UI thread's, until `taken` holds a request.
fn takeOne(server: *Server, taken: *std.ArrayListUnmanaged(*Request)) !*Request {
    var waited: usize = 0;
    while (taken.items.len == 0 and waited < 2000) : (waited += 1) {
        _ = server.take(taken);
        if (taken.items.len == 0) server.io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expectEqual(@as(usize, 1), taken.items.len);
    return taken.items[0];
}

test "an upgraded connection carries bytes both ways until the app closes it" {
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

    var peer: UpgradePeer = .{ .io = io, .path = path };
    const thread = try std.Thread.spawn(.{}, UpgradePeer.run, .{&peer});
    var taken: std.ArrayListUnmanaged(*Request) = .empty;
    defer taken.deinit(gpa);
    const req = try takeOne(&server, &taken);
    try std.testing.expectEqualStrings("fizzy-remote-view/1", req.upgrade.?);
    var link: Link = .init(gpa, io, noWake);
    defer link.deinit();
    req.answerUpgrade(&server, &link);

    // What the client wrote behind its request is the link's.
    var got: std.ArrayListUnmanaged(u8) = .empty;
    defer got.deinit(gpa);
    var waited: usize = 0;
    while (got.items.len < 4 and waited < 2000) : (waited += 1) {
        try link.take(&got);
        io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expectEqualStrings("ping", got.items);
    try link.send("pong");
    // Closing ends the client's read, after what was queued is written.
    link.close();
    thread.join();
    try std.testing.expect(std.mem.startsWith(u8, peer.head[0..peer.head_len], "HTTP/1.1 101 Switching Protocols\r\n"));
    try std.testing.expect(std.mem.find(u8, peer.head[0..peer.head_len], "upgrade: fizzy-remote-view/1\r\n") != null);
    try std.testing.expectEqualStrings("pong", &peer.reply);
    try std.testing.expect(peer.ended);
    waited = 0;
    while (!link.isGone() and waited < 2000) : (waited += 1) io.sleep(.fromMilliseconds(1), .awake) catch {};
    try std.testing.expect(link.isGone());
}

test "a client that leaves an upgraded connection finishes its link" {
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

    var peer: UpgradePeer = .{ .io = io, .path = path, .leave = true };
    const thread = try std.Thread.spawn(.{}, UpgradePeer.run, .{&peer});
    var taken: std.ArrayListUnmanaged(*Request) = .empty;
    defer taken.deinit(gpa);
    const req = try takeOne(&server, &taken);
    var link: Link = .init(gpa, io, noWake);
    defer link.deinit();
    req.answerUpgrade(&server, &link);
    thread.join();
    var waited: usize = 0;
    while (!link.isGone() and waited < 2000) : (waited += 1) io.sleep(.fromMilliseconds(1), .awake) catch {};
    try std.testing.expect(link.isGone());
}

test {
    _ = Link;
}
