# macOS: a live resize that never stretches

**Status.** Landed. fizzyedit/SDL `fizzy-3.4` carries the patches (patches 3–5 in
[`docs/DEPENDENCIES.md`](DEPENDENCIES.md), tag `fizzy-3.4.16-3`), fizzyedit/sdl_zig `fizzy` builds
it (tag `fizzy-1.0.3+3.4.16-3`), and fizzy's `.sdl` pins that. Fizzy's side does nothing on an SDL
without them. The first two versions were run on a Mac and were not enough; measured on one (see
"What a measured drag showed"), the second never drew a single frame in a step, because the Metal
view drew from `-updateLayer`, which AppKit never calls for it. The third, which draws from the
layer delegate's `-displayLayer:` instead, showed no stretched frame in any drag measured.

## The symptom, and where it comes from

Dragging a window edge on macOS, the content jitters: for a frame it is the old content stretched to
the new size, then it is right, then it is stretched again.

AppKit resizes a window under the pointer in a tracking loop of its own. Each mouse-dragged event is
one *step*: AppKit sets the window's new frame (the content views resize with it, and
`NSWindowDidResizeNotification` goes out, on which SDL sends `RESIZED`/`PIXEL_SIZE_CHANGED` and its
Metal view takes the new `drawableSize`), then commits the step's Core Animation transaction. The
window server shows the window at the new size **with whatever the layer holds at that moment**: the
previous size's drawable, which the layer's gravity (`kCAGravityResize`, set by
`window_monitor.m`) stretches across the new bounds.

The frame for the new size comes later, and on its own:

1. SDL draws during a live resize only from a 60 Hz `NSTimer` (`windowWillStartLiveResize:` →
   `SDL_OnWindowLiveResizeUpdate` → `SDL_AppIterate`), not when the size changes.
2. SDL_GPU's Metal driver presents with `-[MTLCommandBuffer presentDrawable:]`, which shows the
   drawable when Metal's own thread gets to it, outside any transaction AppKit commits.

So every step shows the old frame stretched, and the new frame lands a tick later, until the next
step stretches it again: the content updates fall between the window's size updates.

## Why fizzy alone could not fix it

Everything tried so far changes *when* a frame is drawn: vsync off for the drag
(`fizzy_macos_window_live_resize_vsync`), the monitor's pump, pushing AppKit's sizes into SDL by
hand, the gravity. None of it can change *how* SDL presents, and a drawable presented with
`presentDrawable:` never joins the transaction that resized the window, however early it is drawn.
That line is in SDL's Metal driver, so the fix is a patch, which `fizzyedit/SDL` now makes possible.

## The fix: two ingredients, both needed

1. **Draw inside the step's transaction.** AppKit displays the views a step dirtied while the
   step's transaction is open, before it commits. The Metal view's redraw policy
   (`NSViewLayerContentsRedrawDuringViewResize`) makes it one of them, and its `updateLayer` runs
   the app's frame. With the timer alone, the frame always comes after the commit.
2. **Present with the transaction.** `CAMetalLayer.presentsWithTransaction = YES` for that frame,
   presented the way Apple prescribes for it: commit the command buffer, `waitUntilScheduled`, then
   `[drawable present]` on the main thread. The drawable then becomes the layer's content in the
   same transaction as the window's new size, and the window server shows the two together.

Either alone is not enough: drawn in the step but presented by Metal's thread, the frame still
misses the step's commit; presented with the transaction but drawn by the timer, the step's commit
still holds the stale frame. This is Zed's arrangement (`crates/gpui_macos/src/window.rs`: the
redraw policy, `displayLayer:` drawing one frame with `presentsWithTransaction` on and its display
link stopped, then off again), and Chromium solves the same problem by blocking `setFrameSize:`
until a frame of the new size arrives.

## What the first version showed

The first version drew from `windowDidResize:` (the notification) and kept the layer presenting
with the transaction for the whole drag, timer frames included. On a Mac:

- The jitter got much smaller, and some frames were perfectly still, but the content looked like two
  images over each other: correct frames interleaved with stretched ones.
- Horizontal resizing jittered; purely vertical resizing hardly did.
- A corner drag could get stuck: the window stopped following, the app froze, and the window
  snapped to the pointer on release.

Read against Zed's version, two things in it were wrong:

- **Where it drew.** The notification is not the display: when AppKit commits relative to it is
  AppKit's business, and a frame drawn there can land on either side of the commit, which is the
  interleaving. (Why only horizontal steps miss is not known; the titlebar relayouts on width
  changes, which is one candidate.) Drawing from the view's own display puts every frame inside the
  transaction that commits the step, by construction, once per commit.
