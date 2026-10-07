//! The rules a floating view follows, as values: where its window opens, what keeps it on
//! screen, what it is called, how the floats stack, when a view may float and where it goes when
//! its float closes. `Floats.zig` and `ViewDrag.zig` apply them; nothing here draws or holds
//! state. std-only, so the rules are unit-tested without a Window (`build/app.zig`) — tests in
//! the dvui-facing layout files are never collected.
const std = @import("std");

/// A rect in natural units (points), relative to the main window's top left. Its own type, not
/// dvui's, so this file stays std-only; `Floats.zig` converts at the edge.
pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,

    pub fn eql(a: Rect, b: Rect) bool {
        return a.x == b.x and a.y == b.y and a.w == b.w and a.h == b.h;
    }

    fn centerX(r: Rect) f32 {
        return r.x + r.w / 2;
    }

    fn centerY(r: Rect) f32 {
        return r.y + r.h / 2;
    }
};

/// A float opens at this share of the place it came out of — big enough to read the view in,
/// small enough that what it floated off is still there round it.
pub const share: f32 = 0.6;
/// The smallest a float opens: a view shrunk below this is not one anybody can use.
pub const open_min_w: f32 = 360;
pub const open_min_h: f32 = 240;
/// The largest share of the window a float opens at, whatever it came out of.
pub const open_max_share: f32 = 0.9;
/// How far a float keeps from the window's edge when it is placed for the user.
pub const margin: f32 = 8;
/// How far a float floated out of another float steps down and right, so the two never sit
/// exactly over one another — the step dvui's own windows take (`window_avoid`).
pub const nudge: f32 = 24;
/// The smallest the user may resize a float to: its header and a little of its view.
pub const resize_min_w: f32 = 160;
pub const resize_min_h: f32 = 96;

/// The prefix every float's place is named with. A float is a place like any other, so its
/// name is what the assignment table, the split forest and the saved layout key it by.
pub const name_prefix = "Float ";

/// Where a float opens for a view carried out of `source`, in a window of size `window`
/// (both natural units): `share` of the place it left, never smaller than the open minimum nor
/// larger than `open_max_share` of the window, centred on where the view was, and held `margin`
/// inside the window.
pub fn initialRect(source: Rect, window: Rect) Rect {
    const cap_w = @min(window.w * open_max_share, window.w - 2 * margin);
    const cap_h = @min(window.h * open_max_share, window.h - 2 * margin);
    const w = @max(0, @min(@max(source.w * share, open_min_w), cap_w));
    const h = @max(0, @min(@max(source.h * share, open_min_h), cap_h));
    return inside(.{ .x = source.centerX() - w / 2, .y = source.centerY() - h / 2, .w = w, .h = h }, window);
}

/// Where a float opens for a view carried out of `source` and let go as a drop with its picture:
/// the place itself, its size and where it was, kept inside the window and no smaller than a float
/// may be resized to — so the picture it grows with lands on the view as the float shows it (the
/// user: the size the popped out region was, aligned with its snapshot).
pub fn asTaken(source: Rect, window: Rect) Rect {
    const cap_w = @max(0, window.w - 2 * margin);
    const cap_h = @max(0, window.h - 2 * margin);
    return inside(.{
        .x = source.x,
        .y = source.y,
        .w = @min(@max(source.w, resize_min_w), cap_w),
        .h = @min(@max(source.h, resize_min_h), cap_h),
    }, window);
}

/// A float opened from the float `from`: the same size, a step down and right, kept inside.
pub fn nudged(from: Rect, window: Rect) Rect {
    return inside(.{ .x = from.x + nudge, .y = from.y + nudge, .w = from.w, .h = from.h }, window);
}

/// A saved float brought back into a window that may have changed size since: no larger than
/// the window allows, and wholly on it, so a layout saved on a big display never opens a float
/// nobody can reach on a small one.
pub fn reachable(r: Rect, window: Rect) Rect {
    const cap_w = @max(0, window.w - 2 * margin);
    const cap_h = @max(0, window.h - 2 * margin);
    return inside(.{
        .x = r.x,
        .y = r.y,
        .w = @min(@max(r.w, resize_min_w), cap_w),
        .h = @min(@max(r.h, resize_min_h), cap_h),
    }, window);
}

/// `r` moved, not resized, to lie `margin` inside `window` — or as close to its top left as it
/// can when it is too large to.
fn inside(r: Rect, window: Rect) Rect {
    var out = r;
    const max_x = window.x + window.w - margin - r.w;
    const max_y = window.y + window.h - margin - r.h;
    out.x = @max(window.x + margin, @min(r.x, max_x));
    out.y = @max(window.y + margin, @min(r.y, max_y));
    return out;
}

