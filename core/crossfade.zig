//! Timeline for a content swap: fade the outgoing pixels, or blur them first so
//! the incoming view can settle (or a plugin can load) underneath.
//!
//! Pure — `core.anim.transition` supplies the pictures and the clock. Holding
//! `pending` freezes the outgoing side at peak blur until the caller says the
//! next view is ready; nothing here loads a plugin.
const std = @import("std");

pub const Kind = enum { fade, blur };

/// One sample of the overlay. `*_blur` is 0 sharp … 1 smeared; `*_alpha` is
/// the snapshot's opacity over whatever is drawing live.
pub const Sample = struct {
    out_blur: f32 = 0,
    out_alpha: f32 = 0,
    in_blur: f32 = 0,
    in_alpha: f32 = 0,
};

/// Fade is short so a tab still feels instant. Blur is long enough to hide a
/// settle frame and read as a deliberate handoff rather than a flash.
pub const fade_ns: i128 = 150 * std.time.ns_per_ms;
pub const blur_ns: i128 = 560 * std.time.ns_per_ms;

/// Outgoing is fully blurred; incoming has not been shown yet. `pending` holds
/// here so a plugin need not load until its view is used.
pub const hold: f32 = 0.30;
/// Incoming is fully up under the still-opaque outgoing — both max-blurred.
pub const overlap_mid: f32 = 0.50;
/// Outgoing has dissolved; incoming is still max-blurred.
pub const handoff_end: f32 = 0.72;

pub fn durationNs(kind: Kind) i128 {
    return switch (kind) {
        .fade => fade_ns,
        .blur => blur_ns,
    };
}

/// `t` is linear 0…1 through the duration. `pending` ignores `t` and returns
/// the hold pose (outgoing covering, incoming hidden).
pub fn sample(kind: Kind, t: f32, pending: bool) Sample {
    switch (kind) {
        .fade => {
            if (pending) return .{ .out_alpha = 1, .in_alpha = 1 };
            const u = std.math.clamp(t, 0, 1);
            return .{ .out_alpha = 1 - outQuad(u), .in_alpha = 1 };
        },
        .blur => {
            const u = if (pending) hold else std.math.clamp(t, 0, 1);
            return sampleBlur(u);
        },
    }
}

fn sampleBlur(t: f32) Sample {
    // Incoming fades up *under* a still-opaque outgoing, then outgoing
    // dissolves. Crossing two partial alphas punched a hole to the live
    // content and read as a snap rather than a dissolve.
    if (t <= hold) {
        const u = t / hold;
        return .{
            .out_blur = smooth(u),
            .out_alpha = 1,
            .in_blur = 1,
            .in_alpha = 0,
        };
    }
    if (t <= overlap_mid) {
        const u = (t - hold) / (overlap_mid - hold);
        return .{
            .out_blur = 1,
            .out_alpha = 1,
            .in_blur = 1,
            .in_alpha = smooth(u),
        };
    }
    if (t <= handoff_end) {
        const u = (t - overlap_mid) / (handoff_end - overlap_mid);
        return .{
            .out_blur = 1,
            .out_alpha = 1 - smooth(u),
            .in_blur = 1,
            .in_alpha = 1,
        };
    }
    const u = (t - handoff_end) / (1 - handoff_end);
    return .{
        .out_blur = 1,
        .out_alpha = 0,
        .in_blur = 1 - smooth(u),
        .in_alpha = 1,
    };
}

fn smooth(t: f32) f32 {
    const u = std.math.clamp(t, 0, 1);
    return u * u * (3 - 2 * u);
}

fn outQuad(t: f32) f32 {
    const u = 1 - t;
    return 1 - u * u;
}

const testing = std.testing;

test "a fade is a straight alpha cross with no blur" {
    const a = sample(.fade, 0, false);
    try testing.expectEqual(@as(f32, 0), a.out_blur);
    try testing.expectEqual(@as(f32, 1), a.out_alpha);
    try testing.expectEqual(@as(f32, 1), a.in_alpha);

    const b = sample(.fade, 1, false);
    try testing.expectEqual(@as(f32, 0), b.out_alpha);
    try testing.expectEqual(@as(f32, 1), b.in_alpha);
}

test "a fade holds the outgoing snapshot while pending" {
    const held = sample(.fade, 1, true);
    try testing.expectEqual(@as(f32, 1), held.out_alpha);
}

test "blur starts sharp and covers the incoming view" {
    const a = sample(.blur, 0, false);
    try testing.expectEqual(@as(f32, 0), a.out_blur);
    try testing.expectEqual(@as(f32, 1), a.out_alpha);
    try testing.expectEqual(@as(f32, 0), a.in_alpha);
}

test "blur reaches peak and hides the incoming view at the hold" {
    const a = sample(.blur, hold, false);
    try testing.expectApproxEqAbs(@as(f32, 1), a.out_blur, 1e-5);
    try testing.expectEqual(@as(f32, 1), a.out_alpha);
    try testing.expectEqual(@as(f32, 0), a.in_alpha);
}

test "pending freezes blur at the hold no matter where t is" {
    const early = sample(.blur, 0, true);
    const late = sample(.blur, 1, true);
    try testing.expectApproxEqAbs(@as(f32, 1), early.out_blur, 1e-5);
    try testing.expectEqual(@as(f32, 1), early.out_alpha);
    try testing.expectEqual(@as(f32, 0), early.in_alpha);
    try testing.expectEqual(early.out_blur, late.out_blur);
    try testing.expectEqual(early.out_alpha, late.out_alpha);
    try testing.expectEqual(early.in_alpha, late.in_alpha);
}

test "both snapshots sit fully overlapping at mid-handoff" {
    const a = sample(.blur, overlap_mid, false);
    try testing.expectEqual(@as(f32, 1), a.out_blur);
    try testing.expectEqual(@as(f32, 1), a.in_blur);
    try testing.expectApproxEqAbs(@as(f32, 1), a.out_alpha, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 1), a.in_alpha, 1e-5);
}

test "handoff ends with only the incoming snapshot, still max-blurred" {
    const a = sample(.blur, handoff_end, false);
    try testing.expectEqual(@as(f32, 1), a.out_blur);
    try testing.expectEqual(@as(f32, 1), a.in_blur);
    try testing.expectApproxEqAbs(@as(f32, 0), a.out_alpha, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 1), a.in_alpha, 1e-5);
}

test "the overlay stays covering through the whole blur" {
    var i: u32 = 0;
    while (i <= 20) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) / 20;
        const s = sample(.blur, t, false);
        try testing.expect(s.out_alpha >= 0.999 or s.in_alpha >= 0.999);
    }
}

test "blur ends sharp on the incoming snapshot" {
    const a = sample(.blur, 1, false);
    try testing.expectEqual(@as(f32, 0), a.out_alpha);
    try testing.expectApproxEqAbs(@as(f32, 0), a.in_blur, 1e-5);
    try testing.expectEqual(@as(f32, 1), a.in_alpha);
}

test "outgoing blur only rises before the hold" {
    const a = sample(.blur, hold * 0.25, false);
    const b = sample(.blur, hold * 0.75, false);
    try testing.expect(a.out_blur < b.out_blur);
    try testing.expect(b.out_blur < 1);
}
