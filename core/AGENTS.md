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
- **Touch selection of read-only text is `widgets.SelectableText`, not a bare `dvui.textLayout`.**
  dvui selects a word on the first tap, so a finger landing on a message to scroll it selects it.
  `SelectableText` selects on a 0.45 s hold within 14 pt (`TouchHold.zig`), a tap clears; the mouse
  is dvui's. `st.tl` is the layout: draw into it with `addText` / `addLink` as before.
- **Text fields are `widgets.TextEntry`, not `dvui.textEntry`, in app and plugin code.** dvui
  focuses a field on the *press* (`Window.addEventMouseButton` adds a `.focus` before every
  pointer press), so a scroll that starts on a field enters it and raises the keyboard.
  `TextEntry` marks that event handled for a touch and focuses on the release of a tap; a hold or
  double tap selects the word (`SelectableText.selectWordAt`), a tap on the caret toggles the
  Cut / Copy / Paste / Select all menu, a drag is left to the enclosing scroll. Mouse and pen are
  dvui's. `te.entry` is dvui's widget (`getText`, `textSet` and its other methods).
  Existing callers in `plugins/workbench/src/files.zig`, `src/editor/CommandPalette.zig` and
  `src/editor/dialogs/WebSaveAs.zig` are follow-ups at their field-construction sites. The
  rule is text only for now: no lint yet (the PM's call). The text plugin's vendored
  `TextEntryWidget` is the editor, not a field, and is its own.
- **Touch or mouse: ask dvui, never infer it.** `dvui.pointerKind()` is the window's answer,
  set as the backend adds events, the same in the app, a plugin dylib and a wasm side module.
  State kept by scanning events (a global, a per-frame key) differs per module and per frame.
  A lifted finger hovers nothing: dvui puts the frame's `.position` event off every window, so a
  hover look needs no touch check of its own. The native backend gives only fingers on the screen
  touch buttons (`backend/src/touch_slots.zig`); a trackpad's fingers move the mouse.
  The web backend does the same: a stylus touch (an Apple Pencil) is the mouse (dvui's `web.js`,
  `web/patches/dvui/0003`).
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
  Rows of different heights use `core.widgets.VirtualList` over `core.HeightIndex`, which holds
  the reader's place as a row key + offset and the rows' total under that 2e6 limit by being
  given a window of the history, not all of it.
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
