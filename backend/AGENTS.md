# backend/: fizzy's native backend

SDL3, the SDL_GPU renderer (`GpuRenderer.zig`) and the platform pieces (`platform/`: title bars,
the OS's glass, OS windows for floats, menus, dialogs). A package of its own (`build.zig` says
how an app wires it).

- **Fizzy's in-app glass is here,** in `src/glass/` (its own module, `glassModule`): the frame
  target, the frosted backdrops, the liquid glass and its program, motion. So a plain dvui app on
  this backend can be made of the same glass as fizzy's surfaces. `core` re-exports each name
  (`core.FrameTarget`, `core.widgets.BlurBackdrop`, …) and takes the backend's instance over the
  same dvui (`core_module.addImports`); it depends on dvui and `glass_look` only. Its profiler
  scopes reach `core.profile` through `glass/prof.zig`, which the profiler hands its scopes to.
- **dvui is the caller's.** It is never pinned here; the backend compiles against the app's dvui.
- **SDL is patched here,** not in a fork: `patches/sdl/*.patch`, applied by zig-patch. How to
  change, add or bump them is `docs/DEPENDENCIES.md` ("SDL", "Bumping"). Touching a patch or this
  `build.zig` runs CI's `sdl` job, the suites for the patches (`zig build test-sdl` here).
- **std-only tests are listed in `build.zig`'s `unit_tests`,** and fizzy's `zig build test` runs
  them. Window rules that can be stated without a window go in such a file
  (`platform/window_layout.zig`, `viewport_map.zig`).
- **Verify on the platform you changed.** CI's Windows cross-compile proves fizzy links, not that
  it works. `docs/MACOS_LIVE_RESIZE.md` and `docs/WINDOWS_LIVE_RESIZE.md` show how a resize
  was measured.

## macOS pitfalls

The `.m` files in `src/platform/macos/` are built **without ARC**, under a frame loop that is Zig.

- **Autorelease pools:** each SDL callback (`appInit`, `appIterate`, `appEvent`, `appQuit` in
  `SDLBackend.zig`) runs in a pool, so Objective-C called from the frame needs none of its own.
  A thread fizzy starts, or a callback AppKit makes on its own schedule, does. Release
  `alloc`/`copy` results by hand. A closed window that lingers: run with
  `OBJC_DEBUG_MISSING_POOLS=YES` before suspecting the view hierarchy.
- **Secondary windows** (floats, menus, dialogs):
  - AppKit's show and close animations never finish under this loop and leave ghost windows. Set
    `NSWindowAnimationBehaviorNone`.
  - SDL shows a non-activating window *below* the key window, so order it explicitly.
  - `orderedIndex` is stale right after `setLevel:`: order after a level change, don't ask first.
  - A child window (`addChildWindow:`) drops to its parent's level. Set the level after attaching,
    and attach only once it is shown.
  - No macOS window both stays above another and has a full screen of its own. A child window
    moves with its parent and goes into full screen with it. A window above the normal level is
    taken into the app's full-screen Space as a palette, on the way there and when the person
    swipes to it, before the app hears the Space changed. A normal window comes forward when
    clicked. So a float in the OS's frame (`ViewportFrame.native`) is an ordinary window: don't
    attach it or raise its level to keep it above the main one. Three rounds of that each failed
    at a new moment (fizzyedit/fizzy#483, #492).
  - Borderless windows join the Window menu only through `changeWindowsItem:`.
- **A press reaches SDL3View but not SDL:** SDL3View inherits NSView's `-mouseDown:`, which keeps
  the press in a full-screen window. `visual_effect_view.m` adds a forwarding one. Add the
  forward; don't rebuild the responder chain.
- **Full screen** (`window_monitor.m`):
  - `toggleFullScreen:` called inside an open frame nests `appIterate` in it (dvui logs "window is
    already the current_window"), so defer it.
  - AppKit pictures the after-state synchronously *inside* `toggleFullScreen:`.
  - Whoever moves a window's frame sets its drawable size, because SDL hears of the new size late.
  - Take frame jumps only inside the app's frame transaction.
  - Step a still window's way (`WindowMonitor.still`) only in the app's frames. Stepped by the
    pump between them, its backdrop runs ahead of a late picture and shows as a band round it.
  - Read the pixel density from `backingScaleFactor`.
  - A sandbox fizzy launched from a shell isn't the active app, and AppKit stalls or refuses its
    transitions.
- **Per-frame presents are what cost.** A display-sized overlay, or an extra window presented
  every frame, halved drag fps (the main thread waited in `nextDrawable`), while the blur made no
  difference. Size overlays to their content. Measure idle against drag fps, and `sample` for
  `nextDrawable`, before blaming shaders.
- **Glass:** what each `NSGlassEffectView` variant and material actually does, measured, is in
  `docs/MACOS_GLASS.md`. Don't add SwiftUI or a `swiftc` step for transitions AppKit lacks.
