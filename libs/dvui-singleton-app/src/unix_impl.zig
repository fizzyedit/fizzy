//! Unix domain socket primary implementation (Linux, macOS, *BSD).
//! Uses `std.Io.net` (so the caller is responsible for providing an `Io`
//! that supports Unix sockets).

const std = @import("std");
const builtin = @import("builtin");
const root = @import("root.zig");

const log = std.log.scoped(.singleton_app);

// Boolean atomics aren't supported on every backend; use a u8 with 0/1.
const Running = std.atomic.Value(u8);

pub const AcquireArgs = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    app_id: []const u8,
    unix_socket_dir: []const u8,
    callback: ?root.SecondInstanceFn,
    user_data: ?*anyopaque,
    argv: []const []const u8,
};

pub const Primary = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    server: std.Io.net.Server,
    path: []u8,
    callback: ?root.SecondInstanceFn,
    user_data: ?*anyopaque,
    thread: std.Thread,
    running: Running,

    pub fn acquire(args: AcquireArgs) !?*Primary {
        const path = try buildSocketPath(args.allocator, args.unix_socket_dir, args.app_id);
        var path_owner: ?[]u8 = path;
        defer if (path_owner) |p| args.allocator.free(p);

        if (path.len > std.Io.net.UnixAddress.max_len) return root.Error.PathTooLong;
        const addr = std.Io.net.UnixAddress.init(path) catch return root.Error.PathTooLong;

        var attempt: u8 = 0;
        while (attempt < 2) : (attempt += 1) {
            const server = addr.listen(args.io, .{}) catch |err| switch (err) {
                error.AddressInUse => {
                    // Either a live primary is listening, or it's a stale socket.
                    if (try trySendArgv(args.io, addr, args.argv)) {
                        return null;
                    }
                    // Stale socket file — remove and retry.
                    _ = unlinkPath(path);
                    continue;
                },
                else => return err,
            };

            // Restrict access to the current user.
            _ = chmodPath(path, 0o600);

            const primary = try args.allocator.create(Primary);
            errdefer args.allocator.destroy(primary);
            primary.* = .{
                .allocator = args.allocator,
                .io = args.io,
                .server = server,
                .path = path,
                .callback = args.callback,
                .user_data = args.user_data,
                .thread = undefined,
                .running = Running.init(1),
            };
            path_owner = null;

            primary.thread = try std.Thread.spawn(.{}, acceptLoop, .{primary});
            return primary;
        }
        return root.Error.LockUnavailable;
    }

    pub fn shutdown(self: *Primary) void {
        self.running.store(0, .release);
        // Closing the server makes the in-flight `accept` return an error;
        // the loop sees `running == 0` and exits cleanly.
        self.server.deinit(self.io);
        self.thread.join();
        _ = unlinkPath(self.path);
        self.allocator.free(self.path);
    }

    fn acceptLoop(self: *Primary) void {
        while (self.running.load(.acquire) != 0) {
            const stream = self.server.accept(self.io) catch |err| {
                if (self.running.load(.acquire) == 0) return;
                log.warn("accept failed: {t}", .{err});
                std.Io.sleep(self.io, .fromMilliseconds(10), .awake) catch {};
                continue;
            };
            defer stream.close(self.io);

            var rbuf: [4096]u8 = undefined;
            var sr = stream.reader(self.io, &rbuf);
            const argv = root.readArgvIo(self.allocator, &sr.interface) catch |err| {
                log.warn("read argv failed: {t}", .{err});
                continue;
            };
            defer root.freeArgv(self.allocator, argv);

            if (self.callback) |cb| cb(argv, self.user_data);
        }
    }
};

fn trySendArgv(_: std.Io, addr: std.Io.net.UnixAddress, argv: []const []const u8) !bool {
    // Either the primary accepts us, or the socket file is stale. We can't
    // distinguish between "no listener" and other transient connect errors
    // without enumerating the impl's error set, so treat any failure here
    // as "no live primary" — the caller will fall through to remove the
    // stale socket and retry binding.
    //
    // Use libc connect directly: std.Io's posixConnectUnix does not map
    // ECONNREFUSED, so a stale socket triggers unexpectedErrno + stack trace
    // even though the caller catches the error.
    const fd = connectUnixClient(addr.path) orelse return false;
    defer _ = std.c.close(fd);

    writeArgvFd(fd, argv) catch return false;
    return true;
}

fn connectUnixClient(path: []const u8) ?std.c.fd_t {
    const sock = std.c.socket(std.c.AF.UNIX, std.c.SOCK.STREAM, 0);
    if (sock < 0) return null;
    errdefer _ = std.c.close(@intCast(sock));

    var storage: std.c.sockaddr.un = .{
        .family = std.c.AF.UNIX,
        .path = undefined,
    };
    const addr_len: std.c.socklen_t = @intCast(@offsetOf(std.c.sockaddr.un, "path") + path.len + 1);
    if (path.len >= storage.path.len) return null;
    @memcpy(storage.path[0..path.len], path);
    storage.path[path.len] = 0;
    const rc = std.c.connect(@intCast(sock), @ptrCast(&storage), addr_len);
    if (rc == 0) return @intCast(sock);
    _ = std.c.close(@intCast(sock));
    switch (std.posix.errno(rc)) {
        .CONNREFUSED => return null,
        else => return null,
    }
}

fn writeArgvFd(fd: std.c.fd_t, argv: []const []const u8) !void {
    var hdr: [4]u8 = undefined;
    std.mem.writeInt(u32, &hdr, @intCast(argv.len), .little);
    try writeAllFd(fd, &hdr);
    var total: u64 = 4;
    for (argv) |arg| {
        if (arg.len > root.max_arg_bytes) return root.Error.ArgTooLong;
        total += 4 + @as(u64, arg.len);
        if (total > root.max_total_bytes) return root.Error.PayloadTooLarge;
        std.mem.writeInt(u32, &hdr, @intCast(arg.len), .little);
        try writeAllFd(fd, &hdr);
        if (arg.len > 0) try writeAllFd(fd, arg);
    }
}

fn writeAllFd(fd: std.c.fd_t, bytes: []const u8) !void {
    var index: usize = 0;
    while (index < bytes.len) {
        const n = std.c.write(fd, bytes[index..].ptr, bytes.len - index);
        if (n < 0) return error.WriteFailed;
        index += @intCast(n);
    }
}

fn buildSocketPath(allocator: std.mem.Allocator, dir: []const u8, app_id: []const u8) ![]u8 {
    const trimmed = trimTrailingSlash(dir);
    const uid: u32 = @intCast(std.c.getuid());
    return std.fmt.allocPrint(allocator, "{s}/{s}-{d}.sock", .{ trimmed, app_id, uid });
}

fn trimTrailingSlash(s: []const u8) []const u8 {
    var n = s.len;
    while (n > 1 and s[n - 1] == '/') n -= 1;
    return s[0..n];
}

// Filesystem helpers: we drop straight to libc to stay independent of
// whatever filesystem flavour the caller is using through `std.Io`.

fn pathZ(buf: *[1024]u8, path: []const u8) ?[*:0]u8 {
    if (path.len >= buf.len) return null;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return @ptrCast(buf);
}

fn unlinkPath(path: []const u8) c_int {
    var buf: [1024]u8 = undefined;
    const p = pathZ(&buf, path) orelse return -1;
    return std.c.unlink(p);
}

fn chmodPath(path: []const u8, mode: std.c.mode_t) c_int {
    var buf: [1024]u8 = undefined;
    const p = pathZ(&buf, path) orelse return -1;
    return std.c.fchmodat(std.posix.AT.FDCWD, p, mode, 0);
}
