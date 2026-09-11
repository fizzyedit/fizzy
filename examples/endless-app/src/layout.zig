//! The endless-handles shape, owned by this app — not a shipped fizzy preset.
//!
//! A real consumer copies a shape into its own source (or writes one). This file is that copy:
//! fizzy compiles it in through `-Dapp-layout=` and calls `layout` instead of a shipped preset.
//!
//! Starts as one empty Center and a dormant split handle on each of the four window edges.
//! Dragging a handle inward past a threshold appends a named region (`edge-left-1`, then
//! `edge-left-2`, …) to that edge; a new dormant handle stays on the outer side. There is no
//! count cap: a handle that would leave Center smaller than `min_center` does not commit.
const std = @import("std");
const dvui = @import("dvui");
const core = @import("core");

const Layout = @import("app").layout.Layout;
const State = @import("app").layout.State;
const Split = core.widgets.Split;

/// A user-created place. Nothing a plugin ships matches this word, so a new region stays
/// empty until the picker (or an assignment) fills it.
pub const slot: []const []const u8 = &.{"slot"};

pub const Side = enum { left, right, top, bottom };

/// Below this, a released drag is a miss — a click must not mint a sliver.
pub const commit_threshold: f32 = 48;
/// What Center keeps. A new edge region that would leave less than this does not exist.
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

    const lefts = namesOn(f.state, f.arena, .left);
    var li = lefts.len;
    while (li > 0) {
        li -= 1;
        try edgeRegion(f, lefts[li], .horizontal, li);
        f.split(@src(), .{ .id_extra = li });
    }

    {
        var mid = try f.region(@src(), .{ .dir = .vertical }, .{ .expand = .both });
        defer mid.deinit();

        const tops = namesOn(f.state, f.arena, .top);
        var ti = tops.len;
        while (ti > 0) {
            ti -= 1;
            try edgeRegion(f, tops[ti], .vertical, ti);
            f.split(@src(), .{ .id_extra = ti });
        }

        {
            var center = try f.region(@src(), .{
                .name = "Center",
                .keywords = slot,
                .by_name = true,
            }, .{ .expand = .both });
            defer center.deinit();
        }

        const bottoms = namesOn(f.state, f.arena, .bottom);
        for (bottoms, 0..) |name, bi| {
            f.split(@src(), .{ .id_extra = bi });
            try edgeRegion(f, name, .vertical, bi);
        }
    }

    const rights = namesOn(f.state, f.arena, .right);
    for (rights, 0..) |name, ri| {
        f.split(@src(), .{ .id_extra = ri });
        try edgeRegion(f, name, .horizontal, ri);
    }

    if (body.box) |box| {
        dormantHandle(f, box, .left);
        dormantHandle(f, box, .right);
        dormantHandle(f, box, .top);
        dormantHandle(f, box, .bottom);
    }

    return .ok;
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
/// regions, their splits, and Center's floor. Zero means the handle must not commit.
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

fn edgeRegion(f: *Layout, name: []const u8, axis: dvui.enums.Direction, id_extra: usize) !void {
    const ext = f.state.extent(name, 200);
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

/// A Split overlaid on one outer edge of `container`. Dragging it inward past
/// `commit_threshold` and releasing appends a region on that edge — unless Center
/// would be left smaller than `min_center`.
fn dormantHandle(f: *Layout, container: *dvui.BoxWidget, side: Side) void {
    const axis: dvui.enums.Direction = switch (side) {
        .left, .right => .horizontal,
        .top, .bottom => .vertical,
    };
    const content = container.data().contentRect();
    const along = switch (side) {
        .left, .right => content.w,
        .top, .bottom => content.h,
    };
    const room = roomOn(f.state, along, side);
    if (side == .left) t_left_room = room;
    if (room < commit_threshold) return;

    const hs = Split.handle_size;
    const at: dvui.Rect = switch (side) {
        .left => .{ .x = 0, .y = 0, .w = hs, .h = content.h },
        .right => .{ .x = @max(0, content.w - hs), .y = 0, .w = hs, .h = content.h },
        .top => .{ .x = 0, .y = 0, .w = content.w, .h = hs },
        .bottom => .{ .x = 0, .y = @max(0, content.h - hs), .w = content.w, .h = hs },
    };

    var divider = Split.init(@src(), axis, @intFromEnum(side), at);
    defer divider.deinit();

    const wd = divider.box.data();
    const grabbed = divider.grab(container);
    const was = dvui.dataGet(null, wd.id, "_held", bool) orelse false;
    const now = dvui.captured(wd.id);
    var preview = dvui.dataGet(null, wd.id, "_preview", f32) orelse 0;

    if (grabbed.to) |p| {
        const rs = container.data().borderRectScale();
        preview = @max(0, switch (side) {
            .left => (p - rs.r.x) / rs.s,
            .right => (rs.r.x + rs.r.w - p) / rs.s,
            .top => (p - rs.r.y) / rs.s,
            .bottom => (rs.r.y + rs.r.h - p) / rs.s,
        });
        preview = @min(preview, room);
        dvui.dataSet(null, wd.id, "_preview", preview);
        dvui.refresh(null, @src(), wd.id);
    }

    if (preview > 0) drawPreview(container, side, preview);
    divider.draw(grabbed.dist);

    if (was and !now) {
        if (preview >= commit_threshold and preview <= room) {
            _ = promote(f.state, f.gpa, side, preview);
            f.extents_changed = true;
        }
        dvui.dataSet(null, wd.id, "_preview", @as(f32, 0));
    }
    dvui.dataSet(null, wd.id, "_held", now);

    if (side == .left) {
        const srs = wd.borderRectScale();
        t_left_x = srs.r.x + srs.r.w / 2;
        t_scale = srs.s;
    }
}

fn drawPreview(container: *dvui.BoxWidget, side: Side, extent: f32) void {
    var ftb: dvui.RenderFrontToBack = undefined;
    ftb.init();
    defer ftb.deinit();

    const rs = container.data().contentRectScale();
    var r = rs.r;
    const along = extent * rs.s;
    switch (side) {
        .left => r.w = along,
        .right => {
            r.x = r.x + r.w - along;
            r.w = along;
        },
        .top => r.h = along,
        .bottom => {
            r.y = r.y + r.h - along;
            r.h = along;
        },
    }
    r.fill(.{}, .{ .color = dvui.themeGet().color(.highlight, .fill).opacity(0.18) });
}
