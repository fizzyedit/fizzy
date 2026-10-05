//! The app's window, as the OS has it: its chrome (`setStyle`, `setBackground`), whether it is
//! maximized or full screen, and bringing it forward. macOS and Windows; elsewhere what SDL does.
const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const c = @import("backend").c;
const objc = @import("objc");
const titlebar = @import("titlebar.zig");
const win32_titlebar = @import("win32_titlebar.zig");
const linux_titlebar = @import("linux_titlebar.zig");

const NSPoint = extern struct { x: f64, y: f64 };
const NSSize = extern struct { width: f64, height: f64 };
const NSRect = extern struct { origin: NSPoint, size: NSSize };

// NSWindowStyleMaskFullSizeContentView = 1 << 15 — content view extends under titlebar so vibrancy can cover it.
const NSWindowStyleMaskFullSizeContentView: c_ulong = 1 << 15;
/// The vibrancy material fizzy's windows wear on macOS: the main window's, and a popped-out float's.
pub const ns_visual_effect_material: c_long = 15;

// The window monitor (`FizzyWindowMonitor.m`), which follows the window through Spaces and zooms.
extern fn fizzy_macos_window_is_zoomed(cocoa_window: ?*anyopaque) c_int;
extern fn fizzy_macos_window_in_fullscreen_space(cocoa_window: ?*anyopaque) c_int;
extern fn fizzy_macos_window_chrome_hidden(cocoa_window: ?*anyopaque) c_int;
extern fn fizzy_macos_window_space_transition_active(cocoa_window: ?*anyopaque) c_int;
extern fn fizzy_macos_window_space_entering(cocoa_window: ?*anyopaque) c_int;
extern fn fizzy_macos_titlebar_hit_test_install(cocoa_window: ?*anyopaque, interactive_at: *const fn (f64, f64) callconv(.c) bool) void;
extern fn fizzy_macos_window_liquid_glass(cocoa_window: ?*anyopaque, blur_material: c_long) c_int;
extern fn fizzy_macos_window_has_liquid_glass(cocoa_window: ?*anyopaque) c_int;
extern fn fizzy_macos_window_liquid_glass_look(cocoa_window: ?*anyopaque, look: *const WindowGlass) void;

/// A window's Liquid Glass this frame (`liquidGlassLook`), as `fizzy_macos_window_liquid_glass_look`
/// reads it (`core.glass_look.Window`): each glass layer's variant and style; the body's frost over
/// the lens and the plain blur over that; how much glass there is; the window's colour (0…1 each)
/// with its opacity under the glass last, and its opacity over the body's blur; the window's corner
/// radius, and the clear band along its edge and the feather into the body, in points.
pub const WindowGlass = extern struct {
    under_variant: c_long,
    under_style: c_long,
    over_variant: c_long,
    over_style: c_long,
    frost: f64,
    blur: f64,
    glass: f64,
    fill: [4]f64,
    body_fill: f64,
    radius: f64,
    rim: f64,
    feather: f64,
};

/// Make one of fizzy's titled windows (`raw_ptr`, its `NSWindow`) a window of Liquid Glass — the
/// window's colour under the clear lens, a body of frost and the plain blur (the vibrancy it wore
/// before, `ns_visual_effect_material`) fading into a clear band along its edge, a compact
/// toolbar's corners — where the OS has it (macOS 26). Once per window. Whether it is.
pub fn liquidGlass(raw_ptr: *anyopaque) bool {
    if (comptime builtin.os.tag != .macos) return false;
    return fizzy_macos_window_liquid_glass(raw_ptr, ns_visual_effect_material) != 0;
}

/// `window`'s Liquid Glass this frame (`liquidGlass`). Whether it has any: false, and nothing set,
/// where it stands on vibrancy instead.
pub fn liquidGlassLook(window: *c.SDL_Window, look: WindowGlass) bool {
    if (comptime builtin.os.tag != .macos) return false;
    const ns = c.SDL_GetPointerProperty(c.SDL_GetWindowProperties(window), c.SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, null) orelse return false;
    if (fizzy_macos_window_has_liquid_glass(ns) == 0) return false;
    fizzy_macos_window_liquid_glass_look(ns, &look);
    return true;
}

