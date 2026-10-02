# macOS: a live resize that never stretches

**Status.** Two SDL patches, written against `fizzyedit/SDL`'s `fizzy-3.4` (SDL 3.4.16 plus the two
Windows patches), are in [`docs/patches/sdl/`](patches/sdl/) waiting to move into that fork. Fizzy's
side is in the tree already and does nothing until SDL carries them. **None of it has been built or
run on a Mac yet**: the reasoning below is from SDL's and Apple's sources, not a recording.

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

1. **Draw inside the step.** In `windowDidResize:`, after the size events (so the drawable already
   has the new size) and before AppKit commits, run the app's frame. With the timer alone, the frame
   always comes after the commit.
2. **Present with the transaction.** `CAMetalLayer.presentsWithTransaction = YES`, and present the
   way Apple prescribes for it: commit the command buffer, `waitUntilScheduled`, then
   `[drawable present]` on the main thread. The drawable then becomes the layer's content in the
   same transaction as the window's new size, and the window server shows the two together.

Either alone is not enough: drawn in the step but presented by Metal's thread, the frame still
misses the step's commit; presented with the transaction but drawn by the timer, the step's commit
still holds the stale frame. This is the arrangement Zed (`presentsWithTransaction` while drawing
from `displayLayer:`) and Chromium (blocking `setFrameSize:` until a frame of the new size arrives)
use for the same problem.

Nothing in it needs a newer macOS: `presentsWithTransaction` is 10.11+, `inLiveResize` 10.6. SDL
has no equivalent upstream (checked `main` on 2026-10-02).

## The patches

| | What | Files |
|---|---|---|
| [`0003`](patches/sdl/0003-Metal-present-with-the-Core-Animation-transaction-wh.patch) | Metal: present with the Core Animation transaction when the layer asks for it. The GPU driver (`METAL_Submit`) and the renderer (`METAL_RenderPresent`) commit, wait until scheduled and present on the calling thread when `layer.presentsWithTransaction`; exactly as before otherwise. SDL never sets the property in this patch. | `src/gpu/metal/SDL_gpu_metal.m`, `src/render/metal/SDL_render_metal.m` |
| [`0004`](patches/sdl/0004-Cocoa-draw-each-step-of-a-live-resize-in-the-screen-.patch) | Cocoa: `SDL_HINT_VIDEO_MAC_SYNC_LIVE_RESIZE` (default off). `windowDidResize:` runs the app's frame during a live resize; the Metal view presents with the transaction from `viewWillStartLiveResize` to `viewDidEndLiveResize`; the timer skips any tick a step has already drawn, so it draws only while the pointer rests. A frame is never started from inside one already running. | `include/SDL3/SDL_hints.h`, `src/video/cocoa/SDL_cocoawindow.{h,m}`, `src/video/cocoa/SDL_cocoametalview.m` |

`0004` needs `0003`: without it the layer would ask for transaction presents that SDL's presenters
ignore. The hint is off by default, as it would have to be upstream: it requires the app to present
on the main thread through SDL's Metal paths, and a Vulkan (MoltenVK) app, presenting from its own
thread, must leave it off.

Both apply cleanly to `fizzy-3.4` (`git apply --check` on `3d6e802`). They do not apply to the SDL
dvui pins (a 3.4.4 dev fork with a different `METAL_Submit`), which only `-Dnative-backend=sdl3`
uses; and upstream `main` has moved the lines `0003` touches, so an upstream PR is a small rebase.
The new Objective-C has been checked for syntax under ARC against stub headers, nothing more.

## Fizzy's side (in the tree)

- `platform/macos_monitor.zig` `install` sets `SDL_VIDEO_MAC_SYNC_LIVE_RESIZE=1`, by name, so it
  builds and is ignored on an SDL without the patches. Both native backends go through it.
- `SDLBackend.appIterate` never waits for events while AppKit's tracking loop runs
  (`fizzy_native_in_live_resize`). A frame the timer runs while the pointer rests carries no resize
  event, so `have_resize` did not catch it, and a wait there takes the tracking loop's own mouse
  events (the stall the comment above that check describes). Before this change it could happen
  whenever the pointer paused mid-drag; with the patches every timer frame is such a frame.
- Vsync stays off for the drag, as before. A present inside the step waits only until the GPU has
  scheduled the frame, so it is no longer what keeps the window behind the pointer, but nothing
  says a vsync-paced drawable pool cannot still hold up `nextDrawable` there; revisit on a Mac.

## Landing it

Once the `fizzyedit/SDL` pin (`claude/lucid-maxwell-z5owlo`, `docs/DEPENDENCIES.md` there) is on
`main`:

1. In `fizzyedit/SDL`: the two patches become two changes on `fizzy-3.4`, each described by its
   patch's message (`git am` in the colocated checkout does both; or `patch -p1` and
   `jj describe` per change). Move `fizzy-3.4` to the new tip, push, tag `fizzy-3.4.16-3`.
2. In `fizzyedit/sdl_zig`: point `.sdl` at the tag's commit, tag `fizzy-1.0.3+3.4.16-3`.
3. In fizzy: `zig fetch --save=sdl` the new sdl_zig archive; record both patches in
   `docs/DEPENDENCIES.md` (patches 3 and 4, their files, upstream status), and delete
   `docs/patches/sdl/` and this file's "Status" paragraph.

Conflict surface on a later SDL rebase: `METAL_Submit`'s present loop and `METAL_RenderPresent`'s
tail (`0003`), and the live-resize timer and the end of `windowDidResize:` (`0004`). After resolving,
`clang -fsyntax-only -fobjc-arc` on the four `.m` files with the macOS SDK is enough to push; the
real check is a drag on a Mac.

## Checking it on a Mac

- Drag every edge and corner, slowly and fast, with a trackpad and with a mouse, on a 60 Hz display
  and on ProMotion. Expect no stretched frame at all; the window may follow the pointer a little
  more slowly than before, since each step now waits for fizzy's frame.
- A/B without rebuilding: SDL reads hints from the environment ahead of `SDL_SetHint`, so
  `SDL_VIDEO_MAC_SYNC_LIVE_RESIZE=0` gives the old behaviour.
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
  between size and frame. The same two ingredients would fix them (draw in `windowDidResize:` while
  the monitor knows an animation is running, present with the transaction for its length), as a
  follow-up once the live resize is confirmed.
