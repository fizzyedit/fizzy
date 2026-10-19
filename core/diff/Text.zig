//! A line diff of two texts: git's histogram algorithm over interned line ids, Myers (linear
//! space, bounded cost) where histogram finds no anchor, and the hunks slid to where they read
//! best.
//!
//! This file is the reusable scratch: keep one `Text` per caller, call `diff` as often as
//! needed, and nothing allocates once its buffers have grown to the biggest input seen. The
//! hunks `diff` returns live in the scratch until the next call.
//!
//! Lines end after `\n` and keep it, so `\r\n` is part of the line and a last line without a
//! newline differs from the same line with one. Binary input is just long lines.
//!
//! std-only, so plugins, the web and a plain test root all use it (`plans/DIFF_PLAN.md` 2.1-2.2).
const std = @import("std");

const Text = @This();

/// One changed span: `a`'s lines `a_start..a_start + a_len` became `b`'s lines
/// `b_start..b_start + b_len`. Either length may be zero (a pure insert or delete). The byte
/// ranges are the same spans in the texts, whole lines including their `\n`.
pub const Hunk = struct {
    a_start: u32,
    a_len: u32,
    b_start: u32,
    b_len: u32,
    a_byte: usize,
    a_end: usize,
    b_byte: usize,
    b_end: usize,
};

/// A hunk as the edit that applies it: replace `a[start..end]` with `replacement`.
pub const Edit = struct {
    start: usize,
    end: usize,
    replacement: []const u8,
};

pub const Options = struct {
    /// Lines that occur more often than this in a range are not anchors (git's default).
    max_occurrences: u32 = 64,
    /// Myers gives up on a range whose edit script is longer than this, and replaces the
    /// range whole: the bound on a text where nearly every line changed.
    max_cost: u32 = 1024,
};

pub const Error = error{TooLarge} || std.mem.Allocator.Error;

const nil = std.math.maxInt(u32);
const Job = [4]u32;

hunks: std.ArrayList(Hunk) = .empty,

reps: std.ArrayList([]const u8) = .empty,
hashes: std.ArrayList(u64) = .empty,
table: std.ArrayList(u32) = .empty,
a_ids: std.ArrayList(u32) = .empty,
b_ids: std.ArrayList(u32) = .empty,
a_offs: std.ArrayList(usize) = .empty,
b_offs: std.ArrayList(usize) = .empty,
a_chg: std.ArrayList(u8) = .empty,
b_chg: std.ArrayList(u8) = .empty,
head: std.ArrayList(u32) = .empty,
next: std.ArrayList(u32) = .empty,
cnt: std.ArrayList(u32) = .empty,
stack: std.ArrayList(Job) = .empty,
v: std.ArrayList(i32) = .empty,
local: std.ArrayList([4]u32) = .empty,

pub fn deinit(self: *Text, gpa: std.mem.Allocator) void {
    self.hunks.deinit(gpa);
    self.reps.deinit(gpa);
    self.hashes.deinit(gpa);
    self.table.deinit(gpa);
    self.a_ids.deinit(gpa);
    self.b_ids.deinit(gpa);
    self.a_offs.deinit(gpa);
    self.b_offs.deinit(gpa);
    self.a_chg.deinit(gpa);
    self.b_chg.deinit(gpa);
    self.head.deinit(gpa);
    self.next.deinit(gpa);
    self.cnt.deinit(gpa);
    self.stack.deinit(gpa);
    self.v.deinit(gpa);
    self.local.deinit(gpa);
    self.* = .{};
}

/// `edit` for `h`, the replacement borrowed from `b`.
pub fn edit(h: Hunk, b: []const u8) Edit {
    return .{ .start = h.a_byte, .end = h.a_end, .replacement = b[h.b_byte..h.b_end] };
}

/// A position in a document as a protocol names it (LSP: a line and a character in the
/// negotiated encoding). The library never knows the document type, so `range` takes the
/// owner's byte-to-position function.
pub const Position = struct { line: u32, character: u32 };
pub const Range = struct { start: Position, end: Position };

/// `e`'s span in `a` as protocol positions, through `toPosition(ctx, byte) Position`.
pub fn range(e: Edit, ctx: anytype, comptime toPosition: fn (@TypeOf(ctx), usize) Position) Range {
    return .{ .start = toPosition(ctx, e.start), .end = toPosition(ctx, e.end) };
}

