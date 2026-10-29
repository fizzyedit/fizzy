//! `Client` — a host application's way to a running fizzy: find the installed one, quietly start it
//! when nothing listens, connect to its control socket, upgrade to the remote-view stream and
//! exchange hellos (plans/EMBEDDED_EDITOR_PLAN.md, step 5). `capi.zig` is the C ABI over it.
//!
//! The steps, and the error each one ends in:
//!
//!   1. *Locate* the executable (`locate`): `FIZZY_EXE`, then the OS's usual install places
//!      (`candidates`), then the system's own index (Launch Services, the registry's App Paths).
//!      Nothing found is `NotInstalled`, or `Sandboxed` from a sandbox, which cannot see them.
//!   2. Ask it for its socket (`fizzy --control-path`, with the `--profile` in play), unless the
//!      caller names the socket.
//!   3. *Dial.* If nothing listens, start fizzy with `--quiet` (macOS: `open -g -j`, which never
//!      takes focus) and dial again with a growing pause until the deadline. A start that dies
//!      is `StartFailed`, one that is only slow `TimedOut`. Fizzy is never started with a
//!      private profile of its own to get around a sandbox: that would be a second fizzy the
//!      person did not ask for.
//!   4. *Upgrade* `GET /remote` and exchange hellos. `FizzyTooOld` (no `/remote`, or a protocol
//!      older than ours) and `ClientTooOld` (newer than ours) say who updates.
//!
//! `reconnect` runs the same steps again after a drop. std-only.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const message = @import("message.zig");
const codec = @import("codec.zig");
const Endpoint = @import("Endpoint.zig");

const Client = @This();

pub const upgrade_token = "fizzy-remote-view/1";

/// The environment variable that names the executable, and the profile folder, for a host that
/// must not search (and for tests).
pub const env_exe = "FIZZY_EXE";
pub const env_profile = "FIZZY_PROFILE";

pub const Error = error{
    /// No fizzy where one would be installed.
    NotInstalled,
    /// Nothing listens and the caller asked not to start one.
    NotRunning,
    /// This process cannot see fizzy's install or socket, or may not start it.
    Sandboxed,
    /// Fizzy has no remote view, or speaks only older versions: update fizzy.
    FizzyTooOld,
    /// Fizzy speaks only newer versions: update the add-on.
    ClientTooOld,
    /// Started (or found) but not answering by the deadline.
    TimedOut,
    /// The fizzy we started exited with a failure before it listened.
    StartFailed,
    /// The peer is not speaking the protocol.
    Protocol,
    /// The stream ended.
    Closed,
    OutOfMemory,
};

/// Which application to find: an app built on fizzy takes its own.
pub const Identity = struct {
    /// The executable's name and the Velopack pack id.
    name: []const u8 = "fizzy",
    /// The macOS bundle's name (`Fizzy.app`).
    display_name: []const u8 = "Fizzy",
    bundle_id: []const u8 = "com.foxnne.fizzy",
};

/// What the process's environment says, as values, so a host that has no libc environment (or a
/// test) can say it too.
pub const Env = struct {
    os: std.Target.Os.Tag = builtin.os.tag,
    exe: ?[]const u8 = null,
    profile: ?[]const u8 = null,
    home: ?[]const u8 = null,
    local_app_data: ?[]const u8 = null,
    path: ?[]const u8 = null,
    /// An OS sandbox (App Sandbox, Flatpak, Snap): the install and socket may be out of sight.
    sandboxed: bool = false,

    /// The process's own, through libc; empty without it.
    pub fn fromProcess() Env {
        return .{
            .exe = getenv(env_exe),
            .profile = getenv(env_profile),
            .home = getenv(if (builtin.os.tag == .windows) "USERPROFILE" else "HOME"),
            .local_app_data = getenv("LOCALAPPDATA"),
            .path = getenv("PATH"),
            .sandboxed = getenv("APP_SANDBOX_CONTAINER_ID") != null or
                getenv("FLATPAK_ID") != null or getenv("SNAP") != null,
        };
    }

    fn getenv(name: [:0]const u8) ?[]const u8 {
        if (!builtin.link_libc) return null;
        const value = std.c.getenv(name) orelse return null;
        const slice = std.mem.span(value);
        return if (slice.len == 0) null else slice;
    }
};

