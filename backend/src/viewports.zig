//! OS windows besides the main one, each showing a part of the one frame: a float, a menu or a
//! dialog popped out into a window of its own (`plans/POPOUT_WINDOWS_PLAN.md`, `Viewport`). The
//! API an app draws them with, over this backend's own (`SDLBackend.viewport*`); `viewport_map`
//! is where each one's part of the frame lies.
//!
//! Every call acts on the current dvui window's backend, so it is made between `dvui.Window.begin`
//! and `end`. On Wayland, where a window cannot be placed, there are none (`available`).
const builtin = @import("builtin");
const dvui = @import("dvui");
const SDLBackend = @import("SDLBackend.zig");

/// A window's Liquid Glass this frame, as the main window's (`platform.window.WindowGlassLook`).
pub const WindowGlassLook = SDLBackend.platform.window.WindowGlassLook;

/// Always, on this backend: an app that also builds on one without OS windows (dvui's own, the
/// web) keeps a stand-in with this name false.
pub const supported = true;
pub const Viewport = SDLBackend.Viewport;
/// Physical pixels of the frame.
pub const Rect = SDLBackend.viewport_map.Rect;

/// Whether this run can open viewports: not on Wayland, where a window cannot be placed.
pub fn available() bool {
    return SDLBackend.viewportsAvailable();
}

/// A viewport over `at` (the frame as the main window shows it), its window opening over that
/// place on the desktop, hidden until a frame is presented into it. Its own part of the frame
/// is `frameOf`.
pub fn open(at: Rect, title: [:0]const u8) ?*Viewport {
    return dvui.currentWindow().backend.impl.viewportOpen(at, title);
}

/// A window to carry a view past every window of the app's, over the desktop: clear, the pointer
/// passing through it, above every window, placed and drawn as any viewport (`placeMain`,
/// `present`). Where it can be made (`carries`).
pub fn openCarry(at: Rect) ?*Viewport {
    return dvui.currentWindow().backend.impl.viewportOpenCarry(at);
}

/// Whether one of the app's windows has the keyboard: the app is the active one.
pub fn appActive() bool {
    return SDLBackend.appActive();
}

/// Whether menus can be windows of their own (`openMenu`): macOS, and Windows (Acrylic popups),
/// where viewports are.
pub const menus = builtin.os.tag == .macos or builtin.os.tag == .windows;

/// A window for a menu (`Popout`'s menus): borderless, above every window, never focused, the
/// OS's material in it — rounded by `radius` points — and the pointer over it read in the main
/// window's frame (`mainOffset`). Placed with `placeRiding`, drawn as any viewport. `ride`: the
/// window the OS moves it with — smoothly, through a drag. `dialog`: a dialog's window, the same
/// but in its window's stacking, not above every window.
pub fn openMenu(at: Rect, radius: f32, ride: Ride, dialog: bool) ?*Viewport {
    return dvui.currentWindow().backend.impl.viewportOpenMenu(at, radius, ride, dialog);
}

pub const Ride = SDLBackend.Ride;

/// `placeMain` for a window riding on another (`openMenu`'s `ride`), put somewhere new only when
/// `key` — where it lies over that window — changes.
pub fn placeRiding(vp: *Viewport, frame: Rect, key: Rect) Rect {
    return dvui.currentWindow().backend.impl.viewportPlaceRiding(vp, frame, key);
}

/// Where menu `vp` is drawn in the frame from where its window lies over the main window,
/// physical pixels: none for a menu of the main window's.
pub fn mainOffset(vp: *Viewport, offset: dvui.Point.Physical) void {
    dvui.currentWindow().backend.impl.viewportMainOffset(vp, .{ .x = offset.x, .y = offset.y });
}

/// A piece of the OS's glass in an overlay (`overlayGlass`): a rounded rect, points from the
/// overlay window's top left.
pub const GlassShape = SDLBackend.GlassShape;

/// Whether the OS has Liquid Glass to draw a view drag's glass with (`openOverlay`): macOS 26.
pub fn liquidGlass() bool {
    return SDLBackend.liquidGlassAvailable();
}

/// A window over the display the main window is on (`displayInMain`) holding the OS's glass
/// (`overlayGlass`) under the picture presented into it, the pointer passing through it. Where
/// `liquidGlass`.
pub fn openOverlay(at: Rect) ?*Viewport {
    return dvui.currentWindow().backend.impl.viewportOpenOverlay(at);
}

