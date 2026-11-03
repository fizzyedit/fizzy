//! Timed protocol B touchscreen scripts and getevent replay, in device coordinates.
const std = @import("std");

pub const InputEvent = extern struct { sec: isize = 0, usec: isize = 0, type: u16, code: u16, value: i32 };
pub const EV_SYN = 0;
pub const EV_KEY = 1;
pub const EV_ABS = 3;
pub const SYN_REPORT = 0;
pub const BTN_TOUCH = 0x14a;
pub const ABS_MT_SLOT = 0x2f;
pub const ABS_MT_POSITION_X = 0x35;
pub const ABS_MT_POSITION_Y = 0x36;
pub const ABS_MT_TRACKING_ID = 0x39;
pub const Step = struct { t_ms: u32, slot: u8, kind: enum { down, move, up }, x: i32, y: i32 };
pub const State = struct { next_id: i32 = 1, down: u16 = 0 };

pub fn parseLine(line: []const u8) error{Syntax}!?Step {
    var words = std.mem.tokenizeAny(u8, line[0 .. std.mem.indexOfScalar(u8, line, '#') orelse line.len], " \t\r");
    const time = words.next() orelse return null;
    const t = std.fmt.parseInt(u32, time, 10) catch return error.Syntax;
    const slot = std.fmt.parseInt(u8, words.next() orelse return error.Syntax, 10) catch return error.Syntax;
    if (slot >= 16) return error.Syntax;
    const kind = std.meta.stringToEnum(@FieldType(Step, "kind"), words.next() orelse return error.Syntax) orelse return error.Syntax;
    const x = std.fmt.parseInt(i32, words.next() orelse return error.Syntax, 10) catch return error.Syntax;
    const y = std.fmt.parseInt(i32, words.next() orelse return error.Syntax, 10) catch return error.Syntax;
    if (words.next() != null) return error.Syntax;
    return .{ .t_ms = t, .slot = slot, .kind = kind, .x = x, .y = y };
}

/// Appends events without SYN. The caller owns `out` and frees it with `gpa`.
pub fn encode(gpa: std.mem.Allocator, step: Step, state: *State, out: *std.ArrayList(InputEvent)) !void {
    if (step.slot >= 16) return error.Syntax;
    const bit = @as(u16, 1) << @intCast(step.slot);
    try out.ensureUnusedCapacity(gpa, 5);
    out.appendAssumeCapacity(.{ .type = EV_ABS, .code = ABS_MT_SLOT, .value = step.slot });
    switch (step.kind) {
        .down => {
            if (state.next_id == std.math.maxInt(i32)) return error.Syntax;
            out.appendAssumeCapacity(.{ .type = EV_ABS, .code = ABS_MT_TRACKING_ID, .value = state.next_id });
            state.next_id += 1;
        },
        .up => out.appendAssumeCapacity(.{ .type = EV_ABS, .code = ABS_MT_TRACKING_ID, .value = -1 }),
        .move => {},
    }
    if (step.kind != .up) {
        out.appendAssumeCapacity(.{ .type = EV_ABS, .code = ABS_MT_POSITION_X, .value = step.x });
        out.appendAssumeCapacity(.{ .type = EV_ABS, .code = ABS_MT_POSITION_Y, .value = step.y });
    }
    const before = state.down;
    if (step.kind == .down) state.down |= bit;
    if (step.kind == .up) state.down &= ~bit;
    if ((step.kind == .down and before == 0) or (step.kind == .up and state.down == 0))
        out.appendAssumeCapacity(.{ .type = EV_KEY, .code = BTN_TOUCH, .value = if (state.down == 0) 0 else 1 });
}

const Recorded = struct { t_us: u64, type: u16, code: u16, value: i32 };

pub fn parseGetevent(line: []const u8) error{Syntax}!?Recorded {
    const text = std.mem.trim(u8, line, " \t\r");
    if (text.len == 0 or text[0] == '#') return null;
    if (text[0] != '[') return error.Syntax;
    const end = std.mem.indexOfScalar(u8, text, ']') orelse return error.Syntax;
    var stamp = std.mem.splitScalar(u8, std.mem.trim(u8, text[1..end], " \t"), '.');
    const sec = std.fmt.parseInt(u64, stamp.next() orelse return error.Syntax, 10) catch return error.Syntax;
    const fraction = stamp.next() orelse return error.Syntax;
    if (fraction.len != 6 or stamp.next() != null) return error.Syntax;
    const us = std.fmt.parseInt(u32, fraction, 10) catch return error.Syntax;
    const t = std.math.mul(u64, sec, 1_000_000) catch return error.Syntax;
    const t_us = std.math.add(u64, t, us) catch return error.Syntax;
    var words = std.mem.tokenizeAny(u8, text[end + 1 ..], " \t\r");
    const names = .{ "EV_SYN", "EV_KEY", "EV_ABS", "SYN_REPORT", "BTN_TOUCH", "ABS_MT_SLOT", "ABS_MT_POSITION_X", "ABS_MT_POSITION_Y", "ABS_MT_TRACKING_ID" };
    const values = [_]u16{ EV_SYN, EV_KEY, EV_ABS, SYN_REPORT, BTN_TOUCH, ABS_MT_SLOT, ABS_MT_POSITION_X, ABS_MT_POSITION_Y, ABS_MT_TRACKING_ID };
    const type_name = words.next() orelse return error.Syntax;
    const code_name = words.next() orelse return error.Syntax;
    var event_type: ?u16 = null;
    var code: ?u16 = null;
    inline for (names, values, 0..) |name, value, i| {
        if (i < 3 and std.mem.eql(u8, type_name, name)) event_type = value;
        if (i >= 3 and std.mem.eql(u8, code_name, name)) code = value;
    }
    if (event_type == null or code == null) return null;
    const value = std.fmt.parseInt(u32, words.next() orelse return error.Syntax, 16) catch return error.Syntax;
    if (words.next() != null) return error.Syntax;
    return .{ .t_us = t_us, .type = event_type.?, .code = code.?, .value = @bitCast(value) };
}

