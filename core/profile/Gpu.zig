//! What a frame asked the GPU to make and unmake: textures, render targets, and the switches
//! between targets. Each costs little to ask for and can cost a great deal where the driver does
//! it (WebGL on Safari's ANGLE over Metal recreates a framebuffer in milliseconds), none of it
//! inside any scope the profiler times — so the profiler counts it rather than times it.
//!
//! The backend counts, where every image's textures pass (`dvui.textureCreate` and
//! `Texture.Target.create` from the host and every plugin end up in the host's backend): running
//! totals that only grow, an integer add beside each call into the GPU. The profiler reads them at
//! each frame's start (`core.profile.hostFrameBegin`) and keeps the difference as the last frame's.
//! The same struct is both: a backend's totals, wrapping, and a frame's counts (`since`).
//!
//! std-only, so it tests with `Lookback`.
const Gpu = @This();

const std = @import("std");

/// Textures made from pixels (`textureCreate`).
textures: u32 = 0,
/// Render targets made (`textureCreateTarget`).
targets: u32 = 0,
/// Textures and targets destroyed.
destroyed: u32 = 0,
/// Times drawing moved from one target (or the window) to another.
target_switches: u32 = 0,

/// The counts from totals `prev` to totals `self`: what was asked in between. Wraps, as the
/// totals do.
pub fn since(self: Gpu, prev: Gpu) Gpu {
    var out: Gpu = .{};
    inline for (@typeInfo(Gpu).@"struct".field_names, @typeInfo(Gpu).@"struct".field_types, @typeInfo(Gpu).@"struct".field_attrs) |f_name, _, _| @field(out, f_name) = @field(self, f_name) -% @field(prev, f_name);
    return out;
}

/// Any texture or target made or destroyed: what costs the driver an allocation.
pub fn allocates(self: Gpu) bool {
    return self.textures != 0 or self.targets != 0 or self.destroyed != 0;
}

/// Counts summed over many frames, for their average (`perFrame`).
pub const Sum = struct {
    textures: u64 = 0,
    targets: u64 = 0,
    destroyed: u64 = 0,
    target_switches: u64 = 0,
    frames: u32 = 0,

    pub fn add(self: *Sum, g: Gpu) void {
        inline for (@typeInfo(Gpu).@"struct".field_names, @typeInfo(Gpu).@"struct".field_types, @typeInfo(Gpu).@"struct".field_attrs) |f_name, _, _| @field(self, f_name) += @field(g, f_name);
        self.frames += 1;
    }

    /// Each count per frame; null when no frame was counted.
    pub fn perFrame(self: Sum) ?PerFrame {
        if (self.frames == 0) return null;
        const n: f64 = @floatFromInt(self.frames);
        var out: PerFrame = .{};
        inline for (@typeInfo(Gpu).@"struct".field_names, @typeInfo(Gpu).@"struct".field_types, @typeInfo(Gpu).@"struct".field_attrs) |f_name, _, _| @field(out, f_name) = @as(f64, @floatFromInt(@field(self, f_name))) / n;
        return out;
    }
};

/// Counts per frame, averaged.
pub const PerFrame = struct {
    textures: f64 = 0,
    targets: f64 = 0,
    destroyed: f64 = 0,
    target_switches: f64 = 0,
};

test "a frame's counts are the totals' difference, across a wrap" {
    const prev: Gpu = .{ .textures = std.math.maxInt(u32), .targets = 3 };
    const now: Gpu = .{ .textures = 1, .targets = 8, .target_switches = 4 };
    const d = now.since(prev);
    try std.testing.expectEqual(@as(u32, 2), d.textures);
    try std.testing.expectEqual(@as(u32, 5), d.targets);
    try std.testing.expect(d.allocates());
    try std.testing.expect(!(Gpu{ .target_switches = 9 }).allocates());

    var sum: Sum = .{};
    try std.testing.expectEqual(@as(?PerFrame, null), sum.perFrame());
    sum.add(.{ .targets = 5 });
    sum.add(.{ .targets = 4, .target_switches = 2 });
    const pf = sum.perFrame().?;
    try std.testing.expectEqual(@as(f64, 4.5), pf.targets);
    try std.testing.expectEqual(@as(f64, 1), pf.target_switches);
}