/// One of Liquid Glass's materials: its variant and style.
pub const GlassMaterial = struct { variant: i32, style: i32 };
/// What an overlay's glass is: two layers of the same pieces, `under` and `over`, crossfaded by
/// `over_share` — each layer's pieces alike, for the OS to run them together.
pub const GlassLook = struct {
    under: GlassMaterial,
    over: GlassMaterial,
    over_share: f32,
    /// How much of the glass there is.
    glass: f32 = 1,
    /// The window's colour under the glass, each piece's shape, `fill_opacity` opaque; a lit
    /// piece's lit by `lit_amount` toward `lit_toward`.
    fill: dvui.Color = .black,
    fill_opacity: f32 = 0,
    lit_toward: dvui.Color = .white,
    lit_amount: f32 = 0,
    /// Each piece's clearing bevel (`core.glass_look.band`): a share of its shorter half, at
    /// most `bevel_cap` points, clear for `bevel_clear` of it before the frost and the colour
    /// come in.
    bevel: f32 = 0,
    bevel_cap: f32 = 0,
    bevel_clear: f32 = 0,
    /// Points of plain blur over the lens in each piece's body, in place of the `over` frost,
    /// where the OS can blur what is behind a window without its materials' tint (macOS: Core
    /// Animation's backdrop blur): 0, or none to draw it with, and the frost it is.
    blur: f32 = 0,
};

/// Overlay `vp`'s glass this frame (`openOverlay`), run together within `spacing` points, as
/// `look`.
pub fn overlayGlass(vp: *Viewport, shapes: []const GlassShape, spacing: f32, look: GlassLook) void {
    const f = look.fill;
    const t = look.lit_toward;
    dvui.currentWindow().backend.impl.viewportOverlayGlass(vp, shapes, spacing, .{
        .under_variant = look.under.variant,
        .under_style = look.under.style,
        .over_variant = look.over.variant,
        .over_style = look.over.style,
        .over_share = look.over_share,
        .glass = look.glass,
        .fill = .{ @as(f64, @floatFromInt(f.r)) / 255, @as(f64, @floatFromInt(f.g)) / 255, @as(f64, @floatFromInt(f.b)) / 255, look.fill_opacity },
        .lit_toward = .{ @as(f64, @floatFromInt(t.r)) / 255, @as(f64, @floatFromInt(t.g)) / 255, @as(f64, @floatFromInt(t.b)) / 255, look.lit_amount },
        .bevel = look.bevel,
        .bevel_cap = look.bevel_cap,
        .bevel_clear = look.bevel_clear,
        .blur = look.blur,
    });
}

/// The carried view's picture under an overlay's glass (`overlayPhoto`).
pub const OverlayPhoto = struct {
    /// The rounded rect it shows in, points from the overlay window's top left.
    rect: Rect,
    radius: f32,
    /// Where its image lies, points from `rect`'s top left: it may reach past it.
    image: Rect,
    fill: dvui.Color,
    alpha: f32 = 1,
    /// Points of plain blur on it.
    blur: f32 = 0,
};

/// Overlay `vp`'s image of the carried view's picture: premultiplied RGBA rows, `w` by `h`,
/// copied; null, none. Once a drag (`overlayPhoto` places it).
pub fn overlayPhotoImage(vp: *Viewport, rgba: ?[]const u8, w: u32, h: u32) void {
    dvui.currentWindow().backend.impl.viewportOverlayPhotoImage(vp, rgba, w, h);
}

/// Where overlay `vp` shows the carried view's picture this frame, under its glass, so the
/// glass over it bends it; null, nowhere. Applied with the glass.
pub fn overlayPhoto(vp: *Viewport, photo: ?OverlayPhoto) void {
    const p = photo orelse return dvui.currentWindow().backend.impl.viewportOverlayPhoto(vp, null);
    const f = p.fill;
    dvui.currentWindow().backend.impl.viewportOverlayPhoto(vp, .{
        .x = p.rect.x,
        .y = p.rect.y,
        .w = p.rect.w,
        .h = p.rect.h,
        .radius = p.radius,
        .image = .{ p.image.x, p.image.y, p.image.w, p.image.h },
        .fill = .{ @as(f64, @floatFromInt(f.r)) / 255, @as(f64, @floatFromInt(f.g)) / 255, @as(f64, @floatFromInt(f.b)) / 255, @as(f64, @floatFromInt(f.a)) / 255 },
        .alpha = p.alpha,
        .blur = p.blur,
    });
}

