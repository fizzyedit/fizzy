//! The rules of a conversation, with no bytes in it: hello first each way, one agreed version,
//! views created and closed in order, frame answers matching requests. One side of one
//! connection; `sending` checks what this side is about to say, `received` what the peer said.
//!
//! Bytes are not its business, so the in-process transport (calls into an editor component in the
//! same process) hands `Message` values across with the same two functions, and the socket
//! transport wraps them in `Endpoint`.
const std = @import("std");
const message = @import("message.zig");
const Message = message.Message;
const ViewId = message.ViewId;

const Connection = @This();

pub const Role = message.Role;

pub const Error = error{
    /// This message is not allowed before both hellos have been exchanged.
    NotOpen,
    /// A second hello from the same side, or a hello with an empty version range.
    BadHello,
    /// The versions have nothing in common; `skew` says which side must update. The connection
    /// is closed.
    VersionSkew,
    /// The sender is not the side that may send this type.
    WrongDirection,
    UnknownView,
    DuplicateView,
    /// The view is being closed: nothing more may be sent to it.
    ViewClosing,
    /// A request `seq` that does not rise.
    SeqNotIncreasing,
    /// A frame answering a `seq` that was never asked for, or one already answered.
    UnexpectedFrame,
    /// After `bye`.
    Closed,
    OutOfMemory,
};

pub const State = enum { awaiting_hello, open, closed };

pub const View = struct {
    created: bool = false,
    closing: bool = false,
    tier: message.Tier = .draw_list,
    width: u32 = 0,
    height: u32 = 0,
    scale: f32 = 1,
    focused: bool = false,
    /// Highest `seq` the host asked for, and the highest the editor answered.
    requested: u64 = 0,
    answered: u64 = 0,
};

gpa: std.mem.Allocator,
role: Role,
local: message.Hello,
state: State = .awaiting_hello,
hello_sent: bool = false,
hello_received: bool = false,
/// The protocol version in use, once open.
version: u16 = 0,
/// The peer's hello, once received; its strings are not kept.
peer: message.Hello = .{},
/// Set with `error.VersionSkew`: who has to update.
skew: ?Role = null,
/// Why the connection closed, once it has.
close_reason: ?message.CloseReason = null,
views: std.AutoHashMapUnmanaged(ViewId, View) = .empty,

pub fn init(gpa: std.mem.Allocator, role: Role, local: message.Hello) Connection {
    return .{ .gpa = gpa, .role = role, .local = local };
}

pub fn deinit(self: *Connection) void {
    self.views.deinit(self.gpa);
}

pub fn view(self: *const Connection, id: ViewId) ?View {
    return self.views.get(id);
}

/// The tiers both sides offer. (`tiers_wanted` is the peer's preference among them; the editor
/// decides the tier a view gets.)
pub fn tiersAgreed(self: *const Connection) message.Tiers {
    return self.local.tiers_offered.both(self.peer.tiers_offered);
}

/// Feature bits both sides set.
pub fn featuresAgreed(self: *const Connection) u64 {
    return self.local.features & self.peer.features;
}

/// Check and record a message this side is about to send.
pub fn sending(self: *Connection, msg: Message) Error!void {
    if (self.state == .closed) return error.Closed;
    return self.apply(msg, self.role);
}

/// Check and record a message the peer sent.
pub fn received(self: *Connection, msg: Message) Error!void {
    if (self.state == .closed) return error.Closed;
    const peer_role: Role = if (self.role == .host) .editor else .host;
    return self.apply(msg, peer_role);
}

