//! A conversation kept in memory, so the chat surface can be tried with no team behind it. It
//! answers every message by quoting it. The chat plugin registers it only when no other plugin
//! has offered `chat.provider`.
const std = @import("std");
const sdk = @import("fizzy_sdk");

const Api = sdk.services.chat.Api;

const DemoProvider = @This();

allocator: std.mem.Allocator,
log: std.ArrayList(Api.Message) = .empty,

pub fn deinit(self: *DemoProvider) void {
    for (self.log.items) |m| self.allocator.free(m.text);
    self.log.deinit(self.allocator);
}

pub fn api(self: *DemoProvider) Api {
    return .{ .ctx = self, .vtable = &vtable };
}

const vtable: Api.VTable = .{
    .messages = messages,
    .send = send,
    .attach = attach,
    .status = status,
};

fn messages(ctx: *anyopaque) []const Api.Message {
    const self: *DemoProvider = @ptrCast(@alignCast(ctx));
    return self.log.items;
}

fn send(ctx: *anyopaque, text: []const u8) bool {
    const self: *DemoProvider = @ptrCast(@alignCast(ctx));
    self.append(.user, text) catch return false;
    var buf: [256]u8 = undefined;
    const quoted = text[0..@min(text.len, 200)];
    const reply = std.fmt.bufPrint(&buf, "You said: {s}", .{quoted}) catch return true;
    self.append(.assistant, reply) catch {};
    return true;
}

fn attach(ctx: *anyopaque) void {
    const self: *DemoProvider = @ptrCast(@alignCast(ctx));
    self.append(.system, "The demo conversation has nowhere to keep an attachment.") catch {};
}

fn status(_: *anyopaque) Api.Status {
    return .ready;
}

fn append(self: *DemoProvider, role: Api.Role, text: []const u8) !void {
    const owned = try self.allocator.dupe(u8, text);
    errdefer self.allocator.free(owned);
    try self.log.append(self.allocator, .{ .role = role, .text = owned });
}

test "sending adds the message and its reply" {
    var p: DemoProvider = .{ .allocator = std.testing.allocator };
    defer p.deinit();
    const a = p.api();
    try std.testing.expect(a.send("hello"));
    try std.testing.expectEqual(@as(usize, 2), a.messages().len);
    try std.testing.expectEqual(Api.Role.user, a.messages()[0].role);
    try std.testing.expectEqualStrings("You said: hello", a.messages()[1].text);
}
