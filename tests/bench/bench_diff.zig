//! `zig build bench-diff` — `core.diff` text on about 1 MB (25k lines) against the plan's budget
//! (`plans/DIFF_PLAN.md` section 3), with one reused scratch as a caller would hold.
//!
//! Prints timings rather than asserting them: compare runs at the same `-Doptimize`
//! (`-Doptimize=ReleaseFast` for numbers worth quoting). Each is the best of several runs. It
//! does assert the hunks rebuild the new text, so a fast wrong answer fails.
const std = @import("std");
const diff = @import("diff");

const gpa = std.heap.page_allocator;
const lines = 25_000;

fn nowNs() i96 {
    return std.Io.Clock.boot.now(std.testing.io).nanoseconds;
}

/// Source-shaped lines: indentation, short common ones (braces, blanks) and unique ones.
fn source(out: *std.ArrayList(u8), r: std.Random) !void {
    for (0..lines) |i| {
        switch (r.uintLessThan(u8, 8)) {
            0 => try out.appendSlice(gpa, "}\n"),
            1 => try out.appendSlice(gpa, "\n"),
            else => try out.print(gpa, "{s}const value_{d} = compute(arg_{d}, {d}); // line {d}\n", .{ "        "[0 .. 4 * r.uintLessThan(usize, 3)], i, i % 97, r.int(u16), i }),
        }
    }
}

/// `a` with every `every`-th line replaced (0: none).
fn edited(out: *std.ArrayList(u8), a: []const u8, every: usize, tag: []const u8) !void {
    var it = std.mem.splitScalar(u8, a, '\n');
    var n: usize = 0;
    while (it.next()) |l| : (n += 1) {
        if (it.peek() == null and l.len == 0) break;
        if (every != 0 and n % every == 0) try out.print(gpa, "    {s} {d}\n", .{ tag, n }) else try out.print(gpa, "{s}\n", .{l});
    }
}

fn check(a: []const u8, b: []const u8, hunks: []const diff.Text.Hunk) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var at: usize = 0;
    for (hunks) |h| {
        const e = diff.Text.edit(h, b);
        try out.appendSlice(gpa, a[at..e.start]);
        try out.appendSlice(gpa, e.replacement);
        at = e.end;
    }
    try out.appendSlice(gpa, a[at..]);
    try std.testing.expectEqualStrings(b, out.items);
}

fn run(t: *diff.Text, name: []const u8, budget_ms: f64, a: []const u8, b: []const u8) !void {
    var hunks: []const diff.Text.Hunk = &.{};
    _ = try t.diff(gpa, a, b, .{}); // warm the scratch
    var best: i96 = std.math.maxInt(i96);
    for (0..10) |_| {
        const t0 = nowNs();
        hunks = try t.diff(gpa, a, b, .{});
        best = @min(best, nowNs() - t0);
    }
    try check(a, b, hunks);
    const ms = @as(f64, @floatFromInt(best)) / 1e6;
    std.debug.print("  {s:<34} {d:>9.3} ms  (budget {d:>5.1} ms)  {d} hunks  {s}\n", .{ name, ms, budget_ms, hunks.len, if (ms <= budget_ms) "ok" else "OVER" });
}

test "bench: core.diff text, 1 MB" {
    var prng: std.Random.DefaultPrng = .init(0xbe7c);
    var a: std.ArrayList(u8) = .empty;
    try source(&a, prng.random());
    std.debug.print("\nbench-diff: {d} bytes, {d} lines\n", .{ a.items.len, lines });
    var t: diff.Text = .{};

    try run(&t, "identical", 0.2, a.items, a.items);

    var one: std.ArrayList(u8) = .empty;
    try one.appendSlice(gpa, a.items);
    const mid = std.mem.indexOfScalarPos(u8, one.items, a.items.len / 2, '\n').? + 1;
    try one.insertSlice(gpa, mid, "    one edited line\n");
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
    for (0..lines) |_| {
        try rep_a.appendSlice(gpa, if (r.boolean()) "x\n" else "y\n");
        try rep_b.appendSlice(gpa, if (r.boolean()) "x\n" else "y\n");
    }
    try run(&t, "two-line alphabet (Myers, capped)", 60, rep_a.items, rep_b.items);
}
