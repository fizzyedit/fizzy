# Native windows and glass on Windows and Linux

Status: in progress. Research under `docs/NATIVE_WINDOWS_PLAN.md`. Step 0 (the glass programs
compiled again) is done (#242). Steps 3 (Windows menus and dialogs as Acrylic popups) and 4 (the
Linux window material) are built in PRs of their own, each behind a flag, and step 5's spikes are
run (`spikes/windows-composition/`); nothing else here is.

An investigation, not yet a design anyone has agreed to. macOS has floats as OS windows by default,
and on macOS 26 the OS draws a view drag's glass (`docs/POPOUT_WINDOWS_PLAN.md`, "P6";
`core/native_glass.zig`). This asks what the same experience takes on Windows and Linux, what each
OS gives fizzy to build it from, and in what order to build it. The facts about each OS were
gathered in October 2026, with sources linked. Anything marked **(spike)** was not run, and is the
first thing to check.

**The plan this works under is `docs/NATIVE_WINDOWS_PLAN.md`** (#226). Its decisions stand: on Windows, the slider runs along DWM's backdrop types as Windows Terminal maps its opacity
(no backdrop, then Acrylic, then Mica), fizzy's windows act as one activation group, a carry
window is DWM Acrylic, and the drop zones stay the app's glass, with no merging. Per-shape glass
over the desktop through Windows.UI.Composition is its "Phase 2, only with a go-ahead". This file
is the research for that phase (the overlay below) and for the Linux blur region, which its
"Linux — the compositor's blur" already designs.

## What macOS does, taken apart

The macOS work is one experience, but it rests on several separate things the OS provides. Each one
has a different answer on the other platforms, so they are listed separately:

| # | Piece | macOS (built) | Windows today | Linux today |
|---|---|---|---|---|
| 1 | **Window material**: a blur of the desktop behind the main window and each float's window | vibrancy / Liquid Glass (`visual_effect_view.m`) | Acrylic through DWM (`win32_titlebar.zig`) | none: opaque (`LiquidField.publishOpaqueWindow`) |
| 2 | **OS frame**: corners, shadow, resizing from the edges, snapping | a titled `NSWindow` | DWM, with the app's hit test (built for the main window and floats) | client-side; Wayland frame insets for the shadow |
| 3 | **Window buttons on a float** | traffic lights (`viewports.os_buttons`) | none yet: the float's header needs caption buttons | the app's own |
| 4 | **Menus and dialogs in windows of their own** | `viewportOpenMenu` | not built | not built |
| 5 | **Carry window**: what a dragged view is carried as, shown past every window, in its own shape, with the material and a shadow, clicks passing through | `viewportOpenCarry` (`viewports.carries`) | not built: the drag is cut off at the main window's edge | not built |
| 6 | **The OS's glass**: drop bubbles and the carried drop merging like liquid, refracting what is behind them across every app | `NSGlassEffectContainerView` in the overlay (`viewports.liquidGlass`) | no OS equivalent | no OS equivalent |
| 7 | **One transaction**: a window's place, its glass and its picture reach the screen together | one Core Animation transaction a frame (`renderPresent`, SDL patches 3–5) | none: a composition commit and a swapchain present take separate routes | Wayland: the surface commit; X11: none |

1–3 are mostly done on Windows. 4 and 5 are ordinary windowing work. 6 is where the platforms
really differ, and 7 decides whether whatever is built for 5 and 6 looks native or trails a frame
behind.

## The split that makes it portable: the OS supplies the blur, fizzy supplies the shape

On macOS 26 the OS does both jobs: it shapes the glass (merging the pieces, refracting) and fills
it with material. Nothing on Windows or Linux is like `NSGlassEffectContainerView`. Microsoft said
in August 2026 that there are "no immediate changes" planned to Windows' transparency
([Windows Latest](https://www.windowslatest.com/2026/08/10/microsoft-reveals-why-windows-11-wont-get-liquid-glass-style-ui-even-though-windows-vista-did-it-first-with-aero/)).
The Linux compositors that refract ([hyprglass](https://github.com/hyprnux/hyprglass)) do it as
compositor effects an app cannot ask for. What both platforms *can* do is blur what is behind a
window and clip that blur to a shape the app gives. Fizzy already computes the merged shape
itself: the smooth minimum in `LiquidField` (`shaders/liquid_glass.*`) and its CPU twin
`liquid_blob` are what the app's own glass draws, in every window, on every platform.

So everywhere except macOS 26:

- **the shape is fizzy's**: the merging, necks, rim light, lift, tint, icons and the carried
  photograph are drawn by the app into a transparent window, as `LiquidField` already draws them
  in-window;
- **the material is the OS's**: the OS blurs what is behind that window, inside an outline the app
  hands it each frame (a clip path on Windows, a region on Wayland), traced from the same field.

`core.native_glass` already holds the piece list this needs (rects, radii, `lit`, `alpha`, `frost`,
the merge distance), and `Popout.overlayFrame` already sizes and places a window around the glass.
What changes is the backend. Instead of handing the pieces to Liquid Glass, it draws them as the
app's glass with no frost of its own, and hands the OS the outline of the pieces that take frost.

Three things are lost against macOS 26:

- **No bending of what is behind.** The OS's blur is only a blur. No Windows or Linux API refracts
  another app's pixels (Windows' composition effects take only built-in shaders, and displacement
  is not among them;
  [composition effects](https://learn.microsoft.com/en-us/windows/apps/develop/composition/composition-effects)).
  Within fizzy's own windows that never mattered, because the app refracts its own frame. Over
  the desktop, the clear lens at the bottom of the slider (`core/gfx/glass_look.zig`) can only be
  clear: rim light, no bend. "Windows: real refraction" below is the way round it, at a cost.
- **The blur's strength is the OS's.** Windows' host backdrop arrives blurred: a Microsoft
  engineer said it is blurred "for security reasons"
  ([WindowsCompositionSamples #202](https://github.com/Microsoft/WindowsCompositionSamples/issues/202)).
  Wayland compositors choose the blur radius themselves. The slider's frost (`rough_by`) can only
  fade that blur in and out, not grow it. The user has already rejected that look once ("blurred
  everything at every point"), so the mapping needs looking at again for these platforms.
- **The outline is a frame late, or stepped.** On Windows the clip and the picture travel by
  different routes (below). On Wayland the region is in sync, but made of whole rectangles.

## Step 0 (both platforms): the glass programs compiled again — done (#242)

`core/gfx/shaders/compiled/{spv,dxil}` were last compiled in #206 (2026-10-03), and
`liquid_glass.fragment.hlsl` changed in #227, so Windows and Linux drew the earlier glass even
in-window: no lens, and not the one-slider look. #242 compiled them again with `shadercross` (the
commands are at the top of the HLSL), with the DXC SDL_shadercross vendors (libsdl-org at
2c84a1c5, built with clang: built with GCC 13 it corrupts its heap compiling DXIL). That DXC
compiles #206's HLSL to #206's SPIR-V and DXIL byte for byte. Every comparison below assumes the
programs are current.

## Windows

### What Windows gives

- **DWM system backdrops**, `DwmSetWindowAttribute(DWMWA_SYSTEMBACKDROP_TYPE)` (Windows 11 22H2+):
  Mica, Mica Alt and Acrylic (`DWMSBT_TRANSIENTWINDOW`) behind the whole window, with the frame
  extended over the client area. Corners come from `DWMWA_WINDOW_CORNER_PREFERENCE` (none, small
  or round, which are the system's radii, not any radius), and the shadow is DWM's
  ([enum](https://learn.microsoft.com/en-us/windows/win32/api/dwmapi/ne-dwmapi-dwm_systembackdrop_type)).
  DWM ignores a backdrop on a plain `WS_POPUP`. The window has to keep a caption style that
  `WM_NCCALCSIZE` collapses away, which is already how fizzy's float windows are made. The material
  falls back to a solid colour when the window is inactive, in Battery Saver, or with transparency
  turned off. This is what fizzy uses today. It covers a whole window only, and its outline is one
  of three corner radii.
- **`DwmEnableBlurBehindWindow`** has blurred nothing since Windows 8. Today it only turns on
  per-pixel alpha, which is all SDL does with it for `SDL_WINDOW_TRANSPARENT` (an empty region at
  creation)
  ([docs](https://learn.microsoft.com/en-us/windows/win32/api/dwmapi/nf-dwmapi-dwmenableblurbehindwindow)).
  The undocumented `SetWindowCompositionAttribute` Acrylic lags while dragging, and misbehaves with
  per-pixel alpha from 22H2 on: a Windows 10 fallback at most
  ([window-vibrancy](https://github.com/tauri-apps/window-vibrancy)).
- **DirectComposition**: fizzyedit/SDL already presents a transparent window's D3D12 swapchain
  through it (`docs/DEPENDENCIES.md`, SDL patch 2), as the content of the root visual on a
  **topmost** target (`D3D12_INTERNAL_SetCompositionContent`). It composites alpha correctly, but
  has no public brush that reads what is behind the window.
- **Windows.UI.Composition** (the visual layer, usable from plain Win32: a `DispatcherQueue` on the
  thread, then `ICompositorDesktopInterop::CreateDesktopWindowTarget(hwnd, topmost)`;
  [visual layer with Win32](https://learn.microsoft.com/en-us/windows/apps/desktop/modernize/ui/using-the-visual-layer-with-win32)).
  - `CreateHostBackdropBrush` paints a blur of what is behind the window: other apps, the
    desktop, fizzy's own windows. Win32 windows may use it from Windows 11 (22000) once they set
    `DWMWA_USE_HOSTBACKDROPBRUSH`
    ([brush](https://learn.microsoft.com/en-us/uwp/api/windows.ui.composition.compositor.createhostbackdropbrush),
    [attribute](https://learn.microsoft.com/en-us/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute)).
  - The backdrop can be cut to any shape by a `CompositionGeometricClip` over a
    `CompositionPathGeometry`, which can change every frame. `RectangleClip` has per-corner radii
    (a pill is a rect rounded by half its height).
  - The backdrop **cannot** be the source of a `CompositionMaskBrush`: it fails with "Unsupported
    source brush type"
    ([microsoft-ui-xaml #12063](https://github.com/microsoft/microsoft-ui-xaml/issues/12063),
    [WindowsCompositionSamples #103](https://github.com/Microsoft/WindowsCompositionSamples/issues/103)).
    An effect graph taking the backdrop and a mask surface together (as Acrylic itself mixes the
    backdrop with a noise surface) is untried.
  - It hosts a swapchain (`ICompositorInterop::CreateCompositionSurfaceForSwapChain`), and casts
    shaped shadows (`DropShadow` with a mask).
  - Its changes are committed on the dispatcher's own tick, separately from any swapchain present:
    expect up to a frame between them
    ([Makepad #1190](https://github.com/makepad/makepad/pull/1190); Avalonia applies its
    properties on the render thread just before presenting,
    [#22115](https://github.com/AvaloniaUI/Avalonia/pull/22115)).
- **Capture with self-exclusion**: `SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE)` keeps a window
  out of every capture, and Windows.Graphics.Capture or DXGI Desktop Duplication then gives the app
  what is under it, as a texture.
- **SDL**: `SDL_SetWindowOpacity` makes the window layered (`WS_EX_LAYERED`). SDL's draft "dockable
  windows" ([#16432](https://github.com/libsdl-org/SDL/pull/16432), milestone 3.6) moves a window
  with the pointer while the button is held.

Community attempts at Liquid Glass on Windows
([LiquidGlassWinUI3](https://github.com/JamesLinYJ/LiquidGlassWinUI3): host backdrop, blur, rounded
clip) confirm the pieces work. None of them merges shapes, and none refracts anything but its own
content.

### The plan

**Windows, menus and dialogs: DWM, as now.** Float windows already wear Acrylic, DWM's corners and
shadow, Snap and their own taskbar buttons. What's left is P4's list: caption buttons in the
float's header, `win32_titlebar` state per HWND, persistence, and checking the look on a real GPU
(so far the VM has only shown Acrylic's solid fallback). Menus and dialogs in windows of their own
are the cheapest native win on Windows. Each is a popup owned by the window it opened from and
never activated, framed as the floats are (a caption style collapsed in `WM_NCCALCSIZE`, which
DWM needs to draw a backdrop), with `DWMSBT_TRANSIENTWINDOW` and `DWMWCP_ROUND`: the material and
the corners of Windows 11's own menus and flyouts. `viewportOpenMenu` gains a Windows branch
through `win32_titlebar.viewportChrome`.

**Carried views and the drag's glass: one overlay, never a moving window.** On macOS a carry
window moves under the pointer, and stays in step because its frame changes in the transaction its
picture is presented in. Windows has no such transaction between `SetWindowPos` and a present, and
the plan has already seen what that costs: a window moved in one step and sized in another showed
half-done (`POPOUT_WINDOWS_PLAN.md`, "What P2 found"). So on Windows, nothing that follows the
pointer is a window that moves:

- **One overlay per display**, made when a drag starts. It is topmost, never activated, passes
  clicks through, has no taskbar entry (`WS_EX_TOOLWINDOW`) and no DWM transitions. It uses
  `WS_EX_NOREDIRECTIONBITMAP`, so a window the size of the display costs no bitmap of its own;
  only its visuals cost memory. A host backdrop hit-tests as opaque, so clicks must pass through
  by style (`WS_EX_TRANSPARENT | WS_EX_LAYERED`), not by an empty hit test. Whether that style
  leaves the composition tree alone is **(spike)**.
- **Its picture is a swapchain the size of the glass's area**, not of the display.
  `Popout.overlayArea` already keeps that area steady with room to spare, because presenting a
  display-sized picture each frame halved a drag's frame rate on macOS. On Windows the area moves
  as the visual's offset inside the overlay, not as the window's place.
- **Carry and native glass become one path.** The carried card or tab, the drop's head and tail,
  and the bubbles are all pieces in the same overlay. They are drawn by the app's `LiquidField`,
  so they merge exactly as they do in-window, over the OS's blur. macOS needs two paths because
  Liquid Glass is only on macOS 26; Windows needs only this one.

**The material under the glass: Windows.UI.Composition's host backdrop, clipped to the field.**
DWM's system backdrop can't draw a pill, a disc or a merging drop. The visual layer can. In the
overlay:

1. Under SDL's topmost DirectComposition target, a `DesktopWindowTarget` that is **not** topmost
   (`CreateDesktopWindowTarget(hwnd, FALSE)`). Whether a Windows.UI.Composition target and a
   DirectComposition target can share an HWND like this is **(spike) #1**. If they can't, the SDL
   fork gains a property that hands the swapchain to the app instead of making a target of its
   own, and fizzy hosts it in its own tree (`CreateCompositionSurfaceForSwapChain`).
2. In it, a `SpriteVisual` filled with the host backdrop and clipped by a
   `CompositionPathGeometry`: the outline of the field where it takes frost, traced each frame.
   `liquid_blob` already samples that field and runs marching squares over it, so tracing its edge
   into a path (a Direct2D path geometry, which `CompositionPath` takes) is a small step from code
   that exists. A card or tab that merges with nothing is cheaper as a `RectangleClip` with corner
   radii. A clip edge that turns out aliased **(spike)** sits under the rim light the app draws
   over it, so the clip goes a pixel inside the rim.
3. The window sets `DWMWA_USE_HOSTBACKDROPBRUSH`.

The clip is a composition property, and the glass drawn over it is a swapchain present. The two can
land a frame apart, so the blur trails the rim on a fast drag. Setting the clip immediately before
the present, as Avalonia does, makes them usually coincide. Whether "usually" is good enough is for
PresentMon and the user's eye to decide **(spike) #2**. If it isn't, there is one more thing to try,
an exact match: an effect graph that masks the backdrop with a second swapchain the app presents
alongside the picture. The shape would then change only through presents, as on macOS it changes
only in the transaction. The mask brush can't do this (above). Whether an effect graph can, and
whether it takes a swapchain-backed surface as an input, is **(spike) #3**. Effects are built from
`IGraphicsEffect` descriptions, which fizzy would implement by hand, in the same way the SDL patch
declares DirectComposition's interfaces by vtable slot.

**Windows: real refraction, if the clear lens over other apps matters.** The only way to bend
another app's pixels on Windows is to have them, and Windows does allow that. Mark the overlay
`WDA_EXCLUDEFROMCAPTURE` (Windows 10 2004+) so it never appears in any capture, and capture the
display under it with Windows.Graphics.Capture, or DXGI Desktop Duplication on the same adapter.
The app's own `LiquidField` then frosts and refracts that capture exactly as it does its own frame
in-window, the same at every point of the slider, and close to macOS 26.

It costs:
- a display-sized capture each frame while a drag is on (started at the press, and it takes a
  few frames to start);
- what is behind the glass lagging it by about a frame;
- protected content showing black;
- Windows.Graphics.Capture's border or consent prompt;
- the perception of an editor capturing the screen.

Worth a spike behind a flag. Not the default.

## Linux

### What Linux gives

What a window can ask of the desktop depends on the compositor, and in 2026 the answer has changed:

- **`ext-background-effect-v1`** is now the cross-desktop blur-behind protocol. KWin has it from
  Plasma 6.7, which dropped KDE's own `org_kde_kwin_blur` on Wayland. Mutter has it from GNOME 51
  (September 2026), so GNOME now blurs behind apps that ask
  ([Phoronix](https://www.phoronix.com/news/GNOME-Mutter-Background-Blur)). niri has it from 26.04;
  Hyprland in its development builds; COSMIC is working on it; wlroots/sway do not
  ([scenefx #136](https://github.com/wlrfx/scenefx/issues/136)).
  - One object per surface.
  - Its blur region is a `wl_region` (whole rectangles, so no radius and no anti-aliasing),
    double-buffered and applied on the surface's next commit. A region changes in the same commit
    as the picture.
  - The compositor chooses the blur's strength (Mutter's defaults: radius 24, saturation 1.25,
    a little noise; KWin: a global setting).
  - Whether compositors honour it on popups and subsurfaces is unverified.
- **No placing toplevels**, still. What a Wayland client has instead:
  - **`xdg_popup`**: placed relative to a parent and kept on screen by the compositor. Moving one
    (`reposition`, v3) waits for a configure round trip, so it lags anything that follows the
    pointer.
  - **Synchronized subsurfaces**: their position is applied with the parent's commit.
  - **The drag icon of a `wl_data_device` drag**: the compositor moves it with the pointer itself,
    so it never lags, and it never takes input.
  - **`xdg-toplevel-drag`**: drags a real toplevel. KWin has it; Mutter's is a merge request
    ([!4107](https://gitlab.gnome.org/GNOME/mutter/-/merge_requests/4107)). SDL's draft
    "dockable windows" ([#16432](https://github.com/libsdl-org/SDL/pull/16432), milestone 3.6)
    uses it, and so works on KDE but not GNOME.
  - **An empty `set_input_region`** passes clicks through.
- **X11 is going away.** GNOME 50 removed the X11 session, and Plasma 6.8 (due around 14 October
  2026) is Wayland-only
  ([Phoronix](https://www.phoronix.com/news/KDE-Plasma-68-Wayland-Exclusive)). On X11 a window
  can be placed anywhere and be override-redirect. ARGB windows are translucent only under a
  compositing manager, and input shapes (XShape) pass clicks through. KWin blurs behind
  `_KDE_NET_WM_BLUR_BEHIND_REGION`; picom blurs by its own rules. A property change reaches the
  compositor asynchronously to the present.

Others: Zed blurs on KDE and notes that rounded corners are impossible there. Ghostty and
Alacritty blur on KDE only, and Ghostty's broke when Plasma 6.7 dropped `org_kde_kwin_blur`
([ghostty #13041](https://github.com/ghostty-org/ghostty/discussions/13041)).
Qt has `KWindowEffects::enableBlurBehind`; GTK has nothing yet.

### The plan

Wayland comes first. It is the default on every major desktop, and now has a blur protocol that
both GNOME and KDE implement. It allows less than X11 in where windows go, but X11 sessions are
being removed.

**The window material, wherever the compositor has a blur.** Today the Linux window is opaque and
the app's glass knows it (`LiquidField.publishOpaqueWindow`). Where `ext-background-effect-v1` is
advertised (with `org_kde_kwin_blur` as a fallback for older Plasma), the main window asks for a
blur over its frame, not over the shadow margin in its frame insets, and publishes itself as not
opaque. The window opacity slider then means on Linux what it means on macOS and Windows. The
rounded corners are stepped rectangles a pixel high along each corner's arc, which a blur hides.
The region is surface state, so the request goes out before the frame's present (whose Vulkan WSI
makes the `wl_surface.commit`, on the same connection). A resize then changes the blur and the
picture in the same commit. Where no compositor offers it (sway, GNOME before 51), nothing changes:
the window stays opaque. At the top of the slider the window sends an empty region rather than
none, so a compositor that blurs translucent windows by default (Hyprland) does not; on KDE's own
protocol, where an empty region blurs the whole window, it unsets the blur instead.

**Wayland: popups yes, floats not yet.** A Wayland client still can't place a toplevel, so floats
stay in the main window, as decided. Menus, dialogs and tooltips, though, can leave the main
window as `xdg_popup`s (`SDL_CreatePopupWindow`), placed relative to their parent and kept on
screen by the compositor. That is the Wayland form of `viewportOpenMenu`, blurred behind where the
compositor allows it. They hold still, so the reposition lag doesn't matter. `viewportsAvailable`
stops being one switch: "can place windows" and "can open popups" become separate questions.

**Wayland: carrying a view past the window, later.** A view dragged past the main window's edge is
cut off there today. Wayland's own answer to "a picture that follows the pointer anywhere" is the
**drag icon**: the compositor moves it with no lag, it passes clicks through by definition, and the
client can redraw it every frame, so it isn't the still picture an OS drag image is on macOS.
Letting go over nothing could then open a float through `xdg-toplevel-drag`, the protocol made for
tabs torn out of browsers, once floats as windows are possible on Wayland at all. SDL #16432 is
how SDL means to get there. Both need SDL changes or fizzy's own Wayland code on SDL's
`wl_display`: SDL has no drag source on Wayland, and `start_drag` needs the serial of the press.
This is the largest Linux item, and the last.

**X11: only what is cheap.** Floats as windows already work there (behind `FIZZY_POPOUT=1`).
An overlay like Windows' would be possible: an override-redirect ARGB window with an empty input
shape, opened only when a compositing manager owns `_NET_WM_CM_S<screen>` (without one an ARGB
window is black). Its blur would be a property that lags the present. With X11 sessions going
away, this is not worth building beyond keeping what works working.

## What changes in fizzy

The seams are already in the right places. Most of the macOS work is gated on the OS at a handful
of capability flags and backend functions, and the plan fills those in rather than adding new
paths:

- **`viewports.carries`** (`backend_native.zig`, macOS only today) turns on carry windows, carried
  pictures without their place's background (`dialogs.carry_windows`), and drawing past the main
  window (`screens.publishBeyond`). On Windows it becomes true with the overlay, which serves as
  the carry window there.
- **`viewports.liquidGlass()`** is a yes/no answer today. It becomes a three-way capability:
  `none` (the app's glass in-window, as now), `os_glass` (macOS 26: the OS shapes and fills it),
  and `os_backdrop` (Windows: the app shapes it and the OS fills it). `Popout.nativeGlass` and
  `overlayFrame` branch on it. Under `os_backdrop`, `glassBase` is replaced by the app's own glass
  (`LiquidField` with no frost of its own), and the backend gets the frost's outline instead of
  `GlassShape`s.
- **`core.native_glass.Shape.frost`** already says how much blur each piece takes: all of it for a
  bubble with an icon, none for the carried view's clear lens. That decides which pieces the
  outline includes.
- **`SDLBackend.renderPresent`** has a macOS-only block that opens a transaction, applies frames,
  shapes and glass, and commits after the presents. Windows gets a block in the same place that
  sets the overlay's clip and offset right before the present. Wayland sets the blur region in
  the same place, and needs no commit of its own.
- **`viewportOpenMenu`** and `nativeMenus` / `nativeDialogs` are macOS only. Windows gets them as
  Acrylic popups, and Wayland as `xdg_popup`s, even though Wayland can't have floats as windows.
- **`viewports.os_buttons`** stays macOS only. On Windows the float's header draws
  `caption_buttons.zig`, and `win32_titlebar`'s hover and press state moves from globals to
  per-HWND state (`dwRefData`), as `POPOUT_WINDOWS_PLAN.md` "Next" already lists.
- **The ghost fade** (`viewportFade`, `SDL_SetWindowOpacity`) makes the window layered on Windows
  (`WS_EX_LAYERED`). That is untested with a DirectComposition swapchain and a DWM backdrop
  **(spike)**. The composition tree's root opacity is the alternative.
- **Calling the visual layer from Zig.** Windows.UI.Composition is WinRT: activation factories,
  `IInspectable`, `HSTRING`s. zig's MinGW headers carry no C++/WinRT, so fizzy declares the dozen
  interfaces it calls by vtable slot. fizzyedit/SDL already does this for DirectComposition, and
  `win32_titlebar.zig` already does it for DWM. The bulk is in the clip path
  (`IGeometrySource2DInterop` over a Direct2D path) and, if spike 3 is tried, the effect
  descriptions.

## Order of work

Each step is useful by itself, and the spikes come before anything that depends on their answer.

1. **Recompile the glass programs** (SPIR-V and DXIL; step 0). **Done (#242):** Windows and Linux
   draw the current lens and slider in-window.
2. **Windows: float chrome and lifecycle** (P4): caption buttons in the float header, per-HWND
   `win32_titlebar` state, minimize and close with the main window, and the look checked on a
   hardware GPU. This is what lets `float_windows` default to on for Windows, as it does on macOS.
3. **Windows: menus and dialogs as Acrylic popups** (`viewportOpenMenu`). Small, and the closest
   thing on Windows to the OS's own UI.
4. **Linux: the window material** through `ext-background-effect-v1` (GNOME 51, Plasma 6.7, niri),
   and **Wayland popups** for menus and dialogs. A protocol binding on SDL's `wl_display`, and the
   region set before the present.
5. **Windows spikes**, in a scratch app before fizzy, on a hardware GPU and on WARP, Windows 11
   23H2 and 24H2:
   1. a Windows.UI.Composition target that is not topmost, under SDL's topmost DirectComposition
      target, on one HWND;
   2. a host backdrop clipped by a path rebuilt every frame: its edge, and how far it trails a
      present (PresentMon);
   3. a host backdrop masked through an effect graph by a swapchain the app presents;
   4. the overlay's click-through and z-order with a drag in flight, and `WS_EX_LAYERED` on a
      window with a composition swapchain and a DWM backdrop.

   *Run on WARP in the Windows 11 ARM VM* (`spikes/windows-composition/`; its README has the
   numbers). All four hold:
   1. The two targets share the HWND, aligned to the pixel.
   2. The path clip is antialiased. It **leads** SDL's VSYNC present by its queue (2 frames), and
      lands exactly with a 2-frame delay or with a present that doesn't wait.
   3. AlphaMask takes a presented swapchain as its mask.
   4. Only `WS_EX_TRANSPARENT | WS_EX_LAYERED` passes clicks to other processes, the tree still
      showing; a drag keeps its capture, and `WS_EX_LAYERED` leaves both trees drawing.

   Still to see on a hardware GPU: the blur itself (the VM draws the host backdrop black) and the
   present queue's depth at real refresh rates.
6. **Windows: the overlay** (`viewports.carries`, the `os_backdrop` glass), if spikes 1 and 2
   hold (they do on WARP, the clip delayed by the present queue's depth), and with the go-ahead
   `NATIVE_WINDOWS_PLAN.md` asks for (its Phase 2). If they don't, the fallback is the overlay
   with the app's glass and no OS blur under it.
   That still carries a view past every window, which is the part users will notice most.
7. **Optional: real refraction on Windows** through capture, behind a flag, if the clear lens over
   other apps turns out to matter.
8. **Wayland carry** through the drag icon, then `xdg-toplevel-drag` (or SDL #16432) for floats as
   windows on KDE.

## Still open

- **What "native" should mean on Windows** is settled in `NATIVE_WINDOWS_PLAN.md`: Mica for
  long-lived windows at the top of the slider (Windows Terminal's mapping), Acrylic for transient
  surfaces (menus, carries, and the overlay if Phase 2 goes ahead).
- **The slider where the OS owns the blur.** On Windows and Wayland the frost's strength is fixed,
  so the lower half of `glass_look`'s slider (clear lens to whole frost) needs its own mapping
  there, or a decision that those platforms start at frost.
- **Mixed DPI.** Every viewport uses the main window's density (`POPOUT_WINDOWS_PLAN.md`, P5). A
  per-display overlay makes this matter sooner, as soon as one spans a second display.