/// For AppKit's titlebar region: whether a press at this pixel is the app's (`titlebar.interactiveAt`).
fn titlebarInteractiveAt(x: f64, y: f64) callconv(.c) bool {
    return titlebar.interactiveAt(@intFromFloat(x), @intFromFloat(y));
}

/// The app's windows, captured once at startup (`attach`): what is reached from outside a frame —
/// an OS event, a dialog finishing — where `dvui.currentWindow()` is not.
var attached: ?*dvui.Window = null;
var attached_sdl: ?*c.SDL_Window = null;

/// Remember `win` as the app's window. Call once at startup, before anything else here.
pub fn attach(win: *dvui.Window) void {
    attached = win;
    attached_sdl = win.backend.impl.window;
}

/// The app's dvui window (`attach`), or the frame's.
pub fn dvuiWindow() ?*dvui.Window {
    return attached orelse dvui.current_window;
}

/// The app's SDL window: the one attached at startup, or — called inside a frame before that —
/// the frame's own.
pub fn main() ?*c.SDL_Window {
    if (attached_sdl) |w| return w;
    const cw = dvui.current_window orelse return null;
    return cw.backend.impl.window;
}

fn cocoaWindowOf(window: *c.SDL_Window) ?*anyopaque {
    return c.SDL_GetPointerProperty(
        c.SDL_GetWindowProperties(window),
        c.SDL_PROP_WINDOW_COCOA_WINDOW_POINTER,
        null,
    );
}

/// Reveal the window (it is created hidden, so its chrome and geometry are in place first),
/// maximized when `maximized`.
pub fn show(win: *dvui.Window, maximized: bool) void {
    if (comptime builtin.os.tag != .macos and builtin.os.tag != .windows and builtin.os.tag != .linux) return;
    _ = c.SDL_ShowWindow(win.backend.impl.window);
    if (maximized) _ = c.SDL_MaximizeWindow(win.backend.impl.window);
}

pub fn isMaximized(win: *dvui.Window) bool {
    return windowMaximized(win.backend.impl.window);
}

/// Whether `window` — the main window or a float's own — is maximized: zoomed, full screen, or in
/// a fullscreen Space (on macOS through the whole of its way out of one). Nothing of the desktop
/// behind it shows, and fizzy draws it opaque (`Editor.easeWindowOpacity`).
pub fn windowMaximized(window: *c.SDL_Window) bool {
    const flags = c.SDL_GetWindowFlags(window);
    if (flags & c.SDL_WINDOW_MAXIMIZED != 0) return true;
    if (builtin.os.tag == .macos) {
        const raw_ptr = c.SDL_GetPointerProperty(
            c.SDL_GetWindowProperties(window),
            c.SDL_PROP_WINDOW_COCOA_WINDOW_POINTER,
            null,
        );
        if (raw_ptr != null) {
            if (fizzy_macos_window_in_fullscreen_space(raw_ptr) != 0) return true;
            if (fizzy_macos_window_is_zoomed(raw_ptr) != 0) return true;
            if (fizzy_macos_window_chrome_hidden(raw_ptr) != 0) return true;
        }
        return false;
    }
    return flags & c.SDL_WINDOW_FULLSCREEN != 0;
}

/// Whether `win` covers the desktop, or will once the transition it is in ends (`windowCovers`).
pub fn coversDesktop(win: *dvui.Window) bool {
    return windowCovers(win.backend.impl.window);
}

/// Whether `window` covers the desktop, or will once the transition it is in ends: maximized
/// (`windowMaximized`), and not on its way out of a fullscreen Space — the desktop comes back
/// behind it as it goes, and a window that lets the desktop through fades to it with the
/// transition (`Editor.easeWindowOpacity`), not after.
pub fn windowCovers(window: *c.SDL_Window) bool {
    if (builtin.os.tag == .macos) {
        const raw_ptr = c.SDL_GetPointerProperty(c.SDL_GetWindowProperties(window), c.SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, null);
        if (raw_ptr != null and fizzy_macos_window_space_transition_active(raw_ptr) != 0 and
            fizzy_macos_window_space_entering(raw_ptr) == 0) return false;
    }
    return windowMaximized(window);
}