pub const Options = struct {
    identity: Identity = .{},
    env: Env = .{},
    /// What the host calls itself in its hello, and its version.
    host_name: []const u8 = "host",
    host_version: []const u8 = "",
    tiers: message.Tiers = .{ .draw_list = true },
    /// The socket, when the host knows it (and cannot run fizzy to ask).
    socket_path: ?[]const u8 = null,
    /// Start a quiet fizzy when none listens.
    start: bool = true,
    /// How long `connect` may take from the first dial, a start included.
    timeout_ms: u32 = 15_000,
};

/// An installed fizzy. On macOS `bundle` is the `.app`, started through `open`.
pub const Install = struct {
    exe: []const u8,
    bundle: ?[]const u8 = null,
};

gpa: std.mem.Allocator,
io: Io,
opts: Options,
socket_path: ?[]u8 = null,
stream: ?Io.net.Stream = null,
endpoint: ?Endpoint = null,

pub fn init(gpa: std.mem.Allocator, io: Io, opts: Options) Client {
    return .{ .gpa = gpa, .io = io, .opts = opts };
}

pub fn deinit(self: *Client) void {
    self.close();
    if (self.socket_path) |p| self.gpa.free(p);
}

/// Where fizzy would be installed on `env.os`, likeliest first; not `$PATH` (`onPath`). Touches
/// nothing.
pub fn candidates(arena: std.mem.Allocator, identity: Identity, env: Env) error{OutOfMemory}![]const Install {
    var list: std.ArrayList(Install) = .empty;
    const sep: []const u8 = if (env.os == .windows) "\\" else "/";
    switch (env.os) {
        .macos => {
            const roots = [_]?[]const u8{
                "/Applications",
                if (env.home) |h| try join(
                    arena,
                    "/",
                    &.{ h, "Applications" },
                ) else null,
            };
            for (roots) |root_opt| {
                const root = root_opt orelse continue;
                const app = try std.fmt.allocPrint(arena, "{s}/{s}.app", .{ root, identity.display_name });
                try list.append(
                    arena,
                    .{ .exe = try join(arena, "/", &.{ app, "Contents/MacOS", identity.name }), .bundle = app },
                );
            }
        },
        .windows => if (env.local_app_data) |base| {
            // Velopack: %LOCALAPPDATA%\<packId>\current\<exe>.exe.
            const exe = try std.fmt.allocPrint(arena, "{s}.exe", .{identity.name});
            try list.append(arena, .{ .exe = try join(arena, sep, &.{ base, identity.name, "current", exe }) });
        },
        else => if (env.home) |h| {
            const packed_exe = try join(arena, sep, &.{ h, ".local/share", identity.name, "current", identity.name });
            try list.append(arena, .{ .exe = packed_exe });
            try list.append(arena, .{ .exe = try join(arena, sep, &.{ h, ".local/bin", identity.name }) });
            const image = try std.fmt.allocPrint(arena, "{s}.AppImage", .{identity.name});
            try list.append(arena, .{ .exe = try join(arena, sep, &.{ h, "Applications", image }) });
        },
    }
    return list.items;
}

/// `identity.name` in each `$PATH` directory. Tried after everything else: a bare `fizzy` on the
/// path may be a build or a stray copy, not the install.
fn onPath(arena: std.mem.Allocator, identity: Identity, env: Env) error{OutOfMemory}![]const Install {
    var list: std.ArrayList(Install) = .empty;
    const path = env.path orelse return list.items;
    const sep: []const u8 = if (env.os == .windows) "\\" else "/";
    const exe = if (env.os == .windows) try std.fmt.allocPrint(arena, "{s}.exe", .{identity.name}) else identity.name;
    var dirs = std.mem.tokenizeScalar(u8, path, if (env.os == .windows) ';' else ':');
    while (dirs.next()) |dir| try list.append(arena, .{ .exe = try join(arena, sep, &.{ dir, exe }) });
    return list.items;
}