/// The display the main window is on, in its frame (physical pixels from its top left).
pub fn displayInMain() Rect {
    return dvui.currentWindow().backend.impl.viewportDisplayInMain();
}

/// A carry window's shape this frame (`openCarry`): what it carries fills it, rounded by
/// `radius` physical pixels — the OS's material and shadow in that shape — `alpha` opaque.
/// Null: hidden.
pub fn carryShape(vp: *Viewport, radius: ?f32, alpha: f32) void {
    dvui.currentWindow().backend.impl.viewportCarryShape(vp, radius, alpha);
}

/// `vp`'s window at `other`'s level and just above it — a float born of a drop, over the drag's
/// glass while that goes — until `settle` puts it back at its own. macOS.
pub fn lift(vp: *Viewport, other: *Viewport) void {
    dvui.currentWindow().backend.impl.viewportLift(vp, other);
}

pub fn settle(vp: *Viewport) void {
    dvui.currentWindow().backend.impl.viewportSettle(vp);
}

/// `vp`'s window put just above `other`'s in the stacking (a growing float's picture over the
/// glass it grows out of). macOS.
pub fn orderAbove(vp: *Viewport, other: *Viewport) void {
    dvui.currentWindow().backend.impl.viewportOrderAbove(vp, other);
}

/// A carry window's glass as the lens — the carried view, a drop of water — or as frost, as a
/// window's material is (a float's window growing out of it). Liquid Glass only.
pub fn carryLens(vp: *Viewport, lens: bool) void {
    dvui.currentWindow().backend.impl.viewportCarryLens(vp, lens);
}

/// Whether `vp`'s window lies under the main window in the OS's stacking — a float's, clicked
/// behind it — as last read (macOS; never elsewhere, where floats stay over it).
pub fn underMain(vp: *Viewport) bool {
    return dvui.currentWindow().backend.impl.viewportUnderMain(vp);
}

/// Points from `vp`'s window's left edge past the OS's own buttons in its title bar (macOS's
/// traffic lights, `os_buttons`): 0 without them.
pub fn buttonsWidth(vp: *Viewport) f32 {
    return dvui.currentWindow().backend.impl.viewportButtonsWidth(vp);
}

/// `vp`'s window's Liquid Glass this frame, as the main window's (`windowGlass`). Whether it
/// has any: its float then draws no base of its own.
pub fn windowGlass(vp: *Viewport, look: WindowGlassLook) bool {
    return dvui.currentWindow().backend.impl.viewportLiquidGlass(vp, look.native());
}

/// A float's window's corner radius, points: the OS's for a titled window (`os_frame`).
pub fn windowRadius() f32 {
    return dvui.currentWindow().backend.impl.windowCornerRadius();
}

/// A held pointer over `vp`'s window is read as over the main window beneath it while `on`: its
/// float gone to its ghost while a view is carried out of it, aimed at the places under it.
pub fn seeThrough(vp: *Viewport, on: bool) void {
    dvui.currentWindow().backend.impl.viewportSeeThrough(vp, on);
}

/// Whether `vp`'s window is maximized — zoomed, or in a fullscreen Space of its own — as the
/// main window's is asked: nothing of the desktop behind it shows.
pub fn maximized(vp: *const Viewport) bool {
    return dvui.currentWindow().backend.impl.viewportMaximized(vp);
}

/// Whether `vp`'s window covers the desktop, or will once the transition it is in ends, as the
/// main window's is asked (`coversDesktop`).
pub fn coversDesktop(vp: *const Viewport) bool {
    return dvui.currentWindow().backend.impl.viewportCovers(vp);
}

/// Whether `vp`'s window is on its way into a fullscreen Space (`enteringSpace`).
pub fn enteringSpace(vp: *const Viewport) bool {
    return dvui.currentWindow().backend.impl.viewportEnteringSpace(vp);
}

/// How far `vp`'s window is into full screen as it moves itself there or back (`spaceFullness`).
pub fn spaceFullness(vp: *const Viewport) ?f32 {
    return dvui.currentWindow().backend.impl.viewportSpaceFullness(vp);
}

