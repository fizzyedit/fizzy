# The windowing foundation: one model, decided once a frame, tested without a screen

Status: proposed, #243.

Fizzy's floats, menus, dialogs, view drags and drop zones work, natively, on macOS 26. Everything
else will be built on that machinery, so it needs to stay fast and easy to change. Today it is
neither: Popout re-decides every window by hand each frame, hit tests repeat once per region, and
little of it has a test. This plan sets out how to restructure it in steps. The steps keep the
behaviour as it is, but make each decision testable without a screen. They make the native calls
cheap, share one model across platforms, and leave the backend usable by any dvui app.

**What it builds on, without repeating:**
- [`NATIVE_WINDOWS_PLAN.md`](NATIVE_WINDOWS_PLAN.md) decides which material, glass and window
  chrome each platform uses: capabilities rather than platform names, one `WindowChrome` per OS
  window, a native `layers` interface, one material on one slider, and what SDL should be
  patched to do.
- [`WINDOWS_LINUX_GLASS_PLAN.md`](WINDOWS_LINUX_GLASS_PLAN.md) carries that plan's Windows and
  Linux research. Its built steps are in the open PRs #237, #238 and #242.
- [`POPOUT_WINDOWS_PLAN.md`](POPOUT_WINDOWS_PLAN.md) covers bands, viewports and per-OS dressing.

This plan is about the layer underneath those: which window shows what, how that is decided, and
how the decision is tested. Where the two overlap, those plans decide and this one only says where
the code should live.

The findings come from a review on 2026-10-08. It covered the drop-zone and float core, the backend
windowing layer, glass on every platform, and how portable the backend is. Line numbers will drift.

## Where it stands

**What is already right, and the pattern to copy.** The decisions that are already pure are also
the ones that are tested:
- `viewport_map` (bands, placement, hit tests): 14 tests.
- `float_rules`: 13.
- `window_layout`, the AppKit maths moved into Zig and called from Objective-C: 19.
- `glass_look`: 12.
- `Drop.plan`.

The single dvui frame with a band for each OS window keeps a drag across windows to one layout and
one frame. The GPU presents every window in one submission. Neither needs changing.

**The windows.**
- `SDLBackend.Viewport` is one struct serving five kinds of window: float, menu, dialog, carry and
  overlay.
  - Four booleans encode the kind (`passive`, `overlay`, `menu`, `dialog`), and the code infers it
    from them (`passive and !overlay` means carry).
  - About 3 KB of overlay glass storage sits in every one of the eight slots.
  - All kinds share the eight slots: up to eight floats, menus, the carry window, the overlay and
    growing glass. Running out fails silently (`menuOut` returns null; `popOut` just returns).
- `Popout` has five near-copies of "make a target, set its offset, replay subwindows into it,
  present": `windowFrame`, `carryBegin`, `overlayFrame`, `menuFrame` and `drawGrow`. Menu, overlay
  and carry targets are recreated on every size change, so a menu sliding open makes a texture each
  frame.
- Popout keeps its state in module globals (`outs`, `covers`, `spare`, `menus_left_behind`, …).
  It hands things over across frames (the drop's glass lives in `spare` for exactly one frame, then
  is gone), and it only works in the order `Entry` happens to call it. `core.dialogs.carry_windows`
  is a plain `pub var`, which a plugin dylib's copy of `core` never sees.

**The coordinate spaces.** There are seven:
1. main natural;
2. main physical;
3. band physical;
4. main frame extended past its edge;
5. desktop points;
6. window-local points;
7. render-target pixels.

Conversions between them are scattered across Popout, ViewDrag, `core.screens` and SDLBackend.
Two unrelated thresholds decide whether something is in a band: `main + 40000` in Popout, and a
jump of `30000` in ViewDrag. A third constant, `screens.beyond` (16384 natural units, how far the
desktop reaches past the main window), has to stay clear of the bands without saying so.
`Floats.Viewport.rect` is documented as
being in the main window's frame but holds band units.

**The drag.**
- Hit tests repeat with no cache. During a drag, every region's draw calls `tick` → `settleGhost`
  and `drawZones` → `chooserAt`, `aimedAt` and `wheelOf`. Each of those reaches `zoneBounds`, and
  each `zoneBounds` runs `DropZones.uncovered` twice. That is roughly O(regions × targets ×
  uncovered) per frame, over name lookups that are linear string scans.
