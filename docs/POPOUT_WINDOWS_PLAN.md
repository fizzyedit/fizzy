# Pop-out windows: floats that leave the main window

Agreed design, built through its third phase behind a flag. Written down because the decisions here were
reached by discarding the more obvious design (dvui's `osWindow`), and the reasoning is the
expensive part to re-derive.

## Where it stands

**P6, floats are windows, is under way (2026-10-04), behind `FIZZY_POPOUT=1`.** After testing the
P3 gesture, the user's call: "we want native os windows where we can have them" — a float that is a
window from the frame it is made in, as VS Code's floating windows are, rather than one that splits
out at the main window's edge. Nearly everything that went wrong in P3's polish lived in that
crossing (the held drag, the frame the float is in neither window, the glass's look changing as it
crosses), and a window that is a window from birth never makes it. See "P6: floats are windows"
below. In-window floats stay where there are no OS windows to have (the web, Wayland): "faked"
there.

**Phases 2 and 3 are in, behind `FIZZY_POPOUT=1`, with no dvui change.** A float dragged past the
main window's edge splits out into an OS window of its own, and merges back when let go wholly
inside it. Its popups and a view drag follow it across. On macOS its window wears vibrancy behind
its glass, and on Windows Acrylic, so it looks the same out as in, and the OS moves, resizes and
snaps its window as any other. On X11 the same gesture runs over an opaque backing, and on
Wayland floats stay in the main window. What P2 established, and what it changes
below, is in "What P2 found" at the end. What P3 changed is in "What P3 found", after it.

**Phase 1 is built: in-window floats.** A view dropped on the middle of its own place floats into a
glass window over the layout — a place of the framework's own (`Float N`), movable, resizable,
re-dockable, closed home, remembered in `layout.zon`. The rule is in `app/layout/SPLITS.md`
("Floating a view"), the code in `app/layout/Floats.zig` and `float_rules.zig`. Everything below is
about taking such a float **out** of the main window into an OS window of its own, the way Dear
ImGui's multi-viewports do, without losing fizzy's glass:

- macOS: the window's material is vibrancy, as the main window's is.
- Windows: Acrylic.
- Linux: an opaque window wearing glass chrome fizzy draws (X11; Wayland, below).

A popped-out window has rounded corners, minimizes and closes with the main window, and can be
minimized and maximized itself.

## Decisions

1. **ImGui-style viewports, not dvui's `osWindow`.** There stays one `dvui.Window`. A float that
   leaves the main window keeps its subwindow there; its draw is replayed into a second SDL window's
   swapchain on the shared GPU device.
2. **The main window moving does not move them.** Popped-out windows stay where they are on the
   desktop. The link to the main window is z-order, minimize and close only.
3. **A popped-out window minimizes as an OS window**, with its own Dock / taskbar entry.
4. **The float is the unit.** A popped-out window *is* a float (`Float.viewport`), so docking back,
   closing home, persistence and the drag's occlusion are the same code in either place.

### Why not `osWindow`

dvui's `osWindow` (`OsWindowWidget`) gives each OS window its own `dvui.Window`, and fizzy's backend
already has the matching `SDLBackend.initWindowSecondary` (sharing the primary's GPU device) —
nothing calls it. It is the wrong base for this:

- **A dialog crossing the edge would lose its widget state.** Ids, data, focus, animations and
  textures belong to a `dvui.Window`; moving a subtree between two of them is a remount — the very
  thing a float exists to avoid (`SPLITS.md`, on why a self-split never moves the view).
- **Plugin dylibs are pinned to the main window's context.** Each dylib's dvui is injected with one
  window (`sdk/src/dvui_context.zig`); a second `dvui.Window` is a second context every plugin
  would have to be told about, per draw.
- **Upstream says subwindows "are not detachable"**, and `osWindowImpl` hard-codes a new window's
  position (850, 150) and caps them at five. It is a way to open a second window, not to carry one
  out of the first.

ImGui keeps one context and adds *viewports*: extra platform windows and swapchains that receive a
window's draw lists. Fizzy's natural hook is the same — dvui's deferred subwindow replay
(`Window.endRendering`, called from `core/gfx/FrameTarget.zig`'s `end`) plus `RenderTarget.offset`.

## Phases

| Phase | What | Ships behind |
|---|---|---|
| **P1** (built) | In-window floats | — |
| **P2** (built, flag) | Viewport infrastructure: a float rendered into a second SDL window, input routed back. A debug command "Pop Out Float" | a flag |
| **P3** (built, flag) | The gesture: a float split out as it crosses the main window's edge, merged back when let go fully inside | the flag |
| **P4** | Per-OS dressing, parenting, minimize / maximize / close with the main window | — (flag off) |
| **P5** | Hybrid frost (built), mixed DPI, Wayland | — |
| **P6** (in progress, flag) | Floats are windows: born as native, titled OS windows; the edge crossing gone | the flag |

## The viewport model

The backend holds, per popped-out float:

```
Viewport { sdl_window, swapchain, origin_px, scale, state: hidden|shown|minimized|maximized }
```

and the float points at one: `Float.viewport: ?ViewportId`. Its rect is in **main-window natural
units while in-window** and in **screen units once popped out** (converted at the split and the
merge, never both live).

### The dvui-dev hook

During `endRendering`'s subwindow replay (dvui-dev `src/Window.zig`, the loop over
`subwindows.stack` replaying each `render_cmds`), a subwindow that carries a viewport:

- renders into that viewport's target, with `RenderTarget.offset` set to the viewport's origin in
  main-window pixels (dvui subtracts it from every vertex and clip);
- is skipped in the main target;
- has the window-rect clip and clamp lifted — fizzy's `FloatingWindowWidget` clips to
  `windowRectPixels()` and holds itself on screen (`placeOnScreen`), both meaningless out there.

Shape it so it could go upstream: a per-subwindow `target: ?RenderTarget` dvui honours in the
replay is all fizzy needs, and nothing about it is fizzy's. Pinned in exactly one place
(`sdk/build.zig.zon`, `docs/DEPENDENCIES.md`).

Two facts the hook rests on, verified in dvui-dev: a subwindow not re-added in a frame is pruned at
the end of it (`Subwindows.reset`, from `Window.end`) and comes back as new, on top — so a
popped-out float must be drawn every frame, as in-window floats already are; and `focusSubwindow`
does not raise — only `raiseSubwindow` does (dvui calls it from a window's header, Phase 1 on any
press in a float).

### The renderer

Today `initWindowSecondary` gives each window a `GpuRenderer` of its own sharing the primary's
device (`createWindowRenderer(…, parent.gpu)`). The viewport model wants **one renderer driving N
swapchains on one command buffer**: one frame, one submission, every texture and custom program
(`core/gfx/programs.zig` ids, the liquid glass) valid in every viewport because there is one
`dvui.Window` and one device behind it.

- **Pacing.** The main window paces with vsync; secondary windows present `MAILBOX` or `IMMEDIATE`
  (`GpuRenderer` already picks between them, around its present-mode setup), so a second swapchain
  never halves the frame rate.
- **Skip what nobody sees.** Minimized or fully occluded windows are not acquired: Metal's
  `nextDrawable` stalls about a second on them.
- **Transparent first.** Each viewport's target is cleared to transparent, so its frost samples
  transparent pixels and the OS material shows through — the same as the main window's over
  vibrancy and Acrylic.

This needs **fizzy's backend**. It is the default on macOS, and on Windows since "build: fizzy's own
backend is the default on Windows too" (seen on Windows 11 on Arm: D3D12 on WARP, the transparent
window over Acrylic through DirectComposition). `-Dnative-backend=sdl3` (dvui's SDL_Renderer backend) gets no viewports; its
floats stay in-window.

## Splitting and merging

- **Split** when the float's rect leaves the main window's client area while it is being moved.
  **Merge** only on release, and only when it is fully inside, with hysteresis — a float dragged
  along the edge never flickers between the two.
- **Show sequence:** create the window hidden, position and size it, claim the swapchain, render a
  frame into it, then show it. OS show/hide animations off. The float never blinks.
- While split and still held, the window follows `SDL_GetGlobalMouseState`, not window-relative
  events (the pointer is now over a window that did not see the press).
- **The own-centre drop can go straight out.** A float whose computed rect already lies past the
  edge (a small main window) can land in its own window directly, growing out of the carried glass
  across the boundary.

## Input and focus

- Route SDL events by window id to the one `dvui.Window`, translated into main-window physical
  space by the viewport's origin (today `SDLBackend.addEventWinRecursive` routes to
  `child_os_wins`; the viewport path replaces that, not extends it).
- `SDL_HINT_MOUSE_FOCUS_CLICKTHROUGH`, so the first click on a popped-out window acts. Decide the
  auto-capture policy: a drag that starts in one window and ends in another must keep its capture
  (a view carried out of a popped-out float onto the main window is the common case).
- Text input and the IME rect follow the focused viewport.

## DPI

dvui has one `natural_scale`. First version: every viewport uses the main window's. Later: replay
a viewport's commands with a scale ratio when its display differs (mixed-DPI desktops), which the
hook's per-subwindow target can carry.

## Per-OS dressing (P4)

**macOS.** An unparented borderless `NSWindow` with an `NSVisualEffectView` behind SDL's view
(active, the main window's material — `platform/macos/visual_effect_view.m`) and a `maskImage` for
the rounded corners (`NSGlassEffectView` on macOS 26). No AppKit shadow: fizzy draws its own in a
clear margin. Both are built, as "What P3 found" describes. Still to do: a window level and collection
behaviour that keep it with the app across Spaces, `animationBehavior` none. Not
`addChildWindow`, which drags children along with the parent — decision 2. Minimize and close with
the main window through `platform/macos/window_monitor.m`.

**Windows.** Keep `WS_CAPTION` in the borderless style so DWM draws the backdrop (as
`win32_titlebar.zig` does for the main window); `DWMSBT_TRANSIENTWINDOW`;
`DWMWA_WINDOW_CORNER_PREFERENCE = ROUND`. The owner is the main window (z-order, minimize with it)
plus `WS_EX_APPWINDOW` for its own taskbar entry. `win32_titlebar`'s state moves per HWND (through
`dwRefData`), and `caption_buttons.zig` draws its buttons.

**Linux, X11.** `transient-for` the main window; an opaque window with glass chrome fizzy draws,
as the main window's (`linux_titlebar.zig`'s client decorations).

