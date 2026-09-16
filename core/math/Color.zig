/// Porter-Duff "source over" for premultiplied RGBA (`pixelsPMA` byte layout).
/// `top` is composited over `bottom`. Generic byte math, no pixel-art types.
pub fn blendPmaSrcOver(top: [4]u8, bottom: [4]u8) [4]u8 {
    const sa: u32 = @intCast(top[3]);
    const inv: u32 = 255 - sa;
    var out: [4]u8 = undefined;
    inline for (0..3) |c| {
        const v: u32 = @as(u32, @intCast(top[c])) + @as(u32, @intCast(bottom[c])) * inv / 255;
        out[c] = @intCast(@min(255, v));
    }
    const a: u32 = sa + @as(u32, @intCast(bottom[3])) * inv / 255;
    out[3] = @intCast(@min(255, a));
    return out;
}

const Color = @This();

value: [4]f32,

pub fn initFloats(r: f32, g: f32, b: f32, a: f32) Color {
    return .{
        .value = .{ r, g, b, a },
    };
}

pub fn initBytes(r: u8, g: u8, b: u8, a: u8) Color {
    return .{
        .value = .{ @as(f32, @floatFromInt(r)) / 255, @as(f32, @floatFromInt(g)) / 255, @as(f32, @floatFromInt(b)) / 255, @as(f32, @floatFromInt(a)) / 255 },
    };
}

pub fn bytes(self: Color) [4]u8 {
    return .{
        @as(u8, @intFromFloat(self.value[0] * 255.0)),
        @as(u8, @intFromFloat(self.value[1] * 255.0)),
        @as(u8, @intFromFloat(self.value[2] * 255.0)),
        @as(u8, @intFromFloat(self.value[3] * 255.0)),
    };
}

pub fn lerp(self: Color, other: Color, t: f32) Color {
    return .{ .value = .{
        self.value[0] + (other.value[0] - self.value[0]) * t,
        self.value[1] + (other.value[1] - self.value[1]) * t,
        self.value[2] + (other.value[2] - self.value[2]) * t,
        self.value[3] + (other.value[3] - self.value[3]) * t,
    } };
}
