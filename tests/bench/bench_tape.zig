//! `zig build bench-tape` — how long a tape takes to save and load, ZON against the binary form,
//! and a recording of drawing's size and speed plain against deflated.
//!
//! Prints timings rather than asserting them: compare runs at the same `-Doptimize`
//! (`-Doptimize=ReleaseFast` for numbers worth quoting). The tapes are recording-shaped — glides
//! to a few dozen anchors, clicks, chords, typed text — at the sizes of a scripted demo, a few
//! minutes of recording, and a long session. Each timing is the best of several runs.
const std = @import("std");
const tape_mod = @import("tape");
const Tape = tape_mod.Tape;
const binary = tape_mod.binary;

fn nowNs() i96 {
    return std.Io.Clock.boot.now(std.testing.io).nanoseconds;
}

/// A tape of `n` ops, as a recorder might write one.
fn recording(arena: std.mem.Allocator, n: usize) !Tape {
    var tags: [40][]const u8 = undefined;
    for (&tags, 0..) |*t, i| t.* = try arena.print("workbench.file:demo://rec/src/file_{d}.zig", .{i});
    const ops = try arena.alloc(Tape.Op, n);
    ops[0] = .{ .at = 0, .do = .{ .keyframe = 0 } };
    var prng: std.Random.DefaultPrng = .init(0x7a9e);
    const r = prng.random();
    var t: u32 = 0;
    for (ops[1..]) |*op| {
        t += 10 + r.uintLessThan(u32, 200);
        op.* = switch (r.uintLessThan(u32, 10)) {
            0...4 => .{ .at = t, .ms = 120, .do = .{ .move = .{ .tag = tags[r.uintLessThan(usize, tags.len)], .x = r.float(f32), .y = r.float(f32) } } },
            5 => .{ .at = t, .do = .{ .press = .left } },
            6 => .{ .at = t, .do = .{ .release = .left } },
            7 => .{ .at = t, .do = .{ .key = "mod+s" } },
            8 => .{ .at = t, .ms = 400, .do = .{ .type = "hello, world" } },
            else => .{ .at = t, .do = .{ .scroll = .{ .y = -1 } } },
        };
    }
    const kf = try arena.alloc(Tape.Keyframe, 1);
    kf[0] = .{ .root = "demo://rec", .files = &.{.{ .path = "src/main.zig", .text = "const std = @import(\"std\");\n" }} };
    return .{ .name = "rec", .title = "A recording", .ops = ops, .keyframes = kf };
}

const runs = 7;

/// The best of `runs` timings of `f(args)`, in ms.
fn best(comptime f: anytype, args: anytype) !f64 {
    var fastest: i96 = std.math.maxInt(i96);
    for (0..runs) |_| {
        const t0 = nowNs();
        try @call(.auto, f, args);
        fastest = @min(fastest, nowNs() - t0);
    }
    return @as(f64, @floatFromInt(fastest)) / std.time.ns_per_ms;
}

fn zonWrite(t: Tape, out: *std.Io.Writer.Allocating) !void {
    out.clearRetainingCapacity();
    try t.write(&out.writer);
}

fn zonRead(source: [:0]const u8) !void {
    var owned = try Tape.parse(std.testing.allocator, source, .{});
    owned.deinit();
}

fn binWrite(t: Tape, out: *std.Io.Writer.Allocating) !void {
    out.clearRetainingCapacity();
    try binary.write(std.testing.allocator, t, &out.writer, .{});
}

fn binRead(bytes: []const u8) !void {
    var owned = try binary.read(std.testing.allocator, bytes, steps_check);
    owned.deinit();
}

const steps_check = Tape.test_steps;