**Linux, Wayland.** Stays in-window: a Wayland client cannot position a toplevel, which is why
ImGui's SDL3 backend turns viewports off there. The escape hatch to watch is SDL draft PR #16432,
"dockable windows" (xdg-toplevel-drag). The frame insets fizzyedit/SDL already carries
(`SDL_PROP_WINDOW_CREATE_WAYLAND_FRAME_INSET_*`) are what a popped-out window's shadow would use.

## Lifecycle

- Minimizing the main window hides the popped-out windows; restoring it shows them.
- Each can be OS-minimized with its own entry, and maximized to its display's work area.
- Closing one sends its views home, as an in-window float's close does.
- A display that disappears brings its windows back in-window (or onto the main display), as
  `float_rules.reachable` does for a saved float on a smaller window.

## Single-window globals to refactor

`src/backend/native/platform/window.zig`, `win32_titlebar.zig`, `linux_titlebar.zig`,
`titlebar.zig`, `geometry.zig`, `gestures.zig`, `macos_monitor.zig`, the statics in
`platform/macos/window_monitor.m`, and `src/editor/caption_buttons.zig` all assume one window. The
published style values and the plugin context do not change: there is still one `dvui.Window`.

## Frame pacing

One loop that wakes on any window's events. Coordinate with the frame-drop and resize work in
flight and with `docs/MACOS_LIVE_RESIZE.md` (SDL drawing each live-resize step from
`displayLayer:`): a popped-out window being resized must not stall the main window's frames.

