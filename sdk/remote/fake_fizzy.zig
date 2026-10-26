//! A stand-in for the fizzy executable, for `client_tests.zig`: answers `--control-path`, and
//! otherwise listens on `<profile>/control.sock` and speaks the editor's side of the remote-view
//! stream. How it behaves is the word in `<profile>/mode`, so a test sets it before the client
//! starts it:
//!
//!   * `serve` — listen at once.
//!   * `slow <ms>` — listen after a pause.
//!   * `crash` — exit 3 before listening.
//!   * `old` — hello with versions the client lacks.
//!   * `noremote` — answer `GET /remote` with 404, as a fizzy without a remote view does.
//!   * `bye` — answer `create_view` with a bye.
//!   * `drop` — close the first connection right after the hellos; the second is served.
//!
//! Each `--quiet` start appends a line to `<profile>/launches`. It answers `create_view` with
//! `view_created`, serves one connection (two for `drop`) and exits.
const std = @import("std");
const Io = std.Io;
const remote = @import("root.zig");
const Client = remote.Client;
const Endpoint = remote.Endpoint;
const message = remote.message;

const Mode = enum { serve, slow, crash, old, noremote, drop, bye };

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var profile: ?[]const u8 = null;
    var control_path = false;
    var quiet = false;
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--control-path")) control_path = true;
        if (std.mem.eql(u8, arg, "--quiet")) quiet = true;
        if (std.mem.eql(u8, arg, "--profile")) profile = args.next();
    }
    const dir = profile orelse std.process.exit(1);
    const sock = try std.fmt.allocPrint(gpa, "{s}/control.sock", .{dir});

    if (control_path) {
        var buf: [512]u8 = undefined;
        var out = Io.File.stdout().writer(io, &buf);
        try out.interface.print("{s}\n", .{sock});
        try out.interface.flush();
        return;
    }
    if (quiet) try appendLaunch(gpa, io, dir);

    const text = try Io.Dir.cwd().readFileAlloc(
        io,
        try std.fmt.allocPrint(gpa, "{s}/mode", .{dir}),
        gpa,
        .limited(256),
    );
    var words = std.mem.tokenizeAny(u8, text, " \r\n");
    const mode = std.meta.stringToEnum(Mode, words.next() orelse "serve") orelse .serve;
    switch (mode) {
        .crash => std.process.exit(3),
        .slow => try io.sleep(.fromMilliseconds(try std.fmt.parseInt(i64, words.next() orelse "300", 10)), .awake),
        else => {},
    }
    // A test that fails halfway leaves no fake behind.
    _ = io.concurrent(selfDestruct, .{io}) catch {};

    Io.Dir.deleteFileAbsolute(io, sock) catch {};
    var server = try (try Io.net.UnixAddress.init(sock)).listen(io, .{});
    defer server.deinit(io);
    const connections: usize = if (mode == .drop) 2 else 1;
    for (0..connections) |n| {
        const stream = try server.accept(io);
        defer stream.close(io);
        talk(gpa, io, stream, mode, n) catch {};
    }
}

fn selfDestruct(io: Io) void {
    io.sleep(.fromSeconds(30), .awake) catch {};
    std.process.exit(0);
}

fn appendLaunch(gpa: std.mem.Allocator, io: Io, dir: []const u8) !void {
    const path = try std.fmt.allocPrint(gpa, "{s}/launches", .{dir});
    const before = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(4096)) catch "";
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = try std.fmt.allocPrint(gpa, "{s}start\n", .{before}) });
}

fn talk(gpa: std.mem.Allocator, io: Io, stream: Io.net.Stream, mode: Mode, n: usize) !void {
    var head: [2048]u8 = undefined;
    var len: usize = 0;
    const body_at = while (true) {
        if (std.mem.find(u8, head[0..len], "\r\n\r\n")) |at| break at + 4;
        const got = try Client.readSome(io, stream, head[len..], .none) orelse return;
        if (got == 0) return;
        len += got;
    };
    if (mode == .noremote) return Client.writeAll(io, stream, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n");
    try Client.writeAll(
        io,
        stream,
        "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: " ++ Client.upgrade_token ++ "\r\n\r\n",
    );

    var ep: Endpoint = .init(
        gpa,
        .editor,
        .{
            .app_id = "fizzy-fake",
            .mode = .shared,
            .tiers_offered = .{ .draw_list = true },
            .version_min = if (mode == .old) 9 else message.min_version,
            .version_max = if (mode == .old) 9 else message.max_version,
        },
    );
    defer ep.deinit();
    try ep.start();
    try ep.feed(head[body_at..len]);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var buf: [4096]u8 = undefined;
    while (true) {
        _ = arena_state.reset(.retain_capacity);
        while (ep.poll(arena_state.allocator()) catch null) |msg| switch (msg) {
            .hello => if (mode == .drop and n == 0) {
                try Client.writeAll(io, stream, ep.pending());
                return;
            },
            .create_view => |cv| if (mode == .bye)
                try ep.send(.{ .bye = .{ .reason = .shutdown, .text = "going away" } })
            else
                try ep.send(.{ .view_created = .{
                    .view = cv.view,
                    .tier = .draw_list,
                    .width = cv.width,
                    .height = cv.height,
                } }),
            .bye => return,
            else => {},
        };
        try Client.writeAll(io, stream, ep.pending());
        ep.consume(ep.pending().len);
        const got = try Client.readSome(io, stream, &buf, .none) orelse return;
        if (got == 0) return;
        try ep.feed(buf[0..got]);
    }
}
