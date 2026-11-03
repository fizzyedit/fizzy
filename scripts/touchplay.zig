//! Play device-unit touch scripts or getevent recordings on a Linux protocol B touchscreen.
const std = @import("std");
const linux = std.os.linux;

pub const InputEvent = extern struct { sec: isize, usec: isize, type: u16, code: u16, value: i32 };
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
    var fields = std.mem.tokenizeAny(u8, line[0 .. std.mem.indexOfScalar(u8, line, '#') orelse line.len], " \t\r");
    const time = fields.next() orelse return null;
    const slot = try number(u8, fields.next() orelse return error.Syntax, 10);
    if (slot >= 16) return error.Syntax; // State has one bit per supported slot.
    const kind = std.meta.stringToEnum(@FieldType(Step, "kind"), fields.next() orelse return error.Syntax) orelse return error.Syntax;
    const step: Step = .{
        .t_ms = try number(u32, time, 10),
        .slot = slot,
        .kind = kind,
        .x = try number(i32, fields.next() orelse return error.Syntax, 10),
        .y = try number(i32, fields.next() orelse return error.Syntax, 10),
    };
    if (fields.next() != null) return error.Syntax;
    return step;
}

/// Appends events owned by `out`, using `gpa`. Assumes slot < 16 and available tracking ids.
pub fn encode(gpa: std.mem.Allocator, step: Step, state: *State, out: *std.ArrayList(InputEvent)) !void {
    const bit = @as(u16, 1) << @as(u4, @intCast(step.slot));
    try out.append(gpa, event(EV_ABS, ABS_MT_SLOT, step.slot));
    switch (step.kind) {
        .down => {
            try out.append(gpa, event(EV_ABS, ABS_MT_TRACKING_ID, state.next_id));
            state.next_id += 1;
        },
        .up => try out.append(gpa, event(EV_ABS, ABS_MT_TRACKING_ID, -1)),
        .move => {},
    }
    if (step.kind != .up) {
        try out.append(gpa, event(EV_ABS, ABS_MT_POSITION_X, step.x));
        try out.append(gpa, event(EV_ABS, ABS_MT_POSITION_Y, step.y));
    }
    if (step.kind == .down) {
        if (state.down == 0) try out.append(gpa, event(EV_KEY, BTN_TOUCH, 1));
        state.down |= bit;
    } else if (step.kind == .up) {
        state.down &= ~bit;
        if (state.down == 0) try out.append(gpa, event(EV_KEY, BTN_TOUCH, 0));
    }
}

pub fn parseGetevent(line: []const u8) error{Syntax}!?struct { t_us: u64, type: u16, code: u16, value: i32 } {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0 or trimmed[0] == '#') return null;
    if (trimmed[0] != '[') return error.Syntax;
    const end = std.mem.indexOfScalar(u8, trimmed, ']') orelse return error.Syntax;
    const stamp = std.mem.trim(u8, trimmed[1..end], " \t");
    var parts = std.mem.splitScalar(u8, stamp, '.');
    const seconds = try number(u64, parts.next() orelse return error.Syntax, 10);
    const fraction = parts.next() orelse return error.Syntax;
    if (fraction.len != 6 or parts.next() != null) return error.Syntax;
    const micros = try number(u64, fraction, 10);
    const t_us = std.math.add(u64, std.math.mul(u64, seconds, 1_000_000) catch return error.Syntax, micros) catch return error.Syntax;
    var fields = std.mem.tokenizeAny(u8, trimmed[end + 1 ..], " \t");
    var type_name = fields.next() orelse return error.Syntax;
    if (std.mem.endsWith(u8, type_name, ":")) type_name = fields.next() orelse return error.Syntax;
    const code_name = fields.next() orelse return error.Syntax;
    const type_id = named(type_name) orelse return null;
    const code = named(code_name) orelse return null;
    const value: i32 = @bitCast(try number(u32, fields.next() orelse return error.Syntax, 16));
    if (fields.next() != null) return error.Syntax;
    return .{ .t_us = t_us, .type = type_id, .code = code, .value = value };
}

fn number(comptime T: type, bytes: []const u8, base: u8) error{Syntax}!T {
    return std.fmt.parseInt(T, bytes, base) catch error.Syntax;
}

fn named(name: []const u8) ?u16 {
    inline for (.{ "EV_SYN", "EV_KEY", "EV_ABS", "SYN_REPORT", "BTN_TOUCH", "ABS_MT_SLOT", "ABS_MT_POSITION_X", "ABS_MT_POSITION_Y", "ABS_MT_TRACKING_ID" }) |key| {
        if (std.mem.eql(u8, name, key)) return @field(@This(), key);
    }
    return null;
}

