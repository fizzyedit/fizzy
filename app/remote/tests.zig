//! Remote views end to end: a `Session` over an in-memory link, the input that reaches a dvui
//! window, one body of calls run against a local host and a remote one, and a client on the real
//! control socket.
const std = @import("std");
const dvui = @import("dvui");
const sdk = @import("fizzy_sdk");
const remote = @import("remote");
const Link = @import("../control/Link.zig");
const Server = @import("../control/Server.zig");
const routes = @import("../control/routes.zig");
const RemoteViewHost = @import("RemoteViewHost.zig");
const Service = @import("Service.zig");
const Session = @import("Session.zig");
const ViewHost = @import("../view/ViewHost.zig");

const message = remote.message;
const Message = message.Message;

fn noWake() void {}

const hello_client: message.Hello = .{ .app_id = "blender", .tiers_offered = .{ .draw_list = true } };
const hello_fizzy: message.Hello = .{ .app_id = "fizzy", .tiers_offered = .{ .draw_list = true }, .mode = .standalone };

/// A client with no socket: its bytes cross a `Link` and the session is pumped by hand.
const Harness = struct {
    link: *Link,
    session: *Session,
    client: remote.Endpoint,
    arena: std.heap.ArenaAllocator,

    fn init(self: *Harness) !void {
        const gpa = std.testing.allocator;
        const link = try gpa.create(Link);
        link.* = .init(gpa, std.testing.io, noWake);
        errdefer gpa.destroy(link);
        self.* = .{
            .link = link,
            .session = try Session.create(gpa, link, hello_fizzy),
            .client = .init(gpa, .host, hello_client),
            .arena = .init(gpa),
        };
        try self.client.start();
        try self.step();
        const hello = (try self.next()).hello;
        try std.testing.expectEqualStrings("fizzy", hello.app_id);
    }

    fn deinit(self: *Harness) void {
        self.client.deinit();
        self.arena.deinit();
        // The connection's tasks would set this; there are none.
        self.link.finish();
        self.session.destroy();
    }

    /// Send what the client queued, pump the session, bring back what it answered.
    fn step(self: *Harness) !void {
        try self.link.push(self.client.pending());
        self.client.consume(self.client.pending().len);
        _ = self.session.pump(true);
        if (try self.link.drain()) |bytes| {
            defer std.testing.allocator.free(bytes);
            try self.client.feed(bytes);
        }
    }

    fn next(self: *Harness) !Message {
        _ = self.arena.reset(.retain_capacity);
        return (try self.client.poll(self.arena.allocator())) orelse error.NothingSent;
    }

    fn silent(self: *Harness) !void {
        _ = self.arena.reset(.retain_capacity);
        try std.testing.expect(try self.client.poll(self.arena.allocator()) == null);
    }

    fn openView(self: *Harness, id: message.ViewId, w: u32, h: u32) !*RemoteViewHost {
        try self.client.send(.{ .create_view = .{ .view = id, .width = w, .height = h, .target = "Main" } });
        try self.step();
        try std.testing.expectEqual(id, (try self.next()).view_created.view);
        return self.session.views.get(id).?;
    }
};

test "a client opens a view and gets the frame it asks for" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const v = try h.openView(1, 320, 200);
    try std.testing.expectEqualStrings("Main", v.target);

    try h.client.send(.{ .frame_request = .{ .view = 1, .seq = 1 } });
    try h.step();
    const frame = (try h.next()).frame;
    try std.testing.expectEqual(@as(u64, 1), frame.seq);
    try std.testing.expectEqual(@as(u32, 320), frame.width);
    try std.testing.expectEqual(message.Tier.draw_list, frame.tier);
    try std.testing.expectEqual(@as(usize, 4), frame.draw.vertices.len);
    try std.testing.expectEqual(@as(f32, 320), frame.draw.vertices[2].x);

    // Requests that pile up are answered once, by the newest.
    try h.client.send(.{ .frame_request = .{ .view = 1, .seq = 2 } });
    try h.client.send(.{ .frame_request = .{ .view = 1, .seq = 3 } });
    try h.step();
    try std.testing.expectEqual(@as(u64, 3), (try h.next()).frame.seq);
    try h.silent();

    // Resized, the next frame has the new size.
    try h.client.send(.{ .resize = .{ .view = 1, .width = 64, .height = 32 } });
    try h.client.send(.{ .frame_request = .{ .view = 1, .seq = 4 } });
    try h.step();
    try std.testing.expectEqual(@as(u32, 64), (try h.next()).frame.width);
}

