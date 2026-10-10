//! Fizzy's own use of its window: the platform pieces any app gets (the backend package's `platform`
//! — dialogs, files from the OS, gestures, chrome, geometry, the window monitor, the menu bar) with
//! fizzy's policy over them — where dialogs start, where geometry is kept (`layout.zon`), how high
//! the titlebar strip is, what its menus hold and when their items are enabled. The web build has
//! the same surface in `backend_web.zig`.
const fizzy = @import("../fizzy.zig");

const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const layout_file = @import("layout_file.zig");
const sdl3 = @import("backend").c;
const singleton = @import("app").single_instance;
const Constants = @import("../editor/Constants.zig");
const KeybindSettings = @import("../editor/KeybindSettings.zig");
const menu_model = @import("../editor/menu_model.zig");
const AppInfo = @import("app").AppInfo;

/// The window and platform pieces any app on these backends gets (the backend package's `platform`):
/// dialogs, files from the OS, gestures, the window's chrome and state, Windows' title bar. What
/// follows them here is fizzy's own use of them.
const platform = @import("platform");

pub const setAllocator = platform.dialogs.setAllocator;
pub const DialogDirs = platform.dialogs.DialogDirs;
pub const DialogMode = platform.dialogs.DialogMode;
pub const setDialogDirs = platform.dialogs.setDialogDirs;
pub const DialogFileFilter = platform.dialogs.DialogFileFilter;
pub const showSaveFileDialog = platform.dialogs.showSaveFileDialog;
pub const showOpenFileDialog = platform.dialogs.showOpenFileDialog;
pub const showOpenFolderDialog = platform.dialogs.showOpenFolderDialog;
pub const pollPendingDialogResult = platform.dialogs.pollPendingDialogResult;
fn alloc() std.mem.Allocator {
    return platform.dialogs.allocator();
}

pub const installTrackpadGestureMonitor = platform.gestures.installTrackpadGestureMonitor;
pub const takeTrackpadPinchRatio = platform.gestures.takeTrackpadPinchRatio;

pub const isMaximized = platform.window.isMaximized;
pub const coversDesktop = platform.window.coversDesktop;
pub const enteringSpace = platform.window.enteringSpace;
pub const spaceFullness = platform.window.spaceFullness;
pub const isFullscreenChromeHidden = platform.window.isFullscreenChromeHidden;
pub const setWindowStyle = platform.window.setStyle;
pub const setTitlebarColor = platform.window.setBackground;
pub const raiseWindow = platform.window.raise;
pub const toggleFullscreen = platform.window.toggleFullscreen;

/// Whether fizzy draws its own title bar here (Windows, Linux): widgets in its strip register
/// as interactive so the strip's drag does not take their clicks.
pub const custom_titlebar = platform.titlebar.active;
/// Whether the OS asks fizzy's title-bar hints where a press goes (`custom_titlebar`, and macOS).
pub const titlebar_hit_tested = platform.titlebar.hit_tested;
pub const TitleBarButton = platform.titlebar.TitleBarButton;
pub const resetTitleBarHints = platform.titlebar.resetTitleBarHints;
pub const setTitleBarStrip = platform.titlebar.setTitleBarStrip;
pub fn pushTitleBarInteractiveRect(r: dvui.Rect.Physical) void {
    platform.titlebar.pushTitleBarInteractiveRect(.{ .x = r.x, .y = r.y, .w = r.w, .h = r.h });
}
pub fn setTitleBarCaptionButtonRect(button: TitleBarButton, r: dvui.Rect.Physical) void {
    platform.titlebar.setTitleBarCaptionButtonRect(button, .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h });
}
pub const getHoveredTitleBarButton = platform.titlebar.getHoveredTitleBarButton;
pub const performTitleBarButton = platform.window.performTitleBarButton;

/// Linux: before the window is made, the app draws its own decorations and a drop shadow in
/// `insets` round the frame (`platform.linux_titlebar.useClientDecorations`). A no-op elsewhere.
pub const useClientDecorations = platform.linux_titlebar.useClientDecorations;
pub const ClientDecorationInsets = platform.linux_titlebar.Insets;

/// The margin round the window's frame for its shadow, in effect now (natural units: x left,
/// y top, w right, h bottom); zero but on Linux while the window floats.
pub fn frameInsets(win: *dvui.Window) dvui.Rect {
    const in = platform.linux_titlebar.frameInsets(win.backend.impl.window);
    return .{ .x = in.left, .y = in.top, .w = in.right, .h = in.bottom };
}
/// Linux: the desktop's blur behind the window's frame this frame — inside its shadow's margin,
/// its corners rounded by `radius` points — or none (null). Whether the compositor blurs behind
/// windows at all (`platform.linux_titlebar.blurBehind`); false elsewhere.
pub fn blurBehind(win: *dvui.Window, radius: ?f32) bool {
    return platform.linux_titlebar.blurBehind(win.backend.impl.window, radius);
}
const getWin32Hwnd = platform.win32_titlebar.getWin32Hwnd;

