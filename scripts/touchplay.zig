//! Standalone Linux protocol B touch player, in device coordinates.
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
    var tokens = std.mem.tokenizeAny(u8, line[0 .. std.mem.indexOfScalar(u8, line, '#') orelse line.len], " \t\r");
    const time = tokens.next() orelse return null;
    const t_ms = std.fmt.parseInt(u32, time, 10) catch return error.Syntax;
    const slot = std.fmt.parseInt(u8, tokens.next() orelse return error.Syntax, 10) catch return error.Syntax;
    if (slot >= 16) return error.Syntax; // State has one bit per slot.
    const kind = std.meta.stringToEnum(@FieldType(Step, "kind"), tokens.next() orelse return error.Syntax) orelse return error.Syntax;
    const x = std.fmt.parseInt(i32, tokens.next() orelse return error.Syntax, 10) catch return error.Syntax;
    const y = std.fmt.parseInt(i32, tokens.next() orelse return error.Syntax, 10) catch return error.Syntax;
    if (tokens.next() != null) return error.Syntax;
    return .{ .t_ms = t_ms, .slot = slot, .kind = kind, .x = x, .y = y };
}

fn event(event_type: u16, code: u16, value: i32) InputEvent {
    return .{ .sec = 0, .usec = 0, .type = event_type, .code = code, .value = value };
}

/// Appends without SYN. Caller owns `out`, using std.heap.page_allocator for growth and deinit.
pub fn encode(step: Step, state: *State, out: *std.ArrayList(InputEvent)) !void {
    if (step.slot >= 16) return error.Syntax;
    try out.ensureUnusedCapacity(std.heap.page_allocator, 5); // A first down emits five events.
    const bit = @as(u16, 1) << @intCast(step.slot);
    out.appendAssumeCapacity(event(EV_ABS, ABS_MT_SLOT, step.slot));
    switch (step.kind) {
        .down => {
            out.appendAssumeCapacity(event(EV_ABS, ABS_MT_TRACKING_ID, state.next_id));
            state.next_id = std.math.add(i32, state.next_id, 1) catch return error.Syntax;
            out.appendAssumeCapacity(event(EV_ABS, ABS_MT_POSITION_X, step.x));
            out.appendAssumeCapacity(event(EV_ABS, ABS_MT_POSITION_Y, step.y));
            if (state.down == 0) out.appendAssumeCapacity(event(EV_KEY, BTN_TOUCH, 1));
            state.down |= bit;
        },
        .move => {
            out.appendAssumeCapacity(event(EV_ABS, ABS_MT_POSITION_X, step.x));
            out.appendAssumeCapacity(event(EV_ABS, ABS_MT_POSITION_Y, step.y));
        },
        .up => {
            out.appendAssumeCapacity(event(EV_ABS, ABS_MT_TRACKING_ID, -1));
            state.down &= ~bit;
            if (state.down == 0) out.appendAssumeCapacity(event(EV_KEY, BTN_TOUCH, 0));
        },
    }
}

pub fn parseGetevent(line: []const u8) error{Syntax}!?struct { t_us: u64, type: u16, code: u16, value: i32 } {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0 or trimmed[0] == '#') return null;
    if (trimmed[0] != '[') return error.Syntax;
    const end = std.mem.indexOfScalar(u8, trimmed, ']') orelse return error.Syntax;
    var time = std.mem.splitScalar(u8, std.mem.trim(u8, trimmed[1..end], " \t"), '.');
    const sec = std.fmt.parseInt(u64, time.next().?, 10) catch return error.Syntax;
    const fraction = time.next() orelse return error.Syntax;
    if (fraction.len != 6 or time.next() != null) return error.Syntax;
    const us = std.fmt.parseInt(u64, fraction, 10) catch return error.Syntax;
    const t_us = std.math.add(u64, std.math.mul(u64, sec, std.time.us_per_s) catch return error.Syntax, us) catch return error.Syntax;
    var tokens = std.mem.tokenizeAny(u8, trimmed[end + 1 ..], " \t\r");
    const type_name = tokens.next() orelse return error.Syntax;
    const code_name = tokens.next() orelse return error.Syntax;
    const event_type: u16 = if (std.mem.eql(u8, type_name, "EV_SYN")) EV_SYN else if (std.mem.eql(u8, type_name, "EV_KEY")) EV_KEY else if (std.mem.eql(u8, type_name, "EV_ABS")) EV_ABS else return null;
    const names = [_][]const u8{ "SYN_REPORT", "BTN_TOUCH", "ABS_MT_SLOT", "ABS_MT_POSITION_X", "ABS_MT_POSITION_Y", "ABS_MT_TRACKING_ID" };
    const codes = [_]u16{ SYN_REPORT, BTN_TOUCH, ABS_MT_SLOT, ABS_MT_POSITION_X, ABS_MT_POSITION_Y, ABS_MT_TRACKING_ID };
    const code: u16 = for (names, codes) |name, code| {
        if (std.mem.eql(u8, name, code_name)) break code;
    } else return null;
    const value = std.fmt.parseInt(u32, tokens.next() orelse return error.Syntax, 16) catch return error.Syntax;
    if (tokens.next() != null) return error.Syntax;
    return .{ .t_us = t_us, .type = event_type, .code = code, .value = @bitCast(value) };
}

