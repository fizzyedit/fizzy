//! `zig build bench-tape` — how long a tape takes to save and load, ZON against the binary form.
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
    for (&tags, 0..) |*t, i| t.* = try std.fmt.allocPrint(arena, "workbench.file:demo://rec/src/file_{d}.zig", .{i});
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
    try binary.write(std.testing.allocator, t, &out.writer);
}

fn binRead(bytes: []const u8) !void {
    var owned = try binary.read(std.testing.allocator, bytes, .{});
    owned.deinit();
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
        const source = try std.testing.allocator.dupeZ(u8, zon.written());
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
