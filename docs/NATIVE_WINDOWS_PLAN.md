# Native windows: fizzy's backend between SDL and dvui

Floats became OS windows (#223), and a carried view became a window of its own for the whole drag
(#224). That moved the drag's glass out of the app's shader and into the OS. On macOS 26 the OS
glass is Liquid Glass, and it can look and move like Control Center's, but only if fizzy controls
its windows more closely than SDL alone lets it. This plan covers three things:
- what Liquid Glass can do for fizzy, as measured;
- how the drag's glass (the carried bubble and the drop zones) becomes one native liquid on
  macOS 26, and what other platforms do instead;
- how fizzy's backend grows into the layer between SDL and dvui that owns its windows, while still
  taking SDL's releases.

**The principle (the user's, 2026-10-05):** where the OS has Liquid Glass, fizzy uses it as much as
it can, safely. Private API is acceptable when it has proved stable and is built to fall back
gracefully when it is missing. Every platform gets as close to that glass as it can. Underneath,
fizzy supports the whole range from opaque through blurred to glass, takes each platform's newest
features optionally, and breaks nothing where they are missing.

Related: [`POPOUT_WINDOWS_PLAN.md`](POPOUT_WINDOWS_PLAN.md) (viewports, bands, per-OS dressing) and
[`DEPENDENCIES.md`](DEPENDENCIES.md) (the SDL, sdl_zig and dvui-dev forks and their patches). The
backend review of 2026-10-04 is folded in at the end ("From the 2026-10-04 review").

## Where it stands

- **Fizzy draws through its own backend** (`src/backend/native/`, about 8,300 lines): `SDLBackend`
  (windows, events, presentation), `GpuRenderer` (SDL_GPU), `viewport_map` (bands: each float
  window's part of one frame), and `platform/`. That last part holds the title bar hit tests, the
  per-OS window monitors, the dialogs and menus, and the AppKit code in `platform/macos/*.m`. dvui
  runs in its `custom` backend mode and knows none of this.
- **SDL creates every window.** Fizzy then reaches the native window through SDL's properties
  (`SDL_PROP_WINDOW_COCOA_WINDOW_POINTER`, `..._WIN32_HWND_POINTER`) and dresses it:
  - a style, a skin and the material behind it (`platform.window`, `visual_effect_view.m`);
  - title bar hit testing, by replacing SDL's view class's `-mouseDownCanMoveWindow` at runtime
    (`fizzy_macos_titlebar_hit_test_install`);
  - placement in Core Animation transactions with the frame (`renderPresent`).
- **SDL carries six fizzy patches** (`DEPENDENCIES.md`): transparent window claims, DirectComposition
  presentation, presenting inside a Core Animation transaction, live resize (two patches), and
  Wayland frame insets.
- **Native materials so far:**
  - vibrancy (`NSVisualEffectView`) behind the main window and float windows;
  - Liquid Glass (`NSGlassEffectView`) in the carry window on macOS 26 (#224);
  - Acrylic behind the window on Windows (`win32_titlebar.zig`).

## What Liquid Glass does (measured on macOS 26.5, 2026-10-05)

Throwaway AppKit programs put glass over a striped pattern and captured the screen:
- **The public styles are both frosted.** `Regular` renders dark and `Clear` light. Neither
  refracts: what's behind is blurred past recognition, in a window and from a separate window alike.
- **One of the private variants is a lens.** `_variant` (default 2) chooses the glass:
  - **11** is clear, unblurred and refracting. It bends and magnifies what's behind it toward its
    rim, like a drop of water, and it ignores `tintColor`.
  - **6** is a bright frost with a strong rim.
  - **13** draws no glass at all.
  - The rest are frosts of varying darkness.
- **The lens refracts across windows.** A glass view in a transparent window refracts the window
  beneath it, so the window server does the lensing, not the app. That is how Control Center's
  tiles refract the desktop.
- **It refracts Metal.** In a window, glass over a `CAMetalLayer` reads what Metal drew, so it works
  over fizzy's own frame.
- **It merges.** `NSGlassEffectContainerView` runs its glass views together where they come within
  its `spacing`. Two circles 16 points apart with a spacing of 40 joined with a liquid bridge, over
  AppKit content and over Metal alike. This works only within one window.
- **It follows its window.** A glass window resized every 8 ms was its window's size in every
  capture.
- **It is SwiftUI inside** (`NSGlassEffectView` hosts an `_NSCoreHostingView`). Setting its private
  enum properties by key-value coding with an unexpected value can kill the process with a Swift
  fatal error. Set them only through their typed setters (`set_variant:`), with measured values.

What this means:
- **The look you see in Control Center is reachable**, but through a private variant. #224 gives
  the carried bubble the lens (11), set only on macOS 26 and only where the setter exists. The
  variant numbers could change in a later macOS, and a renumbered 11 could even draw nothing
  (as 13 does). Each new macOS needs the variants measured again before the version gate moves.
- **Merging needs one window.** The bubble and the drop zones can merge as Liquid Glass only if
  they are glass views in the same window. Today the bubble is its window and the drop zones are
  the app's shader, so they cannot.
- **What isn't known yet:** Control Center's exact material. It may be a variant plus a subvariant
  (`_subvariant` is a string whose values aren't known), or a tint over the lens. Next is matching
  it by eye against captures.

## The drag's glass on macOS 26: one overlay of Liquid Glass

**Built** (the prototype after #224, on by default where Liquid Glass exists; `FIZZY_NATIVE_GLASS=0`
keeps the app's glass). One display only so far: the main window's.

During a view drag, one transparent overlay window lies over each screen the drag can reach. It is
the carry window grown to its screen: passive, at the pop-up menu level, joining full-screen Spaces.
In it:
- **An `NSGlassEffectContainerView` holding a pool of glass views.** These are the carried view
  (the drop's head and its tail, or a card or tab) and every drop-zone bubble that is showing,
  whether over the main window's places or over float windows. Each is placed every frame from the
  shapes the frame already computes, which draw nothing in the app while the OS draws them: they
  are declared to `core.native_glass` instead (`DropZones.draw`, `ViewDrag.drawDrop`). The
  container's `spacing` is the drop zones' merge distance (24 points), past the 16-point gap
  between a wheel's bubbles, so they run partly together (the user's choice), the head pulled
  toward the bubble it is aimed at bridges into it, and the head and its springy tail merge into
  the wobbling drop. The aimed bubble lights in fizzy's fill over the glass (below): lit with the
  glass's pressed look (`_interactionState`), it never ran together with the drop snapped onto it
  (measured).
- **Their whole life is the OS's glass:** growing out of the drop and pinching off, and running
  back together after the drag. The overlay stays until the last bubble has gone; handing the
  going back to the app's glass showed them switch material as they left.
- **SDL's Metal view above the glass**, as in today's carry window. It shows what only fizzy draws:
  the carried photograph and the drop zones' icons.
- **Placement and picture in one transaction.** The glass views' frames are set inside the Core
  Animation transaction the overlay's Metal picture presents in (`presentsWithTransaction`, SDL
  patch 3), so glass and picture move together.
- **Nothing of it in the app's windows.** While the overlay shows, the main window and float windows
  draw no drop glass and no carried view. This is #224's rule: nothing in the app follows native
  glass, unless all of it is the app's.
- **Opening a float out of it:** the carried glass grows to the new window's frame, then the window
  shows, as #224's growth does now.

Risks to measure in the prototype:
- the cost of a screen-sized Metal drawable during a drag, which is mostly clear;
- the cost of dozens of glass views re-placed every frame;
- whether merging and lensing keep up at 120 Hz;
- several screens, Stage Manager and full-screen Spaces;
- the private variant going away (then the overlay falls back to the public Clear style, or to
  today's app-drawn drag).

## Other platforms: simpler, and back into the window when over one

Windows, X11, Wayland and the web have nothing like Liquid Glass to merge.
- **Over a window, the drag is the app's own glass** (`core.LiquidField`). The bubble merges with
  the drop zones as it did before #224.
- **Outside every window**, it is a carry window with a simple material: Acrylic on Windows, and
  translucent on X11. Wayland and the web have no carry window, and floats stay in the window.
- **Crossing a window's edge hands the bubble between the two.** That hand-off is accepted there.
  The capability decides which path runs (`viewports.carries` today, a glass capability tomorrow);
  the platform's name does not.

## Floating surfaces: native popup windows that fizzy draws

**Decided (the user, 2026-10-06):** a context menu is an OS popup window with fizzy's own menu
drawn in it — not `NSMenu` or a Win32 menu, and not a fizzy overlay inside the main window. The OS
gives it its shadow, corners, material and stacking; fizzy gives it its look and behaviour, the
same on every platform. Menus first, then the menu bar's dropdowns, tooltips, popovers and, in
time, dialogs.

**The window:** an SDL popup window (`SDL_CreatePopupWindow`, `SDL_WINDOW_POPUP_MENU` or
`SDL_WINDOW_TOOLTIP`), parented to the window the menu opens from — the main window or a float's
own. SDL places it relative to its parent and keeps it above, on every platform; on Wayland it is
an `xdg_popup`, the one way an app may place a window there, so menus can leave the main window
even where floats cannot.

**Its material, per platform:**
- **macOS 26:** the window glass pair (`fizzy_macos_window_liquid_glass`), its frost reaching the
  edge, the transient role on the slider; before 26, vibrancy.
- **Windows 11:** DWM Acrylic (`DWMSBT_TRANSIENTWINDOW`) with round corners
  (`DWMWCP_ROUND`) — Microsoft's own role for transient surfaces. Windows 10: opaque, or the in-app
  frost.
- **Linux:** the compositor's blur region (`ext-background-effect-v1`, `org_kde_kwin_blur`) where
  it offers one, the menu's colour over it; opaque where it does not.

**Drawing it:** the menu stays a dvui subwindow in the one frame. Its drawing is taken out of the
frame and copied into its popup, as a float's window already takes the menus opened in it
(`Popout`), and input on the popup maps back into the frame at the menu's place. Out of the main
window's rect, the menu is drawn in the frame's band past it, as floats are.

**Placing it:** with popups, a menu is kept on the display, not the window: the app publishes the
display as a screen (`core.screens`), so a menu near the window's edge hangs past it rather than
flipping inward.

**Following its window (built on macOS, #227).** A menu of the main window's is the main window's
child window once it shows (`SDL_SetWindowParent`), so the window server moves it with the main
window, smoothly through a drag that fizzy's frames could only follow a frame behind; the app
re-places it only when where it lies over the main window changes. AppKit drops a child to its
parent's level, so a menu's is set back to a popup's. A menu opened in a float that is out is
drawn where it opened in the float's band and cannot follow the float's window; it closes when that
window moves, as an OS menu closes on a press outside it. Where a platform cannot attach a menu to
its window, the same rule applies to the main window: the menu closes when the window moves.

**Dialogs (built on macOS, #227).** Every `core.dialogs` dialog goes the same way, ahead of the menu
bar's dropdowns and tooltips: its own OS window, never focused (the main window keeps the keyboard,
dvui routes keys to the dialog), the pointer read in the main window's frame, its window the main
window's child, at the main window's level rather than a popup's, other apps' windows going over
both. It draws no dim, frost, shadow or fill of its own, the main window is left undimmed, and its
window fades as it flies shut. dvui draws dialogs at the very end of the frame, after the app takes
subwindows into their windows, so `core.dialogs.drawEarly` draws fizzy's dialogs first and
`dialogWindow` skips any it drew when dvui's pass reaches it. A setting, "Native dialogs", beside
"Native menus".

**A dialog belongs to the window it opened in (the user, 2026-10-06).** It is stacked with that
window and no other: a dialog of the main window's sits over the main window and under the floats
kept above it, and a dialog opened in a float that is out opens over that float, as its child
window, and travels with it. The float's window moving, the dialog is put where it lies over the
float as before (`Popout.dialogsRide`) and the OS carries its window there; its float closing,
the dialog comes back over the main window (SDL destroys a window's children with it, so the
backend lets riders go first). Sized and kept on the display, not the float, since its window is
its own (`screens.dialogScreenFor`).

**Open:**
- keyboard focus — whether the popup takes it (Wayland's grab does) or the parent keeps it and
  forwards keys to the menu;
- dismissal when the app deactivates, and on a press in another of fizzy's windows;
- several displays; and menus opened from a float out over the desktop.

## The backend as the layer between SDL and dvui

**The split.**
- **SDL** does the portable plumbing: the event pump and input devices, the GPU device and
  swapchains (SDL_GPU), clipboard, IME, displays and file dialogs.
- **Fizzy's backend** owns window policy and composition:
  - which windows exist (main, floats, carry and overlay);
  - how they're dressed (title bars, materials);
  - native layers (glass shapes and groups);
  - presentation transactions;
  - hit testing and drag regions;
  - bands and input routing;
  - each OS's window monitor.
- **dvui** sees only its backend interface.

**Native layers, as an interface of the backend.** Glass is declared each frame by id, and the
backend reconciles it with the platform, as dvui does with widgets:
- `layers.glass(id, window, shape, material, group)`;
- materials are `window` (vibrancy, Mica, Acrylic), `frost`, `lens` and `clear`;
- a group merges where the platform can, and `layers.supports(.merge, .lens, …)` tells the caller
  whether to fall back to app-drawn glass.

**The seam stays outside the SDK.** Shapes reach the backend through `core` (as `core.screens`
does, in dvui's data), so plugins drawing drop zones or dialogs reach native glass with no SDK
change.

**One `WindowChrome` per OS window** (from the review). The main window, a float's window, the
carry window and the overlay each want a hit test, corners, a material, a shadow and a title bar
policy. Today the main window's state is file-level globals and a float's is `Viewport` fields; on
Windows they have two subclass procs, and two hit tests answer one question
(`titlebar.hitTest`, `viewport_map.hitTest`). One `platform.Chrome` per window holds all of it —
one SDL hit-test callback with the `Chrome` as its data, one Win32 subclass with it as
`dwRefData`, per-window Objective-C state as an associated object on the `NSWindow` — and the
native layers (above) are the `Chrome`'s too: a window's material and its glass are one thing. The
macOS half is partly done: #223 gave the main window and floats one monitor, one style and one skin.

**Where SDL owns the code path, fix it in SDL; where it is policy, do it in fizzy over native
handles** (the review's rule, which this plan takes in place of its first draft). The first draft
had fizzy create its own `NSWindow` and view for SDL to adopt (SDL3 does take one:
`SDL_PROP_WINDOW_CREATE_COCOA_WINDOW_POINTER` / `_VIEW_POINTER`, `_WIN32_HWND_POINTER`, … — SDL
marks it `SDL_WINDOW_EXTERNAL` and adds its Metal view inside the view given). That stays the
fallback for a behaviour neither way can reach. The patches that earn their place:
- **Cocoa: resize and pixel-size events during Space and zoom animations.** SDL holds them back;
  that is why `window_monitor.m` runs a 60 Hz pump and `macos_monitor.zig` calls two private SDL
  functions (`SDL_SendWindowEvent`, `SDL_OnWindowLiveResizeUpdate` — a rename breaks the build, a
  change of meaning breaks it silently). Reads as a bug fix upstream.
- **Cocoa: the window's hit test decides `-mouseDownCanMoveWindow`** for full-size-content windows,
  in place of fizzy replacing that method on SDL's view class at runtime
  (`fizzy_macos_titlebar_hit_test_install`). Today it answers from where the cursor is when AppKit
  asks, which is where the reported "float dragged over the main title bar" misbehaviour lives.
- **Win32: a "client area is the whole window" creation property, with caption-button hit-test
  results** (`HTMINBUTTON`, `HTMAXBUTTON`, `HTCLOSE`), and SDL leaving `WS_SYSMENU` alone. The
  subclass shrinks to backdrop attributes and hover tracking.
- **Wayland and X11: double-click on a draggable region toggles maximize** (only SDL sees the
  clicks).
- **Wayland: a blur-region property** (`ext-background-effect-v1`), next to the frame insets
  already carried — once compositors support it.
Materials, glass views, vibrancy, DWM attributes stay fizzy's: stable OS API over native handles,
where a C patch would be rebase cost for nothing.

**Keeping up with SDL.**
- **Patches only where SDL owns the path,** each proposed upstream (DEPENDENCIES.md rule 4). The
  first to propose is patch 1 (a transparent window's claim): one moved check that every other
  transparent-window patch sits on.
- **A standing check.** A scheduled CI job rebases fizzy's SDL patch stack onto SDL's latest
  release and builds fizzy against it. A conflict or a break shows up the week it happens, not at
  the next bump. Less often, the same job runs against SDL's `main`.
- **Each patch has an acceptance test.** DEPENDENCIES.md names, for each patch, how to see that it
  still works (`scripts/live-resize`, a transparent window's claim, Acrylic through DComp). A bump
  is done when those pass.
- **A cadence.** Fizzy takes each SDL point release within a few weeks, tagging each step
  `fizzy-<sdl version>-<n>`, as now.

## One material, one slider

Everything fizzy draws as glass — the drag's bubble and drop zones, floats, dialogs, popovers,
menus, tooltips, and the main window itself — is one material, set by one slider (the window
opacity, the user's design, 2026-10-05). It runs from fully clear refracting glass, through blur
with the window's colour tinting in, to opaque in the window's colour. The app works at any point
on it, opaque included, and its glass still merges and moves at every point.

**Two forms of every glass surface,** on the same slider, so a surface looks the same in either:
- **In-app:** fizzy's own glass shader, kept (the user: "I don't want to trash our in-app glass"),
  for surfaces drawn inside a window, for the web, and for every platform without native window
  glass. It is tuned to look like macOS's Liquid Glass on the same slider — a clear lens at the
  bottom that magnifies toward a thin bright rim, frost rising with the window's colour, the shine
  kept until the top — so a surface looks alike in either form. Its parameters are continuous:
  refraction kept, blur radius from 0 up, tint mix toward the window's colour from 0 to opaque.
- **Native:** the OS's glass, for surfaces that are OS windows of their own — float windows, the
  carry window, the drag's overlay, and dialogs, popovers and menus moved into windows — where the
  OS has it (Liquid Glass, macOS 26).

****Native where the OS has it, in the OS's own style.** Windows' glass is not macOS's, and fizzy
should look like a Windows app there, not imitate macOS: each platform maps the slider onto its own
materials (below), and the library that does it stays small — one interface, a short file per
platform, the in-app glass behind it all.

**The native way along the slider (built for the drag's glass in #227, measured).**** Liquid Glass
has no blur to turn, only variants, so the way is a blend:
- the clear lens (variant 11) is drawn whole, and frost (Clear) comes in over it late in the
  slider, faded out toward each piece's edge by a radial mask, so the rim stays the clear lens
  with its bright light and only the middle frosts, as the app's own glass does (the user's ask);
- two layers of the same pieces do it, and stay one outline while they do;
- the window's colour is under the glass, as native shape layers beneath it with necks where
  pieces run together, so the glass bends and lights it and keeps its shine; drawn over the glass,
  it muted the shine all the way up (the user);
- only in the last tenth of the slider does the glass go, handing over to the colour drawn flat
  and opaque over everything in the merged shape (`core.liquid_blob.fill`);
- a lit piece is lit in the colour under the glass, never with the glass's pressed look, which
  stops it merging.

`Popout.glassLook` holds that mapping today; it moves into `core` as the app's one material
description, read by both forms.

**Native menus.** On macOS 26 AppKit's own `NSMenu` is already Liquid Glass, with the OS's keyboard
handling and accessibility. That is the native form of a context menu: right-click opens an
`NSMenu` built from the same menu model. Its material is the OS's, not on fizzy's slider. A menu
fizzy draws itself, in an OS window on the native material, is the other way, kept for menus
`NSMenu` cannot express.

**Per platform**, in each platform's own style: see "The materials library" below.

- **The main window takes the same material** where the OS has it: an `NSGlassEffectView` pair
  behind SDL's view in place of vibrancy, the fill over it per the slider. Float windows, the carry
  window and the overlay already sit beside SDL's view that way, so the main window moves to the
  float's view structure (the review's advice too: no responder-chain repair).
- **Accessibility wins over looks.** macOS "Reduce transparency"
  (`accessibilityDisplayShouldReduceTransparency`) and Windows "Transparency effects" off put the
  slider at opaque. "Reduce motion" (`accessibilityDisplayShouldReduceMotion`,
  `SPI_GETCLIENTAREAANIMATION`, the GTK setting) turns the glass's growth, merging and wobble into
  fades. Natively `SDLBackend.prefersReducedMotion` returns false today (the review).
- **Capabilities, not platform names.** A backend declares what it can (`fizzy_ext`): `liquid_glass`,
  `lens`, `merge`, `carry_windows`, which materials it offers. The app picks the best one offered
  and falls back without breaking anything.

## The materials library

The user's brief (2026-10-05): a backend library that matches this look across operating systems
*in their native look* — "Windows has some glass, but it's not the same as macOS" — kept small
enough to maintain while each platform is supported on its own terms. Three studies (Windows,
Linux, the in-app glass against Apple's) shaped what follows; their findings are summarised per
platform below, with what to build and what to skip.

### One vocabulary

- **Inputs:** a surface's **role** — `window` (the main window, a float's window), `transient`
  (menus, popovers, tooltips), `carry` (the dragged bubble), `drop` (drop zones), `scrim` (dimming
  under a modal) — the **slider** `t` (0 clear … 1 opaque), and the **policy** each platform
  probes: transparency allowed (macOS Reduce transparency, Windows Transparency effects / energy
  saver / high contrast, Linux portal `contrast`), reduced motion.
- **Output:** each platform's **realization** of that role at that point: the OS material behind
  the window (or none), the window colour's opacity, whether the OS draws glass shapes itself (the
  overlay), and otherwise the in-app glass's parameters.
- **One pure module, `core/gfx/glass_look.zig`,** unit-tested: the slider's breakpoints, the native
  mapping (today `Popout.glassLook`), the in-app mapping (`inAppLook`), and role adjustments — a
  surface carrying text keeps a minimum of frost, so a dialog over a clear lens still reads.
  Policy off means `t` = 1.
- **Capabilities, not platform names:** a backend declares what it can (`liquid_glass`, `lens`,
  `merge_overlay`, `window_backdrop`, `blur_region`, `carry_windows`); the app picks the best one
  offered and falls back without breaking.

### Each platform's realization

**macOS 26 — Liquid Glass (built for the drag in #227).**
- Every role on Liquid Glass: the lens crossfading into frost, the window colour under the glass.
- The drag's bubble and drop zones merge in the overlay.
- Float windows and the main window take a glass pair behind SDL's view.
- Context menus are popup windows of Liquid Glass with fizzy's menu in them ("Floating surfaces"
  above) — chosen over `NSMenu`, which would be Liquid Glass already but not fizzy's menu.
- Before macOS 26: vibrancy plus the colour, no merging, the drag in the app's glass.

**Windows 11 (22H2+) — DWM materials, Terminal-style.** Windows has no lens and no merging, and
Microsoft has said it will not get a Liquid Glass-style change.
- **Native vocabulary:** Mica for long-lived windows, Mica Alt with tabbed title bars, Acrylic
  only for transient surfaces (Microsoft: "don't put desktop acrylic on large background
  surfaces"), Smoke under modals.
- **The slider along DWM's backdrop types** (`DWMWA_SYSTEMBACKDROP_TYPE`), the way Windows
  Terminal maps its opacity setting:
  - low end: no backdrop, the desktop sharp through the window's alpha, the colour rising;
  - middle: Acrylic (`TRANSIENTWINDOW`) under the colour;
  - top and default: Mica (`MAINWINDOW`) under the colour, which is Windows' native opaque window
    and its inactive-window cue.
  There is a visible step where the backdrop type changes; only Windows.UI.Composition could
  remove it.
- **Roles:**
  - window and float: as above;
  - float windows inactive while the main window has focus are shown solid by DWM, so Fizzy's
    windows act as one activation group (`WM_NCACTIVATE(TRUE)` to the floats, as PowerToys does);
  - transient: Acrylic (in-app acrylic-styled glass inside a window, a DWM Acrylic window
    outside it);
  - carry: a carry window with Acrylic and DWM's round corners;
  - drop: the in-app glass styled as acrylic (blur, tint, noise, 8 px corners, no merging);
  - scrim: Smoke, and dialogs as opaque 8 px cards.
- **Policy probe:** `EnableTransparency`, `SPI_GETHIGHCONTRAST`, power saving status, refreshed on
  `WM_SETTINGCHANGE` and `WM_POWERBROADCAST`. DWM goes solid on its own under them, but Fizzy's
  own alpha and glass do not, so Fizzy clamps `t` itself.
- **About 150 lines** in `win32_titlebar.zig`. Today's main window uses Acrylic for its
  background, against Microsoft's guidance; it moves to Mica at the top of the slider.
- **Phase 2, only with a go-ahead:** per-shape glass over the desktop and a continuous blur
  through Windows.UI.Composition (`SpriteVisual`s with a backdrop brush and geometric clips, on a
  non-topmost target under SDL's DirectComposition swapchain). Roughly 1,000 lines of hand-written
  WinRT interop, an untested layer rule, and a one-frame skew against SDL's presents.
- **Skip:** the undocumented `SetWindowCompositionAttribute`, the Windows App SDK, the 21H2 Mica
  hack, OS blur on Windows 10 (alpha only there, or opaque), refraction and merging.

**Linux — the compositor's blur, where it offers it.**
- **The protocol:** `ext-background-effect-v1`, in KDE Plasma 6.7+, GNOME 51 (Mutter), Hyprland
  0.56+, niri 26.04+ and COSMIC. Plasma 6.6 and older (Kubuntu 26.04 LTS, to 2029) use KDE's own
  `org_kde_kwin_blur`.
- **Blur only:** no tint, no strength — strength is the user's compositor setting — so along the
  slider "more blurred" becomes "more tinted":
  - an empty region at the top, so the compositor does no work (and Hyprland's default blur of
    translucent windows is cancelled);
  - the window's rounded rect blurred below that, the colour's opacity following `t`.
- **Attached by Fizzy, no SDL patch,** in about 200–250 lines:
  - borrow SDL's own libwayland (`dlopen` with `RTLD_NOLOAD`) and its `wl_display`;
  - bind the protocol on a private event queue;
  - set the region in the commit SDL's Vulkan present makes;
  - check the capability bit's value (wayland-protocols 1.45 declared it wrong).
- **Where it cannot:** Sway, labwc and GNOME 50 and older have no blur, and the slider clamps to
  opaque. On X11, check `_NET_WM_CM_S0`: with no compositor the window is opaque and has no shadow
  margins.
- **Bubbles and drop zones are always the in-app glass:** there are no overlay windows on
  Wayland, and nothing on Linux lets an app refract the desktop.
- **Policy:** the XDG settings portal's `reduced-motion` and `contrast` (through libdbus, as SDL
  reads the colour scheme). There is no reduce-transparency key, so high contrast stands in.
- **Skip:** KDE's retired contrast protocol, X11 blur atoms (KWin X11 ends early 2027), and
  per-compositor tuning.

**Web — the in-app glass,** with `prefers-reduced-motion` and `prefers-reduced-transparency`.

### The in-app glass, tuned to Apple's

The app's glass stays, and is the form wherever no native glass exists. Measured against Apple's
lens, it differs mostly in one place: **Apple's lens pulls the backdrop inward from a band near the
rim** (about 29% of the radius), magnifying it and folding it into a mirrored, darker band just
inside the edge, with the middle sharp and unblurred. The app's glass pulls from outside the edge
instead (`liquid_glass.zig`: shrinking, never folding — an inward pull was once tried and rejected
for its mirror line, which is exactly Apple's look).

The work:
- **Shader:** an inward bevel displacement, a band shade, a brighter rim line with a slight
  colour fringe, and signed bevel shading that survives a full tint. That is four copies changed
  together: GLSL (the web compiles it too), Metal, HLSL and the CPU `sample`. It fits the uniform
  slots already there.
- **Cheaper:** an inward pull needs almost no capture margin (today about 2.2× a pane's pixels),
  and a clear lens can skip the blur pyramid entirely (about five render-target switches per pane
  today).
- **One slider:** the in-app glass reads `glass_look.inAppLook(t)` on the same breakpoints as the
  native glass. The separate dialog glass settings become optional advanced overrides; saved
  settings still load, since unknown keys are ignored.
- **Defaults move:** light and dark themes default to different slider values, so each starts at a
  different point on the trip.

### Keeping it small

- **One file per platform's realization, under about 300 lines each,** behind one interface:
  `apply(window, role, look)`, `probePolicy()`, `capabilities()`. The pure mapping and the role
  tables are unit-tested.
- **No per-compositor or per-build tuning.** Platforms are told apart by capabilities. Nothing
  needs an SDL patch.
- **Anything that grows past that** — Windows composition, X11 blur — is a separate phase with its
  own go-ahead.

## The first plugin consumer: pixi's dropper orb and floating buttons

The user's candidate for strengthening the library (2026-10-05), because it is the first time a
plugin, not fizzy, draws glass of its own.

**What it should be:**
- **One liquid layer.** pixi's round glass buttons floating at the canvas window's corner
  (`widgets/glass_button.zig`) and its colour-dropper magnifier.
- **The orb.** While the dropper is active, the magnifier is an orb of glass floating round the
  pointer: refracting at its rim, and in its middle pixi's own pixel-exact zoom of what is under the
  pointer, with just the crosshair.
- **The animation.** The orb pinches off the magnifier button when the dropper starts, follows the
  pointer on a spring, and runs back into the button when it ends. Wherever it overlaps the
  buttons, they merge.
- **Everywhere.** It works in float windows too. Today the magnifier does not; pixi's fix for its
  floating surfaces is on its unpushed branch `claude/popout-screens` (`3b0aecf`).
- **Its logic** (`FileWidget.drawSampleMagnifier*`) is the user's own, from earlier, and wants
  redoing anyway.

**What the library needs for it** — each piece general, not pixi's:
1. **Glass outside drags.** The native overlay opens whenever any glass is declared, not only for a
   view drag, and closes when none is. Declarations carry a **group**: pieces in one group merge
   (pixi's buttons and its orb), pieces in different groups do not (pixi's controls and fizzy's drop
   zones). Natively that is one container per group; in the app, one `LiquidField` per group.
2. **Content over the glass, from any code.** Today only the carried view and the drop icons reach
   it, through `core.screens.markCarried`. A small `core.native_glass` call for "draw this over the
   glass" generalizes it: natively the overlay replays that layer above its glass, as it does now,
   and in the app it is simply drawn after the glass. It is how the orb's zoom and crosshair sit
   crisp inside the glass.
3. **A magnifier look.** The orb's middle shows pixi's zoom, not the lens's own magnification, and
   the glass bends only its rim band: the in-app look with the frost at 0 and the band clear, and
   natively the lens with pixi's picture over its middle (as the carried photo is over the
   bubble's).
4. **Motion from core:** the orb on a `core.Spring` toward the pointer; the pinch-off and merge are
   the group's own merging as the orb and the button come apart and together.
5. **Plugins reach all of it through `core`:** both the declarations and the over-glass layer
   travel in dvui's shared data, as `core.screens` does, so a plugin dylib's glass reaches fizzy's
   overlay with no new SDK call. A change to `core` still means rebuilding pixi against the matching
   SDK, and a release to the store.

## Screen-edge tiling for a carried view

The user asked for a carried view dragged to a screen's side or top to tile as a window would. The
OS tiles only a window the window server itself is dragging — a title bar drag — and the carry
window is placed by fizzy each frame, so the OS never offers it. Handing the drag to the OS
(`performWindowDragWithEvent:` on a real window) would cost fizzy the pointer: no drop zones, no
coming back into a window. So fizzy tiles it itself, the way the OS does:
- **Zones at the screen's edges and corners** — left/right halves, top fill, the four quarters —
  read against the display's usable frame (below the menu bar, beside the Dock), with the system's
  "tiled windows have margins" setting on macOS and Snap's layout on Windows.
- **A preview in glass:** the zone's rect as one more piece of the overlay's glass, the carried
  drop running into it as into a drop zone.
- **Let go there,** the float opens at that frame, growing out of the drop into it as now. From
  then it is an ordinary window, and the OS's own tiling works on it.

## Steps

1. **Done in #224:** the carried bubble is a window of Liquid Glass on macOS 26, a lens on a fifth
   of the base; a float's window grows out of it from its top left and shows only once the glass
   is its size; the lifted place keeps its base; no move cursor over a float's traffic lights.
2. **Built (#227):** the drag's glass as one overlay of Liquid Glass (above), on by default on
   macOS with floats as windows, and on the slider from clear to opaque. Next on it: several displays, measuring its frame cost and merging at
   120 Hz, matching Control Center's material, screen-edge tiling.
3. **Clean the backend first** (the review's steps 1–2, no behaviour change): delete
   `SDLBackend.zig`'s dead SDL2 arms, `initWindowSecondary`, `WindowGeometry`; split it by job
   (backend, events, viewports, app main, live-resize trace); break the `platform`/`backend` import
   cycle and have `platform` take `*SDL_Window`; one `native.cocoa(window)` / `native.hwnd(window)`;
   declare `fizzy_ext` in place of `@hasField` probing; `Viewport` methods with one null type in
   place of the forwarders in `backend_native.viewports` (the prototype added six more); `zig fmt
   --check` in CI.
4. **`WindowChrome`** for the main window, then floats, carry and overlay: one hit test (std-only,
   unit-tested first), one Win32 subclass, no file-level state; materials and native layers on it.
5. **The materials library** (above), in this order:
   - **built (#227):** `core/gfx/glass_look.zig` with the native and in-app mappings, and the
     in-app glass tuned to Apple's (the inward lens in GLSL, Metal and HLSL), on the slider. Still
     to do: rebuild the SPIR-V and DXIL with shadercross, so Vulkan and D3D12 draw it too; skip the
     blur pyramid for a clear lens, and the outward capture margin once the old programs are gone;
     the separate dialog glass settings as advanced overrides;
   - macOS: **built (#227)** the main window and float windows on Liquid Glass (the colour under
     the lens and frost, beside SDL's view, on the slider) with a compact toolbar's 20-point
     corners (measured: none 17, compact 20.5, unified 27 — the user chose compact); still to do,
     context menus as popup windows (below);
   - Windows: the DWM mapping, roles and policy probe;
   - Linux: the blur region and the portal.
6. **Floating surfaces as native popup windows that fizzy draws** (above): context menus first —
   the popup viewport, the menu copied into it, input mapped back, the display as its screen — on
   macOS, then Windows (Acrylic) and Linux (the blur region); then the menu bar's dropdowns,
   tooltips and popovers.
7. **Native layers as the backend's interface,** from the overlay: the drag's glass, then every
   native-form surface.
8. **The other platforms' path:** where native glass can't merge, the bubble is the app's glass over
   a window and a carry window outside them.
9. **The SDL patches above,** then deleting the 60 Hz pump and the private symbols; the scheduled
   rebase-and-build job; upstream PRs.
10. **Peer or palette** (open question), then window-local coordinates for settled viewports — which
   also gives Wayland settled floats and mixed DPI a path.
11. **Packages** (the review's shape): `tape` alone, `replay`, `window` (backend, renderer, platform,
   viewports), `app` (layout, floats, pop-out orchestration and the glass overlay — `Popout` moves
   out of `src/editor/`), with an app's own `main`.

## Open questions

- **Private API: answered.** Acceptable while stable and built to fall back (the user, 2026-10-05):
  gated on a measured macOS version and on each setter, with the public style behind it.
- **Peer or palette.** The review recommends floats as peer windows by default (the main window can
  come in front, each has its own Dock/Alt-Tab entry, as VS Code's and browsers' tear-offs) with a
  per-float "Keep on top" done natively. Today a float is kept over the main window (#224 restored
  that after the user saw one behind it at launch).
- **Colour.** The Metal layer is untagged (`layer.colorspace = nil`), so on a P3 display sRGB values
  stretch to the panel's gamut and colours differ from colour-managed apps — for a pixel-art host.
  Tagging sRGB is a one-time visible shift.
- **Control Center's material:** which variant, subvariant or tint it is.
- **Adopting windows:** what SDL stops doing for an external window, and whether SDL_GPU claims one
  as it does its own.
- **Several screens:** one overlay per screen, and the bubble crossing between them.

## From the 2026-10-04 review

Fable's review of the backend and windowing (at #220) is folded in above where it shapes this plan.
What else it found, and where each stands:

**Done since (#222–#224):** floats' macOS windows titled like the main window (the OS's corners,
shadow, resizing, tiling, Window menu); float windows wait for vsync on macOS; full-screen
auxiliary collection behaviour; one window machinery for the main window and floats on macOS.

**Correctness backlog** (the window layer, not glass, but on the way):
- no message when SDL_GPU finds no device (old GPUs, VMs, RDP) — show `SDL_ShowSimpleMessageBox`
  before quitting;
- a failed pipeline recompiles every draw (cache the failure); programs are never released (a
  reloaded plugin leaks its shader);
- Windows: DPI-blind resize border (`GetSystemMetricsForDpi`), no system menu (Alt+Space,
  right-click caption), maximized under an auto-hide taskbar;
- X11's 250 ms blind spot after an app placement (`SDL_SyncWindow`);
- frame pacing with the main window hidden while a float animates (Windows/X11 present without
  vsync);
- bands at 100 000 px a slot cost `f32` precision by slot 6: a 32 768 stride keeps eight slots at
  1/32 px (the 40 000 "is it banded" thresholds in `Popout`/`ViewDrag` move with it — one constant);
- small ones: UTF-8-safe title truncation, clearing the clipboard, the main window's subclass never
  removed, `GCLP_HBRBACKGROUND` changing SDL's whole window class, the click-through hint flipping
  mid-session.

**Performance to profile, not guess:** pointer motion walking the view tree for the Metal layer
(cache per window), window-sized targets reallocated each live-resize step (bucket them), vertices
copied twice, the stream ring cycling, per-event display-mode reads.

**Elsewhere:** dvui internals — `Popout` empties subwindows' `render_cmds` (now in four places);
dvui's per-subwindow target PR would end that. File drops carry no position; AccessKit sees only the
main window. Web: one shared host module for `index.html` and the worker, WebGL context-loss
handling, the loader's import check across every module, reclaiming plugin memory. Workflow: a
`zig build shaders` step and `fizzy.plugin.addProgram` for one shader source on every backend,
running the Windows backend on WARP in CI, tapes as the windowing regression suite in CI (the
sandbox tapes this work used), `docs/BACKEND.md` for the backend's contract.
