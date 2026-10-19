//! `zig build bench-diff` — `core.diff` against `plans/DIFF_PLAN.md` section 3's budget: a 4K
//! RGBA image identical, with one small stroke, and as grids; a 2048x2048 sprite of 50 layers
//! with one touched. Prints rather than asserts; compare runs at the same `-Doptimize`
//! (`-Doptimize=ReleaseFast` for numbers worth quoting). Each timing is the best of several runs.
const std = @import("std");
const diff = @import("diff");

fn nowNs() i96 {
    return std.Io.Clock.boot.now(std.testing.io).nanoseconds;
}

fn ms(ns: i96) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e6;
}

fn bestOf(comptime n: usize, ctx: anytype, comptime f: anytype) !i96 {
    var best: i96 = std.math.maxInt(i96);
    for (0..n) |_| {
        const t0 = nowNs();
        try f(ctx);
        best = @min(best, nowNs() - t0);
    }
    return best;
}

const Pair = struct {
    gpa: std.mem.Allocator,
    img: *diff.Image,
    a: diff.Image.Source,
    b: diff.Image.Source,
    opts: diff.Image.Options = .{},
};

fn runDiff(p: Pair) !void {
    const r = try p.img.diff(p.gpa, p.a, p.b, p.opts);
    std.mem.doNotOptimizeAway(r.rects.len);
}

fn fill(px: []u8) void {
    var prng = std.Random.DefaultPrng.init(1);
    prng.random().bytes(px);
}

test "bench: 4K image" {
    const gpa = std.testing.allocator;
    const w = 3840;
    const h = 2160;
    const a = try gpa.alloc(u8, w * h * 4);
    defer gpa.free(a);
    fill(a);
    const b = try gpa.dupe(u8, a);
    defer gpa.free(b);
    var img: diff.Image = .{};
    defer img.deinit(gpa);
    var p: Pair = .{ .gpa = gpa, .img = &img, .a = .tight(a, w, h), .b = .tight(b, w, h) };

    std.debug.print("\n== core.diff, 4K RGBA ({d} MB) ==\n", .{a.len >> 20});
    try runDiff(p); // warm up the scratch
    std.debug.print("identical                 {d:8.3} ms  (target < 4)\n", .{ms(try bestOf(5, p, runDiff))});

    // A stroke: 40 x 6 px in the middle.
    for (1000..1006) |y| @memset(b[(y * w + 1500) * 4 ..][0 .. 40 * 4], 0);
    std.debug.print("one small stroke          {d:8.3} ms  (target < 8)\n", .{ms(try bestOf(5, p, runDiff))});
    p.opts.exact = false;
    std.debug.print("  tiles only              {d:8.3} ms\n", .{ms(try bestOf(5, p, runDiff))});
    p.opts.exact = true;

    // Scattered: a pixel in every tile worth of the image's rows, so every tile changes.
    const c = try gpa.dupe(u8, a);
    defer gpa.free(c);
    var y: usize = 0;
    while (y < h) : (y += 32) {
        var x: usize = 0;
        while (x < w) : (x += 32) c[(y * w + x) * 4] +%= 1;
    }
    p.b = .tight(c, w, h);
    std.debug.print("every tile touched        {d:8.3} ms  (worst case for tiles)\n", .{ms(try bestOf(5, p, runDiff))});

    var ga: diff.TileGrid = .{};
    defer ga.deinit(gpa);
    var gb: diff.TileGrid = .{};
    defer gb.deinit(gpa);
    try ga.compute(gpa, .tight(a, w, h), .@"32");
    try gb.compute(gpa, .tight(c, w, h), .@"32"); // every tile changed: the merge's worst case
    var grid_ns: i96 = std.math.maxInt(i96);
    for (0..5) |_| {
        const t0 = nowNs();
        try ga.compute(gpa, .tight(a, w, h), .@"32");
        grid_ns = @min(grid_ns, nowNs() - t0);
    }
    var best: i96 = std.math.maxInt(i96);
    for (0..5) |_| {
        const t1 = nowNs();
        const r = try ga.diff(&gb, &img, gpa, 64);
        std.mem.doNotOptimizeAway(r.rects.len);
        best = @min(best, nowNs() - t1);
    }
    std.debug.print("grid compute (hash 4K)    {d:8.3} ms  ({d} KB kept)\n", .{ ms(grid_ns), ga.hashes.items.len * 8 >> 10 });
    std.debug.print("grid vs kept grid         {d:8.3} ms  (target < 1; every tile changed)\n", .{ms(best)});
}