/// True while the macOS window chrome (traffic lights / titlebar area) is hidden, i.e. while
/// the layout's end state is a fullscreen Space: entering or steady fullscreen. Flips false
/// already at willExitFullScreen so the titlebar strip is back in the layout before the
/// buttons fade in. Driven by AppKit notifications via objc/FizzyWindowMonitor.m, NOT SDL's
/// fullscreen flag (which is wrong for zoomed windows and only updates after animations).
/// On non-macOS targets this is just `isMaximized`.
pub fn isFullscreenChromeHidden(win: *dvui.Window) bool {
    if (builtin.os.tag != .macos) return isMaximized(win);
    const raw_ptr = c.SDL_GetPointerProperty(
        c.SDL_GetWindowProperties(win.backend.impl.window),
        c.SDL_PROP_WINDOW_COCOA_WINDOW_POINTER,
        null,
    );
    return fizzy_macos_window_chrome_hidden(raw_ptr) != 0;
}

/// The window's chrome: full-size content under a transparent, title-less titlebar and a
/// fullscreen Space on macOS; on Windows the DWM Acrylic backdrop over a client area that is the
/// whole window; on Linux no decorations, the app's title bar hit-tested (`linux_titlebar`). Cheap to call every frame — it reads what is set and changes only what SDL has put
/// back (SDL re-applies its own style on maximize, restore and full screen: on Windows that
/// returns `WS_SYSMENU` and its caption buttons, and the backdrop's frame with it). Applying it all
/// unconditionally every frame was a `SetWindowPos(SWP_FRAMECHANGED)` — a `WM_NCCALCSIZE` — a
/// library load and a class-brush write each frame on Windows, and two style-mask writes on macOS.
pub fn setStyle(win: *dvui.Window) void {
    if (builtin.os.tag == .macos) {
        const raw_ptr = c.SDL_GetPointerProperty(
            c.SDL_GetWindowProperties(win.backend.impl.window),
            c.SDL_PROP_WINDOW_COCOA_WINDOW_POINTER,
            null,
        );
        if (raw_ptr) |ptr| {
            styleTitled(ptr);
            // Presses over what the app draws in the titlebar's region (a dialog, a menu) are
            // the app's, not AppKit's to move the window with.
            fizzy_macos_titlebar_hit_test_install(ptr, titlebarInteractiveAt);
        }
        // Every float's own window too: SDL puts its own style back on them as on the main window
        // — into and out of a fullscreen Space above all — and a float's window kept SDL's
        // titlebar strip over its content after one. The pointer over a float's window is its
        // own hit test's (`SDLBackend.viewportHitTest`), so no titlebar hit test of the main one's.
        for (&win.backend.impl.viewports) |*slot| {
            const vp = if (slot.*) |*v| v else continue;
            if (vp.passive) continue;
            const ns = c.SDL_GetPointerProperty(c.SDL_GetWindowProperties(vp.window), c.SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, null) orelse continue;
            styleTitled(ns);
        }
    } else if (builtin.os.tag == .windows) {
        win32_titlebar.applyChrome(win);
    } else if (builtin.os.tag == .linux) {
        linux_titlebar.applyChrome(win);
    }
}

/// What a caption button the app drew does, where the app takes its click (Linux — Windows
/// clicks them itself through `WM_NCHITTEST`): minimize, maximize or restore, and close as the
/// window manager's close would, so the app's own close handling (unsaved work) runs.
pub fn performTitleBarButton(win: *dvui.Window, button: titlebar.TitleBarButton) void {
    const window = win.backend.impl.window;
    switch (button) {
        .minimize => _ = c.SDL_MinimizeWindow(window),
        .maximize => _ = if (c.SDL_GetWindowFlags(window) & c.SDL_WINDOW_MAXIMIZED != 0)
            c.SDL_RestoreWindow(window)
        else
            c.SDL_MaximizeWindow(window),
        .close => {
            var e = std.mem.zeroes(c.SDL_Event);
            e.window.type = c.SDL_EVENT_WINDOW_CLOSE_REQUESTED;
            e.window.windowID = c.SDL_GetWindowID(window);
            _ = c.SDL_PushEvent(&e);
        },
    }
}