fn join(arena: std.mem.Allocator, sep: []const u8, parts: []const []const u8) error{OutOfMemory}![]u8 {
    return std.mem.join(arena, sep, parts);
}

/// The installed fizzy. `FIZZY_EXE` is the only place looked when set: a named executable that
/// is not there is not installed.
pub fn locate(io: Io, arena: std.mem.Allocator, identity: Identity, env: Env) Error!Install {
    if (env.exe) |exe| return if (exists(io, exe)) .{ .exe = exe } else notFound(env);
    for (try candidates(arena, identity, env)) |install| {
        if (exists(io, install.exe)) return install;
    }
    if (lookupSystem(io, arena, identity, env)) |install| return install;
    for (try onPath(arena, identity, env)) |install| {
        if (exists(io, install.exe)) return install;
    }
    return notFound(env);
}

fn notFound(env: Env) Error {
    return if (env.sandboxed) error.Sandboxed else error.NotInstalled;
}

fn exists(io: Io, path: []const u8) bool {
    Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// Launch Services (macOS) and the registry's App Paths (Windows) know installs that no fixed
/// place does.
fn lookupSystem(io: Io, arena: std.mem.Allocator, identity: Identity, env: Env) ?Install {
    switch (env.os) {
        .macos => {
            if (std.mem.findAny(u8, identity.bundle_id, "\"\\") != null) return null;
            const query = std.fmt.allocPrint(
                arena,
                "kMDItemCFBundleIdentifier == \"{s}\"",
                .{identity.bundle_id},
            ) catch return null;
            const out = runCapture(io, arena, &.{ "/usr/bin/mdfind", query }) orelse return null;
            const bundle = std.mem.trim(u8, firstLine(out), " \t\r");
            if (bundle.len == 0) return null;
            const exe = join(arena, "/", &.{ bundle, "Contents/MacOS", identity.name }) catch return null;
            return if (exists(io, exe)) .{ .exe = exe, .bundle = bundle } else null;
        },
        .windows => for ([_][]const u8{ "HKCU", "HKLM" }) |hive| {
            const key = std.fmt.allocPrint(
                arena,
                "{s}\\Software\\Microsoft\\Windows\\CurrentVersion\\App Paths\\{s}.exe",
                .{ hive, identity.name },
            ) catch return null;
            const out = runCapture(io, arena, &.{ "reg", "query", key, "/ve" }) orelse continue;
            const exe = parseRegValue(out) orelse continue;
            if (exists(io, exe)) return .{ .exe = exe };
        },
        else => {},
    }
    return null;
}

/// The value in `reg query … /ve` output: `    (Default)    REG_SZ    C:\path\fizzy.exe`.
fn parseRegValue(out: []const u8) ?[]const u8 {
    const at = std.mem.find(u8, out, "REG_SZ") orelse return null;
    const line = firstLine(out[at + "REG_SZ".len ..]);
    const value = std.mem.trim(u8, line, " \t\r\"");
    return if (value.len == 0) null else value;
}

fn firstLine(text: []const u8) []const u8 {
    return text[0 .. std.mem.findScalar(u8, text, '\n') orelse text.len];
}

/// Stdout of a run that exited 0, or null.
fn runCapture(io: Io, arena: std.mem.Allocator, argv: []const []const u8) ?[]const u8 {
    const result = std.process.run(
        arena,
        io,
        .{ .argv = argv, .timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } } },
    ) catch return null;
    return switch (result.term) {
        .exited => |code| if (code == 0) result.stdout else null,
        else => null,
    };
}

