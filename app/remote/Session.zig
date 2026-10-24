//! One remote client's conversation: the `Link` its bytes cross, the protocol `Endpoint` that cuts
//! them into messages, and the views it opened. `pump` runs once a frame on the UI thread: it
//! takes what arrived, acts on it, and queues what is to go back. It never blocks and has no
//! thread; the connection's own tasks (`control/Server.serveLink`) do the waiting.
const std = @import("std");
const remote = @import("remote");
const Link = @import("../control/Link.zig");

/// The most views one connection may hold open.
pub const max_views = 64;

comptime {
    // A link must hold a whole protocol frame (`Link.max_backlog`).
    std.debug.assert(Link.max_backlog >= remote.codec.default_max_frame);
}
const RemoteViewHost = @import("RemoteViewHost.zig");
const encoder = @import("encoder.zig");

const message = remote.message;
const Session = @This();

gpa: std.mem.Allocator,
/// Which connection, for `fizzy.remote.views`; the service numbers them from 1.
id: u32 = 0,
link: *Link,
endpoint: remote.Endpoint,
views: std.AutoArrayHashMapUnmanaged(message.ViewId, *RemoteViewHost) = .empty,
inbound: std.ArrayList(u8) = .empty,
/// The stream is over: it broke the protocol, the client left or said `bye`. The link closes
/// once what is queued is written.
dead: bool = false,

pub fn create(gpa: std.mem.Allocator, link: *Link, hello: message.Hello) error{OutOfMemory}!*Session {
    const self = try gpa.create(Session);
    errdefer gpa.destroy(self);
    self.* = .{ .gpa = gpa, .link = link, .endpoint = .init(gpa, .editor, hello) };
    errdefer self.endpoint.deinit();
    self.endpoint.start() catch return error.OutOfMemory;
    return self;
}

/// Free everything. Only once the link `isGone` (`Service`).
pub fn destroy(self: *Session) void {
    for (self.views.values()) |v| v.destroy();
    self.views.deinit(self.gpa);
    self.inbound.deinit(self.gpa);
    self.endpoint.deinit();
    self.link.deinit();
    self.gpa.destroy(self.link);
    self.gpa.destroy(self);
}

/// Take what arrived, act on it, send what it earned. Returns whether the session is over and its
/// link gone, for the service to drop it.
pub fn pump(self: *Session, answer_frames: bool) bool {
    if (!self.dead) self.receive();
    if (self.link.isGone()) self.dead = true;
    if (!self.dead and answer_frames) for (self.views.values()) |v| v.end();
    self.reap();
    self.flush();
    return self.dead and self.link.isGone();
}

/// The views the client closed are dropped, each told to it; a stream that is over takes all of
/// its views with it.
fn reap(self: *Session) void {
    var i: usize = 0;
    while (i < self.views.count()) {
        const v = self.views.values()[i];
        if (!v.close_asked and !self.dead) {
            i += 1;
            continue;
        }
        if (!self.dead) self.say(.{ .view_closed = .{ .view = v.id, .reason = .closed } });
        v.destroy();
        self.views.swapRemoveAt(i);
    }
}

fn flush(self: *Session) void {
    const out = self.endpoint.pending();
    if (out.len > 0 and !self.link.isGone()) {
        self.link.send(out) catch {
            self.dead = true;
            return;
        };
    }
    self.endpoint.consume(out.len);
    // `close` lets the bye out; `reapStuck` cuts a peer that will not read it.
    if (self.dead) {
        self.link.close();
        _ = self.link.reapStuck();
    }
}

