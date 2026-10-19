//! Tests for `core.diff` text: the hunks rebuild the new text from the old over random edits and
//! awkward bytes, hunks read well, a reused scratch allocates nothing, the unified output and
//! its cap.
const std = @import("std");
const Text = @import("Text.zig");
const unified = @import("unified.zig");

const gpa = std.testing.allocator;

/// `a` with every hunk applied, as edits in order.
fn apply(out: *std.ArrayList(u8), a: []const u8, b: []const u8, hunks: []const Text.Hunk) !void {
    var at: usize = 0;
    for (hunks) |h| {
        const e = Text.edit(h, b);
        try out.appendSlice(gpa, a[at..e.start]);
        try out.appendSlice(gpa, e.replacement);
        at = e.end;
    }
    try out.appendSlice(gpa, a[at..]);
}

fn expectRoundTrip(t: *Text, a: []const u8, b: []const u8) !void {
    const hunks = try t.diff(gpa, a, b, .{});
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try apply(&out, a, b, hunks);
    try std.testing.expectEqualStrings(b, out.items);
    // Hunks are ordered, apart and in step with the line counts.
    var prev_a: u32 = 0;
    for (hunks) |h| {
        try std.testing.expect(h.a_len > 0 or h.b_len > 0);
        try std.testing.expect(h.a_start >= prev_a);
        prev_a = h.a_start + h.a_len;
        try std.testing.expectEqual(h.a_len, @as(u32, @intCast(std.mem.countScalar(u8, a[h.a_byte..h.a_end], '\n') + @intFromBool(h.a_end > h.a_byte and a[h.a_end - 1] != '\n'))));
    }
}

test "equal texts have no hunks" {
    var t: Text = .{};
    defer t.deinit(gpa);
    try std.testing.expectEqual(0, (try t.diff(gpa, "", "", .{})).len);
    try std.testing.expectEqual(0, (try t.diff(gpa, "a\nb\n", "a\nb\n", .{})).len);
}

test "one changed line is one hunk" {
    var t: Text = .{};
    defer t.deinit(gpa);
    const hunks = try t.diff(gpa, "a\nb\nc\n", "a\nB\nc\n", .{});
    try std.testing.expectEqual(1, hunks.len);
    try std.testing.expectEqual(1, hunks[0].a_start);
    try std.testing.expectEqual(1, hunks[0].a_len);
    try std.testing.expectEqual(1, hunks[0].b_len);
}

test "two distant edits are two hunks" {
    var t: Text = .{};
    defer t.deinit(gpa);
    const a = "1\n2\n3\n4\n5\n6\n7\n8\n";
    const b = "1\nx\n3\n4\n5\n6\ny\n8\n";
    try std.testing.expectEqual(2, (try t.diff(gpa, a, b, .{})).len);
    try expectRoundTrip(&t, a, b);
}

test "inserts and deletes at the ends and in empty texts" {
    var t: Text = .{};
    defer t.deinit(gpa);
    try expectRoundTrip(&t, "", "a\n");
    try expectRoundTrip(&t, "a\n", "");
    try expectRoundTrip(&t, "b\n", "a\nb\nc\n");
    try expectRoundTrip(&t, "a\nb\nc\n", "b\n");
    try expectRoundTrip(&t, "a", "a\n");
    try expectRoundTrip(&t, "a\nb", "a\nb\r\n");
}

test "a block moved up reads as one insert, not a rewrite" {
    var t: Text = .{};
    defer t.deinit(gpa);
    const a = "fn a() {\n}\n\nfn c() {\n}\n";
    const b = "fn a() {\n}\n\nfn b() {\n}\n\nfn c() {\n}\n";
    const hunks = try t.diff(gpa, a, b, .{});
    try std.testing.expectEqual(1, hunks.len);
    try std.testing.expectEqual(0, hunks[0].a_len);
    try std.testing.expectEqual(3, hunks[0].b_len);
    // Slid to end on the blank line, not start on one.
    try std.testing.expectEqualStrings("fn b() {\n}\n\n", b[hunks[0].b_byte..hunks[0].b_end]);
}

test "histogram's anchors: common braces do not pull the diff off the real lines" {
    var t: Text = .{};
    defer t.deinit(gpa);
    const a = "int f() {\n  return 1;\n}\n\nint g() {\n  return 2;\n}\n";
    const b = "int g() {\n  return 2;\n}\n\nint f() {\n  return 1;\n}\n";
    try expectRoundTrip(&t, a, b);
}

test "the cost cap replaces the range, and the result still applies" {
    var t: Text = .{};
    defer t.deinit(gpa);
    var a: std.ArrayList(u8) = .empty;
    defer a.deinit(gpa);
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(gpa);
    // Only two distinct lines, so histogram has no anchor under the cap and Myers runs.
    var prng: std.Random.DefaultPrng = .init(5);
    const r = prng.random();
    for (0..400) |_| {
        try a.appendSlice(gpa, if (r.boolean()) "x\n" else "y\n");
        try b.appendSlice(gpa, if (r.boolean()) "x\n" else "y\n");
    }
    for ([_]u32{ 1024, 4 }) |cost| {
        const hunks = try t.diff(gpa, a.items, b.items, .{ .max_occurrences = 2, .max_cost = cost });
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        try apply(&out, a.items, b.items, hunks);
        try std.testing.expectEqualStrings(b.items, out.items);
    }
}