/// The hunks that turn `a` into `b`, in order, valid until the next call. Equal texts give none.
pub fn diff(self: *Text, gpa: std.mem.Allocator, a: []const u8, b: []const u8, opts: Options) Error![]const Hunk {
    self.hunks.clearRetainingCapacity();
    if (a.len >= nil or b.len >= nil) return error.TooLarge;

    // Common start and end, in whole lines.
    var prefix = commonPrefix(a, b);
    while (prefix > 0 and a[prefix - 1] != '\n') prefix -= 1;
    const ra = a[prefix..];
    const rb = b[prefix..];
    if (ra.len == 0 and rb.len == 0) return self.hunks.items;
    var s = commonSuffix(ra, rb);
    // Back off to where both texts start a line.
    while (s > 0) : (s -= 1) {
        const p = ra.len - s;
        const q = rb.len - s;
        if ((p == 0 or ra[p - 1] == '\n') and (q == 0 or rb[q - 1] == '\n')) break;
    }
    const ma = ra[0 .. ra.len - s];
    const mb = rb[0 .. rb.len - s];
    const first_line: u32 = @intCast(std.mem.countScalar(u8, a[0..prefix], '\n'));

    // Lines of the middle, interned to ids.
    const na_max = std.mem.countScalar(u8, ma, '\n') + 1;
    const nb_max = std.mem.countScalar(u8, mb, '\n') + 1;
    var size: usize = 16;
    while (size < 2 * (na_max + nb_max)) size <<= 1;
    try self.table.resize(gpa, size);
    @memset(self.table.items, 0);
    self.reps.clearRetainingCapacity();
    self.hashes.clearRetainingCapacity();
    try self.tokenize(gpa, ma, prefix, &self.a_offs, &self.a_ids);
    try self.tokenize(gpa, mb, prefix, &self.b_offs, &self.b_ids);
    const na: u32 = @intCast(self.a_ids.items.len);
    const nb: u32 = @intCast(self.b_ids.items.len);
    const unique: u32 = @intCast(self.reps.items.len);

    try self.a_chg.resize(gpa, na);
    try self.b_chg.resize(gpa, nb);
    @memset(self.a_chg.items, 0);
    @memset(self.b_chg.items, 0);
    try self.head.resize(gpa, unique);
    try self.cnt.resize(gpa, unique);
    @memset(self.head.items, nil);
    @memset(self.cnt.items, 0);
    try self.next.resize(gpa, na);

    try self.histogram(gpa, na, nb, opts);
    try self.shift(gpa, na, nb);

    // The hunks, in absolute lines and bytes.
    var i: u32 = 0;
    var j: u32 = 0;
    while (i < na or j < nb) {
        if (i < na and j < nb and self.a_chg.items[i] == 0 and self.b_chg.items[j] == 0) {
            i += 1;
            j += 1;
            continue;
        }
        const si = i;
        const sj = j;
        while (i < na and self.a_chg.items[i] != 0) i += 1;
        while (j < nb and self.b_chg.items[j] != 0) j += 1;
        std.debug.assert(i > si or j > sj);
        try self.hunks.append(gpa, .{
            .a_start = first_line + si,
            .a_len = i - si,
            .b_start = first_line + sj,
            .b_len = j - sj,
            .a_byte = self.a_offs.items[si],
            .a_end = self.a_offs.items[i],
            .b_byte = self.b_offs.items[sj],
            .b_end = self.b_offs.items[j],
        });
    }
    return self.hunks.items;
}

/// Split `text` (which starts at byte `base` of its document) into lines, recording where each
/// starts (and, last, where the text ends) and its id.
fn tokenize(self: *Text, gpa: std.mem.Allocator, text: []const u8, base: usize, offs: *std.ArrayList(usize), ids: *std.ArrayList(u32)) Error!void {
    offs.clearRetainingCapacity();
    ids.clearRetainingCapacity();
    const mask = self.table.items.len - 1;
    var at: usize = 0;
    while (at < text.len) {
        const end = if (std.mem.indexOfScalarPos(u8, text, at, '\n')) |nl| nl + 1 else text.len;
        const line = text[at..end];
        const h = std.hash.Wyhash.hash(0, line);
        var slot: usize = @intCast(h & mask);
        const id: u32 = while (true) : (slot = (slot + 1) & mask) {
            const e = self.table.items[slot];
            if (e == 0) {
                const new: u32 = @intCast(self.reps.items.len);
                try self.reps.append(gpa, line);
                try self.hashes.append(gpa, h);
                self.table.items[slot] = new + 1;
                break new;
            }
            if (self.hashes.items[e - 1] == h and std.mem.eql(u8, self.reps.items[e - 1], line)) break e - 1;
        };
        try offs.append(gpa, base + at);
        try ids.append(gpa, id);
        at = end;
    }
    try offs.append(gpa, base + text.len);
}

