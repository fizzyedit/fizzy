//! Round trip of every message, and what a hostile stream may and may not do.
const std = @import("std");
const message = @import("message.zig");
const codec = @import("codec.zig");
const FrameReader = @import("FrameReader.zig");
const Message = message.Message;

const t = std.testing;

fn sample(comptime tag: message.Type) Message {
    const rect: message.Rect = .{ .x = 1, .y = 2.5, .w = 3, .h = -4 };
    const mods: message.Mods = .{ .shift = true, .super = true };
    return switch (tag) {
        .hello => .{ .hello = .{ .version_min = 1, .version_max = 3, .app_id = "it.fizzy", .app_version = "0.9.1", .tiers_offered = .{ .draw_list = true, .shared_texture = true }, .tiers_wanted = .{ .draw_list = true }, .features = 0x8000_0000_0000_0001, .mode = .standalone } },
        .bye => .{ .bye = .{ .reason = .shutdown, .text = "going away" } },
        .create_view => .{ .create_view = .{ .view = 9, .kind = .document, .target = "/a/b.md", .width = 1920, .height = 1080, .scale = 2, .tier = .native_surface, .native_handle = 0xdead_beef_cafe } },
        .view_created => .{ .view_created = .{ .view = 9, .tier = .shared_texture, .width = 10, .height = 20 } },
        .close_view => .{ .close_view = .{ .view = 9 } },
        .view_closed => .{ .view_closed = .{ .view = 9, .reason = .create_failed, .text = "no such region" } },
        .resize => .{ .resize = .{ .view = 9, .width = 800, .height = 600, .scale = 1.5, .rect = rect } },
        .pointer_motion => .{ .pointer_motion = .{ .view = 9, .x = 10.5, .y = -3, .mods = mods } },
        .pointer_button => .{ .pointer_button = .{ .view = 9, .button = 2, .pressed = true, .x = 1, .y = 2, .mods = mods } },
        .wheel => .{ .wheel = .{ .view = 9, .dx = 0, .dy = -120, .mods = mods } },
        .touch => .{ .touch = .{ .view = 9, .id = 4, .phase = .move, .kind = .pen, .x = 5, .y = 6, .pressure = 0.25 } },
        .key => .{ .key = .{ .view = 9, .down = true, .repeat = true, .host_code = 65, .code = 0x1e, .mods = mods } },
        .text_input => .{ .text_input = .{ .view = 9, .text = "héllo 🙂" } },
        .ime_composition => .{ .ime_composition = .{ .view = 9, .text = "にほん", .sel_start = 3, .sel_len = 6 } },
        .focus => .{ .focus = .{ .view = 9, .focused = true } },
        .clipboard_reply => .{ .clipboard_reply = .{ .view = 9, .request = 77, .found = true, .text = "pasted" } },
        .cursor => .{ .cursor = .{ .view = 9, .shape = .ibeam } },
        .ime_rect => .{ .ime_rect = .{ .view = 9, .rect = rect } },
        .text_input_active => .{ .text_input_active = .{ .view = 9, .active = true } },
        .clipboard_request => .{ .clipboard_request = .{ .view = 9, .request = 78, .op = .write, .text = "copied" } },
        .wants_keys => .{ .wants_keys = .{ .view = 9, .wants = false } },
        .open_url => .{ .open_url = .{ .view = 9, .url = "https://fizzyed.it" } },
        .drag_begin => .{ .drag_begin = .{ .view = 9, .mime = "image/png", .data = "\x89PNG" } },
        .frame_request => .{ .frame_request = .{ .view = 9, .seq = 1 << 40, .deadline_us = 16_000 } },
        .frame => .{ .frame = .{
            .view = 9,
            .seq = 12,
            .tier = .draw_list,
            .width = 640,
            .height = 480,
            .textures = &.{
                .{ .id = 1, .op = .create, .width = 2, .height = 1, .pixels = "\x01\x02\x03\x04\x05\x06\x07\x08" },
                .{ .id = 1, .op = .destroy },
            },
            .draw = .{
                .vertices = &.{
                    .{ .x = 0, .y = 0, .u = 0, .v = 0, .rgba = 0xff00ff00 },
                    .{ .x = 1, .y = 0, .u = 1, .v = 0, .rgba = 0xffffffff },
                    .{ .x = 0, .y = 1, .u = 0, .v = 1, .rgba = 0 },
                },
                .indices = &.{ 0, 1, 2 },
                .cmds = &.{.{ .texture = 1, .clip = rect, .index_offset = 0, .index_count = 3, .vertex_offset = 0 }},
            },
            .fence = 99,
            .slot = 2,
            .damage = &.{rect},
        } },
        .frame_ready => .{ .frame_ready = .{ .view = 9 } },
        _ => unreachable,
    };
}

