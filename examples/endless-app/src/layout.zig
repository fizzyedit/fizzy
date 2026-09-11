//! The endless-handles shape, owned by this app — not a shipped fizzy preset.
//!
//! A real consumer copies a shape into its own source (or writes one). This file is that copy:
//! fizzy compiles it in through `-Dapp-layout=` and calls `layout` instead of a shipped preset.
//!
//! Center accepts the IDE main keywords so the workspace draws there with nothing assigned.
//! Each window edge already has a collapsed region; dragging its split opens it in realtime
//! and a new collapsed region appears on the outer side. There is no count cap — the split
//! constraint stops a drag when Center would be left smaller than `min_center`.
const std = @import("std");
const dvui = @import("dvui");
const core = @import("core");
const sdk = @import("fizzy_sdk");

const Layout = @import("app").layout.Layout;
const State = @import("app").layout.State;
const Split = core.widgets.Split;

/// A user-created place. Nothing a plugin ships matches this word, so a new edge region stays
/// empty until the picker fills it.
pub const slot: []const []const u8 = &.{"slot"};

pub const Side = enum { left, right, top, bottom };

/// Below this, an outer region is still the collapsed sentinel, not an opened tray.
pub const commit_threshold: f32 = 48;
/// What Center keeps. The split constraint refuses a drag that would leave less.
pub const min_center: f32 = 80;

/// Headless tests read the left handle's centre after a frame.
pub var t_left_x: f32 = 0;
pub var t_scale: f32 = 1;
pub var t_left_room: f32 = 0;