const lanes = 32;

/// How many leading bytes agree.
fn commonPrefix(a: []const u8, b: []const u8) usize {
    const n = @min(a.len, b.len);
    var i: usize = 0;
    while (i + lanes <= n) : (i += lanes) {
        const x: @Vector(lanes, u8) = a[i..][0..lanes].*;
        const y: @Vector(lanes, u8) = b[i..][0..lanes].*;
        if (!@reduce(.And, x == y)) break;
    }
    while (i < n and a[i] == b[i]) i += 1;
    return i;
}

/// How many trailing bytes agree.
fn commonSuffix(a: []const u8, b: []const u8) usize {
    const n = @min(a.len, b.len);
    var i: usize = 0;
    while (i + lanes <= n) : (i += lanes) {
        const x: @Vector(lanes, u8) = a[a.len - i - lanes ..][0..lanes].*;
        const y: @Vector(lanes, u8) = b[b.len - i - lanes ..][0..lanes].*;
        if (!@reduce(.And, x == y)) break;
    }
    while (i < n and a[a.len - 1 - i] == b[b.len - 1 - i]) i += 1;
    return i;
}

/// Mark the changed lines of the whole of `a_ids` against `b_ids`. Ranges wait on an explicit
/// stack: a long text splits into thousands of them.
fn histogram(self: *Text, gpa: std.mem.Allocator, na: u32, nb: u32, opts: Options) Error!void {
    self.stack.clearRetainingCapacity();
    try self.stack.append(gpa, .{ 0, na, 0, nb });
    const A = self.a_ids.items;
    const B = self.b_ids.items;
    while (self.stack.pop()) |r| {
        var a_lo, var a_hi, var b_lo, var b_hi = r;
        while (a_lo < a_hi and b_lo < b_hi and A[a_lo] == B[b_lo]) {
            a_lo += 1;
            b_lo += 1;
        }
        while (a_lo < a_hi and b_lo < b_hi and A[a_hi - 1] == B[b_hi - 1]) {
            a_hi -= 1;
            b_hi -= 1;
        }
        if (a_lo == a_hi or b_lo == b_hi) {
            @memset(self.a_chg.items[a_lo..a_hi], 1);
            @memset(self.b_chg.items[b_lo..b_hi], 1);
            continue;
        }

        // Where each id sits in A's range, ascending, and how often.
        var i = a_hi;
        while (i > a_lo) {
            i -= 1;
            const id = A[i];
            self.next.items[i] = self.head.items[id];
            self.head.items[id] = i;
            self.cnt.items[id] += 1;
        }
        // The best match: the longest run, or the rarest lines.
        var best: Job = .{ 0, 0, 0, 0 };
        var best_len: u32 = 0;
        var best_rare: u32 = std.math.maxInt(u32);
        var common = false;
        var j = b_lo;
        while (j < b_hi) {
            const c = self.cnt.items[B[j]];
            var skip_to = j + 1;
            if (c > 0) common = true;
            if (c > 0 and c <= opts.max_occurrences) {
                var p = self.head.items[B[j]];
                while (p != nil) : (p = self.next.items[p]) {
                    var sa = p;
                    var sb = j;
                    var ea = p + 1;
                    var eb = j + 1;
                    var rare = c;
                    while (sa > a_lo and sb > b_lo and A[sa - 1] == B[sb - 1]) {
                        sa -= 1;
                        sb -= 1;
                        rare = @min(rare, self.cnt.items[A[sa]]);
                    }
                    while (ea < a_hi and eb < b_hi and A[ea] == B[eb]) {
                        rare = @min(rare, self.cnt.items[A[ea]]);
                        ea += 1;
                        eb += 1;
                    }
                    if (ea - sa > best_len or (ea - sa == best_len and rare < best_rare)) {
                        best = .{ sa, ea, sb, eb };
                        best_len = ea - sa;
                        best_rare = rare;
                    }
                    skip_to = @max(skip_to, eb);
                }
            }
            j = skip_to;
        }
        i = a_lo;
        while (i < a_hi) : (i += 1) {
            self.head.items[A[i]] = nil;
            self.cnt.items[A[i]] = 0;
        }

        if (best_len > 0) {
            try self.stack.append(gpa, .{ best[1], a_hi, best[3], b_hi });
            try self.stack.append(gpa, .{ a_lo, best[0], b_lo, best[2] });
        } else if (!common) {
            @memset(self.a_chg.items[a_lo..a_hi], 1);
            @memset(self.b_chg.items[b_lo..b_hi], 1);
        } else {
            try self.myers(gpa, a_lo, a_hi, b_lo, b_hi, opts.max_cost);
        }
    }
}

