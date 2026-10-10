# Spike: the drag's glass on Windows, through Windows.UI.Composition

Answers the four questions `plans/WINDOWS_LINUX_GLASS_PLAN.md` ("Order of work", step 5) asks before
fizzy builds the Windows overlay (`NATIVE_WINDOWS_PLAN.md`, Phase 2):

1. Can a Windows.UI.Composition target that is **not** topmost share an HWND with the topmost
   DirectComposition target fizzyedit/SDL presents a transparent window's D3D12 swapchain through?
2. A host backdrop clipped by a path rebuilt every frame: what does its edge look like, and how far
   does it sit from the app's own present?
3. Can an effect graph mask the host backdrop with a swapchain the app presents?
4. Does the overlay pass every click through while its composition tree still shows, with a drag in
   flight? And does `WS_EX_LAYERED` (`SDL_SetWindowOpacity`, the ghost fade) leave a window with a
   composition swapchain and a composition tree alone?

## Run

```sh
cd spikes/windows-composition
zig build -Dtarget=x86_64-windows-gnu   # or aarch64-windows-gnu
```

Then run `zig-out/bin/windows-composition-spike.exe` on Windows 11. It uses fizzy's own pins of
fizzyedit/SDL and zigwin32, and it logs to its console.

The window is transparent, and SDL presents it on D3D12 through its DirectComposition target, as
fizzy's windows are. Under that, a composition target holds one sprite: the host backdrop (a blur
of what is behind the window), cut to a pill that sweeps side to side, with a circle orbiting it.
SDL draws a red box round the pill, a yellow box round the circle, and a green mark at the pill's
leading end. The glass should sit exactly inside the red box.

| Key | What it does |
|---|---|
| `1`–`5` | Mode: `full` window backdrop, `rect` rounded-rect clip, `path` Direct2D path clip, `mask` effect-graph mask, `hosted` (the picture as a swapchain in composition's own tree, not SDL's target) |
| `M` | Merge the circle in, or show the pill alone |
| `T` | When the clip is set: `before` the present, set and `pump` the dispatcher, or `after` |
| `D` | Clip delay: give composition the shape from 0–3 frames ago |
| `F` | SDL_GPU frames in flight, 1–3 |
| `B` | Host backdrop, or a flat colour (easier to see, and measurable) |
| `O` | `SDL_SetWindowOpacity` 0.6 / 1 (spike 4b) |
| `V` | Overlay over the whole display, through its variants: `layered`, `layered_alpha`, `transparent`, `hittest`, off |
| `Space` / `Up` / `Down` | Pause, or change the speed |

Environment variables set the same things at launch: `SPIKE_MODE`, `SPIKE_TIMING`,
`SPIKE_CLIP_DELAY`, `SPIKE_FRAMES_IN_FLIGHT`, `SPIKE_PRESENT` (`vsync`, `mailbox`, `immediate`),
`SPIKE_OVERLAY`, `SPIKE_SPEED` (px/s), `SPIKE_COLOR=1`, `SPIKE_SINGLE=1`, `SPIKE_TRANSLUCENT=1`, and
`SPIKE_SECONDS` to quit after a while.

## How it was measured

Everything below was run in the Windows 11 ARM VM (build 26300, D3D12 on WARP, 60 Hz, aarch64
build), driven through `SendInput`.

**Offsets:** read from screenshots (`Graphics.CopyFromScreen`, which captures DWM's composed frame).
The analyser takes the row through the red box's middle and compares the blue colour-brush glass
with the box's inner edges. The green mark gives the direction of travel. Six screenshots per run.

**Clicks:** `EnumWindows` and DWM attributes for the window list, and the spike's own log of the
clicks and drags that reach it.

The pieces are bound by hand. Every WinRT interface's GUID and vtable slots were read from the OS's
own metadata (`C:\Windows\System32\WinMetadata\*.winmd`, through System.Reflection.Metadata). Each
one is cited in `src/winrt.zig`.

## Findings

**1. Two targets on one HWND: yes.**
- `CreateDesktopWindowTarget(hwnd, FALSE)` on SDL's claimed transparent window succeeds, with
  IsTopmost false.
- The composition tree draws under SDL's DirectComposition content, and SDL's picture draws over it.
- Static, the glass and SDL's box align to the pixel: composition's units on a desktop target are
  the swapchain's pixels.
- So fizzy needs no SDL change to put a backdrop under its picture.

**2. Path clip rebuilt every frame: works, antialiased, and early by SDL's present queue.**
- A new `CompositionPath` per frame, from a hand-written `IGeometrySource2D`, costs one
  `GetGeometry` call per frame (never `TryGetGeometryUsingFactory`).
- The clip's edge is antialiased over 1–2 px (12 → 29 → 175 → 230 across the pill's end), so the
  plan's "aliased edge" worry doesn't hold on WARP.