/// Files the OS asks fizzy to open while it runs go to the single-instance queue, which opens
/// them on the next frame (`platform.open_events`).
pub fn installFileOpenEventHandling(win: *dvui.Window) void {
    platform.open_events.install(win, singleton.queuePath);
}

// AppKit geometry types for NSView frame/bounds (same layout as Foundation).
pub const SavedRegion = layout_file.SavedRegion;
pub const SavedShows = layout_file.SavedShows;
pub const saveRegions = layout_file.saveRegions;
pub const loadRegions = layout_file.loadRegions;
pub const freeRegions = layout_file.freeRegions;
pub const saveTree = layout_file.saveTree;
pub const loadTree = layout_file.loadTree;
const loadWindowFile = layout_file.loadWindowFile;
const writeWindowFile = layout_file.writeWindowFile;

/// Reveal the window after chrome + geometry are settled (it is created hidden): maximized when it
/// was left that way (Windows).
pub fn showWindow(win: *dvui.Window) void {
    platform.window.show(win, platform.geometry.restoredMaximized());
}

/// Style the window (macOS: frame == content first), put it back where it was left
/// (`platform.geometry`, kept in fizzy's `layout.zon`), and follow it through Spaces, zooms and
/// live resizes (`platform.macos_monitor`). Called from `AppInit` while the window is still hidden:
/// the frame is restored on top of the chrome, so the chrome's own resizing cannot move it.
pub fn restoreWindowState(win: *dvui.Window) void {
    platform.window.attach(win);
    if (comptime builtin.os.tag == .macos) setWindowStyle(win);
    if (win.backend.impl.init_opts_save) |opts| if (opts.pref_path) |dir| {
        layout_store_dir = dir;
        platform.geometry.setStore(.{ .load = layoutStoreLoad, .save = layoutStoreSave });
    };
    platform.geometry.restore(win);
    platform.macos_monitor.install(win);
}

/// Keep where the window is for the next launch. Call at shutdown (AppDeinit).
pub fn saveWindowGeometry(win: *dvui.Window) void {
    platform.geometry.save(win);
}

/// Called at the end of AppInit: the monitor may drive frames through window animations now.
pub const macosLaunchComplete = platform.macos_monitor.launchComplete;

/// A window's Liquid Glass this frame (`windowGlass`, `viewports.windowGlass`): what
/// `core.glass_look.window` says at the window's opacity, the window's colour, and the clearing
/// bevel `core.glass_look.band` gives its size.
pub const WindowGlassLook = struct {
    under_variant: i32,
    under_style: i32,
    over_variant: i32,
    over_style: i32,
    frost: f32,
    blur: f32,
    glass: f32,
    fill: dvui.Color,
    /// The colour's opacity in the body…
    fill_opacity: f32,
    /// …and over all of it, the bevel too.
    top_fill: f32,
    /// Points, each.
    radius: f32,
    clear: f32,
    feather: f32,

    fn native(self: WindowGlassLook) platform.window.WindowGlass {
        return .{
            .under_variant = self.under_variant,
            .under_style = self.under_style,
            .over_variant = self.over_variant,
            .over_style = self.over_style,
            .frost = self.frost,
            .blur = self.blur,
            .glass = self.glass,
            .fill = .{ @as(f64, @floatFromInt(self.fill.r)) / 255, @as(f64, @floatFromInt(self.fill.g)) / 255, @as(f64, @floatFromInt(self.fill.b)) / 255, self.fill_opacity },
            .top_fill = self.top_fill,
            .radius = self.radius,
            .clear = self.clear,
            .feather = self.feather,
        };
    }
};

/// The main window's Liquid Glass this frame, where it is a window of Liquid Glass (macOS 26):
/// whether it is — its colour is then under the glass, and the frame draws no base of its own.
pub fn windowGlass(win: *dvui.Window, look: WindowGlassLook) bool {
    if (comptime builtin.os.tag != .macos) return false;
    return platform.window.liquidGlassLook(win.backend.impl.window, look.native());
}

