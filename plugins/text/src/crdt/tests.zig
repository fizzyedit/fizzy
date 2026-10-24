//! Convergence tests for `Replica`: whatever order the same operations arrive in, every replica
//! ends with the same text.

const std = @import("std");
const Replica = @import("Replica.zig");
const Op = @import("op.zig").Op;

const gpa = std.testing.allocator;

fn expectText(r: *const Replica, want: []const u8) !void {
    const got = try r.toOwnedText(gpa);
    defer gpa.free(got);
    try std.testing.expectEqualStrings(want, got);
}

fn typeAt(r: *Replica, pos: usize, s: []const u8, log: *std.ArrayList(Op)) !void {
    for (s, 0..) |c, i| try log.append(gpa, try r.insert(pos + i, c));
}

test "one replica matches a plain list under random edits" {
    var prng: std.Random.DefaultPrng = .init(0xc2d7);
    const rand = prng.random();
    var r = try Replica.init(gpa, 1);
    defer r.deinit();
    var model: std.ArrayList(u21) = .empty;
    defer model.deinit(gpa);
    for (0..3000) |_| {
        if (model.items.len > 0 and rand.uintLessThan(u8, 3) == 0) {
            const pos = rand.uintLessThan(usize, model.items.len);
            _ = r.delete(pos).?;
            _ = model.orderedRemove(pos);
        } else {
            const pos = rand.uintAtMost(usize, model.items.len);
            const ch: u21 = if (rand.boolean()) 'a' + rand.uintLessThan(u21, 26) else 0x1F600 + rand.uintLessThan(u21, 8);
            _ = try r.insert(pos, ch);
            try model.insert(gpa, pos, ch);
        }
        try std.testing.expectEqual(model.items.len, r.len());
    }
    var want: std.ArrayList(u8) = .empty;
    defer want.deinit(gpa);
    for (model.items) |c| {
        var buf: [4]u8 = undefined;
        const n = try std.unicode.utf8Encode(c, &buf);
        try want.appendSlice(gpa, buf[0..n]);
    }
    try expectText(&r, want.items);
}

test "three replicas converge under random edits and random delivery" {
    for (0..300) |seed| convergence(seed) catch |e| {
        std.debug.print("failing seed {d}\n", .{seed});
        return e;
    };
}

fn convergence(seed: u64) !void {
    var prng: std.Random.DefaultPrng = .init(seed *% 0x9e3779b97f4a7c15 +% 1);
    const rand = prng.random();
    var reps: [3]Replica = undefined;
    var inbox: [3]std.ArrayList(Op) = .{ .empty, .empty, .empty };
    var made: usize = 0;
    defer for (0..made) |i| {
        reps[i].deinit();
        inbox[i].deinit(gpa);
    };
    for (&reps, 0..) |*r, i| {
        r.* = try Replica.init(gpa, @intCast(i + 1));
        made += 1;
    }

    for (0..400) |_| {
        const who = rand.uintLessThan(usize, 3);
        const r = &reps[who];
        if (rand.uintLessThan(u8, 10) < 4) {
            // A local edit, broadcast to the others' inboxes.
            const o: Op = if (r.len() > 0 and rand.uintLessThan(u8, 3) == 0)
                r.delete(rand.uintLessThan(usize, r.len())).?
            else
                try r.insert(rand.uintAtMost(usize, r.len()), 'a' + rand.uintLessThan(u21, 26));
            for (0..3) |other| if (other != who) try inbox[other].append(gpa, o);
        } else if (inbox[who].items.len > 0) {
            // A random pending delivery, now and then delivered twice.
            const i = rand.uintLessThan(usize, inbox[who].items.len);
            const o = inbox[who].items[i];
            if (rand.uintLessThan(u8, 8) != 0) _ = inbox[who].swapRemove(i);
            try r.apply(o);
        }
    }
    // Everything still in flight arrives, in a random order, to every replica.
    for (0..3) |who| {
        rand.shuffle(Op, inbox[who].items);
        for (inbox[who].items) |o| try reps[who].apply(o);
    }

    const a = try reps[0].toOwnedText(gpa);
    defer gpa.free(a);
    try std.testing.expectEqual(@as(usize, 0), reps[0].pendingCount());
    for (reps[1..]) |*r| {
        try std.testing.expectEqual(@as(usize, 0), r.pendingCount());
        try expectText(r, a);
        try std.testing.expectEqual(reps[0].len(), r.len());
    }
}

test "a duplicate op changes nothing" {
    var a = try Replica.init(gpa, 1);
    defer a.deinit();
    var b = try Replica.init(gpa, 2);
    defer b.deinit();
    const first = try a.insert(0, 'x');
    const second = try a.insert(1, 'y');
    const d = a.delete(0).?;
    for ([_]Op{ first, second, d, first, d, second }) |o| try b.apply(o);
    try expectText(&b, "y");
    try std.testing.expectEqual(@as(usize, 1), b.len());
}

test "an op waits for its origin" {
    var a = try Replica.init(gpa, 1);
    defer a.deinit();
    var b = try Replica.init(gpa, 2);
    defer b.deinit();
    const first = try a.insert(0, 'x');
    const second = try a.insert(1, 'y');
    try b.apply(second);
    try std.testing.expectEqual(@as(usize, 1), b.pendingCount());
    try expectText(&b, "");
    try b.apply(first);
    try std.testing.expectEqual(@as(usize, 0), b.pendingCount());
    try expectText(&b, "xy");
}

/// Two replicas each type a word between "[" and "]" at once, forwards or backwards.
fn concurrentWords(backwards: bool) !void {
    var a = try Replica.init(gpa, 1);
    defer a.deinit();
    var b = try Replica.init(gpa, 2);
    defer b.deinit();
    var base: std.ArrayList(Op) = .empty;
    defer base.deinit(gpa);
    try typeAt(&a, 0, "[]", &base);
    for (base.items) |o| try b.apply(o);

    var from_a: std.ArrayList(Op) = .empty;
    defer from_a.deinit(gpa);
    var from_b: std.ArrayList(Op) = .empty;
    defer from_b.deinit(gpa);
    if (backwards) {
        for ("alpha") |c| try from_a.append(gpa, try a.insert(1, c));
        for ("bravo") |c| try from_b.append(gpa, try b.insert(1, c));
    } else {
        try typeAt(&a, 1, "alpha", &from_a);
        try typeAt(&b, 1, "bravo", &from_b);
    }
    for (from_b.items) |o| try a.apply(o);
    for (from_a.items) |o| try b.apply(o);

    const got = try a.toOwnedText(gpa);
    defer gpa.free(got);
    const want: [2][]const u8 = if (backwards) .{ "[ahplaovarb]", "[ovarbahpla]" } else .{ "[alphabravo]", "[bravoalpha]" };
    try std.testing.expect(std.mem.eql(u8, got, want[0]) or std.mem.eql(u8, got, want[1]));
    try expectText(&b, got);
}

test "two words typed at one place do not interleave" {
    try concurrentWords(false);
    try concurrentWords(true);
}