/// Mark the changed lines of one range by Myers' O(ND) algorithm: find the middle snake from
/// both ends at once, then do each side of it. Past `max_cost` edits the range is replaced.
fn myers(self: *Text, gpa: std.mem.Allocator, a_lo0: u32, a_hi0: u32, b_lo0: u32, b_hi0: u32, max_cost: u32) Error!void {
    var a_lo = a_lo0;
    var a_hi = a_hi0;
    var b_lo = b_lo0;
    var b_hi = b_hi0;
    const A = self.a_ids.items;
    const B = self.b_ids.items;
    while (a_lo < a_hi and b_lo < b_hi and A[a_lo] == B[b_lo]) {
        a_lo += 1;
        b_lo += 1;
    }
    while (a_lo < a_hi and b_lo < b_hi and A[a_hi - 1] == B[b_hi - 1]) {
        a_hi -= 1;
        b_hi -= 1;
    }
    if (a_lo == a_hi or b_lo == b_hi) {
        @memset(self.a_chg.items[a_lo..a_hi], 1);
        @memset(self.b_chg.items[b_lo..b_hi], 1);
        return;
    }
    const a = A[a_lo..a_hi];
    const b = B[b_lo..b_hi];
    const n: i32 = @intCast(a.len);
    const m: i32 = @intCast(b.len);
    const max_d: i32 = @intCast(@min((a.len + b.len + 1) / 2, max_cost));
    const off = max_d + 1;
    try self.v.resize(gpa, @intCast(4 * off + 4));
    const v1 = self.v.items[0..@intCast(2 * off + 2)];
    const v2 = self.v.items[@intCast(2 * off + 2)..][0..@intCast(2 * off + 2)];
    @memset(self.v.items, -1);
    v1[@intCast(off + 1)] = 0;
    v2[@intCast(off + 1)] = 0;
    const delta = n - m;
    const front = @mod(delta, 2) != 0;
    var k1s: i32 = 0;
    var k1e: i32 = 0;
    var k2s: i32 = 0;
    var k2e: i32 = 0;
    var d: i32 = 0;
    var split: ?[2]u32 = null;
    search: while (d < max_d) : (d += 1) {
        var k1 = -d + k1s;
        while (k1 <= d - k1e) : (k1 += 2) {
            const ko: usize = @intCast(off + k1);
            var x1 = if (k1 == -d or (k1 != d and v1[ko - 1] < v1[ko + 1])) v1[ko + 1] else v1[ko - 1] + 1;
            var y1 = x1 - k1;
            while (x1 < n and y1 < m and a[@intCast(x1)] == b[@intCast(y1)]) {
                x1 += 1;
                y1 += 1;
            }
            v1[ko] = x1;
            if (x1 > n) {
                k1e += 2;
            } else if (y1 > m) {
                k1s += 2;
            } else if (front) {
                const k2o = off + delta - k1;
                if (k2o >= 0 and k2o < v2.len and v2[@intCast(k2o)] != -1 and x1 >= n - v2[@intCast(k2o)]) {
                    split = .{ @intCast(x1), @intCast(y1) };
                    break :search;
                }
            }
        }
        var k2 = -d + k2s;
        while (k2 <= d - k2e) : (k2 += 2) {
            const ko: usize = @intCast(off + k2);
            var x2 = if (k2 == -d or (k2 != d and v2[ko - 1] < v2[ko + 1])) v2[ko + 1] else v2[ko - 1] + 1;
            var y2 = x2 - k2;
            while (x2 < n and y2 < m and a[@intCast(n - x2 - 1)] == b[@intCast(m - y2 - 1)]) {
                x2 += 1;
                y2 += 1;
            }
            v2[ko] = x2;
            if (x2 > n) {
                k2e += 2;
            } else if (y2 > m) {
                k2s += 2;
            } else if (!front) {
                const k1o = off + delta - k2;
                if (k1o >= 0 and k1o < v1.len and v1[@intCast(k1o)] != -1) {
                    const x1 = v1[@intCast(k1o)];
                    if (x1 >= n - x2) {
                        split = .{ @intCast(x1), @intCast(off + x1 - k1o) };
                        break :search;
                    }
                }
            }
        }
    }
    const sp = split orelse {
        @memset(self.a_chg.items[a_lo..a_hi], 1);
        @memset(self.b_chg.items[b_lo..b_hi], 1);
        return;
    };
    // Neither half can be the whole range again, since the snake is strictly inside it.
    try self.myers(gpa, a_lo, a_lo + sp[0], b_lo, b_lo + sp[1], max_cost);
    try self.myers(gpa, a_lo + sp[0], a_hi, b_lo + sp[1], b_hi, max_cost);
}

