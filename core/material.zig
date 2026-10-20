//! What the app's windows are made of, and the glass the app draws itself: opaque (`none`), or
//! showing what is behind — through clear colour (`transparent`), blurred (`blur`), frosted
//! (`frost`), or as Liquid Glass (`liquid`) — and how much of the window's colour covers it
//! (`opacity`).
//!
//! Two materials, each published every frame before anything draws, in dvui's data so a plugin's
//! glass reads the same values as fizzy's. The window material (`publish`, `get`) is what every OS
//! window the backend shows is made of; the backend says which kinds it can show. The in-app
//! material (`publishInApp`, `inApp`) is what the glass the app draws itself is made of — dialogs,
//! menus, floats, toasts — the window material's unless the person chose another; the app's own
//! renderer says which kinds it can draw (`inAppMissing`).
//!
//! A kind asked for and not offered falls back to the richest glass below it that is, else to an
//! opaque window, never to a clear one (`Material.effective`). What was asked stays as it was
//! saved.
//!
//! All but the four publish and read functions is std-only (a unit-test root in `build/app.zig`).
const std = @import("std");

pub const Material = struct {
    kind: Kind = .none,
    /// How much of the theme's window colour covers what is behind, 0 (clear) to 1. Ignored by
    /// `none`; `transparent` at 1 looks as `none` does.
    opacity: f32 = 1,

    /// `kind` where `offered` has it, else the richest glass below it that `offered` has, else
    /// `none`. A clear window only when asked for: in glass's place it reads as a broken window.
    pub fn effective(self: Material, offered: Kinds) Material {
        if (offered.has(self.kind)) return self;
        var k = @backingInt(self.kind);
        while (k > @backingInt(Kind.blur)) {
            k -= 1;
            if (offered.has(@fromBackingInt(k))) return .{ .kind = @fromBackingInt(k), .opacity = self.opacity };
        }
        return .{ .kind = .none, .opacity = self.opacity };
    }
};

/// From the plainest to the richest, as the settings list them: what `Material.effective` falls
/// back through.
pub const Kind = enum(u8) { none, transparent, blur, frost, liquid };

/// The kinds a backend offers. A backend offers a kind only if every surface it puts glass on can
/// show it: a backend whose OS windows can only frost offers no `liquid`, so glass drawn in the app
/// frosts too and the look stays one.
pub const Kinds = packed struct {
    none: bool = true,
    transparent: bool = false,
    blur: bool = false,
    frost: bool = false,
    liquid: bool = false,

    pub fn has(self: Kinds, kind: Kind) bool {
        return switch (kind) {
            inline else => |k| @field(self, @tagName(k)),
        };
    }
};

/// Why the app's own renderer cannot draw `kind` as in-app glass, one static line for a tooltip;
/// null when it can. Frost and blur are drawn over the app's own frame on every backend; Liquid
/// Glass needs the glass program (`glass_program`: the backend draws `programs`).
pub fn inAppMissing(kind: Kind, glass_program: bool) ?[]const u8 {
    return switch (kind) {
        .liquid => if (glass_program) null else "Not available with this renderer: needs the glass program",
        .none, .transparent, .blur, .frost => null,
    };
}

/// The kinds the app's own renderer draws as in-app glass (`inAppMissing`).
pub fn inAppKinds(glass_program: bool) Kinds {
    var kinds: Kinds = .{};
    inline for (comptime std.enums.values(Kind)) |k| @field(kinds, @tagName(k)) = inAppMissing(k, glass_program) == null;
    return kinds;
}

const key = "core.material";

/// The window material this frame, as the backend can show it, set by the app before anything
/// draws: what the OS windows are made of.
pub fn publish(m: Material) void {
    const dvui = @import("dvui");
    dvui.dataSet(null, dvui.Id.update(.zero, key), "_material", m);
}

/// The window material this frame (`publish`): `none` until the app says.
pub fn get() Material {
    const dvui = @import("dvui");
    return dvui.dataGet(null, dvui.Id.update(.zero, key), "_material", Material) orelse .{};
}

/// The in-app material this frame, set by the app before anything draws: what the glass the app
/// draws itself is made of (dialogs, menus, floats, toasts), the window material's unless the
/// person chose another.
pub fn publishInApp(m: Material) void {
    const dvui = @import("dvui");
    dvui.dataSet(null, dvui.Id.update(.zero, key), "_in_app", m);
}

/// The material every glass the app draws is made of this frame (`publishInApp`): the window
/// material's until the app says otherwise.
pub fn inApp() Material {
    const dvui = @import("dvui");
    return dvui.dataGet(null, dvui.Id.update(.zero, key), "_in_app", Material) orelse get();
}

test "effective falls back to the richest glass offered below the one asked" {
    const mac_old: Kinds = .{ .transparent = true, .blur = true, .frost = true };
    try std.testing.expectEqual(Kind.frost, (Material{ .kind = .liquid }).effective(mac_old).kind);
    try std.testing.expectEqual(Kind.blur, (Material{ .kind = .blur }).effective(mac_old).kind);
    const windows: Kinds = .{ .transparent = true, .frost = true };
    try std.testing.expectEqual(Kind.frost, (Material{ .kind = .liquid }).effective(windows).kind);
    try std.testing.expectEqual(Kind.none, (Material{ .kind = .liquid }).effective(.{}).kind);
    try std.testing.expectEqual(@as(f32, 0.4), (Material{ .kind = .liquid, .opacity = 0.4 }).effective(windows).opacity);
}

test "glass not offered falls back to opaque, never to a clear window" {
    const windows: Kinds = .{ .transparent = true, .frost = true };
    try std.testing.expectEqual(Kind.none, (Material{ .kind = .blur }).effective(windows).kind);
    const linux: Kinds = .{ .transparent = true };
    inline for (.{ Kind.blur, Kind.frost, Kind.liquid }) |k| {
        try std.testing.expectEqual(Kind.none, (Material{ .kind = k }).effective(linux).kind);
    }
    try std.testing.expectEqual(Kind.transparent, (Material{ .kind = .transparent }).effective(linux).kind);
    try std.testing.expectEqual(Kind.blur, (Material{ .kind = .liquid }).effective(.{ .transparent = true, .blur = true }).kind);
}

test "in-app glass draws every kind where the glass program is, Liquid Glass only there" {
    const with: Kinds = inAppKinds(true);
    inline for (comptime std.enums.values(Kind)) |k| try std.testing.expect(with.has(k));
    const without: Kinds = inAppKinds(false);
    try std.testing.expect(!without.has(.liquid));
    try std.testing.expect(without.has(.frost));
    try std.testing.expectEqual(Kind.frost, (Material{ .kind = .liquid }).effective(without).kind);
    try std.testing.expect(inAppMissing(.liquid, false) != null);
}