fn waitUntil(start: linux.timespec, t_us: u64) !void {
    const nsec: u64 = @as(u64, @intCast(start.nsec)) + (t_us % std.time.us_per_s) * std.time.ns_per_us;
    const deadline: linux.timespec = .{
        .sec = start.sec + @as(isize, @intCast(t_us / std.time.us_per_s + nsec / std.time.ns_per_s)),
        .nsec = @intCast(nsec % std.time.ns_per_s),
    };
    while (true) switch (linux.errno(linux.clock_nanosleep(.MONOTONIC, .{ .ABSTIME = true }, &deadline, null))) {
        .SUCCESS => return,
        .INTR => continue,
        else => return error.ClockFailed,
    };
}

pub fn main(init: std.process.Init) void {
    var line_number: usize = 0;
    play(init, &line_number) catch |err| {
        var buffer: [256]u8 = undefined;
        const message = std.mem.print(&buffer, "line {d}: {s}\n", .{ line_number, @errorName(err) }) catch "line 0: failure\n";
        std.Io.File.stderr().writeStreamingAll(init.io, message) catch {}; // No further diagnostic sink exists.
        std.process.exit(2);
    };
}

fn play(init: std.process.Init, line_number: *usize) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    const replay = args.len > 1 and std.mem.eql(u8, args[1], "--replay");
    if (args.len != @as(usize, if (replay) 4 else 3)) return error.Usage;
    const node_index: usize = if (replay) 2 else 1;
    const source = try std.Io.Dir.cwd().readFileAlloc(init.io, args[node_index + 1], allocator, .unlimited);
    const node = try std.Io.Dir.cwd().openFile(init.io, args[node_index], .{ .mode = .write_only });
    defer node.close(init.io);
    var start: linux.timespec = undefined;
    if (linux.errno(linux.clock_gettime(.MONOTONIC, &start)) != .SUCCESS) return error.ClockFailed;
    var lines = std.mem.splitScalar(u8, source, '\n');
    var state: State = .{};
    var events: std.ArrayList(InputEvent) = .empty;
    defer events.deinit(std.heap.page_allocator);
    var previous: ?u64 = null;
    var origin: ?u64 = null;
    while (lines.next()) |line| {
        line_number.* += 1;
        events.clearRetainingCapacity();
        if (replay) {
            const parsed = try parseGetevent(line) orelse continue;
            if (previous) |prev| if (parsed.t_us < prev) return error.Syntax;
            if (origin == null) origin = parsed.t_us;
            try waitUntil(start, parsed.t_us - origin.?);
            const ev = event(parsed.type, parsed.code, parsed.value);
            try node.writeStreamingAll(init.io, std.mem.asBytes(&ev));
            previous = parsed.t_us;
        } else {
            const step = try parseLine(line) orelse continue;
            const t_us = @as(u64, step.t_ms) * std.time.us_per_ms;
            if (previous) |prev| {
                if (t_us < prev) return error.Syntax;
                if (t_us != prev) {
                    const syn = event(EV_SYN, SYN_REPORT, 0);
                    try node.writeStreamingAll(init.io, std.mem.asBytes(&syn));
                }
            }
            try waitUntil(start, t_us);
            try encode(step, &state, &events);
            try node.writeStreamingAll(init.io, std.mem.sliceAsBytes(events.items));
            previous = t_us;
        }
    }
    if (!replay and previous != null) {
        const syn = event(EV_SYN, SYN_REPORT, 0);
        try node.writeStreamingAll(init.io, std.mem.asBytes(&syn));
    }
}