fn event(type_id: u16, code: u16, value: i32) InputEvent {
    return .{ .sec = 0, .usec = 0, .type = type_id, .code = code, .value = value };
}

const Timed = struct { t_us: u64, input: InputEvent };

/// Caller owns the result with `gpa`; `line_no` identifies any rejected line.
fn compileEvents(gpa: std.mem.Allocator, text: []const u8, replay: bool, line_no: *usize) !std.ArrayList(Timed) {
    var result: std.ArrayList(Timed) = .empty;
    errdefer result.deinit(gpa);
    var encoded: std.ArrayList(InputEvent) = .empty;
    defer encoded.deinit(gpa);
    var state: State = .{};
    var previous: ?u64 = null;
    var origin: ?u64 = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        line_no.* += 1;
        if (replay) {
            const e = try parseGetevent(line) orelse continue;
            if (previous) |p| if (e.t_us < p) return error.Syntax;
            previous = e.t_us;
            if (origin == null) origin = e.t_us;
            try result.append(gpa, .{ .t_us = e.t_us - origin.?, .input = event(e.type, e.code, e.value) });
        } else {
            const step = try parseLine(line) orelse continue;
            const t_us = @as(u64, step.t_ms) * 1000;
            if (previous) |p| {
                if (t_us < p) return error.Syntax;
                if (t_us != p) try result.append(gpa, .{ .t_us = p, .input = event(EV_SYN, SYN_REPORT, 0) });
            }
            previous = t_us;
            encoded.clearRetainingCapacity();
            try encode(gpa, step, &state, &encoded);
            for (encoded.items) |e| try result.append(gpa, .{ .t_us = t_us, .input = e });
        }
    }
    if (!replay) if (previous) |p| try result.append(gpa, .{ .t_us = p, .input = event(EV_SYN, SYN_REPORT, 0) });
    return result;
}

fn deadline(start: linux.timespec, t_us: u64) linux.timespec {
    const ns: u64 = @as(u64, @intCast(start.nsec)) + (t_us % 1_000_000) * 1000;
    return .{
        .sec = start.sec + @as(isize, @intCast(t_us / 1_000_000 + ns / 1_000_000_000)),
        .nsec = @intCast(ns % 1_000_000_000),
    };
}

pub fn main(init: std.process.Init) void {
    var line_no: usize = 0;
    run(init, &line_no) catch |err| {
        std.debug.print("line {d}: {t}\n", .{ line_no, err });
        std.process.exit(2);
    };
}

fn run(init: std.process.Init, line_no: *usize) !void {
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const replay = args.len > 1 and std.mem.eql(u8, args[1], "--replay");
    const offset: usize = if (replay) 2 else 1;
    if (args.len != offset + 2) return error.Usage;
    const cwd = std.Io.Dir.cwd();
    const text = try cwd.readFileAlloc(init.io, args[offset + 1], gpa, .unlimited);
    defer gpa.free(text);
    var events = try compileEvents(gpa, text, replay, line_no);
    defer events.deinit(gpa);
    const node = try cwd.openFile(init.io, args[offset], .{ .mode = .write_only });
    defer node.close(init.io);
    var start: linux.timespec = .{ .sec = 0, .nsec = 0 };
    if (linux.errno(linux.clock_gettime(.MONOTONIC, &start)) != .SUCCESS) return error.Clock;
    var previous: ?u64 = null;
    for (events.items) |e| {
        if (previous == null or previous.? != e.t_us) {
            const target = deadline(start, e.t_us);
            while (true) switch (linux.errno(linux.clock_nanosleep(.MONOTONIC, .{ .ABSTIME = true }, &target, null))) {
                .SUCCESS => break,
                .INTR => continue,
                else => return error.Clock,
            };
            previous = e.t_us;
        }
        try node.writeStreamingAll(init.io, std.mem.asBytes(&e.input));
    }
}

const testing = std.testing;