/// OS windows besides the main one, each showing a part of the one frame — a float popped out
/// (`plans/POPOUT_WINDOWS_PLAN.md`, the backend's `Viewport`). Fizzy's own backend only: on dvui's
/// SDL3 backend (`-Dnative-backend=sdl3`) there are none, as on the web, and floats stay in.
pub const viewports = struct {
    const Impl = @import("backend");
    pub const supported = @hasDecl(Impl, "viewportOpen");
    pub const Viewport = if (supported) Impl.Viewport else struct {};
    /// Physical pixels of the frame.
    pub const Rect = if (supported) Impl.viewport_map.Rect else struct { x: f32 = 0, y: f32 = 0, w: f32 = 0, h: f32 = 0 };

    /// Whether this run can open viewports: not on Wayland, where a window cannot be placed.
    pub fn available() bool {
        if (comptime !supported) return false;
        return Impl.viewportsAvailable();
    }

    /// A viewport over `at` (the frame as the main window shows it), its window opening over that
    /// place on the desktop, hidden until a frame is presented into it. Its own part of the frame
    /// is `frameOf`.
    pub fn open(at: Rect, title: [:0]const u8) ?*Viewport {
        if (comptime !supported) return null;
        return dvui.currentWindow().backend.impl.viewportOpen(at, title);
    }

    /// A window to carry a view past every window of the app's, over the desktop: clear, the pointer
    /// passing through it, above every window, placed and drawn as any viewport (`placeMain`,
    /// `present`). Where it can be made (`carries`).
    pub fn openCarry(at: Rect) ?*Viewport {
        if (comptime !supported) return null;
        return dvui.currentWindow().backend.impl.viewportOpenCarry(at);
    }

    /// Whether one of the app's windows has the keyboard: the app is the active one.
    pub fn appActive() bool {
        if (comptime !supported) return true;
        return Impl.appActive();
    }

    /// Whether menus can be windows of their own (`openMenu`): macOS, and Windows (Acrylic popups),
    /// where viewports are.
    pub const menus = supported and (builtin.os.tag == .macos or builtin.os.tag == .windows);

    /// A window for a menu (`Popout`'s menus): borderless, above every window, never focused, the
    /// OS's material in it — rounded by `radius` points — and the pointer over it read in the main
    /// window's frame (`mainOffset`). Placed with `placeRiding`, drawn as any viewport. `ride`: the
    /// window the OS moves it with — smoothly, through a drag. `dialog`: a dialog's window, the same
    /// but in its window's stacking, not above every window.
    pub fn openMenu(at: Rect, radius: f32, ride: Ride, dialog: bool) ?*Viewport {
        if (comptime !supported) return null;
        return dvui.currentWindow().backend.impl.viewportOpenMenu(at, radius, ride, dialog);
    }

    pub const Ride = if (supported) Impl.Ride else union(enum) { none, main, viewport: *Viewport };

    /// `placeMain` for a window riding on another (`openMenu`'s `ride`), put somewhere new only when
    /// `key` — where it lies over that window — changes.
    pub fn placeRiding(vp: *Viewport, frame: Rect, key: Rect) Rect {
        if (comptime !supported) return frame;
        return dvui.currentWindow().backend.impl.viewportPlaceRiding(vp, frame, key);
    }

    /// Where menu `vp` is drawn in the frame from where its window lies over the main window,
    /// physical pixels: none for a menu of the main window's.
    pub fn mainOffset(vp: *Viewport, offset: dvui.Point.Physical) void {
        if (comptime !supported) return;
        dvui.currentWindow().backend.impl.viewportMainOffset(vp, .{ .x = offset.x, .y = offset.y });
    }

    /// A piece of the OS's glass in an overlay (`overlayGlass`): a rounded rect, points from the
    /// overlay window's top left.
    pub const GlassShape = if (supported) Impl.GlassShape else extern struct { x: f64, y: f64, w: f64, h: f64, radius: f64, lit: f64, alpha: f64 };

    /// Whether the OS has Liquid Glass to draw a view drag's glass with (`openOverlay`): macOS 26.
    pub fn liquidGlass() bool {
        if (comptime !supported) return false;
        return Impl.liquidGlassAvailable();
    }

    /// A window over the display the main window is on (`displayInMain`) holding the OS's glass
    /// (`overlayGlass`) under the picture presented into it, the pointer passing through it. Where
    /// `liquidGlass`.
    pub fn openOverlay(at: Rect) ?*Viewport {
        if (comptime !supported) return null;
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
        if (comptime !supported) return;
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
        if (comptime !supported) return;
        dvui.currentWindow().backend.impl.viewportOverlayPhotoImage(vp, rgba, w, h);
    }

    /// Where overlay `vp` shows the carried view's picture this frame, under its glass, so the
    /// glass over it bends it; null, nowhere. Applied with the glass.
    pub fn overlayPhoto(vp: *Viewport, photo: ?OverlayPhoto) void {
        if (comptime !supported) return;
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
        if (comptime !supported) return .{};
        return dvui.currentWindow().backend.impl.viewportDisplayInMain();
    }

    /// A carry window's shape this frame (`openCarry`): what it carries fills it, rounded by
    /// `radius` physical pixels — the OS's material and shadow in that shape — `alpha` opaque.
    /// Null: hidden.
    pub fn carryShape(vp: *Viewport, radius: ?f32, alpha: f32) void {
        if (comptime !supported) return;
        dvui.currentWindow().backend.impl.viewportCarryShape(vp, radius, alpha);
    }

    /// `vp`'s window at `other`'s level and just above it — a float born of a drop, over the drag's
    /// glass while that goes — until `settle` puts it back at its own. macOS.
    pub fn lift(vp: *Viewport, other: *Viewport) void {
        if (comptime !supported) return;
        dvui.currentWindow().backend.impl.viewportLift(vp, other);
    }

    pub fn settle(vp: *Viewport) void {
        if (comptime !supported) return;
        dvui.currentWindow().backend.impl.viewportSettle(vp);
    }

    /// `vp`'s window put just above `other`'s in the stacking (a growing float's picture over the
    /// glass it grows out of). macOS.
    pub fn orderAbove(vp: *Viewport, other: *Viewport) void {
        if (comptime !supported) return;
        dvui.currentWindow().backend.impl.viewportOrderAbove(vp, other);
    }

    /// A carry window's glass as the lens — the carried view, a drop of water — or as frost, as a
    /// window's material is (a float's window growing out of it). Liquid Glass only.
    pub fn carryLens(vp: *Viewport, lens: bool) void {
        if (comptime !supported) return;
        dvui.currentWindow().backend.impl.viewportCarryLens(vp, lens);
    }

    /// Whether `vp`'s window lies under the main window in the OS's stacking — a float's, clicked
    /// behind it — as last read (macOS; never elsewhere, where floats stay over it).
    pub fn underMain(vp: *Viewport) bool {
        if (comptime !supported) return false;
        return dvui.currentWindow().backend.impl.viewportUnderMain(vp);
    }

    /// Points from `vp`'s window's left edge past the OS's own buttons in its title bar (macOS's
    /// traffic lights, `os_buttons`): 0 without them.
    pub fn buttonsWidth(vp: *Viewport) f32 {
        if (comptime !supported) return 0;
        return dvui.currentWindow().backend.impl.viewportButtonsWidth(vp);
    }

    /// `vp`'s window's Liquid Glass this frame, as the main window's (`windowGlass`). Whether it
    /// has any: its float then draws no base of its own.
    pub fn windowGlass(vp: *Viewport, look: WindowGlassLook) bool {
        if (comptime !supported) return false;
        return dvui.currentWindow().backend.impl.viewportLiquidGlass(vp, look.native());
    }

    /// A float's window's corner radius, points: the OS's for a titled window (`os_frame`).
    pub fn windowRadius() f32 {
        if (comptime !supported) return 0;
        return dvui.currentWindow().backend.impl.windowCornerRadius();
    }

    /// A held pointer over `vp`'s window is read as over the main window beneath it while `on`: its
    /// float gone to its ghost while a view is carried out of it, aimed at the places under it.
    pub fn seeThrough(vp: *Viewport, on: bool) void {
        if (comptime !supported) return;
        dvui.currentWindow().backend.impl.viewportSeeThrough(vp, on);
    }

    /// Whether `vp`'s window is maximized — zoomed, or in a fullscreen Space of its own — as the
    /// main window's is asked: nothing of the desktop behind it shows.
    pub fn maximized(vp: *const Viewport) bool {
        if (comptime !supported) return false;
        return dvui.currentWindow().backend.impl.viewportMaximized(vp);
    }

    /// Whether `vp`'s window covers the desktop, or will once the transition it is in ends, as the
    /// main window's is asked (`coversDesktop`).
    pub fn coversDesktop(vp: *const Viewport) bool {
        if (comptime !supported) return false;
        return dvui.currentWindow().backend.impl.viewportCovers(vp);
    }

    /// Whether `vp`'s window is on its way into a fullscreen Space (`enteringSpace`).
    pub fn enteringSpace(vp: *const Viewport) bool {
        if (comptime !supported) return false;
        return dvui.currentWindow().backend.impl.viewportEnteringSpace(vp);
    }

    /// How far `vp`'s window is into full screen as it moves itself there or back (`spaceFullness`).
    pub fn spaceFullness(vp: *const Viewport) ?f32 {
        if (comptime !supported) return null;
        return dvui.currentWindow().backend.impl.viewportSpaceFullness(vp);
    }

    /// `vp`'s window `alpha` opaque, all of it — its material too.
    pub fn fade(vp: *Viewport, alpha: f32) void {
        if (comptime !supported) return;
        dvui.currentWindow().backend.impl.viewportFade(vp, alpha);
    }

    /// Whether a carried view can be shown past every window (`openCarry`): macOS.
    pub const carries = supported and builtin.os.tag == .macos;

    pub fn close(vp: *Viewport) void {
        if (comptime !supported) return;
        dvui.currentWindow().backend.impl.viewportClose(vp);
    }

    /// The part of the frame `vp` shows, physical pixels: in its band, past the main window.
    pub fn frameOf(vp: *const Viewport) Rect {
        if (comptime !supported) return .{};
        return vp.frame;
    }

    /// Put `vp`'s window where it shows `frame`; the part of the frame it then shows.
    pub fn place(vp: *Viewport, frame: Rect) Rect {
        if (comptime !supported) return frame;
        return dvui.currentWindow().backend.impl.viewportPlace(vp, frame);
    }

    /// Hand `vp` this frame's picture of its part of the frame, drawn into `target`, or nothing.
    pub fn present(vp: *Viewport, target: ?dvui.TextureTarget) void {
        if (comptime !supported) return;
        dvui.currentWindow().backend.impl.viewportPresent(vp, target);
    }

    /// Where `vp`'s window is now, in the main window's part of the frame (physical pixels from
    /// its top left): where its float goes when it comes back.
    pub fn inMain(vp: *const Viewport) Rect {
        if (comptime !supported) return .{};
        return dvui.currentWindow().backend.impl.viewportInMain(vp);
    }

    /// Put `vp`'s window where it shows `frame` of the main window's frame (past its edge, for a
    /// float split out under a drag); the part of the frame it then shows.
    pub fn placeMain(vp: *Viewport, frame: Rect) Rect {
        if (comptime !supported) return frame;
        return dvui.currentWindow().backend.impl.viewportPlaceMain(vp, frame);
    }

    /// `frame` of the main window's frame as the same desktop place in `vp`'s band.
    pub fn bandFromMain(vp: *const Viewport, frame: Rect) Rect {
        if (comptime !supported) return frame;
        return dvui.currentWindow().backend.impl.viewportBandFromMain(vp, frame);
    }

    /// Whether `vp`'s window has shown a frame yet.
    pub fn shown(vp: *const Viewport) bool {
        if (comptime !supported) return false;
        return dvui.currentWindow().backend.impl.viewportShown(vp);
    }

    /// Where a held pointer is read: by the window it is over, or pinned to the main window's
    /// frame or a viewport's band while a window is moved or resized.
    pub const Pin = if (supported) Impl.PointerPin else union(enum) { none, main, viewport: *Viewport };
    pub fn pinPointer(pin: Pin) void {
        if (comptime !supported) return;
        dvui.currentWindow().backend.impl.viewportPinPointer(pin);
    }

    /// Whether the OS frames a viewport's window itself — its corners, its shadow, resizing from its
    /// edges (Windows: DWM; macOS: a titled window, as the main window is) — so the window is
    /// exactly the float's glass. Otherwise it is the glass with a clear
    /// margin round it, which the float draws its own shadow in.
    pub const os_frame = supported and (builtin.os.tag == .windows or builtin.os.tag == .macos);

    /// Whether a viewport's window has the OS's own buttons to close, minimize and zoom it — macOS's
    /// traffic lights, a titled window's — so its float draws no close button of its own.
    pub const os_buttons = supported and builtin.os.tag == .macos;

    /// A material behind the float's glass in `vp`'s window — its rounded rect `inset` physical
    /// pixels in from the window's edge, `radius` its corners — for the float's frost to read the
    /// desktop through, in the app's light or dark (`dark`). False where the platform has none
    /// (yet).
    pub fn glass(vp: *Viewport, inset: f32, radius: f32, dark: bool) bool {
        if (comptime !supported) return false;
        return dvui.currentWindow().backend.impl.viewportGlass(vp, inset, radius, dark);
    }


    /// The OS asked to close `vp`'s window.
    pub fn closeRequested(vp: *const Viewport) bool {
        if (comptime !supported) return false;
        return vp.close_requested;
    }

    /// Where a press on `vp`'s window is the OS's, from its float this frame (physical pixels of
    /// the frame): `drag` its header, less `keep` (its close button), moves the window; `edge` in
    /// from `glass`'s sides resizes it. Null: all of it is the app's.
    /// `app_side` / `app_corner`: the float's own resize zones, the app's over its header where
    /// the OS resizes from no edge (macOS).
    pub const Hints = struct { drag: Rect, keep: Rect, glass: Rect, edge: f32, app_side: f32 = 0, app_corner: f32 = 0 };
    pub fn hints(vp: *Viewport, h: ?Hints) void {
        if (comptime !supported) return;
        dvui.currentWindow().backend.impl.viewportHints(vp, if (h) |x| .{ .drag = x.drag, .keep = x.keep, .glass = x.glass, .edge = x.edge, .app_side = x.app_side, .app_corner = x.app_corner } else null);
    }

    /// Where `vp`'s window shows in the frame now, when the OS has moved or resized it since the
    /// last ask — where its float goes.
    pub fn osPlaced(vp: *Viewport) ?Rect {
        if (comptime !supported) return null;
        return dvui.currentWindow().backend.impl.viewportOsPlaced(vp);
    }

    /// The press the OS took to move or resize `vp`'s window was let go; `resized` unless the
    /// window was only moved.
    pub const MoveEnd = struct { resized: bool };
    pub fn osMoveEnded(vp: *Viewport) ?MoveEnd {
        if (comptime !supported) return null;
        const e = dvui.currentWindow().backend.impl.viewportOsMoveEnded(vp) orelse return null;
        return .{ .resized = e.resized };
    }

    /// Hand the drag under way to the OS, which moves `vp`'s window from then on. False where it
    /// is not done: the app goes on moving it.
    pub fn dragMove(vp: *Viewport) bool {
        if (comptime !supported) return false;
        return dvui.currentWindow().backend.impl.viewportDragMove(vp);
    }

    /// What `vp`'s window is called: in the taskbar, the Window menu, the window switcher.
    pub fn setTitle(vp: *Viewport, text: []const u8) void {
        if (comptime !supported) return;
        dvui.currentWindow().backend.impl.viewportTitle(vp, text);
    }

    /// The least the OS may resize `vp`'s window to, physical pixels.
    pub fn minSize(vp: *Viewport, w: f32, h: f32) void {
        if (comptime !supported) return;
        dvui.currentWindow().backend.impl.viewportMinSize(vp, w, h);
    }
};