/// `vp`'s window `alpha` opaque, all of it — its material too.
pub fn fade(vp: *Viewport, alpha: f32) void {
    dvui.currentWindow().backend.impl.viewportFade(vp, alpha);
}

/// Whether a carried view can be shown past every window (`openCarry`): macOS.
pub const carries = builtin.os.tag == .macos;

pub fn close(vp: *Viewport) void {
    dvui.currentWindow().backend.impl.viewportClose(vp);
}

/// The part of the frame `vp` shows, physical pixels: in its band, past the main window.
pub fn frameOf(vp: *const Viewport) Rect {
    return vp.frame;
}

/// Put `vp`'s window where it shows `frame`; the part of the frame it then shows.
pub fn place(vp: *Viewport, frame: Rect) Rect {
    return dvui.currentWindow().backend.impl.viewportPlace(vp, frame);
}

/// Hand `vp` this frame's picture of its part of the frame, drawn into `target`, or nothing.
pub fn present(vp: *Viewport, target: ?dvui.TextureTarget) void {
    dvui.currentWindow().backend.impl.viewportPresent(vp, target);
}

/// A viewport's picture this frame, drawn as dvui draws the frame: into a target, from the top left
/// of the part of the frame the viewport shows, until `end`. In it go the subwindows the viewport shows (`subwindow`) — a float and
/// what opened in it, a menu, a carried view — and whatever the app draws under them. Begun after
/// `Window.drawRetained`, so the dialogs and toasts are subwindows by then; then `present`.
pub const Picture = struct {
    /// The frame's own target, back at `end`.
    prev: dvui.RenderTarget,
    /// The picture's.
    rt: dvui.RenderTarget,

    /// `target` cleared, and drawn into from now as `part` of the frame (physical).
    pub fn begin(target: dvui.Texture.Target, part: Rect) Picture {
        target.clear();
        var rt = dvui.currentWindow().render_target;
        rt.texture = target;
        rt.offset = .{ .x = part.x, .y = part.y };
        rt.rendering = true;
        return .{ .prev = dvui.renderTarget(rt), .rt = rt };
    }

    /// Drawn into from now as the part of the frame from `at` (physical): the same drawing again,
    /// from another part of the frame — a layer drawn across several windows' parts of it.
    pub fn moveTo(self: *Picture, at: dvui.Point.Physical) void {
        self.rt.offset = at;
        _ = dvui.renderTarget(self.rt);
    }

    /// Subwindow `sw`'s drawing this frame, in the picture. `take`: out of the frame too, so dvui's
    /// replay into the main window — and any picture after this one — draws none of it.
    pub fn subwindow(_: Picture, sw: *dvui.Subwindows.Subwindow, take: bool) void {
        const cw = dvui.currentWindow();
        const cmds = sw.render_cmds;
        const after = sw.render_cmds_after;
        if (take) {
            sw.render_cmds = .empty;
            sw.render_cmds_after = .empty;
        }
        cw.renderCommands(cmds.items) catch |err| dvui.logError(@src(), err, "drawing a subwindow into a viewport", .{});
        cw.renderCommands(after.items) catch |err| dvui.logError(@src(), err, "drawing a subwindow into a viewport", .{});
    }

    /// Done: drawing goes to the frame's own target again.
    pub fn end(self: Picture) void {
        _ = dvui.renderTarget(self.prev);
    }
};

/// `slot`'s target at `w` by `h` pixels, for a `Picture`: the one in it where it is that size,
/// else a new one, the old let go after the frame. Null where none can be made.
pub fn sizedTarget(slot: *?dvui.Texture.Target, w: u32, h: u32) ?dvui.Texture.Target {
    if (slot.*) |t| if (t.width != w or t.height != h) {
        t.destroyLater();
        slot.* = null;
    };
    if (slot.* == null) slot.* = dvui.textureCreateTarget(.{ .width = w, .height = h, .interpolation = .nearest }) catch return null;
    return slot.*.?;
}

/// Where `vp`'s window is now, in the main window's part of the frame (physical pixels from
/// its top left): where its float goes when it comes back.
pub fn inMain(vp: *const Viewport) Rect {
    return dvui.currentWindow().backend.impl.viewportInMain(vp);
}