- **How long it presented with the transaction.** With it on for the whole drag, a drawable is held
  until the transaction it joined commits and the compositor lets it go; frames drawn faster than
  commits (a timer frame and a step in one pass, or steps AppKit runs back to back) can take all
  three of the layer's drawables, and the next `nextDrawable` then waits up to its one-second
  timeout, on the main thread, inside the tracking loop. That fits the freeze; it has not been
  confirmed. Zed turns it on for the one frame its display draws, and so does the second version.

Nothing in it needs a newer macOS: `presentsWithTransaction` is 10.11+, `inLiveResize` 10.6. SDL
has no equivalent upstream (checked `main` on 2026-10-02).

## What the second version showed

Built from `claude/quirky-rubin-tpb2zd` (Debug), linking the patches through the test pins: no more
ghosted second copy, smaller jitter, and resizing felt more responsive, but it was still not smooth.
That was read as every frame now landing with its own size and something else left over (frame
time, layout settling over several frames, a size committed apart from its frame). Measured, it was
none of the first two: no frame was drawn in a step at all.

## What a measured drag showed

`FIZZY_LIVE_RESIZE_TRACE` and `scripts/live-resize/` (see "Measuring it") drag a window edge with
real mouse events and record the screen at 120 fps, and say for every screen update which frame it
showed and whether that frame was drawn for the size the window showed it at. Run locally on a
MacBook Pro (M5 Pro, 120 Hz ProMotion, macOS 26.5), right edge, 250 pt back and forth, about 110
resize steps a second:

| | frames shown stretched during the drag |
|---|---|
| the timer, as before (`SDL_VIDEO_MAC_SYNC_LIVE_RESIZE=0`) | 51–86%, up to 18 px off (32 px with a large document in Debug) |
| the second version (the test pins' SDL) | 52–61%, up to 34 px off: every frame came from the timer |
| the third version | **0%** — every edge and the corner, ReleaseFast and Debug, empty and with a large markdown document open |

- **The second version never drew in a step.** AppKit marked the Metal view as needing display at
  every step — the redraw policy works — and never displayed it: `-updateLayer` was not called once
  in a drag. NSView does not implement `-displayLayer:` (`instancesRespondToSelector:` is NO), and a
  view whose layer is a `CAMetalLayer` it makes itself is displayed only through its delegate's
  `-displayLayer:`. So the timer fell back after four ticks (SDL logged "Live resize: the Metal view
  is not being displayed"), and every frame was drawn as before, now with vsync on; that is what
  felt better. The third version moves the frame to `-displayLayer:` (Zed's view implements the same
  method for the same reason), and the trace's `src=display` on every frame shows it running.
- **Frame time** is not what was left: a ReleaseFast frame takes 2–3 ms in a step (the in-step
  present waits until the command buffer is scheduled), Debug 4–5 ms. A heavy frame (a large
  markdown document in Debug, ~15 ms) slows the window down to about 54 steps a second, never out
  of sync.
- **Layout settling** is not either: dvui asks for no follow-up frame after a live-resize frame
  (`wait` is the maximum), and right-anchored UI keeps its distance from the window's edge from
  frame to frame in the recordings.
- **Driving it:** posting mouse events into the app's own queue does start AppKit's tracking loop,
  but AppKit also reads the real cursor during it, so the window follows neither. The recorder posts
  HID events instead, which needs Accessibility for the app running it.

## The patches

| | What | Files |
|---|---|---|
| 3 ([`5882e2b`](https://github.com/fizzyedit/SDL/commit/5882e2b)) | Metal: present with the Core Animation transaction when the layer asks for it. The GPU driver (`METAL_Submit`) and the renderer (`METAL_RenderPresent`) commit, wait until scheduled and present on the calling thread when `layer.presentsWithTransaction`; exactly as before otherwise. SDL never sets the property in this patch. | `src/gpu/metal/SDL_gpu_metal.m`, `src/render/metal/SDL_render_metal.m` |
| 4 + 5 ([`80bdc7d`](https://github.com/fizzyedit/SDL/commit/80bdc7d), [`8455e58`](https://github.com/fizzyedit/SDL/commit/8455e58)) | Cocoa: `SDL_HINT_VIDEO_MAC_SYNC_LIVE_RESIZE` (default off). For the length of a live resize the window listener gives the Metal view the redraw policy `DuringViewResize`; the view's `displayLayer:` (its layer's delegate method: AppKit never calls `updateLayer` for it) brings SDL's sizes up to the window (`windowDidResize:` again, a no-op when it has run) and runs the app's frame with the layer presenting with the transaction for that frame alone. The timer only asks the view for a display while the pointer rests; if AppKit does not display the view for four ticks it draws as before and logs `Live resize: the Metal view is not being displayed` once. A frame is never started from inside one already running. | `include/SDL3/SDL_hints.h`, `src/video/cocoa/SDL_cocoawindow.{h,m}`, `src/video/cocoa/SDL_cocoametalview.m` |

4 needs 3: without it the layer would ask for transaction presents that SDL's presenters ignore.
5 is the fix to 4 (`displayLayer:`, not `updateLayer`), to be squashed into it at the next rebase. The hint is off by default, as it would have to be upstream: it requires the app to present
on the main thread through SDL's Metal paths, and a Vulkan (MoltenVK) app, presenting from its own
thread, must leave it off.

They are not in the SDL that dvui pins (a 3.4.4 dev fork with a different `METAL_Submit`), which
only `-Dnative-backend=sdl3` uses; and upstream `main` has moved the lines 3 touches, so an
upstream PR is a small rebase.

## Fizzy's side (in the tree)

- `platform/macos_monitor.zig` `install` sets `SDL_VIDEO_MAC_SYNC_LIVE_RESIZE=1`, by name, so it
  builds and is ignored on an SDL without the patches. Both native backends go through it.
- `SDLBackend.appIterate` never waits for events while AppKit's tracking loop runs
  (`fizzy_native_in_live_resize`). A frame the timer runs while the pointer rests carries no resize
  event, so `have_resize` did not catch it, and a wait there takes the tracking loop's own mouse
  events (the stall the comment above that check describes). Before this change it could happen
  whenever the pointer paused mid-drag; with the patches every frame drawn while the pointer rests
  is such a frame.
- `FIZZY_LIVE_RESIZE_TRACE=1` (`SDLBackend.live_resize_trace`, `platform/macos/live_resize_trace.m`):
  a line on stderr per resize step and per frame inside the tracking loop — where the frame came
  from (`src=display`, drawn from AppKit's display of the view and presented with its transaction,
  or `src=timer`), its time and duration, the window, layer and drawable sizes, and dvui's `wait` —
  on `CACurrentMediaTime`'s clock, and an overlay on every frame: a barcode of the frame's number and
  size, and bars on its edges. Off, it costs a getenv once.
- Vsync is no longer turned off for the drag when SDL draws it (`sdl_draws_live_resize` in
  `window_monitor.m`: the hint is on and the window's delegate, SDL's listener, answers
  `drawsLiveResizeInView:`, which only the patched SDL does). Turning it off was for the timer's
  vsync-blocking present; a present in the step waits only for the GPU to schedule it, and Zed
  runs its resize with display sync on. On an SDL without the patches, vsync goes off as before.
- After each frame inside a live resize, `SDLBackend.appIterate` tells `macos_monitor.m`
  (`fizzy_native_live_resize_next_frame`) when dvui wants the next one, and it asks AppKit to
  display the Metal view then, at the display's rate, while no step does (see "Animating while no
  step comes").

## Animating while no step comes

**The symptom.** Dragging the window down to its minimum size quickly, the app lagged as the
explorer folded itself away, and only until the fold had finished.

**Where it comes from (read from the code, not yet measured).** Inside the tracking loop a frame
comes from AppKit's display of the Metal view, and nothing else: `appIterate` waits for no event
there, so dvui's wait — 0 while something animates — goes unread. A step displays the view. Between
steps, only SDL's 60 Hz timer asks for a display, on a tick where no frame has started for a whole
tick (`sinceFrame < intervalNS` in fizzyedit/SDL's `windowWillStartLiveResize:`). The frame it asks for starts a
little after its tick, so the next tick finds a little less than a tick since it and skips: as few
as 30 frames a second, a quarter of a 120 Hz display's rate.

No step comes while the pointer rests, or once the window is at its minimum size: AppKit leaves
the frame as it is, and the view is not displayed. Neither shows when nothing moves. The explorer
folds when the area beside the rail is narrower than `Region.InitOptions.collapse_below` (640 pt),
a little above the window's minimum width (640 pt, `Constants.min_window_size`), so a fast drag to
the minimum reaches it a few steps into the fold, and the rest of the 300 ms slide played on the
timer's ticks. Once the slide ended there was nothing left to draw.

**The fix.** After each frame in a live resize, `appIterate` passes dvui's wait to
`fizzy_native_live_resize_next_frame` (`macos_monitor.m`), which arms a one-shot timer that marks
the Metal view as needing display when that frame is due — no sooner than a display refresh
(`NSScreen.maximumFramesPerSecond`) after this frame began, and two refreshes after a step, so a
drag's own steps, about a refresh apart, are not each preceded by a frame of this one's. Any frame
that comes first re-arms it; a wait for an event disarms it. The frame is drawn from the same
display a step draws from, presented with its transaction like every other; SDL's timer, finding a
frame inside its tick, asks for nothing. Only when SDL draws the resize (the listener answers
`drawsLiveResizeInView:` for the view); on an SDL without the patches the timer draws every tick, as
before.

**Checking it.** `FIZZY_LIVE_RESIZE_TRACE=1`, drag fast down to the minimum width with the explorer
open, and hold the button: the frames after the last `step` line are the slide. Before, their
`since=` was about 33 ms; now it should be a display refresh (8.3 ms at 120 Hz), with `wait=0` on
each until the slide ends. SDL's timer itself is unchanged: while the pointer rests it still asks
for a display every other tick, wanted or not, but fizzy's animations no longer depend on it.

## Where it lives

The SDL patches are fizzyedit/SDL `fizzy-3.4`'s 3–5, built by fizzyedit/sdl_zig `fizzy`; how to
carry them through an SDL rebase, and where they conflict, is in [`docs/DEPENDENCIES.md`](DEPENDENCIES.md).
After resolving, `clang -fsyntax-only -fobjc-arc` on the `.m` files with the macOS SDK is enough
to push; the real check is a drag on a Mac (below).

## Measuring it

`scripts/live-resize/run.sh <fizzy> <out-dir> <edge> [amp] [period] [cycles] [-- VAR=value ...]`
runs a fizzy beside yours (its own HOME and lock), drags `edge` (`r`, `l`, `t`, `b`, `tr`) back and
forth with real mouse events while recording the screen around the window at 120 fps, quits it, and
prints what `analyze.py` makes of the trace and the recording: steps and frames a second, where the
frames came from and how long they took, and how many screen updates during the drag showed a frame
drawn for another size than the window's (stretched). A/B without rebuilding:

```sh
scripts/live-resize/run.sh zig-out/arm64-macos/fizzy /tmp/lr-new r
scripts/live-resize/run.sh zig-out/arm64-macos/fizzy /tmp/lr-old r -- SDL_VIDEO_MAC_SYNC_LIVE_RESIZE=0
```

The app running it needs Accessibility (for the mouse events) and Screen Recording; the pointer
moves during the drag. `FIZZY_ARGS` passes files to open. `record.swift`'s `png-dir` argument keeps
the captured frames too. A window that ends against the menu bar stops resizing while the pointer
goes on (a gap in the steps, not a stall); keep `amp` within the screen. On a run that reports no
steps, the press missed the edge: run it again.

To iterate on the SDL patches locally without pushing: clone fizzyedit/SDL and fizzyedit/sdl_zig
beside fizzy (`../SDL`, `../sdl_zig`) on `fizzy-3.4` and `fizzy`; in sdl_zig's `build.zig.zon`,
`.sdl = .{ .path = "../SDL" }`; in fizzy's `backend/build.zig.zon`, `.sdl = .{ .path = "../../sdl_zig" }`.
A rebuild picks up an SDL edit.

## Checking it on a Mac by hand

- Drag every edge and corner, slowly and fast, with a trackpad and with a mouse, on a 60 Hz display
  and on ProMotion. Expect no stretched frame at all; the window may follow the pointer a little
  more slowly than before, since each step now waits for fizzy's frame.
- A/B without rebuilding: SDL reads hints from the environment ahead of `SDL_SetHint`, so
  `SDL_VIDEO_MAC_SYNC_LIVE_RESIZE=0` gives the old behaviour (vsync off for the drag included).
- Watch the log for `Live resize: the Metal view is not being displayed`: it means AppKit never
  displayed the view during the drag, so none of this ran and the frames came from the timer. (It
  is what the second version logged on every drag.)
- To see single frames, record the screen at 60 fps (QuickTime) and step through the drag.
- A heavy frame (liquid glass up, a large markdown preview) is the stress case: the resize gets
  slower, never torn. If it gets too slow, the answer is a cheaper frame during a live resize, not
  drawing outside the step.
- Zoom, fullscreen Spaces and the window's restore at launch are untouched (no live resize there);
  check they still behave.

## If it is not enough

- **A frame that still misses** (the swapchain unavailable for a step): `kCAGravityTopLeft`
  instead of `kCAGravityResize` during a manual live resize (`sync_metal_layers` in
  `window_monitor.m`) shows such a frame anchored at the top left, an edge of background, instead
  of stretched. Check the orientation on a Mac before relying on it: gravity's "top" depends on the
  layer's flippedness.
- **Zoom and Space animations** still go through the monitor's 60 Hz pump and have the same split
  between size and frame. The same two ingredients would fix them (the redraw policy and the
  in-display frame while the monitor knows an animation is running), as a follow-up once the live
  resize is confirmed.