test "input is held for the frame, keys and text only while the view has focus" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const v = try h.openView(1, 100, 100);

    try h.client.send(.{ .key = .{ .view = 1, .down = true, .host_code = 0, .code = 4 } });
    try h.client.send(.{ .text_input = .{ .view = 1, .text = "ignored" } });
    try h.client.send(.{ .pointer_motion = .{ .view = 1, .x = 1, .y = 2 } });
    try h.step();
    try std.testing.expectEqual(@as(usize, 1), v.input.items.len);

    try h.client.send(.{ .focus = .{ .view = 1, .focused = true } });
    try h.client.send(.{ .key = .{ .view = 1, .down = true, .host_code = 0, .code = 4 } });
    try h.client.send(.{ .text_input = .{ .view = 1, .text = "hi" } });
    try h.step();
    try std.testing.expectEqual(@as(usize, 3), v.input.items.len);
    try std.testing.expectEqualStrings("hi", v.input.items[2].text);
}

test "input reaches a window where the view lies, and not before it is placed" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const v = try h.openView(1, 100, 100);
    try h.client.send(.{ .focus = .{ .view = 1, .focused = true } });
    try h.client.send(.{ .pointer_button = .{ .view = 1, .button = 0, .pressed = true, .x = 5, .y = 6 } });
    try h.client.send(.{ .key = .{ .view = 1, .down = true, .host_code = 0, .code = 4 } });
    try h.client.send(.{ .text_input = .{ .view = 1, .text = "hi" } });
    try h.step();

    var t = try dvui.testing.init(.{});
    defer t.deinit();
    try v.inject(t.window);
    for (t.window.events.items) |e| try std.testing.expect(e.evt == .mouse and e.evt.mouse.action == .position);
    try std.testing.expectEqual(@as(usize, 0), v.input.items.len);

    try h.client.send(.{ .pointer_button = .{ .view = 1, .button = 0, .pressed = true, .x = 5, .y = 6 } });
    try h.client.send(.{ .key = .{ .view = 1, .down = true, .host_code = 0, .code = 4 } });
    try h.client.send(.{ .text_input = .{ .view = 1, .text = "hi" } });
    try h.step();
    v.place(.{ .x = 30, .y = 40 });
    try v.inject(t.window);
    var pressed_at: ?dvui.Point.Physical = null;
    var key: ?dvui.enums.Key = null;
    var text: []const u8 = "";
    for (t.window.events.items) |e| switch (e.evt) {
        .mouse => |m| if (m.action == .press) {
            pressed_at = m.p;
        },
        .key => |k| key = k.code,
        .text => |tx| text = tx.action.value.txt,
        else => {},
    };
    try std.testing.expectEqual(@as(f32, 35), pressed_at.?.x);
    try std.testing.expectEqual(@as(f32, 46), pressed_at.?.y);
    try std.testing.expectEqual(dvui.enums.Key.a, key.?);
    try std.testing.expectEqualStrings("hi", text);
}

test "closing a view tells the client, and the host is gone from the session" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.openView(1, 100, 100);
    try h.client.send(.{ .close_view = .{ .view = 1 } });
    try h.step();
    const closed = (try h.next()).view_closed;
    try std.testing.expectEqual(@as(u32, 1), closed.view);
    try std.testing.expectEqual(message.ViewClosedReason.closed, closed.reason);
    try std.testing.expectEqual(@as(usize, 0), h.session.views.count());
}

