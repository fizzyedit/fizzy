//! The remote views of a running fizzy: the clients connected to `GET /remote`, each a `Session`,
//! and the views they opened, each a `RemoteViewHost` (plans/EMBEDDED_EDITOR_PLAN.md, step 3).
//! The control server hands over a connection it upgraded (`accept`); the UI thread calls `pump`
//! once a frame, which is the whole of the work: no thread per view, no blocking.
//!
//! **The seam to the frame.** What an app that draws remote views does each frame:
//! `views`, then for each host `place` it, `inject` its input into the window before the frame
//! draws, and `end` it after (setting `editor_draws`, so `pump` leaves the answering to it). Until
//! an app does, `pump` answers frame requests itself with the stub's fill and no input reaches a
//! window: a view the app has not placed has nothing under the pointer.
//! `TODO(seam)`: the editor's frame loop wires this (EMBEDDED_EDITOR_PLAN step 4).
const std = @import("std");
const sdk = @import("fizzy_sdk");
const remote = @import("remote");
const Link = @import("../control/Link.zig");
const RemoteViewHost = @import("RemoteViewHost.zig");
const Session = @import("Session.zig");

const Service = @This();

/// The `Upgrade` token of `GET /remote`, with the protocol's major version.
pub const upgrade_token = "fizzy-remote-view/1";

/// The most connections at once. Worst case per connection is about three `Link.max_backlog`s:
/// the inbox, the outbox, and what the writer task has taken from the outbox to write (up to the
/// same again), plus the capacity those lists retain. A connection that never says hello is not
/// timed out: the socket is the user's own (0600), and a handshake deadline would hook in
/// `Session.pump`, where a session with no peer hello after a time could be marked `dead`.
pub const max_sessions = 8;

gpa: std.mem.Allocator,
/// What fizzy says first to each client.
hello: remote.message.Hello,
sessions: std.ArrayListUnmanaged(*Session) = .empty,
next_session: u32 = 1,
/// The app draws the hosts itself (`end`); `pump` does not answer frames.
editor_draws: bool = false,
/// Owner of `fizzy.remote.views`, a pseudo-plugin as the other routes' are: never in
/// `host.plugins`.
plugin: sdk.Plugin = .{ .state = undefined, .vtable = &vtable, .id = "fizzy.remote", .display_name = "Remote views" },
registered: bool = false,

const vtable: sdk.Plugin.VTable = .{};

pub fn init(gpa: std.mem.Allocator, hello: remote.message.Hello) Service {
    return .{ .gpa = gpa, .hello = hello };
}

/// Drop every connection (their links must be gone: `closeAll` first) and the command.
pub fn deinit(self: *Service, host: *sdk.Host) void {
    if (self.registered) host.withdrawPlugin(&self.plugin);
    self.registered = false;
    self.sessions.deinit(self.gpa);
}

/// Take a connection the control server upgraded. The link is the service's from here: it frees it
/// once the connection's tasks are done with it.
pub fn accept(self: *Service, host: *sdk.Host, link: *Link) error{ OutOfMemory, TooManySessions }!void {
    if (self.sessions.items.len >= max_sessions) return error.TooManySessions;
    try self.ensureCommand(host);
    // The link is the caller's until this succeeds: nothing after the session fails.
    try self.sessions.ensureUnusedCapacity(self.gpa, 1);
    const session = try Session.create(self.gpa, link, self.hello);
    session.id = self.next_session;
    self.sessions.appendAssumeCapacity(session);
    self.next_session += 1;
}

/// Once a frame, on the UI thread: act on what every client sent, send what it earned, and let go
/// of a connection that is over.
pub fn pump(self: *Service) void {
    var i: usize = 0;
    while (i < self.sessions.items.len) {
        const s = self.sessions.items[i];
        if (s.pump(!self.editor_draws)) {
            s.destroy();
            _ = self.sessions.swapRemove(i);
        } else i += 1;
    }
}

/// Some connection has been closed and is not yet gone (`Link.reapStuck` is waiting on it).
pub fn anyClosing(self: *const Service) bool {
    for (self.sessions.items) |s| if (s.link.closed_at.load(.acquire) != 0) return true;
    return false;
}

/// End every connection, waiting for their tasks: at quit, or when the control server stops.
pub fn closeAll(self: *Service) void {
    for (self.sessions.items) |s| s.link.close();
    for (self.sessions.items) |s| {
        // Bounded: a peer that does not read is cut off after `Link.close_grace_ms`.
        while (!s.link.isGone()) {
            _ = s.link.reapStuck();
            // Keep waiting if the sleep is cancelled: the link's tasks may still run, and the
            // session is not ours to free until they are done.
            s.link.io.sleep(.fromMilliseconds(1), .awake) catch {};
        }
        s.destroy();
    }
    self.sessions.clearRetainingCapacity();
}

/// Every open view, in the order they were opened, into `out`.
pub fn views(self: *const Service, out: *std.ArrayListUnmanaged(*RemoteViewHost)) error{OutOfMemory}!void {
    for (self.sessions.items) |s| for (s.views.values()) |v| try out.append(self.gpa, v);
}

fn ensureCommand(self: *Service, host: *sdk.Host) error{OutOfMemory}!void {
    if (self.registered) return;
    self.plugin.state = self;
    host.registerCommand(.{
        .id = "fizzy.remote.views",
        .owner = &self.plugin,
        .title = "Remote Views",
        .visibility = .internal,
        .runWith = listViews,
    }) catch return error.OutOfMemory;
    self.registered = true;
}

const ViewInfo = struct {
    connection: u32,
    view: u32,
    kind: []const u8,
    target: []const u8,
    width: u32,
    height: u32,
    focused: bool,
};

/// `fizzy.remote.views`: the open views, as a list.
fn listViews(state: *anyopaque, call: *sdk.Command.Call) anyerror!void { // lint-allow(anyerror): `Command.runWith`'s signature
    const self: *Service = @ptrCast(@alignCast(state));
    var list: std.ArrayListUnmanaged(ViewInfo) = .empty;
    for (self.sessions.items) |s| for (s.views.values()) |v| try list.append(call.arena, .{
        .connection = s.id,
        .view = v.id,
        .kind = @tagName(v.kind),
        .target = v.target,
        .width = v.width,
        .height = v.height,
        .focused = v.focused,
    });
    try call.returns(list.items);
}