/// A titled window of fizzy's styled as the app is — the main window and every float's own
/// window (`setStyle`): its content under a transparent, title-less titlebar, going full screen in
/// a Space of its own. Reads before it writes: only what SDL has put back changes.
fn styleTitled(raw_ptr: *anyopaque) void {
    const window = objc.Object.fromId(raw_ptr);

    // Re-applying styleMask while in a fullscreen Space exits the Space on macOS.
    if (fizzy_macos_window_in_fullscreen_space(raw_ptr) == 0) {
        // Allow content view to extend under the titlebar so vibrancy covers it.
        const style_mask = window.msgSend(c_ulong, "styleMask", .{});
        if (style_mask & NSWindowStyleMaskFullSizeContentView == 0) {
            window.msgSend(void, "setStyleMask:", .{style_mask | NSWindowStyleMaskFullSizeContentView});
        }
    }
    // This sets the titlebar to transparent so our effect view shows through.
    if (!window.msgSend(bool, "titlebarAppearsTransparent", .{})) {
        window.msgSend(void, "setTitlebarAppearsTransparent:", .{true});
    }
    // Hide the title text in the titlebar (matches Windows, where we
    // draw our own chrome). `NSWindowTitleHidden` = 1. The window still
    // has a programmatic title (used by the Window menu / Dock) — only
    // the rendered titlebar string is hidden.
    if (window.msgSend(c_long, "titleVisibility", .{}) != 1) {
        window.msgSend(void, "setTitleVisibility:", .{@as(c_long, 1)});
    }
    // Green button enters a native fullscreen Space (menu bar hidden).
    const NSWindowCollectionBehaviorFullScreenPrimary: c_ulong = 1 << 7;
    const behavior = window.msgSend(c_ulong, "collectionBehavior", .{});
    if (behavior & NSWindowCollectionBehaviorFullScreenPrimary == 0) {
        window.msgSend(void, "setCollectionBehavior:", .{behavior | NSWindowCollectionBehaviorFullScreenPrimary});
    }
}

/// A window of fizzy's skinned as the app is: its background — what AppKit draws its title bar
/// with, the one a fullscreen window reveals at the top among them — `color`, and its appearance
/// light or dark by the app's theme, not the system's, so its title bar, traffic lights and
/// vibrancy read as the app does. The main window's and every float's own window's alike
/// (`setBackground`, `SDLBackend.viewportGlass`).
pub fn skin(raw_ptr: *anyopaque, color: dvui.Color, dark: bool) void {
    if (comptime builtin.os.tag != .macos) return;
    const window = objc.Object.fromId(raw_ptr);
    const NSColor = objc.getClass("NSColor").?;
    const new_color = NSColor.msgSend(objc.Object, "colorWithRed:green:blue:alpha:", .{
        @as(f64, @floatFromInt(color.r)) / 255.0,
        @as(f64, @floatFromInt(color.g)) / 255.0,
        @as(f64, @floatFromInt(color.b)) / 255.0,
        @as(f64, @floatFromInt(color.a)) / 255.0,
    });
    // This sets both the titlebar and the window background color — clear on a window of Liquid
    // Glass (`liquidGlass`), whose colour is under its glass.
    const glass = fizzy_macos_window_has_liquid_glass(raw_ptr) != 0;
    window.msgSend(void, "setBackgroundColor:", .{if (glass) NSColor.msgSend(objc.Object, "clearColor", .{}).value else new_color.value});

    // Set window NSAppearance so the app (title bar, traffic lights, vibrancy) matches dvui theme.
    if (objc.getClass("NSAppearance")) |NSAppearance| {
        if (objc.getClass("NSString")) |NSString| {
            const name_c: [*c]const u8 = if (dark)
                "NSAppearanceNameVibrantDark"
            else
                "NSAppearanceNameVibrantLight";
            const name_obj = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{name_c});
            if (name_obj.value != 0) {
                const appearance = NSAppearance.msgSend(objc.Object, "appearanceNamed:", .{name_obj.value});
                if (appearance.value != 0) {
                    window.msgSend(void, "setAppearance:", .{appearance.value});
                }
            }
        }
    }
}