/// The socket `install` listens on: `fizzy --control-path`, with the same profile as a launch.
pub fn controlPath(io: Io, arena: std.mem.Allocator, install: Install, profile: ?[]const u8) Error![]const u8 {
    const argv: []const []const u8 = if (profile) |p|
        &.{ install.exe, "--control-path", "--profile", p }
    else
        &.{ install.exe, "--control-path" };
    const result = std.process.run(
        arena,
        io,
        .{ .argv = argv, .timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } } },
    ) catch |err| return spawnError(err);
    // A fizzy that predates `--control-path` starts as an editor instead: no path to read.
    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    const path = std.mem.trim(u8, firstLine(result.stdout), " \t\r");
    if (!ok or path.len == 0) return error.FizzyTooOld;
    return path;
}

fn spawnError(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.AccessDenied, error.PermissionDenied => error.Sandboxed,
        error.Timeout => error.TimedOut,
        else => error.NotInstalled,
    };
}

/// Start fizzy without taking the person's focus. The child is left to run on its own.
fn startQuiet(io: Io, arena: std.mem.Allocator, install: Install, profile: ?[]const u8, opts: Options) Error!Started {
    var argv: std.ArrayList([]const u8) = .empty;
    const via_open = opts.env.os == .macos and install.bundle != null;
    if (via_open) {
        try argv.appendSlice(arena, &.{ "/usr/bin/open", "-g", "-j", install.bundle.?, "--args" });
    } else try argv.append(arena, install.exe);
    try argv.append(arena, "--quiet");
    if (profile) |p| try argv.appendSlice(arena, &.{ "--profile", p });
    const child = std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |err| return spawnError(err);
    return .{ .child = child, .via_open = via_open };
}

const Started = struct {
    child: std.process.Child,
    /// `open` returns at once and the app runs on: its exit says nothing of the app.
    via_open: bool,

    const Status = enum { running, exited_clean, failed };

    /// A started fizzy that is not `open`'s runs on after we connect, and its exit would leave a
    /// zombie until the host quits: wait for it on a thread of its own. If the thread cannot be
    /// made the child is left, as before.
    fn reapInBackground(self: *Started) void {
        if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) return;
        if (self.via_open) return;
        const pid = self.child.id orelse return;
        const thread = std.Thread.spawn(.{}, reap, .{pid}) catch return;
        thread.detach();
        self.child.id = null;
    }

    fn reap(pid: std.posix.pid_t) void {
        var wait_status: i32 = 0;
        while (true) {
            const rc = std.posix.system.waitpid(pid, &wait_status, 0);
            if (std.posix.errno(rc) != .INTR) return;
        }
    }

    fn status(self: *Started) Status {
        if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) return .running;
        const pid = self.child.id orelse return .running;
        var wait_status: i32 = 0;
        const rc = std.posix.system.waitpid(pid, &wait_status, std.posix.W.NOHANG);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {},
            else => return .running,
        }
        if (rc == 0) return .running;
        self.child.id = null;
        const raw: u32 = @bitCast(wait_status);
        const clean = std.posix.W.IFEXITED(raw) and std.posix.W.EXITSTATUS(raw) == 0;
        return if (clean) .exited_clean else .failed;
    }
};

const Deadline = struct {
    io: Io,
    at_ns: i96,

    fn init(io: Io, ms: u32) Deadline {
        return .{ .io = io, .at_ns = Io.Clock.awake.now(io).nanoseconds + @as(i96, ms) * std.time.ns_per_ms };
    }

    fn remainingMs(self: Deadline) u32 {
        const left = self.at_ns - Io.Clock.awake.now(self.io).nanoseconds;
        return if (left <= 0) 0 else @intCast(@divTrunc(left + std.time.ns_per_ms - 1, std.time.ns_per_ms));
    }
};

fn timeoutMs(ms: u32) Io.Timeout {
    return .{ .duration = .{ .raw = .fromMilliseconds(ms), .clock = .awake } };
}

