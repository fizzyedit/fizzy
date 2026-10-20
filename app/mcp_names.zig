//! MCP tool names for the app's commands. Clients refuse a tool name outside
//! `[A-Za-z0-9_-]{1,64}` (Claude's API among them), and command ids are dotted (`text.insert`), so
//! each id is spelled as a name every client accepts, and found again when a `tools/call` names it.
//!
//! The rule: `.` becomes `__`, any other character outside the set becomes `_`. An id that spells
//! back to itself (`text.insert` ↔ `text__insert`, which is nearly every id) keeps that name, and
//! `unspell` finds it from the name alone. One that does not (it has `__`, or a character outside
//! the set) keeps its name too unless another id has it; then it gets `_` and six hex digits of its
//! id's hash, so which id keeps the plain name does not hang on the order plugins load in. A name
//! past 64 characters is cut to 57 and gets the same suffix. A suffixed name that meets another
//! name is hashed again with the next seed, so no two tools share a name. std-only: the tests run
//! without a Host (`fizzy-mcp-names-tests`); `mcp.zig` applies it to the registry.
const std = @import("std");

pub const max_len = 64;
const suffix_len = 7; // `_` and six hex digits

/// A tool name, held inline.
pub const Name = struct {
    buf: [max_len]u8 = undefined,
    len: u8 = 0,

    pub fn slice(self: *const Name) []const u8 {
        return self.buf[0..self.len];
    }
};

/// `id` spelled as a name: `.` → `__`, anything outside `[A-Za-z0-9_-]` → `_`, and past `max_len`,
/// cut and suffixed. Empty only for an empty id.
pub fn plain(id: []const u8) Name {
    return if (fits(id)) spell(id) else suffixed(id, 0);
}

/// `id`'s name cut to leave room for its hash with `seed` (`_` and six hex digits) on the end.
pub fn suffixed(id: []const u8, seed: u64) Name {
    var n = spell(id);
    n.len = @min(n.len, max_len - suffix_len);
    const hash: u24 = @truncate(std.hash.Wyhash.hash(seed, id));
    _ = std.mem.print(n.buf[n.len..][0..suffix_len], "_{x:0>6}", .{hash}) catch unreachable;
    n.len += suffix_len;
    return n;
}

/// `id` spelled, as much as fits.
fn spell(id: []const u8) Name {
    var n: Name = .{};
    for (id) |c| {
        const spelled: []const u8 = if (c == '.') "__" else if (allowed(c)) &.{c} else "_";
        for (spelled) |b| if (n.len < max_len) {
            n.buf[n.len] = b;
            n.len += 1;
        };
    }
    return n;
}

/// Whether `id`'s plain name spells it back: the name alone finds it, whatever else is registered.
pub fn reversible(id: []const u8) bool {
    if (!fits(id)) return false;
    const name = plain(id);
    var back: [max_len]u8 = undefined;
    return std.mem.eql(u8, unspell(name.slice(), &back), id);
}

/// A name read back as an id: `__` → `.`. Only an id that is `reversible` comes back as it was.
pub fn unspell(name: []const u8, out: *[max_len]u8) []const u8 {
    var i: usize = 0;
    var n: usize = 0;
    while (i < name.len and n < out.len) : (n += 1) {
        if (i + 1 < name.len and name[i] == '_' and name[i + 1] == '_') {
            out[n] = '.';
            i += 2;
        } else {
            out[n] = name[i];
            i += 1;
        }
    }
    return out[0..n];
}

/// The names of `ids`, which are distinct, in their order, in `arena`, no two alike: each its
/// plain name unless that collides and it is not `reversible` (module doc).
pub fn assign(arena: std.mem.Allocator, ids: []const []const u8) error{OutOfMemory}![]Name {
    const names = try arena.alloc(Name, ids.len);
    var count: std.StringHashMapUnmanaged(u32) = .empty;
    for (ids, names) |id, *n| {
        n.* = plain(id);
        const e = try count.getOrPut(arena, try arena.dupe(u8, n.slice()));
        e.value_ptr.* = if (e.found_existing) e.value_ptr.* + 1 else 1;
    }
    // The names taken: the ids that spell back first (no two of those share a name), so none of
    // them moves for another; then the rest, each hashed again until its name is free.
    var taken: std.StringHashMapUnmanaged(void) = .empty;
    for (ids, names) |id, *n| if (reversible(id)) try taken.put(arena, n.slice(), {});
    for (ids, names) |id, *n| {
        if (reversible(id)) continue;
        var seed: u64 = 0;
        if (count.get(n.slice()).? > 1) n.* = suffixed(id, seed);
        while (taken.contains(n.slice())) : (seed += 1) n.* = suffixed(id, seed + 1);
        try taken.put(arena, n.slice(), {});
    }
    return names;
}

