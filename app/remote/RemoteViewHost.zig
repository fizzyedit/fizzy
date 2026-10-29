//! A `ViewHost` whose surface is on the other side of the control socket: a view a remote client
//! (an adapter in Blender, Unreal, ...) asked for. Like a pop-out it is a window the app lays out
//! and draws into the one frame, but the OS never shows it; the client does, from the frames it
//! asks for. Input the client sends waits here as dvui events until the frame injects it.
//!
//! The app owns the part of the frame this host shows (`surface`); `end` answers the client's
//! newest frame request from it. Frames come from the UI thread, on request: nothing here runs on
//! a thread of its own.
const std = @import("std");
const dvui = @import("dvui");
const remote = @import("remote");
const ViewHost = @import("../view/ViewHost.zig");
const keys = @import("keys.zig");
const Session = @import("Session.zig");

const message = remote.message;
const RemoteViewHost = @This();

/// What the client sent that a frame has yet to take, in order.
pub const Input = union(enum) {
    motion: struct { x: f32, y: f32, mods: message.Mods },
    button: message.PointerButton,
    wheel: message.Wheel,
    key: message.Key,
    /// `gpa`-owned.
    text: []u8,
};

/// A client sending faster than frames run loses motion past this, and everything past twice it
/// (and text past `max_text_bytes`), rather than grow without end.
pub const max_queued = 1024;

/// The most text that may wait for a frame, in bytes; past it, text is dropped.
pub const max_text_bytes = 1024 * 1024;

gpa: std.mem.Allocator,
session: *Session,
id: message.ViewId,
kind: message.ViewKind,
/// What the view shows (a region's name, a document's path); `gpa`-owned.
target: []u8,
/// Physical pixels.
width: u32,
height: u32,
scale: f32,
/// Where its part of the frame lies, physical; null until the app has placed it. Input is
/// delivered only once it has: a view nobody draws has nothing under the pointer.
origin: ?dvui.Point.Physical = null,
/// Placed or sized since `begin` last said so.
moved: bool = true,
/// The client has this view's focus: keys and text reach it only then.
focused: bool = false,
/// The client closed it, or the connection did.
close_asked: bool = false,
/// The newest frame the client asked for, and the newest answered; 0 before any.
wanted: u64 = 0,
answered: u64 = 0,
input: std.ArrayList(Input) = .empty,
/// The bytes of the `text` items in `input`.
text_bytes: usize = 0,

pub fn create(gpa: std.mem.Allocator, session: *Session, cv: message.CreateView) error{OutOfMemory}!*RemoteViewHost {
    const self = try gpa.create(RemoteViewHost);
    errdefer gpa.destroy(self);
    self.* = .{
        .gpa = gpa,
        .session = session,
        .id = cv.view,
        .kind = cv.kind,
        .target = try gpa.dupe(u8, cv.target),
        .width = cv.width,
        .height = cv.height,
        .scale = cv.scale,
    };
    return self;
}

pub fn destroy(self: *RemoteViewHost) void {
    self.clearInput();
    self.input.deinit(self.gpa);
    self.gpa.free(self.target);
    self.gpa.destroy(self);
}

pub fn viewHost(self: *RemoteViewHost) ViewHost {
    return .{ .ptr = self, .vtable = ViewHost.vtableOf(RemoteViewHost) };
}

/// The app placed this view's part of the frame at `origin`.
pub fn place(self: *RemoteViewHost, origin: dvui.Point.Physical) void {
    const at = self.origin orelse origin;
    if (self.origin == null or at.x != origin.x or at.y != origin.y) self.moved = true;
    self.origin = origin;
}

pub fn resize(self: *RemoteViewHost, width: u32, height: u32, scale: f32) void {
    // A view has a size (`create_view` refuses one without).
    if (width == 0 or height == 0) return;
    if (width != self.width or height != self.height or scale != self.scale) self.moved = true;
    self.width = width;
    self.height = height;
    self.scale = scale;
}