test "a view the app cannot serve is refused, not left half open" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.client.send(.{ .create_view = .{ .view = 1, .width = 10, .height = 10, .tier = .shared_texture } });
    try h.client.send(.{ .create_view = .{ .view = 2, .width = 0, .height = 10 } });
    try h.step();
    try std.testing.expectEqual(message.ViewClosedReason.unsupported_tier, (try h.next()).view_closed.reason);
    try std.testing.expectEqual(message.ViewClosedReason.create_failed, (try h.next()).view_closed.reason);
    try std.testing.expectEqual(@as(usize, 0), h.session.views.count());
    // Ids are free to use again.
    _ = try h.openView(1, 10, 10);
}

test "a protocol violation ends the connection with a bye" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.openView(1, 10, 10);
    try h.link.push(&.{ 1, 0, 0, 0 });
    _ = h.session.pump(true);
    try std.testing.expect(h.session.dead);
    try std.testing.expect(h.link.closing.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), h.session.views.count());
    const out = (try h.link.drain()).?;
    defer std.testing.allocator.free(out);
    try h.client.feed(out);
    try std.testing.expectEqual(message.CloseReason.protocol_error, (try h.next()).bye.reason);
}

/// What an app does with a view's host each frame, through the seam alone.
fn editorFacing(host: ViewHost, w: f32, h: f32) !void {
    const first = host.begin().?;
    try std.testing.expectEqual(w, first.w);
    try std.testing.expectEqual(h, first.h);
    try std.testing.expect(host.begin() == null);
    try std.testing.expectEqual(w, host.surface().w);
    try std.testing.expect(!host.closeRequested());
    try std.testing.expect(!host.space().covers);
    try std.testing.expect(host.materialBase(.{ .r = 1, .g = 2, .b = 3, .a = 255 }, 1) == null);
    host.end();
}

test "one editor-facing body runs against a local host and a remote one" {
    const Local = struct {
        moved: bool = true,
        pub fn begin(l: *@This()) ?dvui.Rect.Physical {
            defer l.moved = false;
            return if (l.moved) surface(l) else null;
        }
        pub fn end(_: *@This()) void {}
        pub fn surface(_: *@This()) dvui.Rect.Physical {
            return .{ .w = 100, .h = 50 };
        }
        pub fn space(_: *@This()) ViewHost.Space {
            return .{};
        }
        pub fn materialBase(_: *@This(), _: dvui.Color, _: f32) ?dvui.Color {
            return null;
        }
        pub fn closeRequested(_: *@This()) bool {
            return false;
        }
    };
    var local: Local = .{};
    try editorFacing(.{ .ptr = &local, .vtable = ViewHost.vtableOf(Local) }, 100, 50);

    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const v = try h.openView(1, 100, 50);
    try editorFacing(v.viewHost(), 100, 50);
    // The seam sees the client's close.
    try h.client.send(.{ .close_view = .{ .view = 1 } });
    try h.step();
    try std.testing.expectEqual(@as(usize, 0), h.session.views.count());
}

