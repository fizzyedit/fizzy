//! Which window materials a platform can draw, and why not the others: the one answer the
//! backend's `materialKinds` and an app's material setting both read, so a material is offered,
//! listed and drawn by the same rule on every platform.
//!
//! std-only, with tests (`build.zig`'s `unit_tests`); `SDLBackend` fills in what it found
//! at run time (`Platform`).
const std = @import("std");

/// The kinds of window material, from the plainest to the richest, field for field with fizzy's
/// `core.material.Kind`.
pub const Kind = enum(u8) { none, transparent, blur, frost, liquid };

/// What the running platform can do, as the backend found it.
pub const Platform = struct {
    os: std.Target.Os.Tag,
    /// The OS draws Liquid Glass: macOS 26 and later.
    liquid_glass: bool = false,
    /// The compositor blurs behind a window: Wayland with `ext-background-effect-v1` or KDE's
    /// `org_kde_kwin_blur` (`wayland_blur`).
    compositor_blur: bool = false,
};

/// Why `kind` cannot be drawn on `platform`, one line for a tooltip; null when it can. The text
/// is static.
pub fn missing(platform: Platform, kind: Kind) ?[]const u8 {
    if (kind == .none) return null;
    return switch (platform.os) {
        .macos => switch (kind) {
            .liquid => if (platform.liquid_glass) null else "Not available before macOS 26: needs Liquid Glass",
            else => null,
        },
        .windows => switch (kind) {
            .blur => "Not available on Windows: its blur is Acrylic, under Frost",
            .liquid => "Not available on Windows: needs Liquid Glass, which only macOS 26 draws",
            else => null,
        },
        .linux => switch (kind) {
            .transparent => null,
            .blur => if (platform.compositor_blur) null else "Not available on Linux yet: needs compositor blur",
            // TODO(fizzyedit/plans#27, linux-blur): frost over the compositor's blur.
            .frost => "Not available on Linux yet: needs frost over compositor blur",
            .liquid => "Not available on Linux: needs Liquid Glass, which only macOS 26 draws",
            .none => unreachable, // Answered above.
        },
        else => "Not available on this platform",
    };
}

/// The kind drawn for `asked` on `platform`: `asked` where it is offered, else the richest glass
/// below it that is, else `none`. A clear window is drawn only when asked for: it is not glass,
/// and in glass's place it reads as a broken window.
pub fn effective(platform: Platform, asked: Kind) Kind {
    if (missing(platform, asked) == null) return asked;
    var k = @backingInt(asked);
    while (k > @backingInt(Kind.blur)) {
        k -= 1;
        if (missing(platform, @fromBackingInt(k)) == null) return @fromBackingInt(k);
    }
    return .none;
}

test "a kind not offered falls back to the richest glass below it, never to a clear window" {
    try std.testing.expectEqual(Kind.frost, effective(.{ .os = .macos }, .liquid));
    try std.testing.expectEqual(Kind.frost, effective(.{ .os = .windows }, .liquid));
    try std.testing.expectEqual(Kind.none, effective(.{ .os = .windows }, .blur));
    try std.testing.expectEqual(Kind.none, effective(.{ .os = .linux }, .liquid));
    try std.testing.expectEqual(Kind.none, effective(.{ .os = .linux }, .frost));
    try std.testing.expectEqual(Kind.blur, effective(.{ .os = .linux, .compositor_blur = true }, .liquid));
    try std.testing.expectEqual(Kind.transparent, effective(.{ .os = .linux }, .transparent));
    try std.testing.expectEqual(Kind.none, effective(.{ .os = .freestanding }, .transparent));
}

test "opaque is drawn everywhere" {
    for ([_]std.Target.Os.Tag{ .macos, .windows, .linux, .freestanding }) |os| {
        try std.testing.expect(missing(.{ .os = os }, .none) == null);
    }
}

test "macOS draws every kind, Liquid Glass from macOS 26" {
    try std.testing.expect(missing(.{ .os = .macos, .liquid_glass = true }, .liquid) == null);
    try std.testing.expect(missing(.{ .os = .macos }, .liquid) != null);
    for ([_]Kind{ .transparent, .blur, .frost }) |k| try std.testing.expect(missing(.{ .os = .macos }, k) == null);
}

test "Windows draws clear and frost" {
    const p: Platform = .{ .os = .windows, .liquid_glass = true, .compositor_blur = true };
    try std.testing.expect(missing(p, .transparent) == null);
    try std.testing.expect(missing(p, .frost) == null);
    try std.testing.expect(missing(p, .blur) != null);
    try std.testing.expect(missing(p, .liquid) != null);
}

test "Linux draws clear, and blur only where the compositor blurs, each missing kind saying why" {
    try std.testing.expect(missing(.{ .os = .linux }, .transparent) == null);
    try std.testing.expect(missing(.{ .os = .linux }, .blur) != null);
    try std.testing.expect(missing(.{ .os = .linux, .compositor_blur = true }, .blur) == null);
    for ([_]Kind{ .frost, .liquid }) |k| {
        const why = missing(.{ .os = .linux, .compositor_blur = true }, k) orelse return error.TestUnexpectedResult;
        try std.testing.expect(std.mem.startsWith(u8, why, "Not available on Linux"));
    }
}
