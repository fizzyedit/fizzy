//! Distance-based axis choice for one trackpad gesture, shared by both wheel parts.
const AxisLock = @This();

state: enum { deciding, horizontal, vertical, free } = .deciding,
sum: [2]f32 = .{ 0, 0 },
held: [2]f32 = .{ 0, 0 },
cross: f32 = 0,
along: f32 = 0,
seen: usize = 0,
last_ns: ?i128 = null,

// Match ScrollArea's wheel rest interval; a pause marks lifted fingers.
pub const gap_ns = 120 * 1_000_000;
pub const decide_pt: f32 = 4;
// A direction within thirty degrees chooses its dominant axis.
pub const lock_ratio: f32 = 1.73;
// One and a half times the touch hold slop permits a deliberate direction change.
pub const breakout_pt: f32 = 21;
pub const Axis = enum { horizontal, vertical };

/// Return the signed travel allowed through for this part of a trackpad sample.
pub fn filter(self: *AxisLock, axis: Axis, by: f32, now_ns: i128) f32 {
    if (self.last_ns) |last| {
        if (now_ns - last > gap_ns) self.* = .{};
    }
    self.last_ns = now_ns;
    const i = @backingInt(axis);
    if (self.state == .deciding) {
        self.sum[i] += @abs(by);
        self.held[i] += by;
        self.seen += 1;
        // Backends send a sample's x part before its y part.
        if (self.seen < 2 or self.sum[0] + self.sum[1] < decide_pt) return 0;
        self.state = if (self.sum[0] >= lock_ratio * self.sum[1]) .horizontal else if (self.sum[1] >= lock_ratio * self.sum[0]) .vertical else .free;
        if (self.state == .free or (self.state == .horizontal and axis == .horizontal) or (self.state == .vertical and axis == .vertical)) {
            const out = self.held[i];
            self.held[i] = 0;
            return out;
        }
        return 0;
    }
    if (self.state == .free or (self.state == .horizontal and axis == .horizontal) or (self.state == .vertical and axis == .vertical)) {
        const out = by + self.held[i];
        self.held[i] = 0;
        self.along += @abs(by);
        // Forward progress keeps steady perpendicular jitter from accumulating forever.
        if (self.along > breakout_pt) {
            self.along = 0;
            self.cross = 0;
        }
        return out;
    }
    self.cross += @abs(by);
    if (self.cross > breakout_pt) {
        self.state = .free;
        return by;
    }
    return 0;
}
