//! `fizzy.layout.split` — a container that divides space, carrying the three things a plain
//! `dvui.box` does not: a draggable handle, a size persisted by `@src()`, and fizzy's tuned
//! collapse/peek behavior.
//!
//! The app says which edge it takes and whether it resizes; it never says "first pane",
//! "second pane", or "split ratio". Those belong to the tier below (`fizzy.dvui.paned`).
const std = @import("std");
const dvui = @import("dvui");
const fizzy = @import("../../fizzy.zig");
const Constants = @import("../Constants.zig");

pub const Side = enum {
    left,
    right,
    top,
    bottom,

    /// One implementation, parameterized by axis — there is no separate horizontal and
    /// vertical panel and no duplicated code between them.
    pub fn direction(self: Side) dvui.enums.Direction {
        return switch (self) {
            .left, .right => .horizontal,
            .top, .bottom => .vertical,
        };
    }

    /// Is the docked content the paned's *first* child (near end of the axis)?
    pub fn isNear(self: Side) bool {
        return switch (self) {
            .left, .top => true,
            .right, .bottom => false,
        };
    }
};

pub const Options = struct {
    side: Side,
    /// Fraction of the parent the docked side takes. Null uses the remembered value.
    size: ?f32 = null,
    resize: ?enum { drag } = null,
    collapse: ?enum { peek, hide } = null,
    /// Overrides the `@src()`-derived persistence key; only needed when you want a size to
    /// survive the call site moving during a refactor.
    key: ?[]const u8 = null,
};

pub const Split = struct {
    paned: *fizzy.dvui.PanedWidget,
    side: Side,
    ratio_store: *f32,

    /// True while the docked side should draw.
    pub fn showDock(self: *Split) bool {
        return if (self.side.isNear()) self.paned.showFirst() else self.paned.showSecond();
    }

    /// True while the remaining space should draw.
    pub fn showRest(self: *Split) bool {
        return if (self.side.isNear()) self.paned.showSecond() else self.paned.showFirst();
    }

    pub fn collapsed(self: *Split) bool {
        return self.paned.collapsed();
    }

    pub fn deinit(self: *Split) void {
        if (self.paned.dragging) {
            self.ratio_store.* = self.paned.split_ratio.*;
        }
        self.paned.deinit();
    }
};

/// Ratios persisted per call site. The spike keeps these in a process-global map; Phase 3
/// moves them into `settings.zon` alongside the existing explorer/panel ratios.
var ratios: std.AutoHashMapUnmanaged(u64, f32) = .empty;

fn ratioSlot(id: dvui.Id, default: f32) *f32 {
    const key: u64 = @intFromEnum(id);
    const gop = ratios.getOrPut(fizzy.app().allocator, key) catch {
        // Out of memory for a UI ratio is not worth failing a frame over; fall back to a
        // per-frame temporary so layout still runs.
        const tmp = struct {
            var v: f32 = 0.5;
        };
        tmp.v = default;
        return &tmp.v;
    };
    if (!gop.found_existing) gop.value_ptr.* = default;
    return gop.value_ptr;
}

const handle_size: f32 = 1.0;
const handle_dist: f32 = 8.0;

pub fn split(src: std.builtin.SourceLocation, opts: Options) Split {
    const dir = opts.side.direction();
    const default_ratio = opts.size orelse 0.25;
    // The paned's ratio is always measured from the *first* child, so a far-side dock stores
    // the complement. The app never sees this.
    const stored_default = if (opts.side.isNear()) default_ratio else 1.0 - default_ratio;

    const id = dvui.parentGet().extendId(src, 0);
    const slot = ratioSlot(id, stored_default);

    const collapsed_size: f32 = switch (dir) {
        .horizontal => Constants.min_window_size[0] + 1,
        .vertical => Constants.min_window_size[1] + 1,
    };

    const p = fizzy.dvui.paned(src, .{
        .direction = dir,
        .collapsed_size = if (opts.collapse == null) 0 else collapsed_size,
        .split_ratio = slot,
        .handle_size = if (opts.resize == null) 0 else handle_size,
        .handle_dynamic = if (opts.resize == null) null else .{
            .handle_size_max = handle_size,
            .distance_max = handle_dist,
        },
        .uncollapse_ratio = slot.*,
    }, .{
        .expand = .both,
        .background = false,
    });

    return .{ .paned = p, .side = opts.side, .ratio_store = slot };
}