## Persistence

`SavedRegion.Floating` (`src/backend/layout_file.zig`) gains
`os: ?{ x, y, w, h, display, minimized, maximized }`. A file written by a fizzy without viewports
reads past it and the float comes back in-window, as an older fizzy already reads past `floating`.

## Testing

The rules — split and merge thresholds, the coordinate conversions, which display a window belongs
to — in std-only modules beside `float_rules.zig`, unit-tested from `build/app.zig`. The rest is a
manual QA checklist per OS (macOS, Windows 11 x64 and Arm, X11, Wayland's in-window fallback), run
in a sandboxed fizzy driven by a demo tape where it can be (`docs/AUTOMATION.md`).

## Risks and open questions

- **Fork divergence.** The replay hook is a dvui-dev patch until upstream takes something like it.
- **AccessKit** is per OS window; one `dvui.Window` across several needs a tree per viewport.
- **OS drag and drop** into a secondary window (a file dropped on a popped-out explorer).
- **Spaces and fullscreen** on macOS: a popped-out window on another Space, the main window going
  fullscreen.
- **Focus stealing** when a split creates a window under a held drag.
- **D3D12 on hardware GPUs**: fizzy's backend has run on Windows only on WARP so far.

Phase 1 left these for later, independent of the OS windows:

- **Workbench drags ignore floats.** Its own file and tab drags into document panes
  (`plugins/workbench/src/Workspace.zig`) do not read float occlusion yet.
- **Drop bubbles under a float.** Where a float covers part of a main-window place's drop wheel,
  those bubbles still draw but cannot be aimed at.

## What P2 found

The spike: with `FIZZY_POPOUT=1` on fizzy's backend, the command **Pop Out Float**
(`fizzy.popOutFloat`) takes the topmost float out into an OS window of its own, and brings it back
when run again or when the OS asks that window to close (`src/editor/Popout.zig`). Checked on macOS
in a sandboxed fizzy, the Explorer floated by a demo tape and then popped out: the main window shows
nothing of the float, the new window shows all of it, and input pushed at that window as SDL events
(in-process; no OS events) hovered and expanded a folder in its tree, scrolled it, and dragged the
float by its header — the window followed by exactly the 150×80 points the pointer moved, a frame
behind it while held. Closed, the float was back in the main window with the folder still
expanded: one `dvui.Window`, so widget state crosses the edge both ways untouched.

### No dvui change is needed

The replay hook proposed above for dvui-dev is not needed for this:

- `Window.renderCommands` is public, and fizzy already runs dvui's end-of-frame replay itself
  (`core.FrameTarget.end` calls `endRendering`). Just before it, `Popout.endFrame` takes the
  float's subwindow's queued commands (`subwindows.get(id)`, its `render_cmds` and
  `render_cmds_after`), leaves them empty so the replay into the main window draws nothing of it,
  and replays them itself with the render target switched to a target of the viewport's own,
  `offset` at its part of the frame. dvui offsets every vertex and clip at replay
  (`renderTriangles`) and the frost reads the bound target through that offset
  (`BlurBackdrop.deinitFromTarget`), so nothing the float draws knows where it is going.
- The clip and clamp to the main window are fizzy's own `FloatingWindowWidget`'s
  (`core/widgets/`), so they are lifted there: `detached` (no `placeOnScreen`, clipped to itself).
- If it goes upstream, the shape is still a per-subwindow target honoured in the replay; for fizzy
  it would only shorten `endFrame`.

### Bands: routing without telling dvui anything

A float out of the main window is drawn in a **band** of the frame far past its edge — the first at
x = 100 000 physical pixels, each viewport its own (`src/backend/native/viewport_map.zig`, unit
tested). dvui routes a pointer by what is drawn under it (`Subwindows.windowFor`), and nothing over
the main window is ever under a point in a band, so no main-window pointer reaches a float that has
left, and a pointer translated from the viewport's window lands on it — with no flag on the
subwindow and nothing patched into dvui's events. (Taking the float out of hit-testing instead,
`Subwindow.mouse_events`, and tagging the viewport's events by hand would not hold: at the start of
every frame dvui tags the pointer's resting place against the subwindow stack again, so a pointer
resting over the viewport would hover whatever of the main window lies at the same point.)