test "a tap is slot, id, x, y, touch, then lift" {
    var state: State = .{};
    var out: std.ArrayList(InputEvent) = .empty;
    try out.ensureTotalCapacity(std.testing.allocator, 10);
    defer out.deinit(std.testing.allocator);
    try encode((try parseLine("0 0 down 100 200")).?, &state, &out);
    try encode((try parseLine("50 0 up 100 200")).?, &state, &out);
    const expected = [_]InputEvent{
        event(EV_ABS, ABS_MT_SLOT, 0), event(EV_ABS, ABS_MT_TRACKING_ID, 1),  event(EV_ABS, ABS_MT_POSITION_X, 100), event(EV_ABS, ABS_MT_POSITION_Y, 200), event(EV_KEY, BTN_TOUCH, 1),
        event(EV_ABS, ABS_MT_SLOT, 0), event(EV_ABS, ABS_MT_TRACKING_ID, -1), event(EV_KEY, BTN_TOUCH, 0),
    };
    try std.testing.expectEqualSlices(InputEvent, &expected, out.items);
}

test "a second finger does not repeat BTN_TOUCH" {
    var state: State = .{};
    var out: std.ArrayList(InputEvent) = .empty;
    try out.ensureTotalCapacity(std.testing.allocator, 20);
    defer out.deinit(std.testing.allocator);
    for ([_][]const u8{ "0 0 down 1 2", "0 1 down 3 4", "10 0 up 1 2", "20 1 up 3 4" }) |line| try encode((try parseLine(line)).?, &state, &out);
    const expected = [_]InputEvent{
        event(EV_ABS, ABS_MT_SLOT, 0),         event(EV_ABS, ABS_MT_TRACKING_ID, 1), event(EV_ABS, ABS_MT_POSITION_X, 1),   event(EV_ABS, ABS_MT_POSITION_Y, 2), event(EV_KEY, BTN_TOUCH, 1),
        event(EV_ABS, ABS_MT_SLOT, 1),         event(EV_ABS, ABS_MT_TRACKING_ID, 2), event(EV_ABS, ABS_MT_POSITION_X, 3),   event(EV_ABS, ABS_MT_POSITION_Y, 4), event(EV_ABS, ABS_MT_SLOT, 0),
        event(EV_ABS, ABS_MT_TRACKING_ID, -1), event(EV_ABS, ABS_MT_SLOT, 1),        event(EV_ABS, ABS_MT_TRACKING_ID, -1), event(EV_KEY, BTN_TOUCH, 0),
    };
    try std.testing.expectEqualSlices(InputEvent, &expected, out.items);
}

test "parse errors name the line" {
    try std.testing.expectError(error.Syntax, parseLine("10 0 hover 1 2"));
    try std.testing.expectError(error.Syntax, parseLine("x 0 down 1 2"));
    try std.testing.expectEqual(null, try parseLine("# c"));
    try std.testing.expectError(error.Syntax, parseLine("0 16 down 1 2"));
    try std.testing.expectError(error.Syntax, parseLine("0 0 down 1 2 extra"));
}

test "getevent lines" {
    const parsed = (try parseGetevent("[   12345.678901] EV_ABS       ABS_MT_POSITION_X    000001f4")).?;
    try std.testing.expectEqual(12345678901, parsed.t_us);
    try std.testing.expectEqual(EV_ABS, parsed.type);
    try std.testing.expectEqual(0x35, parsed.code);
    try std.testing.expectEqual(500, parsed.value);
    try std.testing.expectEqual(-1, (try parseGetevent("[ 1.000000] EV_ABS ABS_MT_TRACKING_ID ffffffff")).?.value);
    try std.testing.expectEqual(null, try parseGetevent("[ 1.000000] EV_ABS ABS_UNKNOWN 00000000"));
}
