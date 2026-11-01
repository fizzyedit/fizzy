//! A sheet pulled from the top edge by a page's scroll: the header's brief. One State per app.
const std = @import("std");
const ScrollArea = @import("ScrollArea.zig");

pub const State = struct {
    /// Points open, 0 (shut) .. range. The app keeps it once, not per page.
    extent: f32 = 0,
    /// The open height, measured by the caller each frame (the brief's height).
    range: f32 = 0,
    /// The range the extent was last checked against: a range change keeps an open sheet open.
    seen_range: f32 = 0,
};
/// Arrival speed (pt/s) above which a flick passes the shut stop into the page (T5b, T-snap's `detent`).
pub const pass_speed: f32 = 400;

/// The lead to give the visible page's ScrollArea: `.{ .lead = TopSheet.lead(&sheet) }`.
pub fn lead(state: *State) ScrollArea.Lead {
    return .{ .ctx = state, .extent = extent, .range = range, .take = take };
}

/// 0 shut .. 1 open; the header draws from this alone.
pub fn openness(state: *const State) f32 {
    return if (state.range > 0) std.math.clamp(state.extent / state.range, 0, 1) else 0;
}

fn sync(ctx: *anyopaque) *State {
    const state: *State = @ptrCast(@alignCast(ctx));
    if (state.range != state.seen_range) {
        state.extent = if (state.seen_range > 0 and state.extent >= state.seen_range)
            state.range
        else
            std.math.clamp(state.extent, 0, state.range);
        state.seen_range = state.range;
    }
    return state;
}

fn extent(ctx: *anyopaque) f32 {
    return sync(ctx).extent;
}

fn range(ctx: *anyopaque) f32 {
    return sync(ctx).range;
}

fn take(ctx: *anyopaque, by: f32) f32 {
    const state = sync(ctx);
    const before = state.extent;
    state.extent = std.math.clamp(before - by, 0, state.range);
    return @abs(state.extent - before);
}
