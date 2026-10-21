//! `Client` against `fake_fizzy.zig`, a stand-in executable that listens on a test socket. The
//! build compiles it and names its path in the `fake_fizzy_options` import, so these run under
//! `zig build test`, not a bare `zig test`. POSIX only: the fake's socket and the child's exit
//! status are skipped on Windows.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const remote = @import("root.zig");
const Client = remote.Client;
const message = remote.message;

const t = std.testing;

/// The compiled `fake_fizzy.zig`.
pub const fake_exe: []const u8 = @import("fake_fizzy_options").fake_fizzy;

const Fixture = struct {
    tmp: t.TmpDir,
    profile: [:0]u8,
    fake: []const u8,

    fn init(mode: []const u8) !Fixture {
        if (builtin.os.tag == .windows) return error.SkipZigTest;
        var tmp = t.tmpDir(.{});
        errdefer tmp.cleanup();
        const profile = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
        errdefer t.allocator.free(profile);
        try tmp.dir.writeFile(t.io, .{ .sub_path = "mode", .data = mode });
        return .{ .tmp = tmp, .profile = profile, .fake = fake_exe };
    }

    fn deinit(self: *Fixture) void {
        t.allocator.free(self.profile);
        self.tmp.cleanup();
    }

    fn options(self: *const Fixture) Client.Options {
        return .{ .env = .{ .exe = self.fake, .profile = self.profile }, .host_name = "test-host", .timeout_ms = 5000 };
    }

    /// How many times the fake was started with `--quiet`.
    fn starts(self: *const Fixture) usize {
        const text = self.tmp.dir.readFileAlloc(t.io, "launches", t.allocator, .limited(4096)) catch return 0;
        defer t.allocator.free(text);
        return std.mem.count(u8, text, "start\n");
    }
};

/// A view round trip: proof the stream carries the conversation past the hellos.
fn roundTrip(client: *Client, view: message.ViewId) !void {
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    try client.send(.{ .create_view = .{ .view = view, .width = 320, .height = 200 } });
    const created = (try client.poll(arena_state.allocator(), 5000)).?.view_created;
    try t.expectEqual(view, created.view);
    try t.expectEqual(@as(u32, 320), created.width);
}