fn encoded(msg: Message) !std.ArrayList(u8) {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(t.allocator);
    try codec.encode(t.allocator, &out, msg, codec.default_max_frame);
    return out;
}

fn frameOf(bytes: []const u8) codec.Frame {
    return .{
        .type = @fromBackingInt(@intCast(std.mem.readInt(u16, bytes[4..6], .little))),
        .flags = std.mem.readInt(u16, bytes[6..8], .little),
        .payload = bytes[8..],
    };
}

test "every message round-trips" {
    inline for (@typeInfo(message.Type).@"enum".field_values) |fv| {
        const msg = sample(@fromBackingInt(@intCast(fv)));
        var bytes = try encoded(msg);
        defer bytes.deinit(t.allocator);
        var arena = std.heap.ArenaAllocator.init(t.allocator);
        defer arena.deinit();
        const back = (try codec.decode(arena.allocator(), frameOf(bytes.items))).?;
        try t.expectEqualDeep(msg, back);
        // Required types say so in their header.
        try t.expectEqual(msg.tag().required(), frameOf(bytes.items).flags & codec.flag_required != 0);
    }
}

test "every message's frame is cut and decoded from a stream too" {
    var all: std.ArrayList(u8) = .empty;
    defer all.deinit(t.allocator);
    inline for (@typeInfo(message.Type).@"enum".field_values) |fv| {
        try codec.encode(t.allocator, &all, sample(@fromBackingInt(@intCast(fv))), codec.default_max_frame);
    }
    var r = FrameReader.init(t.allocator);
    defer r.deinit();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var n: usize = 0;
    for (all.items) |b| {
        try r.push(&.{b});
        while (try r.next()) |fr| {
            _ = try codec.decode(arena.allocator(), fr);
            n += 1;
        }
    }
    try t.expectEqual(@typeInfo(message.Type).@"enum".field_values.len, n);
}

test "a truncated payload is refused at every length" {
    inline for (@typeInfo(message.Type).@"enum".field_values) |fv| {
        var bytes = try encoded(sample(@fromBackingInt(@intCast(fv))));
        defer bytes.deinit(t.allocator);
        const full = frameOf(bytes.items);
        var arena = std.heap.ArenaAllocator.init(t.allocator);
        defer arena.deinit();
        var cut: usize = 0;
        while (cut < full.payload.len) : (cut += 1) {
            var fr = full;
            fr.payload = full.payload[0..cut];
            // A cut that lands on a field boundary where the rest all have defaults is the
            // append-only rule, not a truncation; nothing here has such a tail but optional ones.
            _ = codec.decode(arena.allocator(), fr) catch |e| {
                try t.expect(e == error.Truncated or e == error.InvalidValue);
                continue;
            };
        }
    }
}

test "a peer older than a trailing field sends without it" {
    // `Hello` today: cut after the strings, as a peer that predates the tiers would send it.
    var bytes = try encoded(.{ .hello = .{ .app_id = "x", .app_version = "y", .features = 5 } });
    defer bytes.deinit(t.allocator);
    var fr = frameOf(bytes.items);
    fr.payload = fr.payload[0 .. 2 + 2 + 4 + 1 + 4 + 1];
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const h = (try codec.decode(arena.allocator(), fr)).?.hello;
    try t.expectEqualStrings("y", h.app_version);
    try t.expectEqual(@as(u64, 0), h.features);
    try t.expectEqual(message.Mode.unspecified, h.mode);
}