/// A client on the real socket: blocking, on a thread of its own, as an adapter is.
const Peer = struct {
    ep: remote.Endpoint,
    stream: std.Io.net.Stream,
    reader: std.Io.net.Stream.Reader,
    writer: std.Io.net.Stream.Writer,
    rbuf: [4096]u8 = undefined,
    wbuf: [4096]u8 = undefined,
    arena: std.heap.ArenaAllocator,

    const request = "GET /remote HTTP/1.1\r\nHost: x\r\nConnection: Upgrade\r\nUpgrade: " ++ Service.upgrade_token ++ "\r\n\r\n";

    fn open(self: *Peer, path: []const u8) !void {
        const io = std.testing.io;
        const gpa = std.testing.allocator;
        self.stream = try (try std.Io.net.UnixAddress.init(path)).connect(io);
        errdefer self.stream.close(io);
        self.reader = self.stream.reader(io, &self.rbuf);
        self.writer = self.stream.writer(io, &self.wbuf);
        self.ep = .init(gpa, .host, hello_client);
        errdefer self.ep.deinit();
        self.arena = .init(gpa);
        try self.writer.interface.writeAll(request);
        try self.writer.interface.flush();
        var head: [512]u8 = undefined;
        var n: usize = 0;
        while (!std.mem.endsWith(u8, head[0..n], "\r\n\r\n")) {
            head[n] = try self.reader.interface.takeByte();
            n += 1;
        }
        if (!std.mem.startsWith(u8, head[0..n], "HTTP/1.1 101 ")) return error.NotUpgraded;
        try self.ep.start();
        try self.flush();
        try std.testing.expectEqualStrings("fizzy", (try self.next()).hello.app_id);
    }

    fn close(self: *Peer) void {
        self.ep.deinit();
        self.arena.deinit();
        self.stream.close(std.testing.io);
    }

    fn flush(self: *Peer) !void {
        try self.writer.interface.writeAll(self.ep.pending());
        try self.writer.interface.flush();
        self.ep.consume(self.ep.pending().len);
    }

    fn send(self: *Peer, msg: Message) !void {
        try self.ep.send(msg);
        try self.flush();
    }

    /// Blocks until the editor has said something.
    fn next(self: *Peer) !Message {
        _ = self.arena.reset(.retain_capacity);
        while (true) {
            if (try self.ep.poll(self.arena.allocator())) |m| return m;
            const got = try self.reader.interface.peekGreedy(1);
            try self.ep.feed(got);
            self.reader.interface.toss(got.len);
        }
    }
};

const Client = struct {
    path: []const u8,
    /// How far the script has got, for the test to wait on.
    stage: std.atomic.Value(u32) = .init(0),
    failed: std.atomic.Value(bool) = .init(false),
    frame_seq: u64 = 0,
    frame_width: u32 = 0,

    fn run(self: *Client, drop: bool) void {
        self.play(drop) catch |err| {
            std.log.warn("remote test client: {s}", .{@errorName(err)});
            self.failed.store(true, .release);
        };
        self.stage.store(99, .release);
    }

    fn play(self: *Client, drop: bool) !void {
        var peer: Peer = undefined;
        try peer.open(self.path);
        defer peer.close();
        try peer.send(.{ .create_view = .{ .view = 1, .width = 320, .height = 200, .target = "Main" } });
        const created = (try peer.next()).view_created;
        if (created.view != 1 or created.tier != .draw_list) return error.WrongView;
        try peer.send(.{ .focus = .{ .view = 1, .focused = true } });
        try peer.send(.{ .pointer_motion = .{ .view = 1, .x = 3, .y = 4 } });
        try peer.send(.{ .pointer_button = .{ .view = 1, .button = 0, .pressed = true, .x = 3, .y = 4 } });
        try peer.send(.{ .key = .{ .view = 1, .down = true, .host_code = 0, .code = 4 } });
        try peer.send(.{ .text_input = .{ .view = 1, .text = "hi" } });
        try peer.send(.{ .frame_request = .{ .view = 1, .seq = 1 } });
        const frame = (try peer.next()).frame;
        self.frame_seq = frame.seq;
        self.frame_width = frame.width;
        self.stage.store(1, .release);
        if (drop) {
            // Gone with a frame asked for and unread.
            try peer.send(.{ .frame_request = .{ .view = 1, .seq = 2 } });
            return;
        }
        try peer.send(.{ .close_view = .{ .view = 1 } });
        _ = (try peer.next()).view_closed;
    }
};