/// The size a user's resize may leave a float at.
pub fn resized(r: Rect) Rect {
    return .{ .x = r.x, .y = r.y, .w = @max(r.w, resize_min_w), .h = @max(r.h, resize_min_h) };
}

/// `a` toward `b` by `t` (0…1): a landing float on its way from the carried drop to its window.
pub fn lerp(a: Rect, b: Rect, t: f32) Rect {
    return .{
        .x = std.math.lerp(a.x, b.x, t),
        .y = std.math.lerp(a.y, b.y, t),
        .w = std.math.lerp(a.w, b.w, t),
        .h = std.math.lerp(a.h, b.h, t),
    };
}

/// The name for a new float: `Float {n}` for the smallest `n` from 1 that no float in `taken`
/// has. A closed float's number is free again, so floating and closing never counts up forever.
pub fn nextName(buf: []u8, taken: []const []const u8) []const u8 {
    var n: u32 = 1;
    while (true) : (n += 1) {
        const name = std.fmt.bufPrint(buf, name_prefix ++ "{d}", .{n}) catch return name_prefix ++ "1";
        for (taken) |t| {
            if (std.mem.eql(u8, t, name)) break;
        } else return name;
    }
}

/// Whether `name` is `root` or a place a split of it made (`Float 1/r1`, `Float 1/r1/b1`). Not
/// a prefix test: `Float 10` is not under `Float 1`.
pub fn isUnder(name: []const u8, root: []const u8) bool {
    if (!std.mem.startsWith(u8, name, root)) return false;
    return name.len == root.len or name[root.len] == '/';
}

/// The floats' order once dvui has had its say: `out[i]` is the index into `ids` of the float
/// `i`th from the bottom. `ids` are the floats' window ids in their current order, `stack` the
/// window stack bottom to top — a press raises a window there. A float not in the stack (it has
/// not drawn yet: it was made this frame) keeps its place among the others like it, above
/// every float that is.
pub fn stackOrder(out: []usize, ids: []const u64, stack: []const u64) void {
    std.debug.assert(out.len == ids.len);
    for (out, 0..) |*o, i| o.* = i;
    const Ctx = struct {
        ids: []const u64,
        stack: []const u64,
        fn key(ctx: @This(), i: usize) usize {
            for (ctx.stack, 0..) |s, at| if (s == ctx.ids[i]) return at;
            return ctx.stack.len + i;
        }
        fn lessThan(ctx: @This(), a: usize, b: usize) bool {
            return ctx.key(a) < ctx.key(b);
        }
    };
    std.sort.insertion(usize, out, Ctx{ .ids = ids, .stack = stack }, Ctx.lessThan);
}

/// What is true of a view carried onto the middle of its own place, for whether it floats.
pub const Carried = struct {
    /// Out of the picker (or a plugin's own drag): it has no place to float out of.
    loose: bool = false,
    /// A tab's content — an open document — whose place is the slot a plugin made for it.
    slotted: bool = false,
    /// Already the only view of a float nobody split: floating it again would only move it.
    alone_in_float: bool = false,
};

/// Whether dropping a carried view on the middle of its own place floats it. Otherwise that
/// middle does nothing, as it did before floats.
pub fn canFloat(c: Carried) bool {
    return !c.loose and !c.slotted and !c.alone_in_float;
}

/// The place a float's view goes back to when the float closes, as far as it matters.
pub const Home = struct {
    /// The shape still declares it.
    declared: bool,
    /// It holds what the user put there (an assignment), rather than what its keywords choose.
    assigned: bool,
    /// It shows several views (a sidebar, a panel) rather than one.
    shows_many: bool,
    /// It shows nothing now.
    empty: bool,
    /// Let go, the view's keywords would show it in a place of the main window's of their own
    /// accord — a view merged into the float from elsewhere may have keywords no place answers.
    keywords_place: bool,
};

/// What closing a float does with one of its views. Nothing a float holds is lost: every view
/// comes back into the main window.
pub const GoHome = enum {
    /// Added to its home's list, beside what is there.
    add,
    /// Its home's list becomes just this view.
    put,
    /// Let go: its keywords bring it back wherever they choose — its home, when that is a place
    /// its keywords fill. Writing it into such a place would freeze the place's list against
    /// every view a plugin registers from then on.
    keywords,
    /// Into another place of the main window's that shows several: its home is gone or holds
    /// something else, and its keywords would show it nowhere.
    elsewhere,
};