const Frame = struct { t_us: u64, end: usize };

fn compileScript(gpa: std.mem.Allocator, text: []const u8, replay: bool, events: *std.ArrayList(InputEvent), frames: *std.ArrayList(Frame), line_number: *usize) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var state: State = .{};
    var first: ?u64 = null;
    var previous: ?u64 = null;
    while (lines.next()) |line| {
        line_number.* += 1;
        const step = if (replay) null else (try parseLine(line)) orelse continue;
        const record = if (replay) (try parseGetevent(line)) orelse continue else blk: {
            break :blk Recorded{ .t_us = @as(u64, step.?.t_ms) * 1000, .type = 0, .code = 0, .value = 0 };
        };
        if (previous) |p| {
            if (record.t_us < p) return error.Syntax;
            if (record.t_us != p) {
                if (!replay) try events.append(gpa, .{ .type = EV_SYN, .code = SYN_REPORT, .value = 0 });
                try frames.append(gpa, .{ .t_us = p - first.?, .end = events.items.len });
            }
        }
        if (first == null) first = if (replay) record.t_us else 0;
        previous = record.t_us;
        if (replay) {
            try events.append(gpa, .{ .type = record.type, .code = record.code, .value = record.value });
        } else try encode(gpa, step.?, &state, events);
    }
    if (previous) |p| {
        if (!replay) try events.append(gpa, .{ .type = EV_SYN, .code = SYN_REPORT, .value = 0 });
        try frames.append(gpa, .{ .t_us = p - first.?, .end = events.items.len });
    }
}

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        std.debug.print("{s}\n", .{@errorName(err)});
        std.process.exit(2);
    };
}

fn run(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(gpa);
    const replay = args.len > 1 and std.mem.eql(u8, args[1], "--replay");
    const offset: usize = if (replay) 2 else 1;
    if (args.len != offset + 2) return error.Usage;
    const text = try std.Io.Dir.cwd().readFileAlloc(io, args[offset + 1], gpa, .unlimited);
    var events: std.ArrayList(InputEvent) = .empty;
    defer events.deinit(gpa);
    var frames: std.ArrayList(Frame) = .empty;
    defer frames.deinit(gpa);
    var line: usize = 0;
    compileScript(gpa, text, replay, &events, &frames, &line) catch |err| {
        std.debug.print("line {d}: {s}\n", .{ line, @errorName(err) });
        std.process.exit(2);
    };
    const node = try std.Io.Dir.cwd().openFile(io, args[offset], .{ .mode = .write_only });
    defer node.close(io);
    const start = std.Io.Clock.Timestamp.now(io, .awake);
    var begin: usize = 0;
    for (frames.items) |frame| {
        var deadline = start;
        deadline.raw.nanoseconds += @as(i96, frame.t_us) * 1000;
        try deadline.wait(io);
        try node.writeStreamingAll(io, std.mem.sliceAsBytes(events.items[begin..frame.end]));
        begin = frame.end;
    }
}

const testing = std.testing;

test "a tap is slot, id, x, y, touch, then lift" {
    var state: State = .{};
    var out: std.ArrayList(InputEvent) = .empty;
    defer out.deinit(testing.allocator);
    try encode(testing.allocator, (try parseLine("0 0 down 100 200")).?, &state, &out);
    try encode(testing.allocator, (try parseLine("50 0 up 100 200")).?, &state, &out);
    const codes = [_]u16{ 0x2f, 0x39, 0x35, 0x36, 0x14a, 0x2f, 0x39, 0x14a };
    const values = [_]i32{ 0, 1, 100, 200, 1, 0, -1, 0 };
    try testing.expectEqual(codes.len, out.items.len);
    for (out.items, codes, values, 0..) |event, code, value, i| {
        try testing.expectEqual(code, event.code);
        try testing.expectEqual(value, event.value);
        try testing.expectEqual(@as(u16, if (i == 4 or i == 7) 1 else 3), event.type);
        try testing.expectEqual(@as(isize, 0), event.sec);
        try testing.expectEqual(@as(isize, 0), event.usec);
    }
}