test "a remote client opens a view, sends input, gets frames, and leaves without hurting the app" {
    if (!std.Io.net.has_unix_sockets) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var host: sdk.Host = .init(gpa);
    defer host.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir);
    const path = try std.fs.path.join(gpa, &.{ dir, "c.sock" });
    defer gpa.free(path);
    var server: Server = .{ .gpa = gpa, .io = io, .socket_path = path, .wake = noWake };
    try server.start();
    var state: routes.State = .{};
    var stopped = false;
    defer if (!stopped) routes.stop(&server, &state, &host);

    var first: Client = .{ .path = path };
    const t1 = try std.Thread.spawn(.{}, Client.run, .{ &first, true });
    var frames: usize = 0;
    while (first.stage.load(.acquire) < 1 and frames < 5000) : (frames += 1) {
        routes.answerPending(&server, &state, &host);
        io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expect(!first.failed.load(.acquire));
    try std.testing.expectEqual(@as(u64, 1), first.frame_seq);
    try std.testing.expectEqual(@as(u32, 320), first.frame_width);

    // The app lists the view, and its input waits for the frame.
    const remote_service = &state.remote.?;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const listed = host.callCommand("fizzy.remote.views", "", arena_state.allocator());
    try std.testing.expect(std.mem.find(u8, listed.ok.?, ".target = \"Main\"") != null);
    try std.testing.expect(std.mem.find(u8, listed.ok.?, ".width = 320") != null);
    var all: std.ArrayList(*RemoteViewHost) = .empty;
    defer all.deinit(gpa);
    try remote_service.views(&all);
    try std.testing.expectEqual(@as(usize, 1), all.items.len);
    try std.testing.expectEqual(@as(usize, 4), all.items[0].input.items.len);

    // It drops the connection with a frame asked for: the session and its view go, the app carries on.
    frames = 0;
    while (remote_service.sessions.items.len > 0 and frames < 5000) : (frames += 1) {
        routes.answerPending(&server, &state, &host);
        io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    t1.join();
    try std.testing.expectEqual(@as(usize, 0), remote_service.sessions.items.len);
    try std.testing.expect(std.mem.find(u8, host.callCommand("fizzy.remote.views", "", arena_state.allocator()).ok.?, "view") == null);

    // A second client is served as if the first had never been.
    var second: Client = .{ .path = path };
    const t2 = try std.Thread.spawn(.{}, Client.run, .{ &second, false });
    frames = 0;
    while (second.stage.load(.acquire) < 99 and frames < 5000) : (frames += 1) {
        routes.answerPending(&server, &state, &host);
        io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    t2.join();
    try std.testing.expect(!second.failed.load(.acquire));
    try std.testing.expectEqual(@as(u64, 1), second.frame_seq);

    // Stopping closes what is still open.
    routes.stop(&server, &state, &host);
    stopped = true;
}

/// One plain request on the socket; the status line is what the test reads.
fn statusOf(path: []const u8, request: []const u8, out: []u8) ![]const u8 {
    const io = std.testing.io;
    const stream = try (try std.Io.net.UnixAddress.init(path)).connect(io);
    defer stream.close(io);
    var wbuf: [256]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    try w.interface.writeAll(request);
    try w.interface.flush();
    var rbuf: [256]u8 = undefined;
    var r = stream.reader(io, &rbuf);
    var n: usize = 0;
    while (n < out.len and !std.mem.endsWith(u8, out[0..n], "\r\n\r\n")) : (n += 1) out[n] = try r.interface.takeByte();
    return out[0 .. std.mem.findScalar(u8, out[0..n], '\r') orelse n];
}

test "GET /remote needs the upgrade, and only GET" {
    if (!std.Io.net.has_unix_sockets) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var host: sdk.Host = .init(gpa);
    defer host.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir);
    const path = try std.fs.path.join(gpa, &.{ dir, "c.sock" });
    defer gpa.free(path);
    var server: Server = .{ .gpa = gpa, .io = io, .socket_path = path, .wake = noWake };
    try server.start();
    var state: routes.State = .{};
    defer routes.stop(&server, &state, &host);

    const Ask = struct {
        path: []const u8,
        request: []const u8,
        status: [128]u8 = undefined,
        len: usize = 0,
        fn run(self: *@This()) void {
            var buf: [512]u8 = undefined;
            const line = statusOf(self.path, self.request, &buf) catch return;
            @memcpy(self.status[0..line.len], line);
            self.len = line.len;
        }
    };
    var plain: Ask = .{ .path = path, .request = "GET /remote HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n" };
    var post: Ask = .{ .path = path, .request = "POST /remote HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\nConnection: close\r\n\r\n" };
    const ta = try std.Thread.spawn(.{}, Ask.run, .{&plain});
    const tb = try std.Thread.spawn(.{}, Ask.run, .{&post});
    var frames: usize = 0;
    while ((plain.len == 0 or post.len == 0) and frames < 5000) : (frames += 1) {
        routes.answerPending(&server, &state, &host);
        io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    ta.join();
    tb.join();
    try std.testing.expectEqualStrings("HTTP/1.1 426 Upgrade Required", plain.status[0..plain.len]);
    try std.testing.expectEqualStrings("HTTP/1.1 405 Method Not Allowed", post.status[0..post.len]);
    try std.testing.expect(state.remote == null);
}

test "a flood of motion keeps the last, and a release survives a full queue" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const v = try h.openView(1, 100, 100);
    try h.client.send(.{ .focus = .{ .view = 1, .focused = true } });
    try h.client.send(.{ .key = .{ .view = 1, .down = true, .host_code = 0, .code = 4 } });
    try h.client.send(.{ .focus = .{ .view = 1, .focused = false } });
    for (0..4) |i| try h.client.send(.{ .pointer_motion = .{ .view = 1, .x = @floatFromInt(i), .y = 0 } });
    try h.client.send(.{ .key = .{ .view = 1, .down = false, .host_code = 0, .code = 4 } });
    try h.client.send(.{ .resize = .{ .view = 1, .width = 0, .height = 0 } });
    try h.step();
    // The key down, one motion (the last), the key up although focus had left.
    try std.testing.expectEqual(@as(usize, 3), v.input.items.len);
    try std.testing.expectEqual(@as(f32, 3), v.input.items[1].motion.x);
    try std.testing.expect(!v.input.items[2].key.down);
    try std.testing.expectEqual(@as(u32, 100), v.width);
}

test "queued text is bounded in bytes, and a connection holds a bounded number of views" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const v = try h.openView(1, 100, 100);
    v.focused = true;
    const chunk = RemoteViewHost.max_text_bytes / 2 + 1;
    for (0..3) |_| try v.queue(.{ .text = try std.testing.allocator.alloc(u8, chunk) });
    // The second would pass the cap, so only the first waits.
    try std.testing.expectEqual(@as(usize, 1), v.input.items.len);
    try std.testing.expectEqual(chunk, v.text_bytes);

    for (2..Session.max_views + 3) |i| try h.client.send(.{ .create_view = .{ .view = @intCast(i), .width = 10, .height = 10 } });
    try h.step();
    try std.testing.expectEqual(@as(usize, Session.max_views), h.session.views.count());
}

