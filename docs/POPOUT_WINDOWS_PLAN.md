# Pop-out windows: floats that leave the main window

Agreed design, not yet built past its first phase. Written down because the decisions here were
reached by discarding the more obvious design (dvui's `osWindow`), and the reasoning is the
expensive part to re-derive.

## Where it stands

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
| **P2** | Viewport infrastructure: a float rendered into a second SDL window, input routed back. A debug command "Pop Out Float" | a flag |
| **P3** | The gesture: a float split out as it crosses the main window's edge, merged back when let go fully inside | the flag |
| **P4** | Per-OS dressing, parenting, minimize / maximize / close with the main window | — (flag off) |
| **P5** | Hybrid frost, mixed DPI, Wayland | — |

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

**macOS.** An unparented borderless `NSWindow` whose content view is an `NSVisualEffectView`
(active, the main window's material — `platform/macos/visual_effect_view.m`), a `maskImage` for the
rounded corners (`NSGlassEffectView` on macOS 26), `hasShadow`, a window level and collection
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