Within its band the frame follows the desktop, `frame = band + (screen − anchor) · density`, the
anchor being where the main window's top left was when the viewport opened, kept for its life — so
the main window moving does not move the windows that left it (decision 2; checked: the main window
moved by 60×20 and the popped-out window stayed put), and dvui's own drag code moves and resizes a
float out there as in the main window, its window following it (`SDLBackend.viewportPlace`). A pointer over the window goes to
`band + (window position + event position − anchor) · density`, read against where the window is
at the time, as Dear ImGui's SDL3 backend reads its viewports. Two viewports' windows can overlap
on the desktop; their floats never meet in the frame.

### One renderer, N swapchains, as planned — without a second renderer

`GpuRenderer.claimViewport` claims the new window on the main window's device. Each frame the
float's part of the frame is replayed into its own target (above), and `presentInto` acquires the
viewport's drawable on the frame's own command buffer and copies the target into it
(`SDL_BlitGPUTexture`, transparent where the target is); the frame's one submission presents every
window (SDL's Metal backend keeps a per-command-buffer list of them). The viewport presents
IMMEDIATE (no display sync on Metal; MAILBOX where a driver has it), and its drawable is acquired
without waiting (`SDL_AcquireGPUSwapchainTexture`): a drawable not ready skips that window for a
frame rather than holding the main one. Minimized or covered, it is not acquired at all. Cost: one
target per viewport and one copy a frame — the main window's own `FrameTarget` blit, again.
Per-window renderers (`initWindowSecondary`) were not needed: they would share textures (one
device) but not pipelines or program ids (`core.gfx.programs`), and two command buffers a frame
would have to be ordered against each other's uploads.

The window is created hidden, claimed, handed a frame, and shown after that frame is presented,
without taking the keyboard from the main window (`SDL_HINT_WINDOW_ACTIVATE_WHEN_SHOWN`); its first
click acts (`SDL_HINT_MOUSE_FOCUS_CLICKTHROUGH` — every window's, while a viewport is open). Keys
and text from it go to the one dvui window, and text input starts in whichever window has the
keyboard, its IME rect moved into that window's points (written, not exercised in the sandbox).

### Surprises

- **Glass reads the desktop as nothing.** The viewport's target is transparent, so the float's
  frost reads transparent pixels and its glass came out clear: the Explorer's text floated over
  whatever was behind the window. Until P4 gives the window a material to show through, the
  float's window is backed by the chrome's colour, opaque (`Popout.backing`), and the glass over it
  reads as a panel of the main window does. The backing must cover the window's margin too — the
  frost's blur and bevel read past the glass's edge, and a transparent ring there faded every edge
  to see-through; the four corners still fade a little, outside the backing's curve.
- **The float's popups stayed in the main window.** Menus, tooltips, the picker, a dialog and a
  view drag's drop zones are each a subwindow of their own, placed and clamped on the main window
  and drawn there. Dear ImGui gives a popup its parent's viewport. Fixed since: the float's window
  is a screen of its own (`core.screens`) that its popups are placed on and kept within. Every
  subwindow whose middle is in the float's part of the frame is replayed into its window, in
  stack order.
- **A demo tape owns the pointer while it plays.** The player swallows real pointer motion while a
  tape plays and takes a real press as the user diverging (pause, then a re-seek from a snapshot on
  resume), and input from a viewport is real input to it: a run that pushed SDL events at the
  viewport mid-tape seeked back to before the float existed, and the viewport went with its float.
  A test of viewport input lets its tape end first.
- `CGWindowListCopyWindowInfo` reports a sandbox's windows off screen while they are on another
  Space; `screencapture -l` captures them anyway.

### Not done

- A view dragged out of a float that is out would not land in the main window: macOS keeps
  sending a held pointer to the window it was pressed in, and its translation kept it in the band.
  Fixed since: while a button is held, the pointer is placed by the window it is over
  (`SDLBackend.heldPoint`, from `SDL_GetGlobalMouseState`), and a view drag's layer is drawn on
  every screen (`core.screens.markEverywhere`).
- The window is moved and resized only by dvui (header, edges); the OS does neither, and there is
  no OS shadow, rounded mask or material (P4). Tried on Windows 11 (hardware GPU): the right and
  bottom edges resize steadily, but the left and top edges change the window's place and size in
  two SDL calls, and it shows moved and not yet sized for a moment between them. Doing both in one
  `SetWindowPos` behind SDL's back is worse: SDL never learns the new size, its swapchain stays the
  old one (the picture cropped in a bigger window) and its idea of the size goes stale. The fix is
  the OS resizing the window — its edges hit-tested (`WM_NCHITTEST`), as the main window's chrome
  is (`win32_titlebar.zig`) — not the app moving it under SDL.
- A popped-out window's pointer is read from the desktop (`SDL_GetGlobalMouseState`), not from
  the event plus where the window is: the window moves under an edge or header drag, and an event
  queued before a move, read against the window after it, set the edge oscillating.
- On Windows the window is owned by the main window (`SDL_SetWindowParent`), so it stays over it
  and hides and minimizes with it — but has no taskbar button of its own yet (P4). Not on macOS,
  where SDL's child window would move with the main one (decision 2).
- Out, the float draws no frost, shadow or margin (they read and drew into the transparent
  window's empty edges and corners): its panel alone on the opaque backing, until P4's material.
  On macOS it has its shadow and frost since ("What P3 found"). Elsewhere the shadow is drawn,
  and the frost waits for a material.
- One float out at a time in the spike (the backend holds eight). Out, a float is not remembered:
  `layout.zon` keeps its in-window rect, and it comes back in on the next launch.
- One density, the main window's, fixed when the viewport opens (P5).
- macOS only so far; Windows, X11 and Wayland's in-window fallback not tried.

## What P3 found

With `FIZZY_POPOUT=1`, a float held past the main window's edge, being moved or resized, splits
out into a window of its own. So does one held with the pointer past the edge, since a float is
held on the main window by all but a strip of itself. Let go outside, it settles there. Let go
wholly inside, it merges back. A settled float let go wholly inside comes back too, as the command
does (`src/editor/Popout.zig`). There is no transition, as in Dear ImGui: its window shows it
exactly where it was drawn, before and after. Checked on macOS with demo tapes, which put input
straight into dvui.

### Coordinates change only at rest

The plan converted a float's rect "at the split and the merge". Converting under a held drag does
not work: dvui moves a float by the pointer's motion since the press (`FloatingWindowWidget`'s
drag), so a rect moved into a band mid-drag sent the next motion across the frame.

- **Split.** A float split under a drag stays in the main window's frame, which runs on past its
  edge across the desktop: `frame = (screen − main origin) · density`
  (`viewport_map.mainFromScreen`, unit tested). Its window follows it there
  (`SDLBackend.viewportPlaceMain`), and only its own subwindow is taken into the window, by id.
  Everything else in that frame stays the main window's, and nothing opens from the float until
  it settles (`core.screens` cleared).
- **Release.** Only when let go does the float move frames. Outside the main window, it goes into
  its band at the same place on the desktop, its window unmoved (`viewportBandFromMain`). Wholly
  inside, it goes nowhere: it merges where it is.
- **Pointer.** While the float out is being moved or resized, a held pointer is read in the frame
  it is drawn in, from the desktop (`viewports.pinPointer`): the main window's while split, its
  band once settled. It does not jump between frames as it crosses from one window into the
  other.

### No blink

- A new window is created hidden and shown after the first frame it is handed (P2). Until it has
  shown one, the float is copied into it and also left in the main window's replay
  (`viewports.shown`), so it is never on screen in neither.
- Merging, or brought back by the command, the float's window is let go a frame later, once the
  main window has drawn it (`Popout.closeAfterFrame`).

### The macOS dressing

- **One look in and out.** The window is clear and has no AppKit shadow. It is the float's rect
  grown by a clear margin (`Floats.outReach`, its shadow's reach), and the float draws there the
  shadow it draws in the main window (`FloatingWindowWidget.InitOptions.detached_reach`).
- **Vibrancy.** The main window's material sits beside SDL's view and under it, in the window's
  frame view, rather than being made its content view as the main window's is. It is masked to
  the glass's rounded rect with a stretchable image, so the margin stays clear through a resize.
  SDL's view stays its content view, and SDL tears down the window it made. The float frosts over
  it as it does in the main window (`Floats.Viewport.material`). Split under a drag, its frost
  still reads the main window's frame, so what is over the main window reads the app and what is
  past it reads the vibrancy.
- **Matching the main window's glass, then not (#222, P6).** For a while the pop-out imitated a
  glass window in the main window: its frost read the main window's picture behind it (hybrid
  frost), the main window cut a hole under its glass and its vibrancy was masked off the main window
  so its colour matched, and the main window's place was read from the window server so all of that
  kept up with the OS moving the windows. It never quite could: the OS moves a window faster than
  fizzy draws it, so the blur trailed the window and its rim streaked a pixel at a time. Once floats
  were windows from birth (P6), the user's call: "now that its real windows, we stop trying to
  match it to in-app dialogs and just draw it the same as the main window". All of that is gone.
- **Autorelease pools.** Objective-C called from the frame loop needs an autorelease pool of its
  own, because SDL wraps only its own calls. Without one, the subview arrays AppKit autoreleased
  kept the window SDL closed alive in the window server after every pop-in.
- **No OS animation.** AppKit's show and close animations never finished under fizzy's frame loop.
  The stand-in window they draw stayed on screen: shrunk while the float was out, and after the
  pop-out window had gone, where it first opened. The animation is off
  (`NSWindowAnimationBehaviorNone`).
- **Over the main window.** SDL orders a window it shows without activating it below the key
  window, the main one. The pop-out is ordered back above it, and again whenever it has fallen
  behind (a press on the main window, a document opened from Finder raising it): the behaviour of
  an owned window on Windows, without the child window AppKit would move with the main one.
- **Drawn as the main window.** A float in a window the OS frames has no glass of its own: the
  window's base stands under its content, its chrome at the window's opacity over the material
  (`Popout.backing`), as the main window's content stands on its base, and the OS draws the shadow.
  The OS's blur of what is behind the window keeps up with any move, as the main window's does.

### Not checked

- **A real pointer.** The tapes put input straight into dvui, so only a real drag exercises the
  OS's routing of a held pointer across two windows and AppKit's tracking of it.
- **The vibrancy by eye.** The sandbox's windows were on another Space in these runs, and
  `screencapture -l` could not take them.
- **`NSGlassEffectView`** (macOS 26).

### Windows: the window is the glass

A DWM backdrop fills the whole window, so the clear margin macOS keeps for fizzy's own shadow would
come out frosted. On Windows the window is exactly the float's glass (`viewports.os_frame`), and
DWM dresses it as it does the main window (`win32_titlebar.viewportChrome`):

- **Material.** Acrylic, through the frame extended over the whole window.
- **Corners and shadow.** DWM rounds its corners to 8 points, fizzy's surface radius as designed,
  and draws its shadow.
- **No border, no system menu.** With the frame extended, DWM drew the caption buttons of SDL's
  `WS_SYSMENU` over the float's header.

On either OS the material follows the app's light or dark theme, not the system's.

### The OS moves and resizes the window

A settled float's window is moved and resized by the OS, as any window is: Aero Snap, half the
screen, maximized at the top, Win+arrows, macOS tiling.

- **The hit test.** Each frame the float says where its header, its header's close button and its
  glass are (`viewports.hints`). SDL's hit test answers the OS from that (`viewport_map.hitTest`,
  unit tested): the header moves the window, and the glass's edges resize it. The window is
  created resizable, since only a window the OS may resize snaps or tiles.
- **macOS.** SDL there takes only the move from the hit test (AppKit's window-background drag);
  a titled window (P6) resizes from its edges by itself. Having the app move the window instead,
  in the transaction its picture is presented in, was tried: in step, but no tiling, and the window
  lagged the pointer by the app's frame.
- **The float follows its window.** When the OS moves or resizes the window, the float's rect
  follows it (`viewports.osPlaced`). The app's own placement, reported back, is told apart by
  comparing it with where the app last put the window. On X11, where placing a window is
  asynchronous, reports that come soon after the app's own placement are ignored too.
- **Merge after an OS move.** A move the OS made, let go wholly inside the main window, merges as
  one of dvui's does (`viewports.osMoveEnded`). A resize does not, nor a move that snapped or
  maximized the window as it was let go. On Windows the `WM_SYSCOMMAND` that starts the loop says
  which it was: Windows sends `WM_SIZING` when a snapped window takes back its size as it is
  dragged off its snap, though that is a move. Elsewhere the size before and after decides.
- **The handoff.** The drag that splits a float out began as dvui's, in the main window, before
  its window existed. On Windows, once the new window has shown a frame, that drag is handed to
  the OS (`viewports.dragMove`): dvui's capture ends, the float settles where it is, and the window
  takes a caption press where the pointer is, so the OS's move loop carries on from there. Frames
  go on during the loop: SDL runs them from the loop's timer (fizzy uses SDL's main callbacks on
  Windows), and a frame in the loop does not wait for events (`SDLBackend.inLiveResize`).
  Elsewhere the app moves the window until the release, and the OS from the next press.

Checked on Windows 11 on Arm in a VM, with real input inside the VM (`SendInput`):

- the Explorer's float dragged past the main window's edge split out, and its window went on
  following the pointer under the OS;
- dragged on to the screen's left edge, Windows showed its snap preview, and let go there the
  window took the left half, the float laid out to it;
- dragged off the snap, it took back its size, and let go over the main window it merged;
- pulled by its left edge, the OS resized it with its right edge still.

### Linux

- **X11.** The split, the settle and the merge run as on the other two. One difference: Vulkan
  hands a window no swapchain image while it is hidden, so a viewport's window would never get the
  first frame it waits for to show. There, the window is shown empty, which is clear, and drawn
  into from the next frame (`Viewport.mapped`). The float stays in the main window's picture until
  its window has shown a frame, so it never blinks. Checked on Ubuntu in a VM through XWayland,
  Vulkan on llvmpipe, by the tapes, with the window's position sampled as it moved.
- **Wayland.** A client cannot place its windows, so viewports are off there
  (`viewports.available`), and floats stay in the main window.

### Hybrid frost: the same glass in and out

*Removed in P6: a float in its own window is drawn as the main window is ("Matching the main
window's glass, then not", above). Kept as the record of what was tried.*

A float's glass is made as see-through as what it reads, and frosts and refracts it. In the main
window it reads the app; out of it, its window's own pixels. With nothing there it drew nothing;
with the main window's base stood behind it (`Popout.backing`) it drew a tinted pane. That pane
was right over the desktop but not over the main window, where in-window the glass had frosted
the app under it, so the look changed the moment a float split out. (At a window opacity of 0 the
two looked nearly the same: a pop-out's vibrancy blurs whatever is behind its window, and over the
main window that is the main window, which is what the frost does in it.)

Fizzy draws the main window every frame, so where a float's window lies over the main window it
has the picture behind it. The glass's frost reads that instead of its window's pixels: while the
float's drawing replays into its window's target, `BlurBackdrop.behind` names the float's pane, and
its capture comes from `Popout.behindGlass` rather than the target. That builds, over exactly the
rect the frost captures (the margin past the rim included), the main window's picture where the
main window lies under the float's window (`FrameTarget.frameTexture`: the frame drawn so far,
before the deferred subwindows replay; its place in the main window's frame is the window's part
of the frame while split under a drag, and where its window is, `viewports.inMain`, once settled),
and the main window's base past its edge, where the desktop is and nothing of fizzy's sees. The
picture is never shown. The glass then frosts, bends and lights exactly what it does in the main
window, its rim included: past the rim it reads the picture too, where its window holds only the
clear margin its shadow is drawn in. Read from the window's own pixels, the rim bent nothing in
and the glass looked a flat blur.

Checked on macOS with frame dumps. On the frame a float splits out it is drawn twice, in the main
window and in its own, and the two pictures of its glass differ by under 1/255 on average: the same
blur, glows, rim light, and the same text bent at its left rim. Settled straddling the main
window's right edge, the panel's green "All" button shows blurred behind its glass and bent at its
rim exactly where the button is in the main window, and the base past the edge.

What it does not do yet:

- **Deferred subwindows under it.** The picture is the frame before dialogs and other floats
  replay, so a float out over another float frosts the layout, not that float.

## P6: floats are windows

Where the platform has OS windows (`viewports.available`: macOS, Windows, X11), every float is one,
from the frame it is made in.

**Built (first step, macOS):**

- **Born as a window.** A float made by a drop on a view's own middle, or brought back from a saved
  layout, goes into a window of its own before it is ever drawn in the main window
  (`Popout.beginFrame`), at its whole rect (not the carried glass it lands from). One window per
  float (`Popout.outs`, up to the backend's eight). The held drag, splitting at the main window's
  edge and merging back are gone, with `Float.split` and the "Pop Out Float" command: a float's
  views go back into the main window by being carried there, and an emptied float's window closes.
  A window a view is carried out of stays as it is (no ghost).
- **Titled, as the main window is (macOS).** Created titled, not borderless
  (`SDLBackend.viewportOpen`), and dressed as the main window: content under a transparent title
  bar, the title's text hidden (the float's header shows it), the OS's traffic lights, shadow,
  corners and resizing from every edge (`fizzy_macos_viewport_glass`). The window is the glass
  (`viewports.os_frame`): no clear margin, no shadow of fizzy's, and the float resizes nothing
  itself. Its header draws no close button beside the traffic lights (`viewports.os_buttons`); the
  red one closes the float, its views going home (`Floats.Viewport.close_asked`), at once, as any
  window closes — no fly-shut.
- **Drawn as the main window.** No frost, rim or shadow of the float's own in a window the OS frames:
  its content on the window's base over the OS material, as the main window's content is. The hybrid
  frost, the hole and mask under it in the main window, and reading where windows are from the
  window server are gone with it.

- **Carrying a view outside every window (macOS).** While what a view is carried as lies past the
  main window, and over no float's window, a carry window shows it there (`Popout.carryFrame`,
  `viewports.openCarry`): borderless and clear, the pointer passing through it, at a pop-up menu's
  level above every window, in no window list. The drag's drawing, recorded in the main window's
  frame past its edge (`core.screens.publishBeyond` lets it reach there), is copied into it over
  the main window's base, for its glass to read; what of it lies over the main window is cleared,
  where the main window shows it with its glass over the app. Let go over no window of the app's,
  the view floats where it was let go (`ViewDrag.floatAway`, `State.floats_windowed`): a float of
  its size round the pointer, in a window of its own. An OS drag-and-drop session was the
  alternative: its image glued to the cursor, but a still picture, no liquid glass. Not yet: a
  material behind it (its glass is over an opaque base out there, where the desktop is), and
  straddling a float window's edge it is cut at that edge.