/// Fizzy keeps the window's geometry in `layout.zon`, beside its regions — one file for where the
/// window and everything in it were left, and the file it has always kept the frame in.
var layout_store_dir: []const u8 = "";

fn layoutStoreLoad(_: ?*anyopaque) ?platform.geometry.Geometry {
    const gpa = std.heap.page_allocator;
    const f = loadWindowFile(gpa, layout_store_dir);
    defer std.zon.parse.free(gpa, f);
    if (f.w < 1 or f.h < 1) return null;
    return .{ .x = f.x, .y = f.y, .w = f.w, .h = f.h, .state = if (f.maximized) .maximized else .normal };
}

fn layoutStoreSave(_: ?*anyopaque, g: platform.geometry.Geometry) void {
    // Read-modify-write: the regions and tree on disk stay as they are.
    const gpa = std.heap.page_allocator;
    var f = loadWindowFile(gpa, layout_store_dir);
    defer std.zon.parse.free(gpa, f);
    f.x = g.x;
    f.y = g.y;
    f.w = g.w;
    f.h = g.h;
    f.maximized = g.state == .maximized;
    writeWindowFile(layout_store_dir, f);
}

/// Height of the top strip that keeps editor content clear of the traffic lights: collapsed in a
/// fullscreen Space, back early as the window leaves one so the traffic lights never overlap a
/// pane mid-transition; a zoom without a Space keeps the full strip. Fizzy's titlebar heights
/// over the window's state (`platform.macos_monitor.titlebarState`).
pub fn titlebarStripHeight(win: *dvui.Window) f32 {
    if (builtin.os.tag != .macos) return Constants.titlebar_height;
    const t = platform.macos_monitor.titlebarState(win);
    const in: platform.window_layout.StripInputs = .{
        .collapsed = t.collapsed,
        .restoring_chrome = t.restoring_chrome,
        .live_inset = t.live_inset,
        .saved_inset = t.saved_inset,
        .titlebar_height = Constants.titlebar_height,
        .titlebar_top_buffer = Constants.titlebar_top_buffer,
    };
    if (platform.window.spaceFullness(win)) |f| return platform.window_layout.titlebarStripAtFullness(in, f);
    return platform.window_layout.chooseTitlebarStrip(in);
}