pub fn goHome(home: Home) GoHome {
    // A home the user arranged takes it back as it left: beside what is there, or alone where
    // nothing is.
    if (home.declared and home.assigned) {
        if (home.shows_many) return .add;
        if (home.empty) return .put;
    }
    // Brought back by its keywords: let go, so no place's list is written down for it.
    if (home.keywords_place) return .keywords;
    // Let go, it would be shown nowhere: written into its home all the same, as a drop there
    // writes it; where the home is gone or full, into another place.
    if (home.declared and home.shows_many) return .add;
    if (home.declared and home.empty) return .put;
    return .elsewhere;
}

// ── Tests ──────────────────────────────────────────────────────────────────────────────────────

const test_window: Rect = .{ .w = 1600, .h = 1000 };

test "a float opens at a share of its place, centred on it" {
    const r = initialRect(.{ .x = 400, .y = 100, .w = 1000, .h = 800 }, test_window);
    try std.testing.expectApproxEqAbs(@as(f32, 600), r.w, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 480), r.h, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 900), r.x + r.w / 2, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 500), r.y + r.h / 2, 0.01);
}

test "a float let go with its picture opens as its place was, kept on the window" {
    const r = asTaken(.{ .x = 400, .y = 100, .w = 1000, .h = 800 }, test_window);
    try std.testing.expectEqual(@as(f32, 400), r.x);
    try std.testing.expectEqual(@as(f32, 100), r.y);
    try std.testing.expectEqual(@as(f32, 1000), r.w);
    try std.testing.expectEqual(@as(f32, 800), r.h);
    // A sidebar's narrow place keeps its width, above what a float may be resized to.
    const side = asTaken(.{ .x = 0, .y = 40, .w = 240, .h = 900 }, test_window);
    try std.testing.expectEqual(@as(f32, 240), side.w);
    try std.testing.expect(side.x >= margin and side.y + side.h <= test_window.h - margin);
    // Nothing smaller than that.
    const tiny = asTaken(.{ .x = 300, .y = 300, .w = 50, .h = 40 }, test_window);
    try std.testing.expectEqual(resize_min_w, tiny.w);
    try std.testing.expectEqual(resize_min_h, tiny.h);
}

test "a float out of a small place opens at the minimum" {
    const r = initialRect(.{ .x = 0, .y = 0, .w = 200, .h = 120 }, test_window);
    try std.testing.expectEqual(open_min_w, r.w);
    try std.testing.expectEqual(open_min_h, r.h);
}

test "a float out of a place at the edge stays inside the window" {
    // A sidebar hard against the left edge: centred on it, the float would hang off the test_window.
    const r = initialRect(.{ .x = 0, .y = 40, .w = 240, .h = 900 }, test_window);
    try std.testing.expectEqual(margin, r.x);
    try std.testing.expect(r.y >= margin);
    try std.testing.expect(r.y + r.h <= test_window.h - margin);
    // And the bottom right.
    const br = initialRect(.{ .x = 1500, .y = 900, .w = 100, .h = 100 }, test_window);
    try std.testing.expectEqual(test_window.w - margin, br.x + br.w);
    try std.testing.expectEqual(test_window.h - margin, br.y + br.h);
}

test "in a tiny window a float is capped by the window, not the minimum" {
    const tiny: Rect = .{ .w = 300, .h = 200 };
    const r = initialRect(.{ .w = 300, .h = 200 }, tiny);
    try std.testing.expect(r.w <= tiny.w * open_max_share);
    try std.testing.expect(r.h <= tiny.h * open_max_share);
    try std.testing.expect(r.x >= margin and r.y >= margin);
}

test "a float out of a float steps down and right" {
    const from: Rect = .{ .x = 100, .y = 100, .w = 400, .h = 300 };
    const r = nudged(from, test_window);
    try std.testing.expectEqual(Rect{ .x = 124, .y = 124, .w = 400, .h = 300 }, r);
    // Held inside at the test_window's corner.
    const corner = nudged(.{ .x = 1190, .y = 690, .w = 400, .h = 300 }, test_window);
    try std.testing.expectEqual(test_window.w - margin, corner.x + corner.w);
    try std.testing.expectEqual(test_window.h - margin, corner.y + corner.h);
}

test "a saved float is brought back onto a smaller window" {
    const small: Rect = .{ .w = 800, .h = 600 };
    const r = reachable(.{ .x = 1200, .y = 900, .w = 1000, .h = 300 }, small);
    try std.testing.expectEqual(small.w - 2 * margin, r.w);
    try std.testing.expectEqual(@as(f32, 300), r.h);
    try std.testing.expectEqual(margin, r.x);
    try std.testing.expectEqual(small.h - margin, r.y + r.h);
    // Off the top or left comes back in.
    const up = reachable(.{ .x = -500, .y = -50, .w = 400, .h = 300 }, small);
    try std.testing.expectEqual(margin, up.x);
    try std.testing.expectEqual(margin, up.y);
    // Never below the resize minimum.
    const tiny = reachable(.{ .x = 10, .y = 10, .w = 4, .h = 4 }, small);
    try std.testing.expectEqual(resize_min_w, tiny.w);
    try std.testing.expectEqual(resize_min_h, tiny.h);
}

