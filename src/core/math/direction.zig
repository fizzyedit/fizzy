const std = @import("std");

const sqrt = 0.70710678118654752440084436210485;
const sqrt2 = 1.4142135623730950488016887242097;

pub const Direction = enum(u8) {
    none = 0,

    n = 0b0000_0001, // 1
    e = 0b0000_0100, // 4
    s = 0b0000_0011, // 3
    w = 0b0000_1100, // 12

    se = 0b0000_0111, // 5
    ne = 0b0000_0101, // 7
    nw = 0b0000_1101, // 15
    sw = 0b0000_1111, // 13

    pub fn fromRadians(radians: f32) Direction {
        // Normalize angle to [0, 2π)
        var angle = radians;
        const two_pi: f32 = 2.0 * std.math.pi;
        while (angle < 0) angle += two_pi;
        while (angle >= two_pi) angle -= two_pi;

        // 8 directions: N, NE, E, SE, S, SW, W, NW
        // Each sector is 45 degrees (π/4 radians)
        // We'll use the following mapping:
        // 0: E (0)
        // 1: NE (π/4)
        // 2: N (π/2)
        // 3: NW (3π/4)
        // 4: W (π)
        // 5: SW (5π/4)
        // 6: S (3π/2)
        // 7: SE (7π/4)
        const sector: i32 = @intFromFloat(@mod(@divTrunc(angle + (std.math.pi / 8.0), (std.math.pi / 4.0)), 8));

        return switch (sector) {
            0 => .e,
            1 => .ne,
            2 => .n,
            3 => .nw,
            4 => .w,
            5 => .sw,
            6 => .s,
            7 => .se,
            else => .none,
        };
    }

    /// Returns closest direction of size to the supplied vector.
    pub fn find(comptime size: usize, vx: f32, vy: f32) Direction {
        return switch (size) {
            4 => {
                var d: u8 = 0;

                const absx = @abs(vx);
                const absy = @abs(vy);

                if (absy < absx * sqrt2) {
                    //x
                    if (vx > 0) d = 0b0000_0100 else if (vx < 0) d = 0b0000_1100;
                } else {
                    //y
                    if (vy > 0) d = 0b0000_0001 else if (vy < 0) d = 0b0000_0011;
                }

                return @as(Direction, @enumFromInt(d));
            },

            8 => {
                var d: u8 = 0;

                const absx = @abs(vx);
                const absy = @abs(vy);

                if (absy < absx * (sqrt2 + 1.0)) {
                    // x
                    if (vx > 0) d = 0b0000_0100 else if (vx < 0) d = 0b0000_1100;
                }
                if (absy > absx * (sqrt2 - 1.0)) {
                    // y
                    if (vy > 0) d = d | 0b0000_0001 else if (vy < 0) d = d | 0b0000_0011;
                }

                return @as(Direction, @enumFromInt(d));
            },
            else => @compileError("Direction size is unsupported"),
        };
    }

    /// Writes the actual bits of the direction.
    /// Useful for converting input to directions.
    pub fn write(n: bool, s: bool, e: bool, w: bool) Direction {
        var d: u8 = 0;
        if (w) {
            d = d | 0b0000_1100;
        }
        if (e) {
            d = d | 0b0000_0100;
        }
        if (n) {
            d = d | 0b0000_0001;
        }
        if (s) {
            d = d | 0b0000_0011;
        }

        return @as(Direction, @enumFromInt(d));
    }

    /// Returns horizontal axis of the direction.
    pub fn x(self: Direction) f32 {
        return @as(f32, @floatFromInt(@as(i8, @bitCast(@intFromEnum(self))) << 4 >> 6));
    }

    /// Returns vertical axis of the direction.
    pub fn y(self: Direction) f32 {
        return @as(f32, @floatFromInt(@as(i8, @bitCast(@intFromEnum(self))) << 6 >> 6));
    }

    // /// Returns direction as a F32x4.
    // pub fn f32x4(self: Direction) zm.F32x4 {
    //     return zm.f32x4(self.x(), self.y(), 0, 0);
    // }

    // /// Returns direction as a normalized F32x4.
    // pub fn normalized(self: Direction) zm.F32x4 {
    //     return switch (self) {
    //         .none => zm.f32x4s(0),
    //         .s => zm.f32x4(0, -1, 0, 0),
    //         .se => zm.f32x4(sqrt, -sqrt, 0, 0),
    //         .e => zm.f32x4(1, 0, 0, 0),
    //         .ne => zm.f32x4(sqrt, sqrt, 0, 0),
    //         .n => zm.f32x4(0, 1, 0, 0),
    //         .nw => zm.f32x4(-sqrt, sqrt, 0, 0),
    //         .w => zm.f32x4(-1, 0, 0, 0),
    //         .sw => zm.f32x4(-1, -1, 0, 0),
    //     };
    // }

    /// Returns true if direction is flipped to face west.
    pub fn flippedHorizontally(self: Direction) bool {
        return switch (self) {
            .nw, .w, .sw => true,
            else => false,
        };
    }

    /// Returns true if direction is flipped to face north.
    pub fn flippedVertically(self: Direction) bool {
        return switch (self) {
            .nw, .n, .ne => true,
            else => false,
        };
    }

    pub fn rotateCW(self: Direction) Direction {
        return switch (self) {
            .s => .sw,
            .se => .s,
            .e => .se,
            .ne => .e,
            .n => .ne,
            .nw => .n,
            .w => .nw,
            .sw => .w,
            .none => .none,
        };
    }

    pub fn rotateCCW(self: Direction) Direction {
        return switch (self) {
            .s => .se,
            .se => .e,
            .e => .ne,
            .ne => .n,
            .n => .nw,
            .nw => .w,
            .w => .sw,
            .sw => .s,
            .none => .none,
        };
    }

    pub fn fmt(self: Direction) [:0]const u8 {
        return switch (self) {
            .s => "south",
            .se => "southeast",
            .e => "east",
            .ne => "northeast",
            .n => "north",
            .nw => "northwest",
            .w => "west",
            .sw => "southwest",
            .none => "none",
        };
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
//
// `Direction` uses a Y-up convention: positive `vy` (north) sets the
// 0b0001 bit and negative `vy` (south) sets 0b0011. Confirm that
// behavior here so we catch any future re-encoding of the bits.
//
// (Note: the previous version of this `test` block called
// `std.testing.expect` without `try`, so the assertions were silently
// discarded and several expectations did not match the actual encoding.
// They are corrected below.)

const expectEqual = std.testing.expectEqual;

test "Direction.find 8-way diagonals" {
    try expectEqual(Direction.ne, Direction.find(8, 1, 1));
    try expectEqual(Direction.nw, Direction.find(8, -1, 1));
    try expectEqual(Direction.se, Direction.find(8, 1, -1));
    try expectEqual(Direction.sw, Direction.find(8, -1, -1));
}

test "Direction.find 8-way cardinals" {
    try expectEqual(Direction.e, Direction.find(8, 1, 0));
    try expectEqual(Direction.w, Direction.find(8, -1, 0));
    try expectEqual(Direction.n, Direction.find(8, 0, 1));
    try expectEqual(Direction.s, Direction.find(8, 0, -1));
}

test "Direction.find 4-way snaps diagonals to nearest cardinal" {
    // 4-way collapses diagonals onto the dominant axis; equal magnitudes
    // fall on x because the threshold uses `absy < absx * sqrt2`.
    try expectEqual(Direction.e, Direction.find(4, 1, 1));
    try expectEqual(Direction.w, Direction.find(4, -1, -1));
    try expectEqual(Direction.n, Direction.find(4, 0, 1));
    try expectEqual(Direction.s, Direction.find(4, 0, -1));
}

test "Direction.fromRadians produces the documented 8-way mapping" {
    const pi = std.math.pi;
    try expectEqual(Direction.e, Direction.fromRadians(0));
    try expectEqual(Direction.ne, Direction.fromRadians(pi / 4.0));
    try expectEqual(Direction.n, Direction.fromRadians(pi / 2.0));
    try expectEqual(Direction.nw, Direction.fromRadians(3.0 * pi / 4.0));
    try expectEqual(Direction.w, Direction.fromRadians(pi));
    try expectEqual(Direction.sw, Direction.fromRadians(5.0 * pi / 4.0));
    try expectEqual(Direction.s, Direction.fromRadians(3.0 * pi / 2.0));
    try expectEqual(Direction.se, Direction.fromRadians(7.0 * pi / 4.0));
}

test "Direction.fromRadians wraps negative angles" {
    const pi = std.math.pi;
    // -pi normalizes to +pi (both should map to west).
    try expectEqual(Direction.fromRadians(pi), Direction.fromRadians(-pi));
    // -pi/2 normalizes to 3pi/2 (south).
    try expectEqual(Direction.s, Direction.fromRadians(-pi / 2.0));
}

test "Direction.flippedHorizontally and flippedVertically" {
    try std.testing.expect(Direction.find(8, -1, -1).flippedHorizontally());
    try std.testing.expect(!Direction.find(8, 1, 1).flippedHorizontally());
    try std.testing.expect(Direction.find(8, 1, 1).flippedVertically());
    try std.testing.expect(!Direction.find(8, 1, -1).flippedVertically());
}

test "Direction.rotateCW and rotateCCW are inverses on the 8 named directions" {
    inline for (.{ .n, .ne, .e, .se, .s, .sw, .w, .nw }) |dir| {
        const d: Direction = dir;
        try expectEqual(d, d.rotateCW().rotateCCW());
        try expectEqual(d, d.rotateCCW().rotateCW());
    }
}