/// `n` steps of drawing a small sprite, shaped as a pixi stroke's effect will be: the layer, the
/// pixels' indices as deltas (neighbours, so mostly one byte), their colours before and after in
/// runs, and the pen's path. Not pixi's encoding — that is pixi's (step 4 of
/// plans/RECORDING_PLAN.md measures the real one) — but its size and its sameness.
fn drawing(arena: std.mem.Allocator, n: usize) !Tape {
    var prng: std.Random.DefaultPrng = .init(0x51e9);
    const r = prng.random();
    const palette = [_][4]u8{ .{ 0, 0, 0, 0 }, .{ 34, 32, 52, 255 }, .{ 69, 40, 60, 255 }, .{ 172, 50, 50, 255 }, .{ 223, 113, 38, 255 }, .{ 251, 242, 54, 255 } };
    const ops = try arena.alloc(Tape.Op, n + 1);
    ops[0] = .{ .at = 0, .do = .{ .keyframe = 0 } };
    var t: u32 = 0;
    for (ops[1..]) |*op| {
        const pixels = 4 + r.uintLessThan(usize, 56);
        var effect: std.ArrayList(u8) = .empty;
        try effect.appendSlice(arena, &.{ 1, @intCast(pixels) });
        for (0..pixels) |_| try effect.append(arena, if (r.uintLessThan(u8, 8) == 0) 64 else 1);
        // Before: what was there, in a run or three; after: the pen's colour.
        for (0..1 + r.uintLessThan(usize, 3)) |_| {
            try effect.append(arena, @intCast(1 + r.uintLessThan(usize, pixels)));
            try effect.appendSlice(arena, &palette[r.uintLessThan(usize, palette.len)]);
        }
        try effect.append(arena, @intCast(pixels));
        try effect.appendSlice(arena, &palette[1 + r.uintLessThan(usize, palette.len - 1)]);
        // The pen's path: a point every other pixel, a small step and a few ms each.
        const motion = try arena.alloc(u8, (pixels / 2) * 3);
        for (motion, 0..) |*b, i| b.* = if (i % 3 == 2) 8 + r.uintLessThan(u8, 8) else r.uintLessThan(u8, 3);
        const ms: u32 = @intCast(pixels * 12);
        t += 400 + r.uintLessThan(u32, 3000);
        op.* = .{ .at = t, .ms = ms, .do = .{ .step = .{ .file = "sprite.pixi", .effect = effect.items, .motion = motion } } };
        t += ms;
    }
    // The sprite as it opened: a small file, already packed, so it barely deflates.
    const sprite = try arena.alloc(u8, 6 * 1024);
    r.bytes(sprite);
    const files = try arena.alloc(Tape.File, 1);
    files[0] = .{ .path = "sprite.pixi", .text = sprite, .owner = "pixi", .format = 1 };
    const kf = try arena.alloc(Tape.Keyframe, 1);
    kf[0] = .{ .root = "demo://drawing", .files = files, .open = &.{"sprite.pixi"} };
    return .{ .name = "drawing", .ops = ops, .keyframes = kf };
}

fn binWriteWith(t: Tape, out: *std.Io.Writer.Allocating, opts: binary.Options) !void {
    out.clearRetainingCapacity();
    try binary.write(std.testing.allocator, t, &out.writer, opts);
}

test "bench tape: a recording of drawing, plain against deflated" {
    std.debug.print("\n{s:>9} {s:>10} | {s:>9} {s:>9} {s:>9} | {s:>9} {s:>9} {s:>9} | {s:>7}\n", .{
        "steps", "drawing", "plain KB", "write ms", "read ms", "zlib KB", "write ms", "read ms", "smaller",
    });
    for ([_]usize{ 2_000, 20_000, 100_000 }) |n| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const t = try drawing(arena.allocator(), n);
        try t.validate(steps_check);

        var plain: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer plain.deinit();
        const plain_write = try best(binWriteWith, .{ t, &plain, binary.Options{} });
        const plain_read = try best(binRead, .{plain.written()});
        var deflated: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer deflated.deinit();
        const deflated_write = try best(binWriteWith, .{ t, &deflated, binary.Options{ .deflate = true } });
        const deflated_read = try best(binRead, .{deflated.written()});

        const minutes = @as(f64, @floatFromInt(t.duration())) / std.time.ms_per_min;
        std.debug.print("{d:>9} {d:>7.0} min | {d:>9} {d:>9.3} {d:>9.3} | {d:>9} {d:>9.3} {d:>9.3} | {d:>6.1}x\n", .{
            n,
            minutes,
            plain.written().len / 1024,
            plain_write,
            plain_read,
            deflated.written().len / 1024,
            deflated_write,
            deflated_read,
            @as(f64, @floatFromInt(plain.written().len)) / @as(f64, @floatFromInt(deflated.written().len)),
        });
    }
}

test "bench tape: ZON against the binary form" {
    std.debug.print("\n{s:>9} | {s:>9} {s:>9} {s:>10} | {s:>9} {s:>9} {s:>10} | {s:>7} {s:>7}\n", .{
        "ops", "ZON KB", "write ms", "read ms", "bin KB", "write ms", "read ms", "smaller", "faster",
    });
    for ([_]usize{ 200, 10_000, 100_000 }) |n| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const t = try recording(arena.allocator(), n);
        try t.validate(.{});

        var zon: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer zon.deinit();
        const zon_write = try best(zonWrite, .{ t, &zon });
        const source = try std.testing.allocator.dupeSentinel(u8, zon.written(), 0);
        defer std.testing.allocator.free(source);
        const zon_read = try best(zonRead, .{source});

        var bin: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer bin.deinit();
        const bin_write = try best(binWrite, .{ t, &bin });
        const bin_read = try best(binRead, .{bin.written()});

        std.debug.print("{d:>9} | {d:>9} {d:>9.3} {d:>10.3} | {d:>9} {d:>9.3} {d:>10.3} | {d:>6.1}x {d:>6.0}x\n", .{
            n,
            source.len / 1024,
            zon_write,
            zon_read,
            bin.written().len / 1024,
            bin_write,
            bin_read,
            @as(f64, @floatFromInt(source.len)) / @as(f64, @floatFromInt(bin.written().len)),
            zon_read / @max(bin_read, 0.0001),
        });
    }
}