test "bench: 50-layer 2048x2048 sprite, one layer touched" {
    const gpa = std.testing.allocator;
    const n = 2048;
    const layers = 50;
    const a = try gpa.alloc(u8, n * n * 4);
    defer gpa.free(a);
    fill(a);
    const b = try gpa.dupe(u8, a);
    defer gpa.free(b);
    var img: diff.Image = .{};
    defer img.deinit(gpa);
    const touched = try gpa.dupe(u8, a);
    defer gpa.free(touched);
    @memset(touched[(700 * n + 300) * 4 ..][0 .. 64 * 4], 0);
    // An untouched layer shares its storage between the two steps (no compare); the touched one
    // is compared. Then the same layer from distinct buffers, what an untouched layer costs
    // when a step copied it.
    var p: Pair = .{ .gpa = gpa, .img = &img, .a = .tight(a, n, n), .b = .tight(b, n, n) };
    try runDiff(p);
    const t0 = nowNs();
    for (0..layers) |layer| {
        p.b = .tight(if (layer == 17) touched else a, n, n);
        try runDiff(p);
    }
    const shared_ns = nowNs() - t0;
    p.b = .tight(b, n, n);
    std.debug.print("\n== core.diff, {d} layers of {d}x{d} ==\none layer touched         {d:8.3} ms  (target < 10)\n", .{ layers, n, n, ms(shared_ns) });
    std.debug.print("  one layer, distinct copy {d:8.3} ms\n", .{ms(try bestOf(5, p, runDiff))});
}

// ---- text (step 1) ----

const tgpa = std.heap.page_allocator;
const text_lines = 25_000;

/// Source-shaped lines: indentation, short common ones (braces, blanks) and unique ones.
fn source(out: *std.ArrayList(u8), r: std.Random) !void {
    for (0..text_lines) |i| {
        switch (r.uintLessThan(u8, 8)) {
            0 => try out.appendSlice(tgpa, "}\n"),
            1 => try out.appendSlice(tgpa, "\n"),
            else => try out.print(tgpa, "{s}const value_{d} = compute(arg_{d}, {d}); // line {d}\n", .{ "        "[0 .. 4 * r.uintLessThan(usize, 3)], i, i % 97, r.int(u16), i }),
        }
    }
}

/// `a` with every `every`-th line replaced (0: none).
fn edited(out: *std.ArrayList(u8), a: []const u8, every: usize, tag: []const u8) !void {
    var it = std.mem.splitScalar(u8, a, '\n');
    var n: usize = 0;
    while (it.next()) |l| : (n += 1) {
        if (it.peek() == null and l.len == 0) break;
        if (every != 0 and n % every == 0) try out.print(tgpa, "    {s} {d}\n", .{ tag, n }) else try out.print(tgpa, "{s}\n", .{l});
    }
}

fn check(a: []const u8, b: []const u8, hunks: []const diff.Text.Hunk) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(tgpa);
    var at: usize = 0;
    for (hunks) |h| {
        const e = diff.Text.edit(h, b);
        try out.appendSlice(tgpa, a[at..e.start]);
        try out.appendSlice(tgpa, e.replacement);
        at = e.end;
    }
    try out.appendSlice(tgpa, a[at..]);
    try std.testing.expectEqualStrings(b, out.items);
}

fn run(t: *diff.Text, name: []const u8, budget_ms: f64, a: []const u8, b: []const u8) !void {
    var hunks: []const diff.Text.Hunk = &.{};
    _ = try t.diff(tgpa, a, b, .{}); // warm the scratch
    var best: i96 = std.math.maxInt(i96);
    for (0..10) |_| {
        const t0 = nowNs();
        hunks = try t.diff(tgpa, a, b, .{});
        best = @min(best, nowNs() - t0);
    }
    try check(a, b, hunks);
    const took = @as(f64, @floatFromInt(best)) / 1e6;
    std.debug.print("  {s:<34} {d:>9.3} ms  (budget {d:>5.1} ms)  {d} hunks  {s}\n", .{ name, took, budget_ms, hunks.len, if (took <= budget_ms) "ok" else "OVER" });
}

test "bench: text, 1 MB" {
    var prng: std.Random.DefaultPrng = .init(0xbe7c);
    var a: std.ArrayList(u8) = .empty;
    try source(&a, prng.random());
    std.debug.print("\nbench-diff: {d} bytes, {d} lines\n", .{ a.items.len, text_lines });
    var t: diff.Text = .{};

    try run(&t, "identical", 0.2, a.items, a.items);

    var one: std.ArrayList(u8) = .empty;
    try one.appendSlice(tgpa, a.items);
    const mid = std.mem.indexOfScalarPos(u8, one.items, a.items.len / 2, '\n').? + 1;
    try one.insertSlice(tgpa, mid, "    one edited line\n");
    try run(&t, "one line inserted", 2, a.items, one.items);

    var scattered: std.ArrayList(u8) = .empty;
    try edited(&scattered, a.items, 100, "edited");
    try run(&t, "1% of lines edited", 15, a.items, scattered.items);

    var all: std.ArrayList(u8) = .empty;
    try edited(&all, a.items, 1, "rewritten");
    try run(&t, "every line changed", 60, a.items, all.items);

    // Lines that repeat past the occurrence cap, so Myers does the work.
    var rep_a: std.ArrayList(u8) = .empty;
    var rep_b: std.ArrayList(u8) = .empty;
    var r = prng.random();
    for (0..text_lines) |_| {
        try rep_a.appendSlice(tgpa, if (r.boolean()) "x\n" else "y\n");
        try rep_b.appendSlice(tgpa, if (r.boolean()) "x\n" else "y\n");
    }
    try run(&t, "two-line alphabet (Myers, capped)", 60, rep_a.items, rep_b.items);
}