// ---- The native menu bar: fizzy's menus (`menu_model`) on the platform's (`platform.menu`) ----

pub const modifier_command = platform.menu.modifier_command;
pub const modifier_shift = platform.menu.modifier_shift;
pub const modifier_option = platform.menu.modifier_option;
pub const modifier_control = platform.menu.modifier_control;

/// A native menu item the user activated: its index among `menu_model`'s commands. `from_key`
/// means a ⌘-key equivalent, not a click: AppKit runs the menu action *and* passes the keystroke
/// on to SDL, so the key event is still on its way to whatever widget has focus — a command that
/// would otherwise synthesize one (paste into a text field) must not.
pub const NativeMenuAction = struct {
    index: usize,
    from_key: bool,
};

/// `menu_model.menu_bar` as the platform's menus: the same tree `Menu.zig` draws. Each command's
/// tag is its depth-first index among command items, which resolves back to a command id.
/// Recent Folders is a list the app fills as recents change; open actions and plugin sections
/// are the in-app bar's (natively a plugin's items come in as extras, `rebuildDynamicNativeMenus`).
const native_menus: []const platform.menu.Menu = blk: {
    @setEvalBranchQuota(20_000);
    var menus: [menu_model.menu_bar.len]platform.menu.Menu = undefined;
    var tag: u32 = 0;
    for (&menu_model.menu_bar, 0..) |*sub, i| {
        var entries: [sub.items.len]platform.menu.Entry = undefined;
        var n: usize = 0;
        for (sub.items) |item| switch (item) {
            .separator => {
                entries[n] = .separator;
                n += 1;
            },
            .command => |cmd| {
                entries[n] = .{ .command = .{ .title = cmd.title.resolveStatic(), .tag = tag, .symbol = cmd.sf_symbol } };
                n += 1;
                tag += 1;
            },
            .recent_folders => {
                entries[n] = .{ .list = .{ .title = "Recent Folders" } };
                n += 1;
            },
            .open_actions, .plugin_section, .submenu => {},
        };
        const done = entries[0..n].*;
        menus[i] = .{
            .id = sub.id,
            .aliases = sub.aliases,
            .title = sub.title,
            .entries = &done,
            .help = std.mem.eql(u8, sub.id, "fizzy.menu.help"),
        };
    }
    const done = menus;
    break :blk &done;
};

