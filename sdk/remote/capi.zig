//! The C ABI over `Client` (`fizzy_remote.h`): an adapter in a host application (Blender,
//! Unreal, ...) finds, starts and connects to the installed fizzy and exchanges whole frames with
//! it. A frame is the wire's (`README.md`): the adapter's encoder/decoder is the generated half
//! this file leaves out, so what crosses here is bytes.
//!
//! Calls on one handle are not thread safe; two handles are independent.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const message = @import("message.zig");
const codec = @import("codec.zig");
const FrameReader = @import("FrameReader.zig");
const Client = @import("Client.zig");

/// `fizzy_remote_status` in the header: the numbers are the ABI.
const Status = enum(c_int) {
    ok = 0,
    not_installed = 1,
    not_running = 2,
    sandboxed = 3,
    fizzy_too_old = 4,
    client_too_old = 5,
    timed_out = 6,
    start_failed = 7,
    protocol = 8,
    closed = 9,
    out_of_memory = 10,
    buffer_too_small = 11,
    invalid_argument = 12,
};

fn status(err: Client.Error) c_int {
    return @backingInt(switch (err) {
        error.NotInstalled => Status.not_installed,
        error.NotRunning => .not_running,
        error.Sandboxed => .sandboxed,
        error.FizzyTooOld => .fizzy_too_old,
        error.ClientTooOld => .client_too_old,
        error.TimedOut => .timed_out,
        error.StartFailed => .start_failed,
        error.Protocol => .protocol,
        error.Closed => .closed,
        error.OutOfMemory => .out_of_memory,
    });
}

/// Every pointer is a NUL-terminated string or null (the default or the environment's).
pub const Options = extern struct {
    /// `sizeof` this struct, so a later field can be added without breaking a built adapter.
    size: u32,
    timeout_ms: u32,
    /// `FIZZY_REMOTE_NO_START` (1): connect to a running fizzy, never start one.
    flags: u32,
    host_name: ?[*:0]const u8,
    host_version: ?[*:0]const u8,
    /// The application to find, for an app built on fizzy: executable/pack id, macOS bundle name
    /// and bundle id. Fizzy's own when null.
    app_name: ?[*:0]const u8,
    app_display_name: ?[*:0]const u8,
    app_bundle_id: ?[*:0]const u8,
    /// Override `FIZZY_EXE`, `FIZZY_PROFILE`; and the socket itself, for a host that cannot run
    /// fizzy to ask.
    exe: ?[*:0]const u8,
    profile: ?[*:0]const u8,
    socket_path: ?[*:0]const u8,
};

const no_start_flag: u32 = 1;

const Handle = struct {
    arena: std.heap.ArenaAllocator,
    threaded: Io.Threaded,
    client: Client,
    /// An encoded message `recv` could not fit in the caller's buffer yet.
    stash: std.ArrayList(u8) = .empty,
    socket_z: ?[:0]u8 = null,

    fn refreshSocket(self: *Handle) void {
        const path = self.client.socket_path orelse return;
        self.socket_z = self.arena.allocator().dupeSentinel(u8, path, 0) catch return;
    }
};

const gpa = std.heap.smp_allocator;

fn dup(a: std.mem.Allocator, s: ?[*:0]const u8) error{OutOfMemory}!?[]const u8 {
    return if (s) |p| try a.dupe(u8, std.mem.span(p)) else null;
}

/// Find, start and connect: `*out` is a handle to close, on `ok` only.
export fn fizzy_remote_open(options: ?*const Options, out: ?*?*Handle) callconv(.c) c_int {
    const o = options orelse return @backingInt(Status.invalid_argument);
    const result = out orelse return @backingInt(Status.invalid_argument);
    result.* = null;
    if (o.size < @offsetOf(Options, "socket_path") + @sizeOf(?[*:0]const u8))
        return @backingInt(Status.invalid_argument);

    const handle = gpa.create(Handle) catch return @backingInt(Status.out_of_memory);
    handle.* = .{ .arena = .init(gpa), .threaded = .init(gpa, .{ .environ = processEnviron() }), .client = undefined };
    var started = false;
    defer if (!started) {
        handle.arena.deinit();
        handle.threaded.deinit();
        gpa.destroy(handle);
    };
    const a = handle.arena.allocator();

    const opts = clientOptions(a, o) catch return @backingInt(Status.out_of_memory);

    handle.client = .init(gpa, handle.threaded.io(), opts);
    handle.client.connect() catch |err| {
        handle.client.deinit();
        return status(err);
    };
    handle.refreshSocket();
    started = true;
    result.* = handle;
    return 0;
}