- The release rules are split. `Drop.plan` covers the table; `apply` adds held, float-away,
  chooser, plugin-chooser and empty-place branches outside it.
- Lifecycles are implied by flags: `fresh`, `closing`, `aside`, `ghost_firm`, `lifted`,
  `spare_kept`, `held`, `been_drop`. The float lifecycle (fresh → landing → live → ghost → gone)
  and the drag lifecycle (lift → carry → release) are never written down.

**Native calls per frame (macOS, per float window).**
- No NSWindow pointer is cached. Each `cocoaWindow` or `windowX` call does
  `SDL_GetPointerProperty(SDL_GetWindowProperties(…))`: about 15–20 lookups and about 20
  Objective-C messages per float per frame.
- `fizzy_macos_window_liquid_glass_look` opens a Core Animation transaction on every call, with no
  "unchanged" check on the Zig side. It runs for the main window, each float and each menu.
- `setStyle` runs every frame and re-applies `styleTitled` to every window that isn't passive. That
  includes menus and dialogs, which get `FullScreenPrimary` added over the `FullScreenAuxiliary`
  their window was given. Fixed in its own PR (step 2, #245).
- Two owners open Core Animation transactions: the `macos_monitor` hooks and `renderPresent`.

**Glass.**
- The liquid glass shader is three hand-synced copies (GLSL, Metal, HLSL) plus a CPU mirror
  (`LiquidField.sample`) that doesn't model the lens branch.
- Each look is mirrored four deep: `glass_look`, the backend, the platform and Objective-C. Stub
  copies sit in `backend_web` and the native fallback. That fallback's `GlassShape` has already
  drifted (no `frost`); it is latent, because nothing reaches it today.
- Liquid Glass variant numbers live in three places.
- "Is the window translucent" is spelled five ways: `Settings`, `SettingsMigration`, `Editor`
  twice, and `backend_native`.
- `core.liquid_blob`, the CPU mesh the shader replaced, is still filled on every overlay frame
  (`Popout.glassBase`).

**Tests.**
- 32 tests beside the layout code never ran, because no test root reached the `app` module. They
  run now (step 1, #244).
- There are none for Popout, the backend, `screens` or `motion`. `DropZones`' geometry (`wheel`,
  `at`, `atDisc`, `uncovered`) is tested, in `tests/integration.zig` (`drop:`), because `core` has no
  test root of its own.
- The integration tests never set `Float.viewport`, so nothing popped out is ever tested.
- No demo tape drags, floats or pops anything out.

**Dead API.**
- `viewports.bandFromMain`, `dragMove`, `orderAbove`, `shown` and `maximized` have no callers.
- `PointerPin.main` is never set.
- `osMoveEnded`'s `resized` is thrown away, so `os_moving`, `os_start` and
  `ViewportLoop.resized/sizing` have no consumer.

**Full-screen transitions.**
- Fizzy runs its own transition into and out of a Space, so the window can fade, rather than
  AppKit's, which moves still pictures. Each step redraws the whole app at that step's size, so it
  can only be as smooth as one app frame is fast.
- Measured: in Debug, a steady 19–22 ms a frame (about 50 fps). In release before the change
  below, about 8.7 ms on average, with stalls of 30–60 ms.
- Most of the stalls came from resizing the window, and so its Metal drawable, on every step.

## The design

### 1. Decide, then apply

Each frame, the windowing becomes two halves.

**A pure plan.**
- *Input:* the floats and their rects, the drag, the open menus and dialogs, and the OS reports
  gathered at `begin` (moved, resized, close asked, full-screen fraction).
- *Output:* the frame's OS windows, each `{ id, kind, rect, look, order, what it shows }`.
- No dvui, no SDL, no globals, so it is tested like `viewport_map`.

**A reconcile.** The backend applies the plan against what it applied last frame, by id, as dvui
does with widgets. It creates and destroys windows, moves them, and dresses them only when
something changed. `NATIVE_WINDOWS_PLAN.md`'s `layers.glass(id, …)` is the glass half of the same
reconcile.

What this buys:
- **Tests without a screen:** the plan is a value to assert on.
- **Speed:** Objective-C and Win32 run only for what changed, which removes most of the per-frame
  native traffic above.
- **One seam per platform:** a backend implements reconcile, and nothing else needs to know the
  platform.

### 2. One window type, its kinds a union

`Viewport` becomes `OsWindow { window, band, screen, frame, … kind: union(enum) { float, menu,
carry, overlay } }`.
- Each kind's state lives in its own arm, and a dialog is a menu with its own stacking.
- The native handle (NSWindow or HWND) is read once, when the window opens, and kept. This is the
  `WindowChrome` of `NATIVE_WINDOWS_PLAN.md`.
- Slots are budgeted per kind, so menus can never starve floats. Running out is logged, not
  silent.

### 3. One way to fill a window

The five near-copies in Popout become a single function:

```zig
fill(window, which subwindows, target)
```

Targets come from a pool keyed by bucketed size, as `BlurBackdrop.captureSize` already buckets its
captures. A menu sliding open or a carried shape morphing then reuses a texture instead of making
one each frame. With dvui change 1 below, `fill` stops taking subwindows' render commands by hand
and only names a target.

### 4. Typed coordinate spaces

- `viewport_map` owns distinct types for the spaces (`BandPx`, `MainPx`, `ScreenPt`, `WindowPt`)
  and every conversion between them.
- A single `viewport_map.bandOf(x)` replaces both band thresholds, and the desktop's reach
  (`screens.beyond`) is defined next to the bands, as staying short of the first one.
- `Floats.Viewport.rect` says which space it holds, in its type.

### 5. A drag model, computed once a frame

- A pure `DragModel.resolve(targets, occluders, offers, aim, now) → { target, kind, chooser,
  ghost }`, run once a frame. Every region reads the result.
- `under`, `chooserAt`, `targetAtAim`, `zoneBounds` and `settleGhost` (given the time and the
  pointer as inputs) move into it, with tests, built on `DropZones.wheel`, `uncovered` and `atDisc`,
  which are already tested.
- `Drop.plan` grows to cover held, float-away and chooser drops, so `apply` becomes one switch over
  a plan.

### 6. Lifecycles written down

Each lifecycle becomes an explicit state with legal transitions, replacing the flags and one-frame
handoffs:
- **float:** fresh → landing → live → aside or ghost → closing → gone;
- **a float's window:** opening → growing → shown → (moving through a Space) → closing;
- **drag:** lift → carrying → over another window → released.

`spare` becomes a state of the landing it belongs to, so a drop's glass can no longer be dropped
because a float didn't pop out on exactly the next frame.

### 7. Glass: one look record, end to end

This builds on `NATIVE_WINDOWS_PLAN.md` ("One vocabulary", "Capabilities").
- The struct `glass_look` returns is the extern struct each platform reads. No more four-deep
  mirrors, and the Liquid Glass variant numbers live only in `glass_look`.
- The backend publishes its capabilities once (`liquid_glass`, `lens`, `merge`, `window_backdrop`,
  `blur_region`, `carry_windows`). They replace the five spellings of "translucent".
- The shader gets either one source that generates the other two, or a parity test that draws all
  three against `LiquidField.sample` on a fixed grid. Whichever comes after #242 lands.
- Drop `liquid_blob` from the overlay once the native fill draws the same colour.

### 8. Full-screen transitions

**Stage one (built locally, unpushed).**
- A float's window stands still at its full-screen size from the first step. Only the float's
  picture and its glass move inside it, so no drawable is resized and the float isn't laid out
  again in a new window.
- Clicks in a full-screen float are fixed in the same stack: SDL's view now passes the left press
  on itself, which the `mouseDown:` it inherits from AppKit didn't do in full screen.

**Stage two, if release frames don't hold 8.3 ms.**
- Core Animation moves the picture and the glass views, with a `CABasicAnimation` on the frame of
  SDL's view layer and on the glass views. The app draws only the first and last sizes.
- The window server then paces the animation as it does AppKit's, and fizzy keeps its glass.
- The main window moves to the same scheme.

### 9. Testing

- **Pure modules, each with a std-only test root**, as `viewport_map` has:
  - the plan (§1);
  - the drag model (§5);
  - the coordinate spaces (§4);
  - the transition easing and rect;
  - `keepTarget`'s sizing;
  - the pointer-routing decision: global point, window rects, flags and pin in; the frame point
    out. This is the part tapes can't reach.
- **A fake backend:** a recording implementation of the `viewports` facade under dvui's testing
  backend. Integration tests can then pop floats out, set `Float.viewport`, and assert the plan and
  the operations applied.
- **Tapes:**
  - add anchors for corner buttons and drop bubbles;
  - bundle a drag → split → float → pop-out tape;
  - a tape still can't reach the OS's input routing, which is what the routing function's tests
    are for.
- **The shader parity test** (§7).

### 10. Any dvui app

The goal: dvui's own example app, built with `-Dbackend=custom` and fizzy's backend, shows its
floating windows and menus as OS windows.

**On fizzy's side.**
- The backend becomes a package of its own: `SDLBackend`, `GpuRenderer`, `platform/**` (the
  Objective-C included, which today is compiled into fizzy's executable), `viewport_map`, the
  `viewports` facade and the SDL pin. Its C symbols lose the `fizzy_` prefix.
- Popout splits in two:
  - the generic half moves into that package: subwindows into OS windows, carry and overlay
    windows, menus and dialogs as windows;
  - fizzy's policy stays in the app: `Floats`, `ViewDrag`, the looks.

**On dvui's side, smallest and most valuable first.** Each change goes to the fork
(`DEPENDENCIES.md`) and is proposed upstream:
1. **Redirecting a subwindow's render target in `Window.endRendering`'s replay.** A target and
   offset per subwindow, or a callback that returns one.
   - It replaces Popout emptying `render_cmds` by hand.
   - Because the redirect happens inside the replay, after dialogs and toasts are drawn, it also
     removes `core.dialogs.drawEarly`.
   - `POPOUT_WINDOWS_PLAN.md` already proposes it.
2. **A screens hook.** `dvui.screenFor(rect)` and its pixel form, defaulting to the window's rect.
   - The floating widgets' `placeOnScreen` and `clipSet(windowRectPixels())` call it instead of
     using the window's rect.
   - `FloatingWindowWidget` gets an option to skip the clamp.
   - It removes fizzy's forks of `FloatingWindowWidget`, `FloatingMenu`, `FloatingTooltipWidget`
     and `Popover`, which exist only because the stock ones pull a float drawn in a band back onto
     the main window.
3. **A kind and parent on each subwindow, recorded at `subwindowAdd`.** `FloatingMenu` passes the
   subwindow it opened from. A backend can then send a float's menus and tooltips to the float's
   OS window, replacing "is its middle inside the band" and the `screens.markMenu` tagging.
4. **Input per OS window** (optional while bands work). Tag events with the OS window they came
   from, and make `.leave` per window. Today a viewport's leave sets `mouse_pt` to (-1, -1) for
   every window.
5. **Frame hooks for `dvui.App` backends:** at begin, and before the replay. The backend can then
   run its windows itself, rather than fizzy wrapping its frame function in `Entry`.
6. **A policy flag.** `os_window` on `FloatingWindowWidget`, menus and dialogs, saying which
   subwindows become OS windows.

Later: a natural scale per subwindow (mixed-DPI displays), and an AccessKit tree per OS window.

**The case to make upstream.** dvui's only multi-window model today is `OsWindowWidget`: one
`dvui.Window` per OS window, at most five. A drag across windows needs one frame and one layout,
which is what bands give. The two patches fizzy carries on dvui today (`deferRender` and precise
targets) are for glass, not windowing.

## Steps

Each step is a PR of its own, in this order. Steps 3 to 8 keep the behaviour as it is.

1. **The tests that never ran:** a test root for the `app` module (32 tests). #244
2. **Menus and dialogs stay auxiliary windows:** `setStyle` leaves them alone; they are dressed once
   as they open. #245
3. Typed coordinate spaces and `bandOf` in `viewport_map`, with tests, adopted by Popout, ViewDrag
   and `screens`. After #237 and #238, which touch the same files.
4. `OsWindow` with a union of kinds, the native handle cached, dressing checked for changes on the
   Zig side, per-kind budgets. Measured by Objective-C messages per frame, before and after.
5. Extract the plan (§1), add the fake backend (§9), and write the first integration tests that pop
   a float out.
6. Unify `fill` and add the target pool (§3).
7. The drag model once a frame, with tests, and the release table (§5).
8. Write the lifecycles down (§6).
9. Glass: capabilities, one look record, shader parity (§7). After #242.
10. Full-screen stage two (§8), if release measurements call for it.
11. dvui changes 1–3 on the fork, the backend as a package, and dvui's example app as the
    acceptance test. Then changes 4–6.
12. Remove the dead API, along with steps 3–5 as they touch it.