/// Build the macOS menu bar from `menu_model`. Once; safe to call again.
pub fn setupMacOSMenuBar() void {
    if (builtin.os.tag != .macos) return;
    platform.menu.install(native_menus, .{
        .enabled = menuEnabled,
        .title = menuTitle,
        .input_blocked = menuInputBlocked,
    }, AppInfo.about_title_z);
    // Plugin items already registered (built-in static plugins register in `postInit`, before
    // this), the recents, and the chords: the items are built with none, and the keymap may
    // have stamped them before they existed.
    rebuildDynamicNativeMenus();
    rebuildNativeRecentFolders();
    fizzy.Editor.Keybinds.syncNativeMenuShortcuts(fizzy.editor());
}

/// True while keys must not act at all: capturing a chord in the Keyboard Shortcuts settings.
fn menuInputBlocked(_: ?*anyopaque) bool {
    return KeybindSettings.isRecording();
}

/// Whether a menu item can be chosen now — the same greying the in-app bar (`Menu.zig`) does.
/// Everything it reads is plain `Host`/`Editor` state, safe outside a frame.
fn menuEnabled(_: ?*anyopaque, ref: platform.menu.Ref) bool {
    if (KeybindSettings.isRecording()) return false;
    switch (ref.section) {
        .bar => {
            const item = menu_model.byTag(ref.tag) orelse return true;
            // Copy/Paste stay enabled even when the active document can't do them: a disabled
            // NSMenuItem does not perform its key equivalent, and on macOS that is the only way
            // the chord reaches the app at all, including focused widgets that handle it.
            if (item.native_always_enabled) return true;
            // A `visible` item that isn't is shown greyed rather than removed: rebuilding the
            // retained NSMenu on every state change isn't worth it for the same information.
            if (item.visible) |f| if (!f(fizzy.editor())) return false;
            const enabled = item.enabled orelse return true;
            return enabled(fizzy.editor());
        },
        // A plugin's item is its command's, on both bars; no command is always enabled.
        .extra => {
            const items = fizzy.editor().app.host.native_menu_items.items;
            if (ref.tag >= items.len) return true;
            const cmd = items[ref.tag].command orelse return true;
            return fizzy.editor().app.host.commandEnabled(cmd);
        },
        .list => return true,
    }
}