test "a tap is slot, id, x, y, touch, then lift" {
    var state: State = .{};
    var out: std.ArrayList(InputEvent) = .empty;
    defer out.deinit(testing.allocator);
    try encode(testing.allocator, (try parseLine("0 0 down 100 200")).?, &state, &out);
    try encode(testing.allocator, (try parseLine("50 0 up 100 200")).?, &state, &out);
    const expected = [_]InputEvent{
        event(3, 0x2f, 0), event(3, 0x39, 1),  event(3, 0x35, 100), event(3, 0x36, 200), event(1, 0x14a, 1),
        event(3, 0x2f, 0), event(3, 0x39, -1), event(1, 0x14a, 0),
    };
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&expected), std.mem.sliceAsBytes(out.items));
    try testing.expectEqual(@as(usize, 24), @sizeOf(InputEvent));
}

test "a second finger does not repeat BTN_TOUCH" {
    var line: usize = 0;
    var out = try compileEvents(testing.allocator, "0 0 down 1 2\n0 1 down 3 4\n1 0 up 1 2\n2 1 up 3 4", false, &line);
    defer out.deinit(testing.allocator);
    const expected = [_]InputEvent{
        event(3, 0x2f, 0),  event(3, 0x39, 1),  event(3, 0x35, 1), event(3, 0x36, 2), event(1, 0x14a, 1),
        event(3, 0x2f, 1),  event(3, 0x39, 2),  event(3, 0x35, 3), event(3, 0x36, 4), event(0, 0, 0),
        event(3, 0x2f, 0),  event(3, 0x39, -1), event(0, 0, 0),    event(3, 0x2f, 1), event(3, 0x39, -1),
        event(1, 0x14a, 0), event(0, 0, 0),
    };
    try testing.expectEqual(expected.len, out.items.len);
    for (out.items, expected, 0..) |actual, want, i| {
        try testing.expectEqualDeep(want, actual.input);
        try testing.expectEqual(@as(u64, if (i < 10) 0 else if (i < 13) 1000 else 2000), actual.t_us);
    }
}

test "parse errors name the line" {
    try testing.expectError(error.Syntax, parseLine("10 0 hover 1 2"));
    try testing.expectError(error.Syntax, parseLine("x 0 down 1 2"));
    try testing.expectEqual(null, try parseLine("# c"));
    try testing.expectError(error.Syntax, parseLine("0 16 down 1 2"));
    var line: usize = 0;
    try testing.expectError(error.Syntax, compileEvents(testing.allocator, "# c\n0 0 down 1 2\nx 0 down 1 2", false, &line));
    try testing.expectEqual(@as(usize, 3), line);
    line = 0;
    try testing.expectError(error.Syntax, compileEvents(testing.allocator, "2 0 move 1 2\n1 0 move 1 2", false, &line));
    try testing.expectEqual(@as(usize, 2), line);
}

test "getevent lines" {
    const e = (try parseGetevent("[   12345.678901] EV_ABS       ABS_MT_POSITION_X    000001f4")).?;
    try testing.expectEqualDeep(@TypeOf(e){ .t_us = 12345678901, .type = 3, .code = 0x35, .value = 500 }, e);
    try testing.expectEqual(@as(i32, -1), (try parseGetevent("[ 1.000000] /dev/input/event2: EV_ABS ABS_MT_TRACKING_ID ffffffff")).?.value);
    try testing.expectEqual(null, try parseGetevent("[ 1.000000] EV_ABS ABS_UNKNOWN 00000000"));
    try testing.expectEqual(null, try parseGetevent("[ 1.000000] EV_UNKNOWN ABS_MT_SLOT 00000000"));
}

test "moves, replay times and absolute deadlines need no sleeping" {
    var line: usize = 0;
    var out = try compileEvents(testing.allocator, "4 2 move -1 20 # wobble", false, &line);
    defer out.deinit(testing.allocator);
    const expected = [_]InputEvent{ event(3, 0x2f, 2), event(3, 0x35, -1), event(3, 0x36, 20), event(0, 0, 0) };
    try testing.expectEqual(expected.len, out.items.len);
    for (out.items, expected) |actual, want| try testing.expectEqualDeep(want, actual.input);
    line = 0;
    var replay = try compileEvents(testing.allocator, "[ 12345.678901] EV_ABS ABS_MT_SLOT 00000000\n[ 12345.682901] EV_SYN SYN_REPORT 00000000", true, &line);
    defer replay.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 0), replay.items[0].t_us);
    try testing.expectEqual(@as(u64, 4000), replay.items[1].t_us);
    try testing.expectEqualDeep(event(0, 0, 0), replay.items[1].input);
    try testing.expectEqualDeep(linux.timespec{ .sec = 12, .nsec = 3_000_000 }, deadline(.{ .sec = 10, .nsec = 999_000_000 }, 1_004_000));
}