fn apply(self: *Connection, msg: Message, from: Role) Error!void {
    const mine = from == self.role;
    switch (msg.tag().sender()) {
        .either => {},
        .host => if (from != .host) return error.WrongDirection,
        .editor => if (from != .editor) return error.WrongDirection,
    }
    switch (msg) {
        .hello => |h| {
            if (h.version_min > h.version_max) {
                self.state = .closed;
                self.close_reason = .protocol_error;
                return error.BadHello;
            }
            if (mine) {
                if (self.hello_sent) return error.BadHello;
                self.hello_sent = true;
            } else {
                if (self.hello_received) return error.BadHello;
                self.hello_received = true;
                self.peer = h;
                self.peer.app_id = "";
                self.peer.app_version = "";
                switch (message.negotiate(self.local, h)) {
                    .version => |v| self.version = v,
                    // Whoever is too old is the one that updates.
                    .peer_too_old => return self.fail(.{ .reason = .your_side_too_old, .update = from }),
                    .peer_too_new => return self.fail(.{ .reason = .your_side_too_new, .update = self.role }),
                }
            }
            if (self.hello_sent and self.hello_received) self.state = .open;
            return;
        },
        .bye => |b| {
            self.state = .closed;
            self.close_reason = b.reason;
            return;
        },
        else => {},
    }
    // Everything else: this side's hello is out (so the peer knows our version before we use
    // it), and the peer's is in when it is the peer speaking.
    if (mine and self.state != .open) return error.NotOpen;
    if (!mine and !self.hello_received) return error.NotOpen;

    switch (msg) {
        .create_view => |m| {
            if (m.view == 0) return error.UnknownView;
            if (self.views.contains(m.view)) return error.DuplicateView;
            try self.views.put(self.gpa, m.view, .{ .tier = m.tier, .width = m.width, .height = m.height, .scale = m.scale });
        },
        .view_created => |m| {
            const v = self.views.getPtr(m.view) orelse return error.UnknownView;
            if (v.created) return error.DuplicateView;
            v.created = true;
            v.tier = m.tier;
            v.width = m.width;
            v.height = m.height;
        },
        .view_closed => |m| {
            if (!self.views.remove(m.view)) return error.UnknownView;
        },
        .frame => |m| {
            const v = self.views.getPtr(m.view) orelse return error.UnknownView;
            if (!v.created or m.tier != v.tier) return error.UnexpectedFrame;
            if (m.seq <= v.answered or m.seq > v.requested) return error.UnexpectedFrame;
            v.answered = m.seq;
        },
        else => {
            const id = msg.view().?;
            const v = self.views.getPtr(id) orelse return error.UnknownView;
            if (from == .host and v.closing) return error.ViewClosing;
            switch (msg) {
                .close_view => v.closing = true,
                .resize => |m| {
                    v.width = m.width;
                    v.height = m.height;
                    v.scale = m.scale;
                },
                .focus => |m| v.focused = m.focused,
                .frame_request => |m| {
                    if (m.seq <= v.requested) return error.SeqNotIncreasing;
                    v.requested = m.seq;
                },
                else => {},
            }
        },
    }
}

const Failure = struct { reason: message.CloseReason, update: Role };

fn fail(self: *Connection, f: Failure) Error {
    self.state = .closed;
    self.close_reason = f.reason;
    self.skew = f.update;
    return error.VersionSkew;
}

const t = std.testing;

fn pair() struct { host: Connection, editor: Connection } {
    return .{
        .host = Connection.init(t.allocator, .host, .{}),
        .editor = Connection.init(t.allocator, .editor, .{ .mode = .shared }),
    };
}

/// Send `msg` from one side and deliver it to the other.
fn say(from: *Connection, to: *Connection, msg: Message) !void {
    try from.sending(msg);
    try to.received(msg);
}

fn open(p: *@TypeOf(pair())) !void {
    try say(&p.host, &p.editor, .{ .hello = p.host.local });
    try say(&p.editor, &p.host, .{ .hello = p.editor.local });
    try t.expectEqual(State.open, p.host.state);
    try t.expectEqual(State.open, p.editor.state);
    try t.expectEqual(@as(u16, 1), p.host.version);
}

test "hello first, each way, then open" {
    var p = pair();
    defer p.host.deinit();
    defer p.editor.deinit();
    try t.expectError(error.NotOpen, p.host.sending(.{ .focus = .{ .view = 1, .focused = true } }));
    try open(&p);
    try t.expectError(error.BadHello, p.host.sending(.{ .hello = .{} }));
}

test "a peer speaking before its hello is refused" {
    var p = pair();
    defer p.host.deinit();
    defer p.editor.deinit();
    try t.expectError(error.NotOpen, p.editor.received(.{ .close_view = .{ .view = 1 } }));
}

