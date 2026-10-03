# Windows: a live resize whose frames fit the window

**Status.** On test, not yet seen on hardware. The SDL patch is on fizzyedit/SDL
`claude/windows-live-resize` (`ee721bf`), built by fizzyedit/sdl_zig `claude/windows-live-resize`
(`8e88dba`), which fizzy's branch of the same name pins. Measured only in a Windows 11 on Arm VM
(UTM, D3D12 on WARP), which cannot judge the half that matters most (see "What the VM showed").
The macOS counterpart is [`MACOS_LIVE_RESIZE.md`](MACOS_LIVE_RESIZE.md).

## The symptom, and where it comes from

Dragging a window's edge, its right and bottom sides run ahead of fizzy's drawing: growing, an edge
with nothing drawn on it; shrinking, the frame cut off, the chrome at the edge missing. Nothing
stretches, unlike macOS: fizzy's window is transparent, and SDL presents a transparent window
through a DirectComposition swap chain (fizzyedit/SDL patch 2), which the compositor shows at its
own size, unscaled, anchored at the top left.

Windows resizes a window under the pointer from a modal loop of its own: each mouse move is a step
that sets the window's new size (`WM_WINDOWPOSCHANGED`), and the compositor shows the window at it
at the next composite, with whatever frame the swap chain holds. The frame for the new size comes
later, from two delays:

1. SDL draws during the loop only from a `USER_TIMER_MINIMUM` timer, which Windows raises only once
   the loop's queue is empty — after the step, often a composite or more after it.
2. Frames queue: SDL_GPU lets frames run ahead of the GPU, and each present waits its turn at the
   compositor, so a frame drawn for one size reaches the screen behind others drawn for older ones.

## The fix: two ingredients

1. **Draw each step from inside it** (the SDL patch, `SDL_HINT_VIDEO_WIN_SYNC_LIVE_RESIZE=1`, which
   `win32_titlebar.applyChrome` sets). `WM_WINDOWPOSCHANGED`, inside the loop, runs the app's frame
   for a step that changed the size, then `DwmFlush`es: the loop's next step starts just after a
   composite, so a size and the frame drawn for it reach the screen together. The timer draws only
   while the pointer rests (no step for 50 ms).
2. **Finish each frame of the drag on the GPU before presenting it** (`GpuRenderer.present`'s
   `finish`, whenever `SDLBackend.inLiveResize` — the thread's `GUI_INMOVESIZE`). No frame queues
   behind another, and the step's `DwmFlush` finds its frame done. It needs no SDL patch.

`SDLBackend.appIterate` also no longer waits for events inside the loop (`inLiveResize` was
macOS-only): a frame the timer runs carries no event, and a wait there would hold up the loop.

The compositor applies a window's size and its frame separately, so a composite that falls between
the two still shows one frame that does not fit; drawing right after a composite makes that rare
when a frame takes well under one refresh.

## What the VM showed

A drag of the right edge driven through QEMU's monitor: 12 steps of 10 px out, 12 back, 30 ms
apart, a screen dump after each, scored by whether the drawing reached the window's edge (growing)
and kept its chrome (shrinking). Two drags per row, 48 frames:

| | frames that fit the window |
|---|---|
| neither (PR #206's build) | 19 / 48 |
| the GPU finish alone (`SDL_VIDEO_WIN_SYNC_LIVE_RESIZE=0`) | **41** / 48 |
| the steps alone | 39 / 48 |
| both (what this ships) | 32 / 48 |
| both, without `DwmFlush` / without the timer's rest | 35–37 / 48 |

Either ingredient alone halves the misses or better; together they did no better in the VM. That
is not the hardware's answer: WARP draws on the CPU, a step's frame took 7–11 ms there and a
composite 20–60 ms (`FIZZY_LIVE_RESIZE_TRACE`), so each step blocked the loop for several
composites. On a GPU a frame takes 1–3 ms against a 16.7 ms or shorter refresh, which is what the
steps are built for, and the timer's delay (1) is there on any hardware.

## Checking it on Windows hardware

- Drag the right and bottom edges and the corner, out and back, slowly and fast. Expect the drawing
  to keep to the window's edges; the window may follow the pointer a little more slowly, since each
  step waits for a composite.
- A/B without rebuilding (SDL reads hints from the environment ahead of `SDL_SetHint`):
  `set SDL_VIDEO_WIN_SYNC_LIVE_RESIZE=0` keeps the GPU finish only; PR #206's build has neither.
- `set FIZZY_LIVE_RESIZE_TRACE=1` has SDL log every step: its size, how long the frame took and
  how long the compositor took to show it. "Shown" well over one refresh means the steps are
  costing composites.
- Moving the window (a title-bar drag) changes no size and draws no step; snapping and maximizing
  are not live resizes. Check both still behave.

## If it is not enough

- **Present before the window takes the size.** From `WM_WINDOWPOSCHANGING` (the step's size,
  before it is applied) draw and present the frame, then let the step go on: a frame that misses
  then shows on the old size for a composite instead of the new size showing the old frame.
- **Draw through the redirection surface for the drag** (Raph Levien's recipe in "The smooth resize
  test"): the legacy blt model is synchronized with the window manager, the flip model is not. It
  would need SDL_GPU to switch swap chains on `WM_ENTERSIZEMOVE`/`WM_EXITSIZEMOVE`, and a
  transparent window may lose its Acrylic for the drag.