/// One read of at most `buf.len` bytes: the count (0 is the end of the stream), or null when
/// `timeout` passed first.
pub fn readSome(io: Io, stream: Io.net.Stream, buf: []u8, timeout: Io.Timeout) error{Closed}!?usize {
    var data: [1][]u8 = .{buf};
    const result = io.operateTimeout(
        .{ .net_read = .{ .socket_handle = stream.socket.handle, .data = &data } },
        timeout,
    ) catch |err| switch (err) {
        error.Timeout => return null,
        else => return error.Closed,
    };
    const read = result.net_read catch return error.Closed;
    return read.data_len;
}

pub fn writeAll(io: Io, stream: Io.net.Stream, bytes: []const u8) error{Closed}!void {
    var buf: [1024]u8 = undefined;
    var writer = stream.writer(io, &buf);
    writer.interface.writeAll(bytes) catch return error.Closed;
    writer.interface.flush() catch return error.Closed;
}

/// Find, start if need be, connect and say hello. On error nothing stays open.
pub fn connect(self: *Client) Error!void {
    self.close();
    var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const deadline: Deadline = .init(self.io, self.opts.timeout_ms);
    const opts = self.opts;

    var install: ?Install = null;
    if (opts.socket_path) |p| {
        if (self.socket_path == null) self.socket_path = try self.gpa.dupe(u8, p);
    } else {
        const found = try locate(self.io, arena, opts.identity, opts.env);
        install = found;
        const path = try controlPath(self.io, arena, found, opts.env.profile);
        if (self.socket_path) |old| self.gpa.free(old);
        self.socket_path = try self.gpa.dupe(u8, path);
    }
    const socket = self.socket_path.?;
    const addr = Io.net.UnixAddress.init(socket) catch return error.Protocol;

    var started: ?Started = null;
    // Whatever ends `connect`, a fizzy we started is waited for when it exits. It is not killed:
    // a slow one may still come up and be found by a later `connect`.
    defer if (started) |*st| st.reapInBackground();
    var pause_ms: u32 = 10;
    while (true) {
        if (addr.connect(self.io)) |stream| {
            if (self.upgrade(stream, deadline)) |_| return else |err| switch (err) {
                // fizzy is quitting or still coming up: a later dial may be served.
                error.Closed => {},
                else => return err,
            }
        } else |err| switch (err) {
            error.AccessDenied, error.PermissionDenied => return error.Sandboxed,
            else => {},
        }
        if (!opts.start) return error.NotRunning;
        if (started == null) {
            const found = install orelse try locate(self.io, arena, opts.identity, opts.env);
            started = try startQuiet(self.io, arena, found, opts.env.profile, opts);
        } else if (!started.?.via_open and started.?.status() == .failed) {
            return error.StartFailed;
        }
        const left = deadline.remainingMs();
        if (left == 0) return error.TimedOut;
        self.io.sleep(.fromMilliseconds(@min(pause_ms, left)), .awake) catch return error.Closed;
        pause_ms = @min(pause_ms * 2, 250);
    }
}