test "a second finger does not repeat BTN_TOUCH" {
    var state: State = .{};
    var out: std.ArrayList(InputEvent) = .empty;
    defer out.deinit(testing.allocator);
    for ([_][]const u8{ "0 0 down 1 2", "0 1 down 3 4", "1 0 up 1 2", "1 1 up 3 4" }) |line|
        try encode(testing.allocator, (try parseLine(line)).?, &state, &out);
    var touches: std.ArrayList(i32) = .empty;
    defer touches.deinit(testing.allocator);
    var ids: std.ArrayList(i32) = .empty;
    defer ids.deinit(testing.allocator);
    for (out.items) |event| {
        if (event.code == BTN_TOUCH) try touches.append(testing.allocator, event.value);
        if (event.code == ABS_MT_TRACKING_ID) try ids.append(testing.allocator, event.value);
    }
    try testing.expectEqualSlices(i32, &.{ 1, 0 }, touches.items);
    try testing.expectEqualSlices(i32, &.{ 1, 2, -1, -1 }, ids.items);
}

test "parse errors name the line" {
    try testing.expectError(error.Syntax, parseLine("10 0 hover 1 2"));
    try testing.expectError(error.Syntax, parseLine("x 0 down 1 2"));
    try testing.expectEqual(null, try parseLine("# c"));
    try testing.expectEqual(null, try parseLine(" \t"));
    try testing.expectError(error.Syntax, parseLine("0 16 down 1 2"));
    try testing.expectError(error.Syntax, parseLine("0 0 down 1 2 extra"));
    var out: std.ArrayList(InputEvent) = .empty;
    defer out.deinit(testing.allocator);
    var frames: std.ArrayList(Frame) = .empty;
    defer frames.deinit(testing.allocator);
    var line: usize = 0;
    try testing.expectError(error.Syntax, compileScript(testing.allocator, "# c\n10 0 hover 1 2", false, &out, &frames, &line));
    try testing.expectEqual(@as(usize, 2), line);
}

test "getevent lines" {
    const event = (try parseGetevent("[   12345.678901] EV_ABS ABS_MT_POSITION_X 000001f4")).?;
    try testing.expectEqual(Recorded{ .t_us = 12345678901, .type = 3, .code = 0x35, .value = 500 }, event);
    try testing.expectEqual(@as(i32, -1), (try parseGetevent("[ 1.000000] EV_ABS ABS_MT_TRACKING_ID ffffffff")).?.value);
    try testing.expectEqual(null, try parseGetevent("[ 1.000000] EV_ABS ABS_UNKNOWN 00000000"));
}

test "frames group equal times and preserve replay timing" {
    var out: std.ArrayList(InputEvent) = .empty;
    defer out.deinit(testing.allocator);
    var frames: std.ArrayList(Frame) = .empty;
    defer frames.deinit(testing.allocator);
    var line: usize = 0;
    try compileScript(testing.allocator, "4 0 down 1 2\n4 1 down 3 4\n8 0 move 5 6", false, &out, &frames, &line);
    try testing.expectEqualSlices(Frame, &.{ .{ .t_us = 4000, .end = 10 }, .{ .t_us = 8000, .end = 14 } }, frames.items);
    try testing.expectEqual(InputEvent{ .type = 0, .code = 0, .value = 0 }, out.items[9]);
    try testing.expectEqualSlices(InputEvent, &.{
        .{ .type = 3, .code = 0x2f, .value = 0 },
        .{ .type = 3, .code = 0x35, .value = 5 },
        .{ .type = 3, .code = 0x36, .value = 6 },
        .{ .type = 0, .code = 0, .value = 0 },
    }, out.items[10..]);
    out.clearRetainingCapacity();
    frames.clearRetainingCapacity();
    try compileScript(testing.allocator, "[ 9.000000] EV_ABS ABS_MT_TRACKING_ID ffffffff\n[ 9.000004] EV_SYN SYN_REPORT 00000000", true, &out, &frames, &line);
    try testing.expectEqualSlices(Frame, &.{ .{ .t_us = 0, .end = 1 }, .{ .t_us = 4, .end = 2 } }, frames.items);
}

test "descending times are rejected before playback" {
    var out: std.ArrayList(InputEvent) = .empty;
    defer out.deinit(testing.allocator);
    var frames: std.ArrayList(Frame) = .empty;
    defer frames.deinit(testing.allocator);
    for ([_][]const u8{ "2 0 down 1 2\n1 0 up 1 2", "[ 2.000000] EV_SYN SYN_REPORT 00000000\n[ 1.000000] EV_SYN SYN_REPORT 00000000" }, 0..) |text, i| {
        out.clearRetainingCapacity();
        frames.clearRetainingCapacity();
        var line: usize = 0;
        try testing.expectError(error.Syntax, compileScript(testing.allocator, text, i == 1, &out, &frames, &line));
        try testing.expectEqual(@as(usize, 2), line);
    }
}