test "a float is named for the smallest free number, and reuses a closed one's" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("Float 1", nextName(&buf, &.{}));
    try std.testing.expectEqualStrings("Float 2", nextName(&buf, &.{"Float 1"}));
    try std.testing.expectEqualStrings("Float 1", nextName(&buf, &.{ "Float 2", "Float 3" }));
    try std.testing.expectEqualStrings("Float 3", nextName(&buf, &.{ "Float 2", "Float 1", "Main" }));
}

test "a place is under a float by its split path, not a prefix" {
    try std.testing.expect(isUnder("Float 1", "Float 1"));
    try std.testing.expect(isUnder("Float 1/r1", "Float 1"));
    try std.testing.expect(isUnder("Float 1/r1/b2", "Float 1"));
    try std.testing.expect(!isUnder("Float 10", "Float 1"));
    try std.testing.expect(!isUnder("Float 10/r1", "Float 1"));
    try std.testing.expect(!isUnder("Main", "Float 1"));
}

test "floats stack as dvui's windows do, and one not drawn yet goes on top" {
    var out: [3]usize = undefined;
    // The middle float was raised: it is last in the stack (the main test_window is 1).
    stackOrder(&out, &.{ 10, 20, 30 }, &.{ 1, 10, 30, 20 });
    try std.testing.expectEqualSlices(usize, &.{ 0, 2, 1 }, &out);
    // Float 40 was made this frame and has no test_window yet.
    var out4: [4]usize = undefined;
    stackOrder(&out4, &.{ 10, 40, 20, 30 }, &.{ 1, 30, 20, 10 });
    try std.testing.expectEqualSlices(usize, &.{ 3, 2, 0, 1 }, &out4);
    // Nothing drawn: the order stands.
    stackOrder(&out, &.{ 10, 20, 30 }, &.{1});
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, &out);
}

test "a view floats out of its own place's middle, unless it has no place or is one already" {
    try std.testing.expect(canFloat(.{}));
    try std.testing.expect(!canFloat(.{ .loose = true }));
    try std.testing.expect(!canFloat(.{ .slotted = true }));
    try std.testing.expect(!canFloat(.{ .alone_in_float = true }));
}

test "closing a float sends a view home without freezing a place its keywords fill" {
    // The sidebar, filled by keywords: let go, and the keywords bring it back.
    try std.testing.expectEqual(GoHome.keywords, goHome(.{ .declared = true, .assigned = false, .shows_many = true, .empty = false, .keywords_place = true }));
    // A panel the user arranged: added beside what is there.
    try std.testing.expectEqual(GoHome.add, goHome(.{ .declared = true, .assigned = true, .shows_many = true, .empty = false, .keywords_place = true }));
    // A slot the user arranged, emptied by the float: the view goes back in.
    try std.testing.expectEqual(GoHome.put, goHome(.{ .declared = true, .assigned = true, .shows_many = false, .empty = true, .keywords_place = true }));
    // Something else went there since: the view does not evict it.
    try std.testing.expectEqual(GoHome.keywords, goHome(.{ .declared = true, .assigned = true, .shows_many = false, .empty = false, .keywords_place = true }));
    // The place is gone (a split since closed).
    try std.testing.expectEqual(GoHome.keywords, goHome(.{ .declared = false, .assigned = true, .shows_many = true, .empty = true, .keywords_place = true }));
}

test "closing a float loses no view its keywords would show nowhere" {
    // Merged in from elsewhere, into a float out of the sidebar its keywords fill: the sidebar
    // takes it, beside what its keywords show there.
    try std.testing.expectEqual(GoHome.add, goHome(.{ .declared = true, .assigned = false, .shows_many = true, .empty = false, .keywords_place = false }));
    // A slot something else went into since, or a home gone: another place of the main window's.
    try std.testing.expectEqual(GoHome.elsewhere, goHome(.{ .declared = true, .assigned = true, .shows_many = false, .empty = false, .keywords_place = false }));
    try std.testing.expectEqual(GoHome.elsewhere, goHome(.{ .declared = false, .assigned = false, .shows_many = false, .empty = true, .keywords_place = false }));
    // An empty slot takes it back in.
    try std.testing.expectEqual(GoHome.put, goHome(.{ .declared = true, .assigned = false, .shows_many = false, .empty = true, .keywords_place = false }));
}