test "a view's life, and the frames that answer requests" {
    var p = pair();
    defer p.host.deinit();
    defer p.editor.deinit();
    try open(&p);
    try say(&p.host, &p.editor, .{ .create_view = .{ .view = 7, .width = 100, .height = 50 } });
    try t.expectError(error.DuplicateView, p.host.sending(.{ .create_view = .{ .view = 7, .width = 1, .height = 1 } }));
    // The host may pipeline input before the view is confirmed.
    try say(&p.host, &p.editor, .{ .focus = .{ .view = 7, .focused = true } });
    try say(&p.editor, &p.host, .{ .view_created = .{ .view = 7, .tier = .draw_list, .width = 100, .height = 50 } });
    try t.expect(p.host.view(7).?.focused);

    try t.expectError(error.UnexpectedFrame, p.editor.sending(.{ .frame = .{ .view = 7, .seq = 1, .tier = .draw_list } }));
    try say(&p.host, &p.editor, .{ .frame_request = .{ .view = 7, .seq = 1 } });
    try t.expectError(error.SeqNotIncreasing, p.host.sending(.{ .frame_request = .{ .view = 7, .seq = 1 } }));
    try say(&p.host, &p.editor, .{ .frame_request = .{ .view = 7, .seq = 3 } });
    // Fizzy may skip seq 1 and answer 3 only; 2 was never asked, and 3 cannot be answered twice.
    try say(&p.editor, &p.host, .{ .frame = .{ .view = 7, .seq = 3, .tier = .draw_list } });
    try t.expectError(error.UnexpectedFrame, p.editor.sending(.{ .frame = .{ .view = 7, .seq = 3, .tier = .draw_list } }));
    try t.expectError(error.UnexpectedFrame, p.editor.sending(.{ .frame = .{ .view = 7, .seq = 4, .tier = .draw_list } }));

    try say(&p.host, &p.editor, .{ .close_view = .{ .view = 7 } });
    try t.expectError(error.ViewClosing, p.host.sending(.{ .resize = .{ .view = 7, .width = 1, .height = 1 } }));
    // The editor's in-flight messages still arrive until it confirms.
    try say(&p.editor, &p.host, .{ .frame_ready = .{ .view = 7 } });
    try say(&p.editor, &p.host, .{ .view_closed = .{ .view = 7 } });
    try t.expectError(error.UnknownView, p.editor.sending(.{ .frame_ready = .{ .view = 7 } }));
}

test "the editor can refuse or end a view on its own" {
    var p = pair();
    defer p.host.deinit();
    defer p.editor.deinit();
    try open(&p);
    try say(&p.host, &p.editor, .{ .create_view = .{ .view = 2, .width = 1, .height = 1 } });
    try say(&p.editor, &p.host, .{ .view_closed = .{ .view = 2, .reason = .unsupported_tier } });
    try t.expect(p.host.view(2) == null);
}

test "each side may send only its own messages" {
    var p = pair();
    defer p.host.deinit();
    defer p.editor.deinit();
    try open(&p);
    try t.expectError(error.WrongDirection, p.host.sending(.{ .cursor = .{ .view = 1, .shape = .arrow } }));
    try t.expectError(error.WrongDirection, p.host.received(.{ .create_view = .{ .view = 1, .width = 1, .height = 1 } }));
}

test "no common version closes, naming who updates" {
    var p = pair();
    defer p.host.deinit();
    defer p.editor.deinit();
    // An adapter from the future: it wants 5..6, fizzy speaks 1.
    p.host.local.version_min = 5;
    p.host.local.version_max = 6;
    try p.host.sending(.{ .hello = p.host.local });
    try t.expectError(error.VersionSkew, p.editor.received(.{ .hello = p.host.local }));
    try t.expectEqual(Role.editor, p.editor.skew.?);
    try t.expectEqual(message.CloseReason.your_side_too_new, p.editor.close_reason.?);
    try t.expectError(error.Closed, p.editor.sending(.{ .hello = .{} }));

    // And the other way: fizzy newer than an adapter that tops out below it.
    var q = pair();
    defer q.host.deinit();
    defer q.editor.deinit();
    q.editor.local.version_min = 4;
    q.editor.local.version_max = 4;
    try t.expectError(error.VersionSkew, q.editor.received(.{ .hello = .{} }));
    try t.expectEqual(Role.host, q.editor.skew.?);
    try t.expectEqual(message.CloseReason.your_side_too_old, q.editor.close_reason.?);
}

test "bye closes" {
    var p = pair();
    defer p.host.deinit();
    defer p.editor.deinit();
    try open(&p);
    try say(&p.host, &p.editor, .{ .bye = .{ .reason = .shutdown } });
    try t.expectEqual(State.closed, p.editor.state);
    try t.expectError(error.Closed, p.editor.sending(.{ .frame_ready = .{ .view = 1 } }));
}

test "view 0 is no view, and a frame must match its view's tier" {
    var p = pair();
    defer p.host.deinit();
    defer p.editor.deinit();
    try open(&p);
    try t.expectError(error.UnknownView, p.host.sending(.{ .create_view = .{ .view = 0, .width = 1, .height = 1 } }));
    try say(&p.host, &p.editor, .{ .create_view = .{ .view = 1, .width = 1, .height = 1 } });
    try say(&p.host, &p.editor, .{ .frame_request = .{ .view = 1, .seq = 1 } });
    try t.expectError(error.UnexpectedFrame, p.editor.sending(.{ .frame = .{ .view = 1, .seq = 1, .tier = .draw_list } }));
    try say(&p.editor, &p.host, .{ .view_created = .{ .view = 1, .tier = .draw_list, .width = 1, .height = 1 } });
    try t.expectError(error.UnexpectedFrame, p.editor.sending(.{ .frame = .{ .view = 1, .seq = 1, .tier = .shared_texture } }));
}
