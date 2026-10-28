//! Why a window material is missing on a platform: one line for each kind a target does not offer,
//! read from the same `Offer` the resolver reads (`glass_look.resolve`), so a material is offered,
//! listed and drawn by the same rule on every platform.
//!
//! std-only, with tests (`build.zig`'s `unit_tests`); `SDLBackend` fills the offer from what it found
//! at run time (`materialOffer`).
const std = @import("std");
const glass_look = @import("glass_look");
const Kind = glass_look.Kind;
const Offer = glass_look.Offer;

/// Why `kind` cannot be drawn with `offer`, one line for a tooltip; null when it can. The text is
/// static.
pub fn missing(offer: Offer, kind: Kind) ?[]const u8 {
    if (offer.kinds.has(kind)) return null;
    return reasons.get(offer.target).get(kind) orelse "Not available on this platform";
}

const Reasons = std.EnumMap(Kind, []const u8);

/// What each target says of a kind it lacks; a kind with none, "Not available on this platform".
const reasons: std.EnumArray(glass_look.Target, Reasons) = .initDefault(.init(.{}), .{
    .macos = .init(.{
        .liquid = "Not available before macOS 26: needs Liquid Glass",
    }),
    .windows = .init(.{
        .blur = "Not available on Windows: its blur is Acrylic, under Frost",
        .frost = "Not available before Windows 11 22H2: needs DWM's Acrylic backdrop",
        .liquid = "Not available on Windows: needs Liquid Glass, which only macOS 26 draws",
    }),
    .linux = .init(.{
        .blur = "Not available on Linux yet: needs compositor blur",
        // TODO(fizzyedit/plans#27, linux-blur): frost over the compositor's blur.
        .frost = "Not available on Linux yet: needs frost over compositor blur",
        .liquid = "Not available on Linux: needs Liquid Glass, which only macOS 26 draws",
    }),
});

// The offers the backend made before `Offer` (each OS and what it found), and what `missing` said
// of each kind on each: the tooltips must not move.
test "every tooltip is as it was for every platform" {
    const Case = struct { offer: Offer, says: [5]?[]const u8 };
    const mac_liquid = "Not available before macOS 26: needs Liquid Glass";
    const win_blur = "Not available on Windows: its blur is Acrylic, under Frost";
    const win_frost = "Not available before Windows 11 22H2: needs DWM's Acrylic backdrop";
    const win_liquid = "Not available on Windows: needs Liquid Glass, which only macOS 26 draws";
    const linux_blur = "Not available on Linux yet: needs compositor blur";
    const linux_frost = "Not available on Linux yet: needs frost over compositor blur";
    const linux_liquid = "Not available on Linux: needs Liquid Glass, which only macOS 26 draws";
    const other = "Not available on this platform";
    const every: glass_look.Natives = .init(.{ .appkit = true, .appkit_glass = true, .dwm = true, .compositor_blur = true });
    const cases = [_]Case{
        //                                                                    none  clear  blur        frost        liquid
        .{ .offer = .init(.macos, .initOne(.appkit), true, false), .says = .{ null, null, null, null, mac_liquid } },
        .{ .offer = .init(.macos, .init(.{ .appkit = true, .appkit_glass = true }), true, false), .says = .{ null, null, null, null, null } },
        .{ .offer = .init(.windows, .empty, true, false), .says = .{ null, null, win_blur, win_frost, win_liquid } },
        .{ .offer = .init(.windows, .initOne(.dwm), true, false), .says = .{ null, null, win_blur, null, win_liquid } },
        .{ .offer = .init(.windows, every, true, false), .says = .{ null, null, win_blur, null, win_liquid } },
        .{ .offer = .init(.linux, .empty, true, false), .says = .{ null, null, linux_blur, linux_frost, linux_liquid } },
        .{ .offer = .init(.linux, .initOne(.compositor_blur), true, false), .says = .{ null, null, null, linux_frost, linux_liquid } },
        .{ .offer = .init(.other, every, true, false), .says = .{ null, other, other, other, other } },
    };
    for (cases) |case| {
        for (std.enums.values(Kind), case.says) |kind, says| {
            const said = missing(case.offer, kind);
            if (says) |s| try std.testing.expectEqualStrings(s, said orelse return error.TestExpectedReason) else try std.testing.expectEqual(@as(?[]const u8, null), said);
        }
    }
}

test "a kind not offered falls back to the richest glass below it, never to a clear window" {
    const M = glass_look.Material;
    try std.testing.expectEqual(Kind.frost, (M{ .kind = .liquid }).effective(Offer.init(.macos, .initOne(.appkit), true, false).kinds).kind);
    try std.testing.expectEqual(Kind.none, (M{ .kind = .blur }).effective(Offer.init(.windows, .initOne(.dwm), true, false).kinds).kind);
    try std.testing.expectEqual(Kind.blur, (M{ .kind = .liquid }).effective(Offer.init(.linux, .initOne(.compositor_blur), true, false).kinds).kind);
    try std.testing.expectEqual(Kind.none, (M{ .kind = .transparent }).effective(Offer.init(.other, .empty, true, false).kinds).kind);
}