pub fn setBackground(win: *dvui.Window, color: dvui.Color) void {
    if (builtin.os.tag == .macos) {
        const raw_ptr = c.SDL_GetPointerProperty(
            c.SDL_GetWindowProperties(win.backend.impl.window),
            c.SDL_PROP_WINDOW_COCOA_WINDOW_POINTER,
            null,
        );
        if (raw_ptr != null) {
            const window = objc.Object.fromId(raw_ptr);

            setStyle(win);

            // Liquid Glass where the OS has it (macOS 26), beside SDL's view as a float's window
            // is; else the content view wrapped in an NSVisualEffectView once, for vibrancy.
            if (!liquidGlass(raw_ptr.?)) wrapContentViewWithVibrancy(window);

            skin(raw_ptr.?, color, dvui.themeGet().dark);
            // Every float's own window too, and each opened from now on (`SDLBackend.viewportGlass`):
            // side by side, and each in a Space of its own, they are one app's windows.
            win.backend.impl.window_skin = color;
            for (&win.backend.impl.viewports) |*slot| {
                const vp = if (slot.*) |*v| v else continue;
                if (vp.passive) continue;
                const ns = c.SDL_GetPointerProperty(c.SDL_GetWindowProperties(vp.window), c.SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, null) orelse continue;
                skin(ns, color, dvui.themeGet().dark);
            }

            // SDL3 currently removes the shadow when the transparency flag for the window is set. This brings it back.
            window.msgSend(void, "setHasShadow:", .{true});
        }
    } else if (builtin.os.tag == .windows) {
        setStyle(win);
        win32_titlebar.clearCaptionColors(win);
        // As macOS's NSAppearance above: the backdrop matches the dvui theme.
        win32_titlebar.setDarkMode(win, dvui.themeGet().dark);
    }
}

/// Wraps the window's content view in an NSVisualEffectView so the window gets
/// vibrancy (blur of the desktop behind it). Safe to call multiple times;
/// only wraps once per window. Caller should set full-size content view style
/// mask and titlebarAppearsTransparent before calling so the effect covers the titlebar.
/// Uses FizzyVisualEffectView (custom subclass) when available so right-click is forwarded to the content view.
fn wrapContentViewWithVibrancy(window: objc.Object) void {
    const content_view = window.msgSend(objc.Object, "contentView", .{});
    if (content_view.value == 0) return;

    const NSVisualEffectViewClass = objc.getClass("NSVisualEffectView") orelse return;
    const fill_mask: c_ulong = 18; // NSViewWidthSizable | NSViewHeightSizable

    const is_effect_view = content_view.msgSend(bool, "isKindOfClass:", .{NSVisualEffectViewClass.value});
    if (is_effect_view) {
        content_view.msgSend(void, "setMaterial:", .{ns_visual_effect_material});
        content_view.msgSend(void, "setMenu:", .{@as(usize, 0)});
        // Keep the content subview's nextResponder pointing at the window delegate so rightMouseDown reaches SDL.
        const subviews = content_view.msgSend(objc.Object, "subviews", .{});
        const count: usize = subviews.msgSend(usize, "count", .{});
        if (count > 0) {
            const sub = subviews.msgSend(objc.Object, "objectAtIndex:", .{@as(c_ulong, 0)});
            const delegate = window.msgSend(objc.Object, "delegate", .{});
            if (delegate.value != 0) sub.msgSend(void, "setNextResponder:", .{delegate.value});
        }
        return;
    }

    // Prefer custom subclass that forwards rightMouseDown to the content view (see vibrancy_rightclick_fix.m).
    const EffectViewClass = objc.getClass("FizzyVisualEffectView") orelse NSVisualEffectViewClass;
    const effect_view = EffectViewClass.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "init", .{});
    if (effect_view.value == 0) return;

    effect_view.msgSend(void, "setBlendingMode:", .{@as(c_long, 0)}); // NSVisualEffectBlendingModeBehindWindow
    effect_view.msgSend(void, "setState:", .{@as(c_long, 1)}); // NSVisualEffectStateActive
    effect_view.msgSend(void, "setMaterial:", .{ns_visual_effect_material});
    effect_view.msgSend(void, "setMenu:", .{@as(usize, 0)}); // no context menu so right-click can reach subview

    window.msgSend(void, "setContentView:", .{effect_view.value});
    effect_view.msgSend(void, "addSubview:", .{content_view.value});
    content_view.msgSend(void, "setMenu:", .{@as(usize, 0)}); // no context menu so rightMouseDown is delivered
    // SDL sets the content view's nextResponder to the window delegate (listener) so rightMouseDown reaches the handler.
    // Adding the view as our subview made its nextResponder us; restore it so right-click events reach the app.
    const delegate = window.msgSend(objc.Object, "delegate", .{});
    if (delegate.value != 0) {
        content_view.msgSend(void, "setNextResponder:", .{delegate.value});
    }

    const bounds = effect_view.msgSend(NSRect, "bounds", .{});
    content_view.msgSend(void, "setFrame:", .{bounds});
    content_view.msgSend(void, "setAutoresizingMask:", .{fill_mask});
}

