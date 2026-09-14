//! Timeline for a content swap: fade the outgoing pixels, or blur them first so
//! the incoming view can settle (or a plugin can load) underneath.
//!
//! Pure — `core.anim.transition` supplies the pictures and the clock. Holding
//! `pending` freezes the outgoing side at peak blur until the caller says the
//! next view is ready; nothing here loads a plugin.
const std = @import("std");

/// `fade` drops the outgoing snapshot's alpha. `blur` frosts it first, sitting fully covering
/// through `hold` (so a settle frame, or a plugin load, can hide under it), then dissolves while
/// the incoming sharpens in. `frost` is a blur with no hold: it frosts *while* it goes and never
/// fully covers the live view — for a preview whose incoming content is already drawing
/// underneath, where a held opaque frost reads as a wall of colour rather than a defocus.
pub const Kind = enum { fade, blur, frost };

/// One sample of the overlay. `*_blur` is 0 sharp … 1 smeared; `*_alpha` is
/// the snapshot's opacity over whatever is drawing live.
pub const Sample = struct {
    out_blur: f32 = 0,
    out_alpha: f32 = 0,
    in_blur: f32 = 0,
    in_alpha: f32 = 0,
};

/// Fade is short so a tab still feels instant. Blur is long enough to hide a
/// settle frame without reading as a second exposure.
pub const fade_ns: i128 = 150 * std.time.ns_per_ms;
pub const blur_ns: i128 = 420 * std.time.ns_per_ms;

/// Outgoing is fully blurred and still covering. `pending` holds here so a
/// plugin need not load until its view is used.
pub const hold: f32 = 0.35;

pub fn durationNs(kind: Kind) i128 {
    return switch (kind) {
        .fade => fade_ns,
        .blur, .frost => blur_ns,
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
        .frost => {
            const u = if (pending) hold else std.math.clamp(t, 0, 1);
            return .{ .out_blur = smooth(u / hold), .out_alpha = 1 - smooth(u) };
        },
    }
}

fn sampleBlur(t: f32) Sample {
    // One overlay: the outgoing snapshot blurs, then dissolves over the live
    // incoming view. Stacking a second full-opacity blurred snapshot is what
    // read as glare.
    if (t <= hold) {
        const u = t / hold;
        return .{
            .out_blur = smooth(u),
            .out_alpha = 1,
            .in_blur = 0,
            .in_alpha = 0,
        };
    }
    // Past the hold both overlays go together: the outgoing frost dissolves, and the
    // incoming frost thins over the live view beneath it — the sharpening-in half.
    const u = (t - hold) / (1 - hold);
    return .{
        .out_blur = 1,
        .out_alpha = 1 - smooth(u),
        .in_blur = 1,
        .in_alpha = 1 - smooth(u),
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

test "after the hold both frosts fade: the outgoing dissolves, the incoming sharpens in" {
    const a = sample(.blur, hold + 0.01, false);
    const b = sample(.blur, 0.8, false);
    try testing.expectApproxEqAbs(@as(f32, 1), a.out_blur, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 1), b.out_blur, 1e-5);
    try testing.expect(a.out_alpha > b.out_alpha);
    try testing.expectApproxEqAbs(@as(f32, 1), a.in_blur, 1e-5);
    try testing.expect(a.in_alpha > b.in_alpha);
    try testing.expect(b.in_alpha > 0);
}

test "blur ends with the overlay gone" {
    const a = sample(.blur, 1, false);
    try testing.expectEqual(@as(f32, 0), a.out_alpha);
    try testing.expectEqual(@as(f32, 0), a.in_alpha);
}

test "outgoing blur only rises before the hold" {
    const a = sample(.blur, hold * 0.25, false);
    const b = sample(.blur, hold * 0.75, false);
    try testing.expect(a.out_blur < b.out_blur);
    try testing.expect(b.out_blur < 1);
}

// The preview's geometry ease is outCubic. Fed to `sample(.blur)` as `t` it
// crosses the hold — the only part that is a blur — almost immediately, so
// the motion people saw was the fade tail. A linear clock stays in the blur
// for the first third.
test "an eased preview clock is already fading at one fifth of the slide" {
    const eased = 1 - (1 - 0.2) * (1 - 0.2) * (1 - 0.2);
    const s = sample(.blur, eased, false);
    try testing.expect(eased > hold);
    try testing.expectApproxEqAbs(@as(f32, 1), s.out_blur, 1e-5);
    try testing.expect(s.out_alpha < 1);
}

test "a linear preview clock is still blurring at one fifth of the slide" {
    const s = sample(.blur, 0.2, false);
    try testing.expect(0.2 < hold);
    try testing.expect(s.out_blur > 0);
    try testing.expect(s.out_blur < 1);
    try testing.expectEqual(@as(f32, 1), s.out_alpha);
}

test "frost never covers the live view once it is moving" {
    const a = sample(.frost, 0.2, false);
    try testing.expect(a.out_alpha < 1);
    try testing.expect(a.out_blur > 0);
    const b = sample(.frost, hold, false);
    try testing.expectApproxEqAbs(@as(f32, 1), b.out_blur, 1e-5);
    try testing.expect(b.out_alpha < 0.8);
    const c = sample(.frost, 1, false);
    try testing.expectApproxEqAbs(@as(f32, 0), c.out_alpha, 1e-5);
}