/// `GET /remote` on `stream`, then the hellos. Takes ownership of `stream`.
fn upgrade(self: *Client, stream: Io.net.Stream, deadline: Deadline) Error!void {
    errdefer stream.close(self.io);
    try writeAll(
        self.io,
        stream,
        "GET /remote HTTP/1.1\r\nHost: localhost\r\nConnection: Upgrade\r\nUpgrade: " ++ upgrade_token ++ "\r\n\r\n",
    );

    var head: [2048]u8 = undefined;
    var len: usize = 0;
    const body_at = while (true) {
        if (std.mem.find(u8, head[0..len], "\r\n\r\n")) |at| break at + 4;
        if (len == head.len) return error.Protocol;
        const n = try readSome(
            self.io,
            stream,
            head[len..],
            timeoutMs(deadline.remainingMs()),
        ) orelse return error.TimedOut;
        if (n == 0) return error.Closed;
        len += n;
    };
    const status_line = firstLine(head[0..len]);
    if (std.mem.startsWith(u8, status_line, "HTTP/1.1 503")) return error.Closed;
    if (!std.mem.startsWith(u8, status_line, "HTTP/1.1 101")) return error.FizzyTooOld;

    var ep: Endpoint = .init(self.gpa, .host, .{
        .app_id = self.opts.host_name,
        .app_version = self.opts.host_version,
        .tiers_offered = self.opts.tiers,
        .tiers_wanted = self.opts.tiers,
    });
    errdefer ep.deinit();
    ep.start() catch |err| return epError(err);
    try ep.feed(head[body_at..len]);
    self.stream = stream;
    errdefer self.stream = null;
    try self.flush(&ep);

    var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena_state.deinit();
    var buf: [4096]u8 = undefined;
    while (true) {
        const got = ep.poll(arena_state.allocator()) catch |err| {
            self.flush(&ep) catch {};
            return skewError(&ep, err);
        };
        if (got) |msg| switch (msg) {
            .hello => break,
            .bye => |bye| return switch (bye.reason) {
                .your_side_too_old => error.ClientTooOld,
                .your_side_too_new => error.FizzyTooOld,
                else => error.Closed,
            },
            else => return error.Protocol,
        };
        const n = try readSome(self.io, stream, &buf, timeoutMs(deadline.remainingMs())) orelse return error.TimedOut;
        if (n == 0) return error.Closed;
        try ep.feed(buf[0..n]);
    }
    self.endpoint = ep;
}

fn epError(err: Endpoint.Error) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Closed => error.Closed,
        else => error.Protocol,
    };
}

fn skewError(ep: *const Endpoint, err: Endpoint.Error) Error {
    return switch (err) {
        error.VersionSkew => if (ep.conn.skew == .host) error.ClientTooOld else error.FizzyTooOld,
        error.OutOfMemory => error.OutOfMemory,
        else => error.Protocol,
    };
}

fn flush(self: *Client, ep: *Endpoint) Error!void {
    const stream = self.stream orelse return error.Closed;
    if (ep.pending().len == 0) return;
    try writeAll(self.io, stream, ep.pending());
    ep.consume(ep.pending().len);
}

/// Whether a stream is open (a drop shows on the next `poll` or `send`).
pub fn connected(self: *const Client) bool {
    return self.endpoint != null and self.stream != null;
}

/// Check `msg` against the conversation's rules and send it. A message the rules refuse is the
/// caller's mistake: it is not sent and the stream stays open. A write that fails closes the
/// client.
pub fn send(self: *Client, msg: message.Message) Error!void {
    const ep = &(self.endpoint orelse return error.Closed);
    if (self.stream == null) return self.closeStale();
    ep.send(msg) catch |err| return epError(err);
    self.flush(ep) catch |err| {
        self.close();
        return err;
    };
}

/// The next message from fizzy, waiting up to `wait_ms` (null: forever); null when that passes.
/// Lists are allocated from `arena`; strings borrow the client until the next `poll`, `send`,
/// `reconnect` or `close`, after which they dangle (a `bye`'s too: it borrows the endpoint, which
/// outlives the stream until then). Whatever ends the stream closes the client, and `reconnect`
/// opens it again.
pub fn poll(self: *Client, arena: std.mem.Allocator, wait_ms: ?u32) Error!?message.Message {
    const ep = &(self.endpoint orelse return error.Closed);
    const stream = self.stream orelse return self.closeStale();
    const deadline: ?Deadline = if (wait_ms) |ms| .init(self.io, ms) else null;
    var buf: [16 * 1024]u8 = undefined;
    while (true) {
        const got = ep.poll(arena) catch |err| {
            self.flush(ep) catch {};
            const failure = skewError(ep, err);
            self.close();
            return failure;
        };
        if (got) |msg| {
            if (msg == .bye) self.closeAfterBye();
            return msg;
        }
        const timeout: Io.Timeout = if (deadline) |d| timeoutMs(d.remainingMs()) else .none;
        const n = readSome(self.io, stream, &buf, timeout) catch |err| {
            self.close();
            return err;
        } orelse return null;
        if (n == 0) {
            self.close();
            return error.Closed;
        }
        ep.feed(buf[0..n]) catch |err| {
            self.close();
            return err;
        };
    }
}