/// A model item's label now, for one that follows the app ("Show Explorer" / "Hide Explorer").
fn menuTitle(_: ?*anyopaque, ref: platform.menu.Ref) ?[*:0]const u8 {
    if (ref.section != .bar) return null;
    const item = menu_model.byTag(ref.tag) orelse return null;
    return switch (item.title) {
        .static => null,
        .dynamic => |f| f(fizzy.editor()).ptr,
    };
}

/// Rebuild every plugin-contributed native menu and item from the host's registry: on every
/// plugin load, unload and hide-toggle. Each item's tag is its index in `host.native_menu_items`.
pub fn rebuildDynamicNativeMenus() void {
    if (builtin.os.tag != .macos) return;
    const host = &fizzy.editor().app.host;
    var menus: std.ArrayListUnmanaged(platform.menu.ExtraMenu) = .empty;
    defer menus.deinit(alloc());
    var items: std.ArrayListUnmanaged(platform.menu.ExtraItem) = .empty;
    defer items.deinit(alloc());
    for (host.menus.items) |mc| {
        if (mc.hidden) continue;
        menus.append(alloc(), .{ .id = mc.id, .title = mc.title }) catch {};
    }
    for (host.native_menu_items.items, 0..) |ni, i| {
        if (ni.hidden) continue;
        items.append(alloc(), .{ .menu_id = ni.parent_menu_id, .title = ni.title, .symbol = ni.sf_symbol, .tag = @intCast(i) }) catch {};
    }
    platform.menu.setExtras(menus.items, items.items);
    // The items are built with no key equivalent; this is what puts the keymap's chords on them.
    fizzy.Editor.Keybinds.syncNativeMenuShortcuts(fizzy.editor());
}

