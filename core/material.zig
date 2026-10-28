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
//! The types and the resolver are `glass_look`'s, std-only and tested there; this file publishes
//! and reads them.
const glass_look = @import("glass_look");

/// What a window or glass is made of, and the kinds there are (`glass_look`, std-only)…
pub const Material = glass_look.Material;
pub const Kind = glass_look.Kind;
pub const Kinds = glass_look.Kinds;
pub const inAppMissing = glass_look.inAppMissing;
pub const inAppKinds = glass_look.inAppKinds;

/// …and the one resolver every OS window's body and every glass's rung comes from: what the target
/// offers (`Offer`, filled by the backend), what is asked, what is drawn (`resolve`).
pub const resolve = glass_look.resolve;
pub const Offer = glass_look.Offer;
pub const Resolved = glass_look.Resolved;
pub const WindowRole = glass_look.WindowRole;
pub const Thickness = glass_look.Thickness;
pub const Body = glass_look.Body;
pub const NativeBody = glass_look.NativeBody;
pub const Natives = glass_look.Natives;
pub const Target = glass_look.Target;

/// The numbers a glass is drawn with, one set per role (`glass_look.Look`)…
pub const Look = glass_look.Look;
pub const Role = glass_look.Role;
/// …the five sets (`Looks.fromOpacity` is fizzy's)…
pub const Looks = glass_look.Looks;

/// …published for this frame: null for the earlier glass, as each field's own numbers say.
pub const publishLook = @import("glass").LiquidField.publishLook;

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