test "a service takes max_sessions connections, refuses the next, and a connection whose tasks are done frees a slot" {
    const gpa = std.testing.allocator;
    var svc: Service = .init(gpa, hello_fizzy);
    // The command is registered once and not needed here: no host is touched.
    svc.registered = true;
    const host: *sdk.Host = undefined;
    defer {
        // The connections' tasks would set this; there are none, and `closeAll` waits for it.
        for (svc.sessions.items) |s| s.link.finish();
        svc.closeAll();
        svc.sessions.deinit(gpa);
    }
    for (0..Service.max_sessions) |_| {
        const link = try gpa.create(Link);
        link.* = .init(gpa, std.testing.io, noWake);
        try svc.accept(host, link);
    }
    const extra = try gpa.create(Link);
    extra.* = .init(gpa, std.testing.io, noWake);
    try std.testing.expectError(error.TooManySessions, svc.accept(host, extra));
    // The caller keeps a refused link.
    extra.deinit();
    gpa.destroy(extra);

    // A connection whose tasks are done is dropped by the next pump.
    const first = svc.sessions.items[0].link;
    first.close();
    first.finish();
    svc.pump();
    try std.testing.expectEqual(@as(usize, Service.max_sessions - 1), svc.sessions.items.len);
    const again = try gpa.create(Link);
    again.* = .init(gpa, std.testing.io, noWake);
    try svc.accept(host, again);
    try std.testing.expectEqual(@as(usize, Service.max_sessions), svc.sessions.items.len);
}

