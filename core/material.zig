//! What the app's windows are made of: an opaque window (`none`, the default), or one that shows
//! what is behind it — through clear window colour (`transparent`), blurred (`blur`), frosted
//! (`frost`), or as Liquid Glass (`liquid`) — and how much of the window's colour covers it
//! (`opacity`). One for the app: every OS window the backend shows takes it, and every glass the
//! app draws reads it (`get`), so they look as one.
//!
//! The backend says which kinds it can show; a kind asked for and not offered falls back to the
//! richest glass below it that is, else to an opaque window, never to a clear one
//! (`Material.effective`). What was asked stays as it was saved. The app publishes the result each
//! frame before anything draws (`publish`): in dvui's data, as `native_glass` is, so a plugin's
//! glass reads the same value as fizzy's.
//!
//! `Material`, `Kind`, `Kinds` and `effective` are std-only (a unit-test root in `build/app.zig`);
//! only `publish` and `get` reach dvui.
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

const key = "core.material";

/// The material this frame, as the backend can show it, set by the app before anything draws.
pub fn publish(m: Material) void {
    const dvui = @import("dvui");
    dvui.dataSet(null, dvui.Id.update(.zero, key), "_material", m);
}

/// The material every glass draws in this frame (`publish`): `none` until the app says.
pub fn get() Material {
    const dvui = @import("dvui");
    return dvui.dataGet(null, dvui.Id.update(.zero, key), "_material", Material) orelse .{};
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