/// The peer ended the conversation; its bye is the caller's to read, the stream is done. The
/// endpoint stays until the next `poll`, `send`, `reconnect` or `close`, because the bye's
/// strings borrow it and dangle once it is gone.
fn closeAfterBye(self: *Client) void {
    if (self.stream) |s| s.close(self.io);
    self.stream = null;
}

/// The stream ended with a bye already delivered: finish closing.
fn closeStale(self: *Client) error{Closed} {
    self.close();
    return error.Closed;
}

/// Open again after a drop, finding and starting fizzy as `connect` does. Views are gone with
/// the old stream: the host creates them again.
pub fn reconnect(self: *Client) Error!void {
    return self.connect();
}

pub fn close(self: *Client) void {
    if (self.endpoint) |*ep| ep.deinit();
    self.endpoint = null;
    if (self.stream) |s| s.close(self.io);
    self.stream = null;
}

test candidates {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const id: Identity = .{};

    const mac = try candidates(arena, id, .{ .os = .macos, .home = "/Users/a", .path = "/usr/bin:/opt/bin" });
    try std.testing.expectEqualStrings("/Applications/Fizzy.app/Contents/MacOS/fizzy", mac[0].exe);
    try std.testing.expectEqualStrings("/Applications/Fizzy.app", mac[0].bundle.?);
    try std.testing.expectEqualStrings("/Users/a/Applications/Fizzy.app", mac[1].bundle.?);
    try std.testing.expectEqual(@as(usize, 2), mac.len);
    const mac_path = try onPath(arena, id, .{ .os = .macos, .path = "/usr/bin:/opt/bin" });
    try std.testing.expectEqualStrings("/opt/bin/fizzy", mac_path[1].exe);

    const win = try candidates(
        arena,
        id,
        .{ .os = .windows, .local_app_data = "C:\\Users\\a\\AppData\\Local", .path = "C:\\bin;D:\\tools" },
    );
    try std.testing.expectEqualStrings("C:\\Users\\a\\AppData\\Local\\fizzy\\current\\fizzy.exe", win[0].exe);
    const win_path = try onPath(arena, id, .{ .os = .windows, .path = "C:\\bin;D:\\tools" });
    try std.testing.expectEqualStrings("D:\\tools\\fizzy.exe", win_path[1].exe);

    const linux = try candidates(arena, .{ .name = "paint" }, .{ .os = .linux, .home = "/home/a", .path = "/usr/bin" });
    try std.testing.expectEqualStrings("/home/a/.local/share/paint/current/paint", linux[0].exe);
    try std.testing.expectEqualStrings("/home/a/Applications/paint.AppImage", linux[2].exe);
    try std.testing.expectEqual(@as(usize, 3), linux.len);
    try std.testing.expectEqualStrings(
        "/usr/bin/paint",
        (try onPath(arena, .{ .name = "paint" }, .{ .os = .linux, .path = "/usr/bin" }))[0].exe,
    );
}

test parseRegValue {
    const out = "\r\nHKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion" ++
        "\\App Paths\\fizzy.exe\r\n    (Default)    REG_SZ    " ++
        "C:\\Users\\a\\AppData\\Local\\fizzy\\current\\fizzy.exe\r\n";
    try std.testing.expectEqualStrings("C:\\Users\\a\\AppData\\Local\\fizzy\\current\\fizzy.exe", parseRegValue(out).?);
    try std.testing.expect(parseRegValue("ERROR: The system was unable to find the specified registry key") == null);
}