/// Slide each pure insert or delete to where it reads best: a group of lines can move over an
/// unchanged line equal to its edge without changing what the diff means. Prefers ending on a
/// blank line, then before a less indented line; ties go lower.
fn shift(self: *Text, gpa: std.mem.Allocator, na: u32, nb: u32) Error!void {
    // Which groups are pure, found before any slide moves them.
    self.local.clearRetainingCapacity();
    var i: u32 = 0;
    var j: u32 = 0;
    while (i < na or j < nb) {
        if (i < na and j < nb and self.a_chg.items[i] == 0 and self.b_chg.items[j] == 0) {
            i += 1;
            j += 1;
            continue;
        }
        const si = i;
        const sj = j;
        while (i < na and self.a_chg.items[i] != 0) i += 1;
        while (j < nb and self.b_chg.items[j] != 0) j += 1;
        if ((i == si) != (j == sj)) try self.local.append(gpa, .{ si, i, sj, j });
    }
    for (self.local.items) |g| {
        if (g[0] != g[1]) self.slide(self.a_ids.items, self.a_chg.items, g[0], g[1]) else self.slide(self.b_ids.items, self.b_chg.items, g[2], g[3]);
    }
}

fn slide(self: *Text, ids: []const u32, chg: []u8, start: u32, end: u32) void {
    var s = start;
    var e = end;
    // Another slide may have merged this group into a neighbour; leave those.
    if ((s > 0 and chg[s - 1] != 0) or (e < chg.len and chg[e] != 0)) return;
    for (chg[s..e]) |c| if (c == 0) return;
    while (s > 0 and chg[s - 1] == 0 and ids[s - 1] == ids[e - 1]) {
        chg[e - 1] = 0;
        chg[s - 1] = 1;
        s -= 1;
        e -= 1;
    }
    var best_s = s;
    var best = self.score(ids, e);
    while (e < chg.len and chg[e] == 0 and ids[s] == ids[e]) {
        chg[s] = 0;
        chg[e] = 1;
        s += 1;
        e += 1;
        const sc = self.score(ids, e);
        if (sc >= best) {
            best = sc;
            best_s = s;
        }
    }
    while (s > best_s) {
        chg[e - 1] = 0;
        chg[s - 1] = 1;
        s -= 1;
        e -= 1;
    }
}

/// How well a group ending before line `e` reads.
fn score(self: *Text, ids: []const u32, e: u32) i32 {
    const last = self.reps.items[ids[e - 1]];
    var s: i32 = if (std.mem.trim(u8, last, " \t\r\n").len == 0) 1000 else 0;
    if (e < ids.len) {
        const after = self.reps.items[ids[e]];
        const indent = after.len - std.mem.trimStart(u8, after, " \t").len;
        s -= @intCast(@min(indent, 200));
    }
    return s;
}
