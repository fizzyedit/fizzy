# core/: the shared floor

What fizzy *and* every plugin dylib draw with: widgets, animation, dialogs, drawing, icons, math,
paths, fuzzy matching, the LSP client, the profiler.

- **App-agnostic.** Nothing here imports `app/`, `src/` or `AppInfo`; what differs per app comes
  in as a parameter (`paths.configFolder` takes the directory name).
- **Its imports are wired in one place,** `sdk/core_module.zig`, called by both the app build and
  the plugin SDK so the two can't drift. A new dependency of `core` goes there.
- **A change here reaches store plugins only at the next SDK release,** even when the fingerprint
  doesn't move, because they build `core` from the released SDK tarball.
- **The in-app glass is the backend's** (`backend/src/glass/`: `FrameTarget`, `BlurBackdrop`,
  `LiquidField`, `liquid_glass`, `liquid_blob`, `programs`, `motion`), re-exported here under the
  names it always had. Import it as `@import("glass")`, never by path; it must not import `core`
  (the profiler reaches it through `glass/prof.zig`).
- **Use the shared pieces:** `core.fuzzy` for any filter box (lower scores are better);
  `core.icon.icon` rather than `dvui.icon` (cached as a texture).
- **Tests:** std-only files (`math/*`, `reveal.zig`, `crossfade.zig`, `FrameClock.zig`, `fuzzy.zig`,
  …) have roots in `build/app.zig`'s unit list. Put pure logic in such a file. Tests that need a
  real `dvui.Window` are reached from `sizing_tests.zig`, a root one directory up so the whole of
  `core/` is inside its module.

## Pitfalls

- **On macOS, spawn through `core.darwin_spawn`, never `std.process.run`.** Zig 0.16's start-up
  code captures `environ`'s length once. One `unsetenv` anywhere in the process (SDL, a plugin, a
  system framework) shrinks the array in place, and the next std spawn reads past its end and
  crashes. `darwin_spawn` builds the child's environment from `getenv` and needs an absolute
  `argv[0]`. Linux and Windows call sites still use std and carry the same latent hazard.
- **dvui stamps every mouse event with the modifiers of the last *key* event.** A keyup lost to
  another app (⌘-Tab, an OAuth popup) then turns every click into a modified click: a tree
  selects instead of expanding, until you type. Fizzy's backends set `win.modifiers` from the OS
  before each mouse event (`backend/src/SDLBackend.zig`, `src/backend/WebBackend.zig`); a new
  backend must too.
- **Touch or mouse: ask dvui, never infer it.** `dvui.pointerKind()` is the window's answer,
  set as the backend adds events, the same in the app, a plugin dylib and a wasm side module.
  State kept by scanning events (a global, a per-frame key) differs per module and per frame.
  A lifted finger hovers nothing: dvui puts the frame's `.position` event off every window, so a
  hover look needs no touch check of its own. The native backend gives only fingers on the screen
  touch buttons (`backend/src/touch_slots.zig`); a trackpad's fingers move the mouse.
  The web backend does the same: a stylus touch (an Apple Pencil) is the mouse (`web/web.js`).
- **A cursor that must win asks with a priority.** `dvui.cursorSet` keeps the first asked in a
  frame; `dvui.cursorSetPriority` the highest. Splits and a float's corner ask at `.resize`, a
  carried view at `.drag`, so a hover cursor (a tab's hand) never takes their arrow. The cursor
  only: which widget takes a press is still drawing order, so ask at `.resize` only where the
  handle takes the press before what is under it. A float's edges, handled after its children,
  stay at `.normal`.
- **Very long lists:** dvui clamps every min size at `max_float_safe` (2e6, about 93k rows at
  21.5 pt), so the scroll range silently ends early. A widget not drawn on a frame loses its
  min size, so a row scrolled back into view is zero-height for a frame. A virtualized list must
  overscan, size its spacers from `count × pitch` rather than from what was drawn, and measure
  pitch as the *largest* gap between drawn rows.
- **dvui draws dialogs and toasts in `Window.endRendering`,** after the app's frame and after
  floats have taken their subwindows. Anything that must see a dialog's subwindow that frame
  draws it earlier itself. dvui also stops its widget capture at `drawRetained`, so snapshots
  capture dialogs through a capture scope (`dialogs.zig`).
- **A blur costs its passes, not its taps.** Each pass is a render-target switch; on SDL's Metal
  renderer that's a new command encoder and buffer. Cut passes, not samples.
- **Judge performance by main-thread CPU, not fps.** At 120 Hz a frame over 8.33 ms takes
  16.7 ms, so "half the fps" means the frame crossed the line. Log `CLOCK_THREAD_CPUTIME_ID` per
  frame, or `sample` the process and read the `nextDrawable` wait as headroom.
  `SDL_RENDER_VSYNC=0` stops holding once the window is frontmost.
- **The disk answers a listing later, like a mount.** `FileTable.listDir` waits at most 2 ms for
  `LocalFs`'s pool thread, then returns null and the answer lands on a later frame's `pump`;
  `search` likewise indexes and ranks a slice per frame (`indexing`, `ranking`). A caller that
  needs the whole answer pumps until they are false (`settledSearch` in `FileTable.zig`'s
  tests); one that draws shows a loading row (`listingPending`, `listingProgress`).