/// How many folders the Recent Folders list was last filled with: a choice's position in it,
/// newest first, back to an index into the recents.
var native_recent_count: usize = 0;

/// Fill the Recent Folders submenu from the recents, newest first. AppKit menus are retained
/// state, so this has to run whenever the list changes.
pub fn rebuildNativeRecentFolders() void {
    if (comptime builtin.os.tag != .macos) return;
    const folders = fizzy.editor().app.recents.folders.items;
    const titles = alloc().alloc([]const u8, folders.len) catch return;
    defer alloc().free(titles);
    for (folders, 0..) |f, i| titles[folders.len - 1 - i] = f;
    native_recent_count = folders.len;
    platform.menu.setList(0, titles);
}

/// Returns and clears a pending Recent Folders choice, as an index into the recents.
pub fn pollPendingRecentFolder() ?usize {
    const a = platform.menu.pollActivation(.list) orelse return null;
    if (a.ref.tag >= native_recent_count) return null;
    return native_recent_count - 1 - a.ref.tag;
}

/// Returns and clears a pending app-menu About click.
pub const pollPendingAbout = platform.menu.pollAbout;

/// Returns and clears a pending native menu action (macOS menu bar). Call once per frame.
pub fn pollPendingNativeMenuAction() ?NativeMenuAction {
    const a = platform.menu.pollActivation(.bar) orelse return null;
    if (a.ref.tag >= menu_model.flat_commands.len) return null;
    return .{ .index = a.ref.tag, .from_key = a.from_key };
}

/// Returns and clears a pending plugin menu item, as its index in `host.native_menu_items`.
pub fn pollPendingGenericNativeMenuAction() ?usize {
    const a = platform.menu.pollActivation(.extra) orelse return null;
    return a.ref.tag;
}

/// Point a menu item at a different chord (`key` lowercase, as AppKit expects; null clears it,
/// right for a chord AppKit can't express).
pub fn setNativeMenuShortcut(tag: usize, key: ?[]const u8, modifier_mask: c_ulong) void {
    platform.menu.setKeyEquivalent(.{ .section = .bar, .tag = @intCast(tag) }, key, modifier_mask);
}

/// `setNativeMenuShortcut` for a plugin's item, keyed by its index in `host.native_menu_items`.
pub fn setDynamicNativeMenuShortcut(index: usize, key: ?[]const u8, modifier_mask: c_ulong) void {
    platform.menu.setKeyEquivalent(.{ .section = .extra, .tag = @intCast(index) }, key, modifier_mask);
}

/// Override the SDL app metadata DVUI sets to its example defaults. On macOS this
/// is what drives the app menu's `About <name>` / `Hide <name>` / `Quit <name>`
/// items. Must be called before `setupMacOSMenuBar` so the inserted Help menu
/// references the right product name.
pub fn setSdlAppMetadata(name: [*:0]const u8, version: [*:0]const u8, identifier: [*:0]const u8) void {
    _ = sdl3.SDL_SetAppMetadata(name, version, identifier);
}

