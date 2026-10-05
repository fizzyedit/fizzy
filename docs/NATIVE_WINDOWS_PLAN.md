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

Related: [`POPOUT_WINDOWS_PLAN.md`](POPOUT_WINDOWS_PLAN.md) (viewports, bands, per-OS dressing) and
[`DEPENDENCIES.md`](DEPENDENCIES.md) (the SDL, sdl_zig and dvui-dev forks and their patches).

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

During a view drag, one transparent overlay window lies over each screen the drag can reach. It is
the carry window grown to its screen: passive, at the pop-up menu level, joining full-screen Spaces.
In it:
- **An `NSGlassEffectContainerView` holding a pool of glass views.** These are the carried view
  (the drop's head and its tail, or a card or tab) and every drop-zone bubble that is showing,
  whether over the main window's places or over float windows. Each is placed every frame from the
  shapes the frame already computes (`ViewDrag.drop_shapes`, `DropZones` shapes). The container's
  `spacing` is the drop zones' merge distance, so the head pulled toward the bubble it is aimed at
  bridges into it as Liquid Glass. The head and its springy tail, as two glass views, merge into
  the wobbling drop.
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

**Fizzy makes its own native windows, and SDL adopts them.** SDL3 takes a window it didn't create:
- the creation properties are `SDL_PROP_WINDOW_CREATE_COCOA_WINDOW_POINTER` / `_COCOA_VIEW_POINTER`,
  `_WIN32_HWND_POINTER`, `_X11_WINDOW_NUMBER` and `_WAYLAND_WL_SURFACE_POINTER`;
- SDL marks such a window `SDL_WINDOW_EXTERNAL`, installs its event listener, and adds its Metal
  view as a subview of the view it was given (`SDL_cocoawindow.m`, `SDL_cocoametalview.m`).

So fizzy can create its own `NSWindow` subclass and content view and hand them over. The view
hierarchy, title bar behaviour and live resize would then be fizzy's code, not runtime replacements
of SDL's methods or patches to SDL:
- **Title bar drag regions.** Today they are answered from a runtime-replaced method
  (`fizzy_mouseDownCanMoveWindow`), from the cursor's position when AppKit asks. Fizzy's view would
  decide per press and start window drags itself (`performWindowDragWithEvent:`), as Chromium does.
  This is where the reported "float dragged over the main title bar" misbehaviour lives.
- **Live resize** (SDL patches 4 and 5) becomes `displayLayer:` in fizzy's own view, so two patches
  leave SDL.
- **Glass, vibrancy and the overlay's container** are subviews fizzy places, not views slipped in
  beside SDL's.
- **On Windows,** an HWND fizzy creates can carry its DirectComposition visuals. Patch 2 may then
  be able to leave SDL too, which needs checking against SDL_GPU's D3D12 swapchain.

What adopting a window costs has to be measured first. An external window loses some of what SDL
does for windows it made (full screen, its own `NSWindow` subclass's event handling). The
prototype lists each difference, and fizzy's window code covers what it needs.

**Keeping up with SDL.**
- **Fewer patches.** Each patch that moves into fizzy's code, through foreign windows, properties
  and hints, is one less to rebase. The goal is patches only where SDL has no seam, and each of those
  proposed upstream (DEPENDENCIES.md rule 4).
- **A standing check.** A scheduled CI job rebases fizzy's SDL patch stack onto SDL's latest
  release and builds fizzy against it. A conflict or a break shows up the week it happens, not at
  the next bump. Less often, the same job runs against SDL's `main`.
- **Each patch has an acceptance test.** DEPENDENCIES.md names, for each patch, how to see that it
  still works (`scripts/live-resize`, a transparent window's claim, Acrylic through DComp). A bump
  is done when those pass.
- **A cadence.** Fizzy takes each SDL point release within a few weeks, tagging each step
  `fizzy-<sdl version>-<n>`, as now.

## Steps

1. **Done in #224:** the carried bubble is a window of Liquid Glass on macOS 26, as a lens. The
   float window shows only once the glass it grows out of is its size.
2. **Prototype the overlay** on macOS 26, behind `FIZZY_NATIVE_GLASS=1`: one screen-sized overlay
   with a pool of glass views in a container, holding the bubble's head and tail and the drop
   zones. Measure the frame cost, merging at 120 Hz and the transaction sync, and match Control
   Center's material.
3. **Native layers in the backend:** the Zig interface, the macOS implementation from the
   prototype, and `ViewDrag`/`DropZones` publishing their shapes through `core`. Where layers
   draw, the app's glass doesn't.
4. **The other platforms' path:** where native glass can't merge, the bubble is the app's glass
   over a window and a carry window outside them.
5. **Fizzy's own windows on macOS:** a fizzy `NSWindow` and view handed to SDL. Title bar drags
   move into it (fixing the title bar case), then live resize, and SDL patches 4 and 5 are dropped.
   Then Windows (an HWND with DComp visuals).
6. **The SDL path:** the scheduled rebase-and-build job, upstream PRs for the patches that remain,
   and each patch's acceptance test in DEPENDENCIES.md.

## Open questions

- **Private API.** Is a private glass variant acceptable for fizzy's look at all? The plan gates
  it on a measured macOS version and on the setter being there, and keeps the public style as the
  fallback.
- **Control Center's material:** which variant, subvariant or tint it is.
- **Adopting windows:** what SDL stops doing for an external window, and whether SDL_GPU claims one
  as it does its own.
- **Several screens:** one overlay per screen, and the bubble crossing between them.