test "a fizzy that is already listening is found, not started again" {
    var fx = try Fixture.init("serve");
    defer fx.deinit();
    var child = try std.process.spawn(t.io, .{
        .argv = &.{ fx.fake, "--quiet", "--profile", fx.profile },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer _ = child.wait(t.io) catch {};
    var listening = false;
    for (0..500) |_| {
        if (fx.tmp.dir.access(t.io, "control.sock", .{})) |_| {
            listening = true;
            break;
        } else |_| try t.io.sleep(.fromMilliseconds(10), .awake);
    }
    try t.expect(listening);

    var client: Client = .init(t.allocator, t.io, fx.options());
    defer client.deinit();
    try client.connect();
    try roundTrip(&client, 1);
    try t.expectEqual(@as(usize, 1), fx.starts());
}

test "nothing listening: fizzy is started quietly and connected to" {
    var fx = try Fixture.init("serve");
    defer fx.deinit();
    var client: Client = .init(t.allocator, t.io, fx.options());
    defer client.deinit();
    try client.connect();
    try roundTrip(&client, 7);
    try t.expectEqual(@as(usize, 1), fx.starts());
}

test "not installed, not running, and sandboxed are three errors" {
    var fx = try Fixture.init("serve");
    defer fx.deinit();
    const nowhere = try std.fmt.allocPrint(t.allocator, "{s}/nope", .{fx.profile});
    defer t.allocator.free(nowhere);

    var opts = fx.options();
    opts.env.exe = nowhere;
    var client: Client = .init(t.allocator, t.io, opts);
    defer client.deinit();
    try t.expectError(error.NotInstalled, client.connect());

    // A search that finds nothing in a home with nothing in it.
    opts.env = .{ .os = .linux, .home = fx.profile, .path = fx.profile };
    client.opts = opts;
    try t.expectError(error.NotInstalled, client.connect());
    client.opts.env.sandboxed = true;
    try t.expectError(error.Sandboxed, client.connect());
    try t.expectEqual(@as(usize, 0), fx.starts());

    // A named socket nobody listens on, and no start asked for.
    opts.env = .{};
    opts.socket_path = nowhere;
    opts.start = false;
    client.opts = opts;
    try t.expectError(error.NotRunning, client.connect());
}

test "a slow start is waited for, a too slow one times out and is found later" {
    var fx = try Fixture.init("slow 300");
    defer fx.deinit();
    var client: Client = .init(t.allocator, t.io, fx.options());
    defer client.deinit();
    try client.connect();
    try roundTrip(&client, 1);
    client.close();

    var slow = try Fixture.init("slow 2500");
    defer slow.deinit();
    var opts = slow.options();
    opts.timeout_ms = 1000;
    var late: Client = .init(t.allocator, t.io, opts);
    defer late.deinit();
    try t.expectError(error.TimedOut, late.connect());
    // The process may not have run far enough to note its start when the deadline passed.
    for (0..100) |_| {
        if (slow.starts() != 0) break;
        try t.io.sleep(.fromMilliseconds(50), .awake);
    }
    try t.expectEqual(@as(usize, 1), slow.starts());
    late.opts.start = false;
    late.opts.timeout_ms = 5000;
    // Not started a second time: the first one finishes starting and is found.
    var found = false;
    for (0..100) |_| {
        late.connect() catch {
            try t.io.sleep(.fromMilliseconds(50), .awake);
            continue;
        };
        found = true;
        break;
    }
    try t.expect(found);
    try t.expectEqual(@as(usize, 1), slow.starts());
}

test "a fizzy that dies while starting is StartFailed" {
    var fx = try Fixture.init("crash");
    defer fx.deinit();
    var client: Client = .init(t.allocator, t.io, fx.options());
    defer client.deinit();
    try t.expectError(error.StartFailed, client.connect());
    try t.expectEqual(@as(usize, 1), fx.starts());
}

test "versions: a fizzy from the future or the past says who updates" {
    var newer = try Fixture.init("old");
    defer newer.deinit();
    var client: Client = .init(t.allocator, t.io, newer.options());
    defer client.deinit();
    try t.expectError(error.ClientTooOld, client.connect());
    try t.expect(!client.connected());

    var no_remote = try Fixture.init("noremote");
    defer no_remote.deinit();
    client.opts = no_remote.options();
    try t.expectError(error.FizzyTooOld, client.connect());
}

test "a dropped stream closes the client and reconnect opens it again" {
    var fx = try Fixture.init("drop");
    defer fx.deinit();
    var client: Client = .init(t.allocator, t.io, fx.options());
    defer client.deinit();
    try client.connect();
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    try t.expectError(error.Closed, client.poll(arena_state.allocator(), 5000));
    try t.expect(!client.connected());
    try t.expectError(error.Closed, client.send(.{ .create_view = .{ .view = 1, .width = 1, .height = 1 } }));

    try client.reconnect();
    try roundTrip(&client, 1);
    try t.expectEqual(@as(usize, 1), fx.starts());
}

test "polling after a bye closes the client instead of crashing" {
    var fx = try Fixture.init("bye");
    defer fx.deinit();
    var client: Client = .init(t.allocator, t.io, fx.options());
    defer client.deinit();
    try client.connect();
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    try client.send(.{ .create_view = .{ .view = 1, .width = 1, .height = 1 } });
    const bye = (try client.poll(arena_state.allocator(), 5000)).?.bye;
    try t.expectEqualStrings("going away", bye.text);
    try t.expect(!client.connected());
    try t.expectError(error.Closed, client.poll(arena_state.allocator(), 100));
    try t.expectError(error.Closed, client.send(.{ .create_view = .{ .view = 2, .width = 1, .height = 1 } }));
}