fn clientOptions(a: std.mem.Allocator, o: *const Options) error{OutOfMemory}!Client.Options {
    var opts: Client.Options = .{ .env = .fromProcess() };
    if (try dup(a, o.exe)) |v| opts.env.exe = v;
    if (try dup(a, o.profile)) |v| opts.env.profile = v;
    if (try dup(a, o.app_name)) |v| opts.identity.name = v;
    if (try dup(a, o.app_display_name)) |v| opts.identity.display_name = v;
    if (try dup(a, o.app_bundle_id)) |v| opts.identity.bundle_id = v;
    if (try dup(a, o.host_name)) |v| opts.host_name = v;
    if (try dup(a, o.host_version)) |v| opts.host_version = v;
    opts.socket_path = try dup(a, o.socket_path);
    opts.start = o.flags & no_start_flag == 0;
    if (o.timeout_ms != 0) opts.timeout_ms = o.timeout_ms;
    return opts;
}

fn processEnviron() std.process.Environ {
    if (comptime !builtin.link_libc or builtin.os.tag == .windows) return .empty;
    var n: usize = 0;
    while (std.c.environ[n] != null) n += 1;
    return .{ .block = .{ .slice = std.c.environ[0..n :null] } };
}

/// Connect again after a drop (`recv`/`send` returned `closed`), starting fizzy if it quit.
export fn fizzy_remote_reconnect(handle: ?*Handle) callconv(.c) c_int {
    const h = handle orelse return @backingInt(Status.invalid_argument);
    h.client.connect() catch |err| return status(err);
    h.refreshSocket();
    return 0;
}

/// Send one whole frame.
export fn fizzy_remote_send(handle: ?*Handle, frame: ?[*]const u8, len: usize) callconv(.c) c_int {
    const h = handle orelse return @backingInt(Status.invalid_argument);
    const bytes = (frame orelse return @backingInt(Status.invalid_argument))[0..len];
    var reader: FrameReader = .init(gpa);
    defer reader.deinit();
    reader.push(bytes) catch return @backingInt(Status.out_of_memory);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const frame_in = (reader.next() catch return @backingInt(Status.protocol)) orelse
        return @backingInt(Status.protocol);
    const msg = (codec.decode(arena.allocator(), frame_in) catch return @backingInt(Status.protocol)) orelse
        return @backingInt(Status.protocol);
    h.client.send(msg) catch |err| return status(err);
    return 0;
}

/// The next frame from fizzy into `buf`, waiting up to `timeout_ms` (negative: forever).
/// `*len` is its length; 0 with `ok` means the wait passed. A frame larger than `cap` is kept:
/// `buffer_too_small` with `*len` the size needed, then call again with room.
export fn fizzy_remote_recv(
    handle: ?*Handle,
    buf: ?[*]u8,
    cap: usize,
    len: ?*usize,
    timeout_ms: i32,
) callconv(.c) c_int {
    const h = handle orelse return @backingInt(Status.invalid_argument);
    const out_len = len orelse return @backingInt(Status.invalid_argument);
    out_len.* = 0;
    if (h.stash.items.len == 0) {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const wait: ?u32 = if (timeout_ms < 0) null else @intCast(timeout_ms);
        const msg = (h.client.poll(arena.allocator(), wait) catch |err| return status(err)) orelse return 0;
        codec.encode(gpa, &h.stash, msg, codec.default_max_frame) catch return @backingInt(Status.protocol);
    }
    out_len.* = h.stash.items.len;
    if (h.stash.items.len > cap or buf == null) return @backingInt(Status.buffer_too_small);
    @memcpy(buf.?[0..h.stash.items.len], h.stash.items);
    h.stash.clearRetainingCapacity();
    return 0;
}

