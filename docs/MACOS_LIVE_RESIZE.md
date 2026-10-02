# macOS: a live resize that never stretches

**Status.** Two SDL patches, written against `fizzyedit/SDL`'s `fizzy-3.4` (SDL 3.4.16 plus the two
Windows patches), are in [`docs/patches/sdl/`](patches/sdl/) waiting to move into that fork. Fizzy's
side is in the tree already and does nothing until SDL carries them. The first version was run on a
Mac and was not enough (see "What the first version showed"); the second, described here, follows
Zed's GPUI and has not been run yet.

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

## The patches

| | What | Files |
|---|---|---|
| [`0003`](patches/sdl/0003-Metal-present-with-the-Core-Animation-transaction-wh.patch) | Metal: present with the Core Animation transaction when the layer asks for it. The GPU driver (`METAL_Submit`) and the renderer (`METAL_RenderPresent`) commit, wait until scheduled and present on the calling thread when `layer.presentsWithTransaction`; exactly as before otherwise. SDL never sets the property in this patch. | `src/gpu/metal/SDL_gpu_metal.m`, `src/render/metal/SDL_render_metal.m` |
| [`0004`](patches/sdl/0004-Cocoa-draw-each-step-of-a-live-resize-in-the-transac.patch) | Cocoa: `SDL_HINT_VIDEO_MAC_SYNC_LIVE_RESIZE` (default off). For the length of a live resize the window listener gives the Metal view the redraw policy `DuringViewResize`; the view's `updateLayer` brings SDL's sizes up to the window (`windowDidResize:` again, a no-op when it has run) and runs the app's frame with the layer presenting with the transaction for that frame alone. The timer only asks the view for a display while the pointer rests; if AppKit does not display the view for four ticks it draws as before and logs `Live resize: the Metal view is not being displayed` once. A frame is never started from inside one already running. | `include/SDL3/SDL_hints.h`, `src/video/cocoa/SDL_cocoawindow.{h,m}`, `src/video/cocoa/SDL_cocoametalview.m` |

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
  whenever the pointer paused mid-drag; with the patches every frame drawn while the pointer rests
  is such a frame.
- Vsync is no longer turned off for the drag when SDL draws it (`sdl_draws_live_resize` in
  `window_monitor.m`: the hint is on and the window's delegate, SDL's listener, answers
  `drawsLiveResizeInView:`, which only the patched SDL does). Turning it off was for the timer's
  vsync-blocking present; a present in the step waits only for the GPU to schedule it, and Zed
  runs its resize with display sync on. On an SDL without the patches, vsync goes off as before.

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
tail (`0003`), and the listener's live-resize notifications and the Metal view's end (`0004`). After resolving,
`clang -fsyntax-only -fobjc-arc` on the four `.m` files with the macOS SDK is enough to push; the
real check is a drag on a Mac.

## Checking it on a Mac

- Drag every edge and corner, slowly and fast, with a trackpad and with a mouse, on a 60 Hz display
  and on ProMotion. Expect no stretched frame at all; the window may follow the pointer a little
  more slowly than before, since each step now waits for fizzy's frame.
- A/B without rebuilding: SDL reads hints from the environment ahead of `SDL_SetHint`, so
  `SDL_VIDEO_MAC_SYNC_LIVE_RESIZE=0` gives the old behaviour (vsync off for the drag included).
- Watch the log for `Live resize: the Metal view is not being displayed`: it means AppKit never
  displayed the view during the drag, so none of this ran and the frames came from the timer.
- Horizontal and vertical drags separately, and the left and top edges as well as the right and
  bottom: the first version told them apart, and which edges still jitter (if any) says whether it
  is the window's width or its origin that matters.
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