/// A raw upgraded connection that never reads past the `101`: all a stuck peer is.
fn upgradeRaw(path: []const u8) !std.Io.net.Stream {
    const io = std.testing.io;
    const stream = try (try std.Io.net.UnixAddress.init(path)).connect(io);
    errdefer stream.close(io);
    var wbuf: [256]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    try w.interface.writeAll(Peer.request);
    try w.interface.flush();
    return stream;
}

fn refusedStatus(path: []const u8, out: *[128]u8, result: *[]const u8, replied: *std.atomic.Value(bool)) void {
    result.* = statusOf(path, Peer.request, out) catch "error";
    replied.store(true, .release);
}

test "on the socket, the ninth client is refused with 503, and a peer that stops reading is cut off to free its slot" {
    if (!std.Io.net.has_unix_sockets) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var host: sdk.Host = .init(gpa);
    defer host.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir);
    const path = try std.fs.path.join(gpa, &.{ dir, "c.sock" });
    defer gpa.free(path);
    var server: Server = .{ .gpa = gpa, .io = io, .socket_path = path, .wake = noWake };
    try server.start();
    var state: routes.State = .{};
    var stopped = false;
    defer if (!stopped) routes.stop(&server, &state, &host);

    var streams: [Service.max_sessions]std.Io.net.Stream = undefined;
    var opened: usize = 0;
    defer for (streams[0..opened]) |s| s.close(io);
    for (&streams) |*s| {
        s.* = try upgradeRaw(path);
        opened += 1;
    }
    var frames: usize = 0;
    const svc_ptr = blk: {
        while (state.remote == null and frames < 5000) : (frames += 1) {
            routes.answerPending(&server, &state, &host);
            io.sleep(.fromMilliseconds(1), .awake) catch {};
        }
        break :blk &state.remote.?;
    };
    while (svc_ptr.sessions.items.len < Service.max_sessions and frames < 5000) : (frames += 1) {
        routes.answerPending(&server, &state, &host);
        io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expectEqual(@as(usize, Service.max_sessions), svc_ptr.sessions.items.len);

    // The next is refused with a plain 503, not a 101.
    var head: [128]u8 = undefined;
    var status: []const u8 = "";
    var replied: std.atomic.Value(bool) = .init(false);
    const t = try std.Thread.spawn(.{}, refusedStatus, .{ path, &head, &status, &replied });
    frames = 0;
    while (!replied.load(.acquire) and frames < 5000) : (frames += 1) {
        routes.answerPending(&server, &state, &host);
        io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    t.join();
    try std.testing.expectEqualStrings("HTTP/1.1 503 Service Unavailable", status);
    try std.testing.expectEqual(@as(usize, Service.max_sessions), svc_ptr.sessions.items.len);

    // Fill the first peer's way until its writer blocks, then close: the grace period ends in an
    // abort, and the next pump frees the slot.
    const link = svc_ptr.sessions.items[0].link;
    const big = try gpa.alloc(u8, 8 * 1024 * 1024);
    defer gpa.free(big);
    @memset(big, 0);
    try link.send(big);
    try link.send(big);
    io.sleep(.fromMilliseconds(200), .awake) catch {};
    try std.testing.expect(!link.isGone());
    link.close();
    frames = 0;
    while (svc_ptr.sessions.items.len == Service.max_sessions and frames < 10000) : (frames += 1) {
        _ = link.reapStuck();
        routes.answerPending(&server, &state, &host);
        io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expectEqual(@as(usize, Service.max_sessions - 1), svc_ptr.sessions.items.len);

    routes.stop(&server, &state, &host);
    stopped = true;
}