**Next:**

1. **Growing out of the carried glass.** The window's frame from the drop to its rect, in step
   with its picture (the transaction moves and resizes already use).
2. **Windows and X11 chrome.** Windows: the float's header draws caption buttons, as the main
   window's does (`caption_buttons.zig`). X11: client-side decorations, as the main window's. And
   the carry window there.
3. **Persistence of where the windows are** (`SavedRegion.Floating.os`): a saved float comes back
   in its window where it was on the desktop, not where it would be over the main window.

## Next steps

1. **The look on Windows with a GPU.** The VM draws Acrylic as its solid fallback, and its rounded
   corners only partly.
2. **macOS and X11 with a real pointer.** On macOS: the AppKit drag of the header, tiling, and
   whether a handoff at the split can be done there (`performWindowDragWithEvent:` takes the press
   that began the drag). On X11: the hit test's `_NET_WM_MOVERESIZE`, the clear margin with and
   without a compositor (without one it would show black), and a handoff through it.
3. **Persistence** (`SavedRegion.Floating.os`).
4. **P4's lifecycle.** Minimize, maximize and close with the main window. Done of it: a pop-out
   is called what its float's header says, has a taskbar button of its own on Windows (an owned
   window with `WS_EX_APPWINDOW`, the main window's icon on it; checked in the VM, its thumbnail
   beside the main window's), and is in the Window menu and the Dock's on macOS. On X11 it is
   transient for the main window, which keeps it out of most taskbars.
