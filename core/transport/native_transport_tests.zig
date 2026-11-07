//! Native HTTP deadline, redirect policy and stable filesystem wire-code contracts.
const std = @import("std");
const builtin = @import("builtin");
const NativeTransport = @import("NativeTransport.zig");
const vfs = @import("../vfs/vfs.zig");
const Fs = @import("../vfs/Fs.zig");

const Server = struct {
    io: std.Io,
    listener: std.Io.net.Server,
    thread: ?std.Thread = null,
    hold: bool,
    request_limit: usize,
    release: std.atomic.Value(bool) = .init(false),
    requests: std.atomic.Value(usize) = .init(0),

    fn start(hold: bool, request_limit: usize) !*Server {
        const self = try std.testing.allocator.create(Server);
        errdefer std.testing.allocator.destroy(self);
        const io = std.testing.io;
        const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        self.* = .{ .io = io, .listener = try address.listen(io, .{ .reuse_address = true }), .hold = hold, .request_limit = request_limit };
        errdefer self.listener.deinit(io);
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
        return self;
    }

    fn stop(self: *Server) void {
        self.release.store(true, .release);
        self.listener.deinit(self.io);
        if (self.thread) |thread| thread.join();
        std.testing.allocator.destroy(self);
    }

    fn serve(self: *Server) void {
        while (!self.release.load(.acquire) and self.requests.load(.acquire) < self.request_limit) {
            const stream = self.listener.accept(self.io) catch return;
            defer stream.close(self.io);
            var in_buf: [4096]u8 = undefined;
            var out_buf: [4096]u8 = undefined;
            var reader = stream.reader(self.io, &in_buf);
            var writer = stream.writer(self.io, &out_buf);
            var server = std.http.Server.init(&reader.interface, &writer.interface);
            var req = server.receiveHead() catch return;
            _ = self.requests.fetchAdd(1, .release);
            if (self.hold) {
                while (!self.release.load(.acquire)) std.Io.sleep(self.io, .fromMilliseconds(1), .awake) catch {};
                return;
            }
            if (std.mem.eql(u8, req.head.target, "/a")) {
                req.respond("", .{
                    .status = .found,
                    .extra_headers = &.{.{ .name = "Location", .value = "/b" }},
                    .keep_alive = false,
                }) catch return;
            } else {
                req.respond("here", .{ .keep_alive = false }) catch return;
                return;
            }
        }
    }
};

const Sink = struct {
    calls: usize = 0,
    err: ?vfs.Error = null,
    status: u16 = 0,
    body: ?[]u8 = null,

    fn done(ctx: ?*anyopaque, result: vfs.Error!vfs.http.Response) void {
        const self: *Sink = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        const response = result catch |err| {
            self.err = err;
            return;
        };
        self.status = response.status;
        self.body = response.body;
    }

    fn wait(self: *Sink, transport: vfs.http.Transport) !void {
        const io = std.testing.io;
        const start = std.Io.Clock.boot.now(io).nanoseconds;
        while (self.calls == 0) {
            if (std.Io.Clock.boot.now(io).nanoseconds - start > 5 * std.time.ns_per_s) return error.NoResponse;
            transport.pump();
            try std.Io.sleep(io, .fromMilliseconds(1), .awake);
        }
    }
};

test "a request past its timeout lands as Timeout" {
    if (builtin.target.cpu.arch == .wasm32) return error.SkipZigTest;
    const a = std.testing.allocator;
    const server = try Server.start(true, 1);
    defer server.stop();
    var nt = NativeTransport.init(a, std.testing.io, null);
    // Release the held connection before joining the worker, including on assertion failure.
    defer {
        server.release.store(true, .release);
        nt.deinit();
    }
    const url = try a.print("http://127.0.0.1:{d}/a", .{server.listener.socket.address.getPort()});
    defer a.free(url);
    var sink: Sink = .{};
    defer if (sink.body) |body| a.free(body);
    const start = std.Io.Clock.boot.now(std.testing.io).nanoseconds;
    _ = try nt.transport().request(a, .{ .method = .GET, .url = url, .timeout_ms = 50 }, Sink.done, &sink);
    try sink.wait(nt.transport());
    try std.testing.expectEqual(error.Timeout, sink.err.?);
    try std.testing.expect(std.Io.Clock.boot.now(std.testing.io).nanoseconds - start < std.time.ns_per_s);
    for (0..20) |_| {
        nt.transport().pump();
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    try std.testing.expectEqual(@as(usize, 1), sink.calls);
    server.release.store(true, .release);
    for (0..20) |_| {
        nt.transport().pump();
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    try std.testing.expectEqual(@as(usize, 1), sink.calls);
}

fn redirect(follow: bool) !void {
    const a = std.testing.allocator;
    const server = try Server.start(false, if (follow) 2 else 1);
    defer server.stop();
    var nt = NativeTransport.init(a, std.testing.io, null);
    defer nt.deinit();
    const url = try a.print("http://127.0.0.1:{d}/a", .{server.listener.socket.address.getPort()});
    defer a.free(url);
    var sink: Sink = .{};
    defer if (sink.body) |body| a.free(body);
    _ = try nt.transport().request(a, .{ .method = .GET, .url = url, .follow_redirects = follow }, Sink.done, &sink);
    try sink.wait(nt.transport());
    if (sink.err) |err| return err;
    try std.testing.expectEqual(@as(usize, 1), sink.calls);
    try std.testing.expectEqual(@as(u16, if (follow) 200 else 302), sink.status);
    try std.testing.expectEqual(@as(usize, if (follow) 2 else 1), server.requests.load(.acquire));
    if (follow) try std.testing.expectEqualStrings("here", sink.body.?);
}

test "a GET follows a redirect to its target" {
    if (builtin.target.cpu.arch == .wasm32) return error.SkipZigTest;
    try redirect(true);
}

test "a request that does not follow gets the redirect back" {
    if (builtin.target.cpu.arch == .wasm32) return error.SkipZigTest;
    try redirect(false);
}

test "Timeout is appended, every older code is the same" {
    const snapshot = [_]Fs.Error{
        error.Io,            error.OutOfMemory,  error.Unsupported, error.NotFound,
        error.NotADirectory, error.NotAFile,     error.NotEmpty,    error.Exists,
        error.NotBinary,     error.Unauthorized, error.Forbidden,   error.Http,
        error.InvalidJson,   error.Cancelled,    error.Conflict,
    };
    for (snapshot, 1..) |err, code| {
        const result = Fs.Result(void).of(err);
        try std.testing.expectEqual(@as(u8, @intCast(code)), result.code);
        try std.testing.expectError(err, result.get());
        try std.testing.expectError(err, (Fs.Result(void){ .code = @intCast(code), .value = {} }).get());
    }
    const timeout = Fs.Result(void).of(error.Timeout);
    try std.testing.expectEqual(@as(u8, 16), timeout.code);
    try std.testing.expectError(error.Timeout, timeout.get());
    try std.testing.expectError(error.Io, (Fs.Result(void){ .code = 255, .value = {} }).get());
}