pub fn begin(self: *RemoteViewHost) ?dvui.Rect.Physical {
    if (!self.moved) return null;
    self.moved = false;
    return self.surface();
}

/// Answers the newest frame the client asked for, if one is waiting.
pub fn end(self: *RemoteViewHost) void {
    if (self.wanted <= self.answered or self.close_asked) return;
    self.session.sendFrame(self);
}

pub fn surface(self: *RemoteViewHost) dvui.Rect.Physical {
    const at = self.origin orelse dvui.Point.Physical{};
    return .{ .x = at.x, .y = at.y, .w = @floatFromInt(self.width), .h = @floatFromInt(self.height) };
}

pub fn space(_: *RemoteViewHost) ViewHost.Space {
    return .{};
}

/// The client's surface is its own: the app draws the base.
pub fn materialBase(_: *RemoteViewHost, _: dvui.Color, _: f32) ?dvui.Color {
    return null;
}

pub fn closeRequested(self: *RemoteViewHost) bool {
    return self.close_asked;
}

/// Hold `item` until `inject`. Keys and text are the focused view's alone, but a key's release is
/// always kept: dropped, the key would stay held. Past `max_queued`, motion is what gives way (a
/// run of it keeps only the last); a press, release or key never does.
pub fn queue(self: *RemoteViewHost, item: Input) error{OutOfMemory}!void {
    const wanted = switch (item) {
        .key => |k| self.focused or !k.down,
        .text => self.focused,
        else => true,
    };
    if (!wanted) {
        if (item == .text) self.gpa.free(item.text);
        return;
    }
    if (item == .motion) {
        const last = self.input.items.len;
        if (last > 0 and self.input.items[last - 1] == .motion) {
            self.input.items[last - 1] = item;
            return;
        }
        if (last >= max_queued) return;
    }
    if (self.input.items.len >= 2 * max_queued or
        (item == .text and self.text_bytes + item.text.len > max_text_bytes))
    {
        if (item == .text) self.gpa.free(item.text);
        return;
    }
    try self.input.append(self.gpa, item);
    if (item == .text) self.text_bytes += item.text.len;
}

/// Hand what is waiting to `win` as dvui events, at this view's place in the frame, before the
/// frame draws. With no place yet it is dropped.
pub fn inject(self: *RemoteViewHost, win: *dvui.Window) error{OutOfMemory}!void {
    defer self.clearInput();
    const at = self.origin orelse return;
    for (self.input.items) |item| switch (item) {
        .motion => |m| {
            win.modifiers = keys.toMod(m.mods);
            _ = try win.addEventMouseMotion(.{ .pt = .{ .x = at.x + m.x, .y = at.y + m.y } });
        },
        .button => |b| {
            win.modifiers = keys.toMod(b.mods);
            _ = try win.addEventMouseMotion(.{ .pt = .{ .x = at.x + b.x, .y = at.y + b.y } });
            _ = try win.addEventMouseButton(keys.button(b.button), if (b.pressed) .press else .release);
        },
        .wheel => |w| {
            win.modifiers = keys.toMod(w.mods);
            if (w.dy != 0) _ = try win.addEventMouseWheel(w.dy, .vertical, null);
            if (w.dx != 0) _ = try win.addEventMouseWheel(w.dx, .horizontal, null);
        },
        .key => |k| _ = try win.addEventKey(.{
            .code = keys.fromHid(k.code),
            .action = if (!k.down) .up else if (k.repeat) .repeat else .down,
            .mod = keys.toMod(k.mods),
        }),
        .text => |t| _ = try win.addEventText(.{ .text = t }),
    };
}

fn clearInput(self: *RemoteViewHost) void {
    for (self.input.items) |item| if (item == .text) self.gpa.free(item.text);
    self.input.clearRetainingCapacity();
    self.text_bytes = 0;
}