/// Put `vp`'s window where it shows `frame` of the main window's frame (past its edge, for a
/// float split out under a drag); the part of the frame it then shows.
pub fn placeMain(vp: *Viewport, frame: Rect) Rect {
    return dvui.currentWindow().backend.impl.viewportPlaceMain(vp, frame);
}

/// `frame` of the main window's frame as the same desktop place in `vp`'s band.
pub fn bandFromMain(vp: *const Viewport, frame: Rect) Rect {
    return dvui.currentWindow().backend.impl.viewportBandFromMain(vp, frame);
}

/// Whether `vp`'s window has shown a frame yet.
pub fn shown(vp: *const Viewport) bool {
    return dvui.currentWindow().backend.impl.viewportShown(vp);
}

/// Where a held pointer is read: by the window it is over, or pinned to the main window's
/// frame or a viewport's band while a window is moved or resized.
pub const Pin = SDLBackend.PointerPin;
pub fn pinPointer(pin: Pin) void {
    dvui.currentWindow().backend.impl.viewportPinPointer(pin);
}

/// Whether the OS frames a viewport's window itself — its corners, its shadow, resizing from its
/// edges (Windows: DWM; macOS: a titled window, as the main window is) — so the window is
/// exactly the float's glass. Otherwise it is the glass with a clear
/// margin round it, which the float draws its own shadow in.
pub const os_frame = builtin.os.tag == .windows or builtin.os.tag == .macos;

/// Whether a viewport's window has the OS's own buttons to close, minimize and zoom it — macOS's
/// traffic lights, a titled window's — so its float draws no close button of its own.
pub const os_buttons = builtin.os.tag == .macos;

/// A material behind the float's glass in `vp`'s window — its rounded rect `inset` physical
/// pixels in from the window's edge, `radius` its corners — for the float's frost to read the
/// desktop through, in the app's light or dark (`dark`). False where the platform has none
/// (yet).
pub fn glass(vp: *Viewport, inset: f32, radius: f32, dark: bool) bool {
    return dvui.currentWindow().backend.impl.viewportGlass(vp, inset, radius, dark);
}


/// The OS asked to close `vp`'s window.
pub fn closeRequested(vp: *const Viewport) bool {
    return vp.close_requested;
}

/// Where a press on `vp`'s window is the OS's, from its float this frame (physical pixels of
/// the frame): `drag` its header, less `keep` (its close button), moves the window; `edge` in
/// from `glass`'s sides resizes it. Null: all of it is the app's.
/// `app_side` / `app_corner`: the float's own resize zones, the app's over its header where
/// the OS resizes from no edge (macOS).
pub const Hints = struct { drag: Rect, keep: Rect, glass: Rect, edge: f32, app_side: f32 = 0, app_corner: f32 = 0 };
pub fn hints(vp: *Viewport, h: ?Hints) void {
    dvui.currentWindow().backend.impl.viewportHints(vp, if (h) |x| .{ .drag = x.drag, .keep = x.keep, .glass = x.glass, .edge = x.edge, .app_side = x.app_side, .app_corner = x.app_corner } else null);
}

/// Where `vp`'s window shows in the frame now, when the OS has moved or resized it since the
/// last ask — where its float goes.
pub fn osPlaced(vp: *Viewport) ?Rect {
    return dvui.currentWindow().backend.impl.viewportOsPlaced(vp);
}

/// The press the OS took to move or resize `vp`'s window was let go; `resized` unless the
/// window was only moved.
pub const MoveEnd = struct { resized: bool };
pub fn osMoveEnded(vp: *Viewport) ?MoveEnd {
    const e = dvui.currentWindow().backend.impl.viewportOsMoveEnded(vp) orelse return null;
    return .{ .resized = e.resized };
}

/// Hand the drag under way to the OS, which moves `vp`'s window from then on. False where it
/// is not done: the app goes on moving it.
pub fn dragMove(vp: *Viewport) bool {
    return dvui.currentWindow().backend.impl.viewportDragMove(vp);
}

/// What `vp`'s window is called: in the taskbar, the Window menu, the window switcher.
pub fn setTitle(vp: *Viewport, text: []const u8) void {
    dvui.currentWindow().backend.impl.viewportTitle(vp, text);
}

/// The least the OS may resize `vp`'s window to, physical pixels.
pub fn minSize(vp: *Viewport, w: f32, h: f32) void {
    dvui.currentWindow().backend.impl.viewportMinSize(vp, w, h);
}