/// The control socket in use, valid until the next call on the handle; null before a connect.
export fn fizzy_remote_socket_path(handle: ?*const Handle) callconv(.c) ?[*:0]const u8 {
    const h = handle orelse return null;
    return if (h.socket_z) |p| p.ptr else null;
}

/// A short English reason for a status, for a host's log; never null.
export fn fizzy_remote_status_string(code: c_int) callconv(.c) [*:0]const u8 {
    return switch (std.enums.fromInt(Status, code) orelse return "unknown status") {
        .ok => "ok",
        .not_installed => "fizzy is not installed",
        .not_running => "fizzy is not running",
        .sandboxed => "this app's sandbox hides or forbids fizzy",
        .fizzy_too_old => "fizzy is too old: update fizzy",
        .client_too_old => "this add-on is too old: update it",
        .timed_out => "fizzy did not answer in time",
        .start_failed => "fizzy exited while starting",
        .protocol => "fizzy did not speak the protocol",
        .closed => "the connection closed",
        .out_of_memory => "out of memory",
        .buffer_too_small => "the buffer is too small",
        .invalid_argument => "invalid argument",
    };
}

/// The newest protocol version this library speaks.
export fn fizzy_remote_protocol_version() callconv(.c) u32 {
    return message.max_version;
}

/// End the connection and free the handle. Fizzy keeps running.
export fn fizzy_remote_close(handle: ?*Handle) callconv(.c) void {
    const h = handle orelse return;
    h.client.deinit();
    h.stash.deinit(gpa);
    h.threaded.deinit();
    h.arena.deinit();
    gpa.destroy(h);
}

const t = std.testing;

test "the C ABI opens, round trips a frame and closes" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const profile = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(profile);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "mode", .data = "serve" });

    var opts = std.mem.zeroes(Options);
    opts.size = @sizeOf(Options);
    opts.timeout_ms = 5000;
    opts.host_name = "c-test";
    const fake = try t.allocator.dupeSentinel(u8, @import("client_tests.zig").fake_exe, 0);
    defer t.allocator.free(fake);
    opts.exe = fake;
    opts.profile = profile;
    var handle: ?*Handle = null;
    try t.expectEqual(@as(c_int, 0), fizzy_remote_open(&opts, &handle));
    defer fizzy_remote_close(handle);
    try t.expect(std.mem.endsWith(u8, std.mem.span(fizzy_remote_socket_path(handle).?), "control.sock"));

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(t.allocator);
    try codec.encode(
        t.allocator,
        &out,
        .{ .create_view = .{ .view = 3, .width = 64, .height = 48 } },
        codec.default_max_frame,
    );
    try t.expectEqual(@as(c_int, 0), fizzy_remote_send(handle, out.items.ptr, out.items.len));

    var small: [4]u8 = undefined;
    var len: usize = 0;
    try t.expectEqual(@backingInt(Status.buffer_too_small), fizzy_remote_recv(handle, &small, small.len, &len, 5000));
    try t.expect(len > small.len);
    var frame: [256]u8 = undefined;
    try t.expectEqual(@as(c_int, 0), fizzy_remote_recv(handle, &frame, frame.len, &len, 5000));
    var reader: FrameReader = .init(t.allocator);
    defer reader.deinit();
    try reader.push(frame[0..len]);
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const created = (try codec.decode(arena.allocator(), (try reader.next()).?)).?.view_created;
    try t.expectEqual(@as(u32, 3), created.view);

    try t.expectEqual(@as(c_int, 0), fizzy_remote_recv(handle, &frame, frame.len, &len, 20));
    try t.expectEqual(@as(usize, 0), len);
}

test "the C ABI says why it could not open" {
    var opts = std.mem.zeroes(Options);
    opts.size = @sizeOf(Options);
    opts.exe = "/nonexistent/fizzy";
    var handle: ?*Handle = null;
    const code = fizzy_remote_open(&opts, &handle);
    try t.expectEqual(@backingInt(Status.not_installed), code);
    try t.expect(handle == null);
    try t.expectEqualStrings("fizzy is not installed", std.mem.span(fizzy_remote_status_string(code)));
    try t.expectEqual(@backingInt(Status.invalid_argument), fizzy_remote_open(null, &handle));
}