fn receive(self: *Session) void {
    self.inbound.clearRetainingCapacity();
    self.link.take(&self.inbound) catch {
        self.dead = true;
        return;
    };
    self.endpoint.feed(self.inbound.items) catch {
        self.dead = true;
        return;
    };
    var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena_state.deinit();
    while (true) {
        _ = arena_state.reset(.retain_capacity);
        const next = self.endpoint.poll(arena_state.allocator()) catch {
            self.dead = true;
            break;
        };
        const msg = next orelse break;
        self.handle(msg) catch {
            self.dead = true;
            break;
        };
        if (self.dead) break;
    }
    // A bye (the client's, or the one a violation queued) ends it.
    if (self.endpoint.conn.state == .closed) self.dead = true;
}

fn say(self: *Session, msg: message.Message) void {
    self.endpoint.send(msg) catch {
        self.dead = true;
    };
}

fn handle(self: *Session, msg: message.Message) error{OutOfMemory}!void {
    switch (msg) {
        .create_view => |cv| try self.createView(cv),
        .close_view => |m| if (self.views.get(m.view)) |v| {
            v.close_asked = true;
        },
        .resize => |m| if (self.views.get(m.view)) |v| v.resize(m.width, m.height, m.scale),
        .focus => |m| if (self.views.get(m.view)) |v| {
            v.focused = m.focused;
        },
        .frame_request => |m| if (self.views.get(m.view)) |v| {
            v.wanted = m.seq;
        },
        .pointer_motion => |m| if (self.views.get(m.view)) |v| try v.queue(.{ .motion = .{ .x = m.x, .y = m.y, .mods = m.mods } }),
        .pointer_button => |m| if (self.views.get(m.view)) |v| try v.queue(.{ .button = m }),
        .wheel => |m| if (self.views.get(m.view)) |v| try v.queue(.{ .wheel = m }),
        .key => |m| if (self.views.get(m.view)) |v| try v.queue(.{ .key = m }),
        .text_input => |m| if (self.views.get(m.view)) |v| {
            const text = try self.gpa.dupe(u8, m.text);
            errdefer self.gpa.free(text);
            try v.queue(.{ .text = text });
        },
        // The tier-3 stub has no use for these yet: touch, IME, clipboard.
        else => {},
    }
}

fn createView(self: *Session, cv: message.CreateView) error{OutOfMemory}!void {
    if (cv.tier != .draw_list) {
        self.refuse(cv.view, .unsupported_tier, "only the draw-list tier is served");
        return;
    }
    if (cv.width == 0 or cv.height == 0) {
        self.refuse(cv.view, .create_failed, "a view has a size");
        return;
    }
    if (self.views.contains(cv.view)) {
        // The protocol layer already ends a stream that does this; this only guards the map.
        // Not `refuse`: its `view_closed` would make the client forget the view that is open.
        self.say(.{ .bye = .{ .reason = .protocol_error, .text = "that view id is already open" } });
        self.dead = true;
        return;
    }
    if (self.views.count() >= max_views) {
        self.refuse(cv.view, .create_failed, "too many views");
        return;
    }
    const v = try RemoteViewHost.create(self.gpa, self, cv);
    errdefer v.destroy();
    try self.views.put(self.gpa, cv.view, v);
    self.say(.{ .view_created = .{ .view = cv.view, .tier = .draw_list, .width = cv.width, .height = cv.height } });
}

/// Answer a `create_view` with a close: the connection took the view in, so the client hears it
/// closed (`view_closed` is the only reply that drops the connection's record of it).
fn refuse(self: *Session, id: message.ViewId, reason: message.ViewClosedReason, text: []const u8) void {
    self.say(.{ .view_closed = .{ .view = id, .reason = reason, .text = text } });
}

/// Answer `v`'s newest request with the stub's fill.
pub fn sendFrame(self: *Session, v: *RemoteViewHost) void {
    var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena_state.deinit();
    const draw = encoder.solidFill(arena_state.allocator(), v.width, v.height, encoder.fill_rgba) catch return;
    self.say(.{ .frame = .{ .view = v.id, .seq = v.wanted, .tier = .draw_list, .width = v.width, .height = v.height, .draw = draw } });
    v.answered = v.wanted;
}