fn allowed(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
}

/// Whether `id`'s plain name needs no cut.
fn fits(id: []const u8) bool {
    var len: usize = 0;
    for (id) |c| len += if (c == '.') 2 else 1;
    return len <= max_len;
}

fn valid(name: []const u8) bool {
    if (name.len == 0 or name.len > max_len) return false;
    for (name) |c| if (!allowed(c)) return false;
    return true;
}

test "a dotted id spells as a name and back" {
    for ([_][]const u8{ "text.insert", "fizzy.screen", "pixi.layer.add", "a-b_c.d9" }) |id| {
        const n = plain(id);
        try std.testing.expect(valid(n.slice()));
        try std.testing.expect(reversible(id));
        var back: [max_len]u8 = undefined;
        try std.testing.expectEqualStrings(id, unspell(n.slice(), &back));
    }
    const insert = plain("text.insert");
    try std.testing.expectEqualStrings("text__insert", insert.slice());
    const add = plain("pixi.layer.add");
    try std.testing.expectEqualStrings("pixi__layer__add", add.slice());
}

test "other characters become _, and such an id does not spell back" {
    const spaced = plain("a b/c");
    try std.testing.expectEqualStrings("a_b_c", spaced.slice());
    const accented = plain("caf\xc3\xa9");
    try std.testing.expectEqualStrings("caf__", accented.slice());
    try std.testing.expect(!reversible("a b"));
    try std.testing.expect(!reversible("a__b"));
}

test "a long id is cut and suffixed, and two that share a start stay apart" {
    const xs: [70]u8 = @splat('x');
    const long_a = "plugin." ++ xs ++ ".a";
    const long_b = "plugin." ++ xs ++ ".b";
    const a = plain(long_a);
    const b = plain(long_b);
    try std.testing.expectEqual(@as(usize, max_len), a.len);
    try std.testing.expect(valid(a.slice()));
    try std.testing.expect(!std.mem.eql(u8, a.slice(), b.slice()));
    try std.testing.expect(!reversible(long_a));
    // Exactly at the limit still fits.
    const edge: [max_len]u8 = @splat('a');
    const at_edge = plain(&edge);
    try std.testing.expectEqualStrings(&edge, at_edge.slice());
    try std.testing.expect(reversible(&edge));
    const again = suffixed(long_a, 0);
    try std.testing.expectEqualStrings(a.slice(), again.slice());
}

test "a collision suffixes the id that does not spell back, whatever the order" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_][2][]const u8{ .{ "a.b", "a__b" }, .{ "a__b", "a.b" } }) |ids| {
        const names = try assign(arena, &ids);
        const dotted: usize = if (std.mem.eql(u8, ids[0], "a.b")) 0 else 1;
        try std.testing.expectEqualStrings("a__b", names[dotted].slice());
        const other = names[1 - dotted].slice();
        try std.testing.expect(valid(other));
        try std.testing.expect(std.mem.startsWith(u8, other, "a__b_"));
        try std.testing.expectEqual(@as(usize, "a__b".len + suffix_len), other.len);
    }
    // Neither spells back: both are suffixed, and apart.
    const both = try assign(arena, &.{ "a b", "a/b", "c.d" });
    try std.testing.expect(!std.mem.eql(u8, both[0].slice(), both[1].slice()));
    try std.testing.expect(std.mem.startsWith(u8, both[0].slice(), "a_b_"));
    try std.testing.expectEqualStrings("c__d", both[2].slice());
    // Alone, an id that does not spell back keeps its plain name.
    const alone = try assign(arena, &.{"a b"});
    try std.testing.expectEqualStrings("a_b", alone[0].slice());
    // A suffixed name another id already has as its own is hashed again.
    const first = suffixed("a b", 0);
    var twin_id: [max_len]u8 = undefined;
    const met = try assign(arena, &.{ "a b", "a/b", unspell(first.slice(), &twin_id) });
    try std.testing.expectEqualStrings(first.slice(), met[2].slice());
    try std.testing.expect(!std.mem.eql(u8, met[0].slice(), met[2].slice()));
    try std.testing.expect(!std.mem.eql(u8, met[0].slice(), met[1].slice()));
}