fn randomText(r: std.Random, w: *std.ArrayList(u8), lines: usize, alphabet: []const u8) !void {
    for (0..lines) |_| {
        for (0..r.uintLessThan(usize, 5)) |_| try w.append(gpa, alphabet[r.uintLessThan(usize, alphabet.len)]);
        if (r.uintLessThan(u8, 12) != 0) try w.append(gpa, '\n');
    }
}

test "random edits round trip, over text, CRLF, no final newline and binary" {
    var t: Text = .{};
    defer t.deinit(gpa);
    var prng: std.Random.DefaultPrng = .init(0xd1ff);
    const r = prng.random();
    const alphabets = [_][]const u8{ "ab\n", "ab\r\n", "a\n\n\n", "\x00\xff\n\r ab" };
    for (0..300) |n| {
        var a: std.ArrayList(u8) = .empty;
        defer a.deinit(gpa);
        try randomText(r, &a, r.uintLessThan(usize, 60), alphabets[n % alphabets.len]);
        // b is a with a few random splices.
        var b: std.ArrayList(u8) = .empty;
        defer b.deinit(gpa);
        try b.appendSlice(gpa, a.items);
        for (0..r.uintLessThan(usize, 5)) |_| {
            const at = if (b.items.len == 0) 0 else r.uintLessThan(usize, b.items.len);
            const cut = @min(r.uintLessThan(usize, 20), b.items.len - at);
            var piece: std.ArrayList(u8) = .empty;
            defer piece.deinit(gpa);
            try randomText(r, &piece, r.uintLessThan(usize, 4), alphabets[n % alphabets.len]);
            try b.replaceRange(gpa, at, cut, piece.items);
        }
        try expectRoundTrip(&t, a.items, b.items);
        try expectRoundTrip(&t, b.items, a.items);
    }
}

test "non-overlapping edits keep their hunks apart" {
    var t: Text = .{};
    defer t.deinit(gpa);
    var a: std.ArrayList(u8) = .empty;
    defer a.deinit(gpa);
    for (0..200) |i| try a.print(gpa, "line {d}\n", .{i});
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(gpa);
    var it = std.mem.splitScalar(u8, a.items, '\n');
    var n: usize = 0;
    while (it.next()) |l| : (n += 1) {
        if (l.len == 0) continue;
        if (n % 50 == 7) try b.print(gpa, "changed {d}\n", .{n}) else try b.print(gpa, "{s}\n", .{l});
    }
    try std.testing.expectEqual(4, (try t.diff(gpa, a.items, b.items, .{})).len);
}

test "a reused scratch allocates nothing" {
    var t: Text = .{};
    defer t.deinit(gpa);
    const a = "a\nb\nc\nd\ne\nf\ng\n";
    const b = "a\nB\nc\nd\nE\nf\ng\nh\n";
    _ = try t.diff(gpa, a, b, .{});
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    const hunks = try t.diff(failing.allocator(), a, b, .{});
    try std.testing.expectEqual(3, hunks.len);
}

fn render(a: []const u8, b: []const u8, opts: unified.Options) !struct { text: []u8, omitted: u32 } {
    var t: Text = .{};
    defer t.deinit(gpa);
    const hunks = try t.diff(gpa, a, b, .{});
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const omitted = try unified.write(gpa, &out.writer, "a/f", "b/f", a, b, hunks, opts);
    return .{ .text = try out.toOwnedSlice(), .omitted = omitted };
}

test "unified output" {
    const a = "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n";
    const b = "1\n2\n3\nfour\n5\n6\n7\n8\n9\n10\n11\n12\n13\n";
    const got = try render(a, b, .{ .context = 2 });
    defer gpa.free(got.text);
    try std.testing.expectEqualStrings(
        \\--- a/f
        \\+++ b/f
        \\@@ -2,5 +2,5 @@
        \\ 2
        \\ 3
        \\-4
        \\+four
        \\ 5
        \\ 6
        \\@@ -11,2 +11,3 @@
        \\ 11
        \\ 12
        \\+13
        \\
    , got.text);
}

test "unified marks a missing final newline and writes pure inserts and deletes" {
    const got = try render("a\nb", "a\nb\nc\n", .{ .context = 1 });
    defer gpa.free(got.text);
    try std.testing.expectEqualStrings(
        \\--- a/f
        \\+++ b/f
        \\@@ -1,2 +1,3 @@
        \\ a
        \\-b
        \\\ No newline at end of file
        \\+b
        \\+c
        \\
    , got.text);
    const gone = try render("a\n", "", .{});
    defer gpa.free(gone.text);
    try std.testing.expectEqualStrings("--- a/f\n+++ b/f\n@@ -1 +0,0 @@\n-a\n", gone.text);
}

test "unified cap leaves whole groups and counts the rest" {
    var a: std.ArrayList(u8) = .empty;
    defer a.deinit(gpa);
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(gpa);
    for (0..100) |i| {
        try a.print(gpa, "line {d}\n", .{i});
        if (i % 20 == 5) try b.print(gpa, "edit {d}\n", .{i}) else try b.print(gpa, "line {d}\n", .{i});
    }
    const full = try render(a.items, b.items, .{});
    defer gpa.free(full.text);
    try std.testing.expectEqual(0, full.omitted);
    const capped = try render(a.items, b.items, .{ .max_bytes = 250 });
    defer gpa.free(capped.text);
    try std.testing.expect(capped.omitted > 0 and capped.omitted < 5);
    try std.testing.expect(capped.text.len <= 250);
    try std.testing.expect(std.mem.indexOf(u8, capped.text, " more hunk") != null);
}