- The clip **leads** the present rather than trailing it, as the plan expected. At 400 px/s with
  SDL's default VSYNC, the glass sits about 14 px ahead of the box: ~2 frames, 35 ms.

| SDL present | Frames in flight | When the clip is set | Clip delay | Glass vs rim |
|---|---|---|---|---|
| VSYNC | 2 | before present / pump | 0 | 2.1–2.3 frames ahead |
| VSYNC | 2 | after present | 0 | 3.3 frames ahead |
| VSYNC | 1 | pump | 0 | 2.2 frames ahead |
| VSYNC | 1 or 2 | pump | 1 | 1.3 frames ahead |
| VSYNC | 2 | pump | **2** | **0.0 ±0.5 px** |
| MAILBOX / IMMEDIATE | 2 | pump | 0 | **0.0 ±0.5 px** |

- Composition properties land at the next DWM frame. SDL's VSYNC present arrives two frames after
  its submit; fewer frames in flight don't shorten that, but presenting without the vsync wait does.
- Pumping the thread's messages between setting the clip and presenting changes nothing; there
  is rarely a message waiting.
- For fizzy:
  - Either give composition the shape from as many frames back as the present queue is deep
    (2 here), measured rather than assumed: `IDXGISwapChain::GetFrameStatistics`, or SDL exposing
    its queue depth.
  - Or have the fork present with a frame-latency waitable swapchain (max latency 1), so the
    present is not queued.
  - Either way, check it on real hardware at 60 and 120 Hz before trusting a constant.

**3. Effect-graph mask: yes.**
- A hand-written `IGraphicsEffect` naming D2D's AlphaMask (no properties) compiles in
  `CreateEffectFactory` (LoadStatus `Pending`, then fine).
- A `CompositionEffectSourceParameter` takes a surface brush over
  `CreateCompositionSurfaceForSwapChain`: a swapchain the app presents. The glass shows exactly
  where the mask is drawn, antialiased by Direct2D.
- The mask here is a D3D11 swapchain presented without waiting, so it leads SDL's VSYNC picture
  by the same 2 frames as the clip. A mask presented on fizzy's own device and queue would move
  with the picture, which is the point of this route.
- Composite/SourceIn is wired as a fallback, and wasn't needed.

**4. Overlay: `WS_EX_TRANSPARENT | WS_EX_LAYERED`.**
- Tested on a display-sized, topmost, never-activated window, with no taskbar entry and
  `WS_EX_NOREDIRECTIONBITMAP`, holding a host backdrop pill and a hosted swapchain rim that follow
  the pointer:

| Style | Click to a window of the same thread | Click to another process (the desktop) | Tree shows |
|---|---|---|---|
| `TRANSPARENT \| LAYERED` | passes | passes | yes |
| same, `SetLayeredWindowAttributes(255)` | passes | passes | yes |
| `TRANSPARENT` alone | blocked; the overlay even becomes foreground | blocked | yes |
| `WM_NCHITTEST` → `HTTRANSPARENT` | passes | **blocked** | yes |

- `WindowFromPoint` claims `HTTRANSPARENT` passes to the desktop. The real click doesn't.
- A drag that starts in the window under the overlay and crosses onto the desktop keeps its
  capture: 30 of 30 motion events reached it, with the overlay's glass following the pointer.
- `SDL_SetWindowOpacity(0.6)` makes the window `WS_EX_LAYERED`. SDL's DirectComposition picture
  and the composition tree both still draw, at 60%, so the ghost fade can stay as it is.

**`hosted` (the fallback for spike 1, not needed):** a swapchain in composition's own tree, beside
the clip, aligns with it with no delay (0 px in 5 of 6 samples, one sample under a frame).

## Not answered here (needs a real GPU)

- **The blur itself.** In the VM the host backdrop draws solid black. Does the glass show a blur of
  what is behind the window on a hardware GPU, with transparency effects on, and fall back when
  they are off or on battery saver?
- **The timings on real hardware:** the present queue's depth at 60/120/144 Hz, and with a
  waitable swapchain in the fork.
- **Windows 11 23H2 / 24H2**: the VM is a 26300 build.

Run it on a real machine and note, for each of `path` with `B` off: the blur, the edge, and the
offset at clip delay 0 and 2 (`D`).