test "trailing bytes from a newer peer are ignored" {
    var bytes = try encoded(.{ .focus = .{ .view = 3, .focused = true } });
    defer bytes.deinit(t.allocator);
    try bytes.appendSlice(t.allocator, "future fields");
    var fr = frameOf(bytes.items);
    fr.payload = bytes.items[8..];
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    try t.expectEqual(@as(u32, 3), (try codec.decode(arena.allocator(), fr)).?.focus.view);
}

test "unknown types: optional skipped, required refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const unknown: message.Type = @fromBackingInt(@intCast(5000));
    try t.expect(try codec.decode(arena.allocator(), .{ .type = unknown, .flags = 0, .payload = "abc" }) == null);
    try t.expectError(error.UnknownRequired, codec.decode(arena.allocator(), .{ .type = unknown, .flags = codec.flag_required, .payload = "abc" }));

    // Through a stream, the skipped frame does not disturb its neighbours.
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(t.allocator);
    try codec.encode(t.allocator, &bytes, sample(.focus), codec.default_max_frame);
    try bytes.appendSlice(t.allocator, &.{ 7, 0, 0, 0, 0x88, 0x13, 0, 0, 1, 2, 3 });
    try codec.encode(t.allocator, &bytes, sample(.frame_ready), codec.default_max_frame);
    var r = FrameReader.init(t.allocator);
    defer r.deinit();
    try r.push(bytes.items);
    var seen: usize = 0;
    while (try r.next()) |fr| {
        if (try codec.decode(arena.allocator(), fr) != null) seen += 1;
    }
    try t.expectEqual(@as(usize, 2), seen);
}

test "a bool that is not 0 or 1 is invalid" {
    var bytes = try encoded(sample(.focus));
    defer bytes.deinit(t.allocator);
    bytes.items[bytes.items.len - 1] = 2;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    try t.expectError(error.InvalidValue, codec.decode(arena.allocator(), frameOf(bytes.items)));
}

test "a hostile list count cannot ask for memory the frame does not hold" {
    var bytes = try encoded(.{ .frame = .{ .view = 1, .seq = 1, .tier = .draw_list } });
    defer bytes.deinit(t.allocator);
    // `textures`' count sits after view, seq, tier, width, height.
    const at = 8 + 4 + 8 + 1 + 4 + 4;
    std.mem.writeInt(u32, bytes.items[at..][0..4], 0xffff_ffff, .little);
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    try t.expectError(error.Truncated, codec.decode(arena.allocator(), frameOf(bytes.items)));
}

test "oversize messages are refused and leave the buffer alone" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(t.allocator);
    try codec.encode(t.allocator, &out, sample(.focus), 1024);
    const before = out.items.len;
    const big: [2000]u8 = @splat(0);
    try t.expectError(error.FrameTooLarge, codec.encode(t.allocator, &out, .{ .text_input = .{ .view = 1, .text = &big } }, 1024));
    try t.expectEqual(before, out.items.len);
}

test "fuzz: random and mutated frames never crash, only error" {
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const rnd = prng.random();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();

    // Mutated valid frames.
    inline for (@typeInfo(message.Type).@"enum".field_values) |fv| {
        var bytes = try encoded(sample(@fromBackingInt(@intCast(fv))));
        defer bytes.deinit(t.allocator);
        for (0..300) |_| {
            const copy = try t.allocator.dupe(u8, bytes.items);
            defer t.allocator.free(copy);
            for (0..rnd.intRangeAtMost(usize, 1, 4)) |_| copy[8 + rnd.uintLessThan(usize, copy.len - 8 + @intFromBool(copy.len == 8))] ^= rnd.int(u8);
            _ = arena.reset(.retain_capacity);
            _ = codec.decode(arena.allocator(), frameOf(copy)) catch {};
        }
    }
    // Pure noise through the framer.
    for (0..500) |_| {
        var buf: [256]u8 = undefined;
        rnd.bytes(&buf);
        var r = FrameReader.init(t.allocator);
        defer r.deinit();
        r.max_frame = 4096;
        try r.push(buf[0..rnd.uintAtMost(usize, buf.len)]);
        _ = arena.reset(.retain_capacity);
        while (r.next() catch null) |fr| _ = codec.decode(arena.allocator(), fr) catch {};
    }
}
