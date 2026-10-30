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
//! The third thing published is the glass's look: one `Look` per `Role` (`Looks`), the numbers every
//! glass the app draws is drawn with (`publishLook`), set once in `Editor.tick` before plugins'
//! `beginFrame` and read by `LiquidField`.
//!
//! Material selection is std-only (a unit-test root in `build/app.zig`). Backdrop publication
//! and its versioned blur cache need a dvui window, as the other publication functions do.
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

/// The numbers a glass is drawn with, one set per role (`glass_look.Look`)…
pub const Look = @import("glass_look").Look;
pub const Role = @import("glass_look").Role;
/// …the five sets (`Looks.fromOpacity` is fizzy's)…
pub const Looks = @import("glass_look").Looks;

/// …published for this frame: null for the earlier glass, as each field's own numbers say.
pub const publishLook = @import("glass").LiquidField.publishLook;

/// The app's picture behind its glass, in physical window coordinates.
/// The app owns both textures and keeps them alive until the next publish (and frame end).
pub const Backdrop = struct {
    sharp: @import("dvui").Texture,
    frost: @import("dvui").Texture,
    covered: @import("dvui").Rect.Physical,
};

/// Publish before drawing glass each frame; null removes the backdrop.
pub fn publishBackdrop(b: ?Backdrop) void {
    const dvui = @import("dvui");
    const id: dvui.Id = @fromBackingInt(@intCast(@import("glass_look").data_id_backing));
    if (b) |picture| dvui.dataSet(null, id, "_app_backdrop", picture) else dvui.dataRemove(null, id, "_app_backdrop");
}

pub fn backdrop() ?Backdrop {
    const dvui = @import("dvui");
    const id: dvui.Id = @fromBackingInt(@intCast(@import("glass_look").data_id_backing));
    return dvui.dataGet(null, id, "_app_backdrop", Backdrop);
}

/// Test seam for the headless backend, which cannot allocate render targets.
var blur_in_test: ?*const fn (@import("dvui").Texture, f32) ?@import("dvui").Texture = null;

const KeptFrost = struct {
    version: ?u64 = null,
    texture: ?@import("dvui").Texture = null,

    fn release(ptr: *anyopaque) void {
        const self: *KeptFrost = @ptrCast(@alignCast(ptr));
        if (self.texture) |texture| @import("dvui").textureDestroyLater(texture);
    }
};

/// Borrow a cached blur until the next version or until this window's data expires.
/// Bump version whenever the picture or radius changes. The window owns the result.
pub fn keptFrost(sharp: @import("dvui").Texture, radius_px: f32, version: u64) ?@import("dvui").Texture {
    const dvui = @import("dvui");
    const id: dvui.Id = @fromBackingInt(@intCast(@import("glass_look").data_id_backing));
    const kept = dvui.dataGetPtrDefault(null, id, "_kept_frost", KeptFrost, .{});
    dvui.dataSetDeinitFunction(null, id, "_kept_frost", &KeptFrost.release);
    if (kept.version == null or kept.version.? != version) {
        KeptFrost.release(kept);
        kept.* = .{ .version = version, .texture = if (@import("builtin").is_test and blur_in_test != null) blur_in_test.?(sharp, radius_px) else @import("glass").BlurBackdrop.blurred(sharp, radius_px) };
    }
    return kept.texture;
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

/// Window test reached by glass.zig; this file also has a std-only unit-test root.
pub fn testKeptFrost() !void {
    if (!@import("builtin").is_test) @compileError("testKeptFrost is for tests");
    const dvui = @import("dvui");
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    const Blur = struct {
        var calls: usize = 0;
        fn run(sharp: dvui.Texture, radius: f32) ?dvui.Texture {
            calls += 1;
            std.debug.assert(radius == 8);
            const pixels = dvui.currentWindow().arena().alloc(dvui.Color.PMA, sharp.width * sharp.height) catch return null;
            @memset(pixels, .{ .r = 255, .g = 255, .b = 255, .a = 255 });
            return dvui.textureCreate(pixels, .{ .width = sharp.width, .height = sharp.height }) catch null;
        }
    };
    Blur.calls = 0;
    blur_in_test = Blur.run;
    defer blur_in_test = null;
    const texture = try dvui.textureCreate(&(@as([16 * 16]dvui.Color.PMA, @splat(.{ .r = 255, .g = 255, .b = 255, .a = 255 }))), .{ .width = 16, .height = 16 });
    defer dvui.textureDestroyLater(texture);
    const first = keptFrost(texture, 8, 1);
    try std.testing.expect(first != null);
    try std.testing.expectEqual(first, keptFrost(texture, 8, 1));
    try std.testing.expectEqual(1, Blur.calls);
    const second = keptFrost(texture, 8, 2);
    try std.testing.expect(second != null);
    try std.testing.expectEqual(2, Blur.calls);
    try std.testing.expect(!std.meta.eql(first, second));
}