/// Bring the window forward and make the app active, for a flow that had to leave it: signing
/// into a cloud provider, or picking a folder, both of which happen in the system browser and
/// leave fizzy behind whatever the user was sent to. Google (and every other provider worth
/// naming) refuses OAuth in an embedded webview, so "do it in-app" is not on the table — the
/// most an app can do is take focus back when the browser is finished with it.
///
/// `SDL_RaiseWindow` alone is enough on Windows and most Linux WMs. On macOS raising a window
/// does not make the *application* active, so the app has to ask as well; the ask is rejected
/// while another app is genuinely in the foreground for user input, which is the OS protecting
/// the user and not something to work around.
/// Enter or leave full screen. On macOS that is the green button's own Space transition, which
/// the window monitor (`FizzyWindowMonitor.m`) already follows; elsewhere SDL's.
pub fn toggleFullscreen() void {
    const w = main() orelse return;
    if (builtin.os.tag == .macos) {
        const ns = cocoaWindowOf(w) orelse return;
        objc.Object.fromId(ns).msgSend(void, "toggleFullScreen:", .{@as(?*anyopaque, null)});
        return;
    }
    const on = (c.SDL_GetWindowFlags(w) & c.SDL_WINDOW_FULLSCREEN) != 0;
    _ = c.SDL_SetWindowFullscreen(w, !on);
}

pub fn raise() void {
    if (main()) |w| _ = c.SDL_RaiseWindow(w);
    if (builtin.os.tag == .macos) activateApp();
}

/// macOS only: make fizzy the active application. `activate(ignoringOtherApps:)` is deprecated
/// on 14+ in favour of `activate`, so try the new selector first and fall back — the old one
/// still works and is the only one on earlier systems.
fn activateApp() void {
    if (builtin.os.tag != .macos) return;
    const NSApplication = objc.getClass("NSApplication") orelse return;
    const app = NSApplication.msgSend(objc.Object, "sharedApplication", .{});
    if (app.value == null) return;
    // `class_respondsToSelector` rather than a version check: `activate` arrived in macOS 14
    // and `activateIgnoringOtherApps:` is deprecated there but still works, so ask the runtime
    // which one this system has. (zig-objc's `Object` has no respondsToSelector of its own.)
    const cls = app.getClass() orelse return;
    if (objc.c.class_respondsToSelector(cls.value, objc.sel("activate").value) != 0) {
        app.msgSend(void, "activate", .{});
    } else {
        app.msgSend(void, "activateIgnoringOtherApps:", .{@as(u8, 1)});
    }
}