pub fn layout(f: *Layout) !dvui.App.Result {
    t_left_x = 0;
    t_scale = 1;
    t_left_room = 0;

    var body = try f.region(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
    defer body.deinit();

    const lefts = namesForSide(f, .left);
    var li = lefts.len;
    while (li > 0) {
        li -= 1;
        try edgeRegion(f, lefts[li], .horizontal, extra(.left, li));
        f.split(@src(), .{ .id_extra = extra(.left, li) });
    }

    {
        var mid = try f.region(@src(), .{ .dir = .vertical }, .{
            .expand = .both,
            .min_size_content = .{ .w = min_center, .h = min_center },
        });
        defer mid.deinit();

        const tops = namesForSide(f, .top);
        var ti = tops.len;
        while (ti > 0) {
            ti -= 1;
            try edgeRegion(f, tops[ti], .vertical, extra(.top, ti));
            f.split(@src(), .{ .id_extra = extra(.top, ti) });
        }

        {
            var center = try f.region(@src(), .{
                .name = "Center",
                .keywords = sdk.keywords.ide.main,
                .by_name = true,
            }, .{
                .expand = .both,
                .min_size_content = .{ .w = min_center, .h = min_center },
            });
            defer center.deinit();
        }

        const bottoms = namesForSide(f, .bottom);
        for (bottoms, 0..) |name, bi| {
            f.split(@src(), .{ .id_extra = extra(.bottom, bi) });
            try edgeRegion(f, name, .vertical, extra(.bottom, bi));
        }
    }

    const rights = namesForSide(f, .right);
    for (rights, 0..) |name, ri| {
        f.split(@src(), .{ .id_extra = extra(.right, ri) });
        try edgeRegion(f, name, .horizontal, extra(.right, ri));
    }

    if (body.box) |box| {
        const rs = box.data().contentRectScale();
        t_left_x = rs.r.x + Split.handle_size * rs.s / 2;
        t_scale = rs.s;
        t_left_room = roomOn(f.state, box.data().contentRect().w, .left);
    }

    return .ok;
}

fn extra(side: Side, index: usize) usize {
    return (@as(usize, @intFromEnum(side)) << 16) | (index & 0xffff);
}

pub fn edgePrefix(side: Side) []const u8 {
    return switch (side) {
        .left => "edge-left-",
        .right => "edge-right-",
        .top => "edge-top-",
        .bottom => "edge-bottom-",
    };
}

pub fn parseEdgeName(name: []const u8) ?struct { side: Side, index: u32 } {
    inline for (std.meta.tags(Side)) |side| {
        const p = edgePrefix(side);
        if (std.mem.startsWith(u8, name, p)) {
            const n = std.fmt.parseInt(u32, name[p.len..], 10) catch return null;
            if (n == 0) return null;
            return .{ .side = side, .index = n };
        }
    }
    return null;
}

/// The next unused index on `side`. Indices are never reused: an assignment to `edge-left-1`
/// must still find that region after `edge-left-2` is created.
pub fn nextIndex(state: *State, side: Side) u32 {
    var max: u32 = 0;
    var it = state.extents.keyIterator();
    while (it.next()) |k| {
        if (parseEdgeName(k.*)) |e| {
            if (e.side == side and e.index > max) max = e.index;
        }
    }
    return max + 1;
}

/// Append a region on `side` at `extent` and persist it. Returns the interned name.
pub fn promote(state: *State, gpa: std.mem.Allocator, side: Side, extent: f32) []const u8 {
    const n = nextIndex(state, side);
    var buf: [32]u8 = undefined;
    const raw = std.fmt.bufPrint(&buf, "{s}{d}", .{ edgePrefix(side), n }) catch return "";
    const name = state.internName(gpa, raw);
    _ = state.setExtent(gpa, name, extent);
    state.markDirty();
    return name;
}

/// How much of `container` is free for a new region on this axis, after existing edge
/// regions, their splits, and Center's floor.
pub fn roomOn(state: *State, container: f32, side: Side) f32 {
    const a: Side = switch (side) {
        .left, .right => .left,
        .top, .bottom => .top,
    };
    const b: Side = switch (side) {
        .left, .right => .right,
        .top, .bottom => .bottom,
    };
    var n: usize = 0;
    var used: f32 = 0;
    var it = state.extents.iterator();
    while (it.next()) |e| {
        const parsed = parseEdgeName(e.key_ptr.*) orelse continue;
        if (parsed.side != a and parsed.side != b) continue;
        n += 1;
        used += e.value_ptr.*;
    }
    const splits = @as(f32, @floatFromInt(n + 1)) * Split.handle_size;
    return @max(0, container - used - splits - min_center);
}

/// Names on `side`, innermost (closest to Center) first. Arena-backed, this frame only.
pub fn namesOn(state: *State, arena: std.mem.Allocator, side: Side) []const []const u8 {
    const Slot = struct { n: u32, name: []const u8 };
    var tmp: std.ArrayListUnmanaged(Slot) = .empty;
    var it = state.extents.keyIterator();
    while (it.next()) |k| {
        const e = parseEdgeName(k.*) orelse continue;
        if (e.side != side) continue;
        tmp.append(arena, .{ .n = e.index, .name = k.* }) catch return &.{};
    }
    std.mem.sort(Slot, tmp.items, {}, struct {
        fn less(_: void, a: Slot, b: Slot) bool {
            return a.n < b.n;
        }
    }.less);
    const out = arena.alloc([]const u8, tmp.items.len) catch return &.{};
    for (tmp.items, out) |s, *o| o.* = s.name;
    return out;
}

/// Persisted names on `side`, plus a collapsed sentinel on the outside when the outer-most
/// one is already open (or when the side has none yet).
fn namesForSide(f: *Layout, side: Side) []const []const u8 {
    const existing = namesOn(f.state, f.arena, side);
    if (existing.len > 0 and f.state.extent(existing[existing.len - 1], 0) <= 0) return existing;
    const n = nextIndex(f.state, side);
    var buf: [32]u8 = undefined;
    const raw = std.fmt.bufPrint(&buf, "{s}{d}", .{ edgePrefix(side), n }) catch return existing;
    const name = f.state.internName(f.gpa, raw);
    const out = f.arena.alloc([]const u8, existing.len + 1) catch return existing;
    @memcpy(out[0..existing.len], existing);
    out[existing.len] = name;
    return out;
}

fn edgeRegion(f: *Layout, name: []const u8, axis: dvui.enums.Direction, id_extra: usize) !void {
    const ext = f.state.extent(name, 0);
    var r = try f.region(@src(), .{
        .name = name,
        .keywords = slot,
        .by_name = true,
        .resize = true,
    }, .{
        .id_extra = id_extra,
        .min_size_content = switch (axis) {
            .horizontal => .{ .w = ext },
            .vertical => .{ .h = ext },
        },
        .expand = switch (axis) {
            .horizontal => .vertical,
            .vertical => .horizontal,
        },
    });
    r.deinit();
}
