# dvui upstream drafts (review only, nothing posted)


---
## FILE: PROPOSAL.md

## Proposal: a better windowing experience for dvui apps (OS windows, pop-out views, blur-behind, screens)

dvui already has `dvui.osWindow`, floating windows and `BlurBackdrop`. Building a desktop editor
on dvui (fizzy) we kept needing the same few things around them, and carried them on a fork.
This proposes them upstream as small, separate, opt-in PRs.

### The shape
- **The windowing code stays in a backend.** Whether a floating window becomes a real OS window,
  how a monitor layout maps onto the frame, what material a window is made of: that is platform
  work, and belongs in a backend. We would offer ours as one (`-Dbackend=fizzy`, built and
  maintained on our side, its own package) rather than as dvui code.
- **dvui gets only small, backend-neutral hooks** that any backend may implement and that do
  nothing when it doesn't. Every PR is additive or default-preserving: SDL3, SDL2, web, wio,
  raylib, dx11 and the rest behave exactly as today unless an app or backend opts in. Each PR
  says how.

### What an app gets
1. **OS windows that behave**: closing a child window no longer frees textures out from under it
   (#TBD), and the floating-window fallback on backends without OS windows honours the size,
   limits and close button the app asked for (#TBD).
2. **Pop-out views**: a backend can show any floating window in an OS window of its own, the OS
   providing title bar and frame (#TBD), and an app can replay one subwindow somewhere else and
   have dialogs exist before it does (#TBD).
3. **Screens**: menus, tooltips and floating windows stay on, and clip to, the screen they were
   opened on when an app shows parts of its frame outside the main window (#TBD).
4. **Blur-behind**: run code at a point in the replay (#988, the blur demo now frosts a floating
   window), float render targets so blurs don't band (#989), and a backend may draw every floating
   window's background itself, e.g. as frosted glass (#TBD).

### The PRs

| PR | What | Depends on |
|---|---|---|
| #TBD `oswindow-close-order` | Deinit a child window before its backend (crash fix) | none |
| #988 `defer-render` | `dvui.deferRender` custom draw command + blurred floating window demo | none |
| #989 `target-precision` | `CreateOptions.precision = .high`, `support_precise_targets` | none |
| #TBD `floating-window-background` | `Backend.floatingWindowBackground` hook | #988 (demo) |
| #TBD `draw-retained` | `Window.drawRetained`, `Window.renderSubwindow` | none |
| #TBD `screens-set` | `dvui.screensSet` / `screenFor` for floating widgets | none |
| #TBD `oswindow-fallback` | The fallback floating window is the window asked for | none |
| #TBD `floating-window-os` | `Backend.floatingWindowOs` (returns OS chrome + insets), `floatingWindowTitle` | oswindow-fallback |

Each can be reviewed and merged on its own; together they let a backend give a dvui app real
pop-out windows and glass without dvui knowing about any OS.

### Separately, later (not part of this set)
Glyph culling in `renderText` (the remainder of #945), names in frame captures, front-to-back
blocks over draw-last strokes, `pointerKind`, and cursor priority. Each will come as its own PR
with the same additive rule.

### Questions
- Is a third-party backend (`-Dbackend=fizzy`) something you'd want listed/built from dvui, or
  should it stay entirely in its own repo with these hooks as the only dvui surface?
- `floatingWindowOs` returning a small struct (`chrome`, `insets`) rather than a bool: does that
  shape fit how you see wio/SDL3 growing native child windows later?
- Hooks as optional backend decls (`@hasDecl`), as `readPixels` is today: OK as the pattern?

---
## FILE: PLAN.md

# dvui upstream: plan (drafts only, nothing posted)
Source of truth is fork branch `zig-0.17` (tag `fizzy-sdk-0.2.30-8` = `3d90fdda`, what fizzy pins),
based on upstream `42a68b92`; `fizzy-dev` is the old Zig 0.16 line. Upstream main is `1c37be6d`.
Whole `zig-0.17` merges cleanly onto it (`git merge-tree`); split PRs conflict only by context
(tests at `Window.zig`'s end, neighbouring hunks). Ordered chunks (windowing/blur set first):
1. 01 `oswindow-close-order` <- branch `oswindow-deinit-order` (`ad5e75e0`, = `a5dbdb90`).
2. 02 `defer-render` <- `6b04d1d9` + demo `f3a020a4` (`blur-demos-0.17`); force-update #988's branch is the maintainer's call (it is ours, `push-xpkqxluynmop`).
3. 03 `target-precision` <- `5720698f`; updates #989.
4. 05 `draw-retained` <- `f4e43837` (`window-draw-retained`) + `renderSubwindow` cut from `ca8d4f84` without blocks.
5. 06 `screens-set` <- `db51f933` (`screens-set`) + nearest-screen hunk of `bd7736d7`.
6. 07 `oswindow-fallback` <- `2c899d18` minus `osWindowFloating` (gone in `bd7736d7`); `.nudge` as its own commit.
7. 08 `floating-window-os` <- `bd7736d7` + `98a0e077` + `59c45df7`; reshape bool -> `?FloatingWindowOs{chrome, insets}`.
8. 04 `floating-window-background` <- `3d90fdda`.
Later: 10 `rendertext-cull-glyphs` (`rendertext-cull-glyphs`/`8aeefa19`), 11 frame-capture names
(`712abef8`), 12 front-to-back (`7157ef48..8fa9b9c9`, squashed, additive field form), 13 pointer kind
(`48496b77`, behind an option; rebase onto upstream #1000/#1014 touch slots), 14 cursor priority
(`186a87f5`+`1b29a16d`, two commits). Not proposed: `e2c9a855` snapshot port (already upstream
`2fc3f883`); `6abe40b6` window material, `18fb6875` tear-off drag hook (unpinned experiments).

Examples/tests still to write: osWindow button in Demo (07); a `.frameless` testing-backend stub
and test (08); background-hook test and a demo backend toggle (04); `renderSubwindow` test and an
`sdl3-ontop` toggle (05); screens demo checkbox (06); `custom` command unit test (02); u16
long-line test (10). Rebase each onto upstream main (Zig 0.17); build `zig build test
-Dbackend=testing`, `sdl3-standalone`, `web-app`, wio. Nothing has been built on upstream main yet.
Open questions for the maintainer:
- Ship `-Dbackend=fizzy` as a separate package that dvui apps add, or ask dvui to list it? Until
  it exists, 08 has no runnable in-tree demo: accept a testing-backend stub as the demonstration?
- 12/13/14 additive forms (keep `defer_render_cmds*`, `touch_lift_clears_hover` default off,
  widget priorities as a droppable commit): agreed, or keep the fork's stronger behaviour?
- Post 02/03 as updates to #988/#989 (force-push our branches) or as fresh PRs?

---
## FILE: 01-oswindow-close-order.md

## OsWindowWidget: deinit a child window before its backend

### Summary
`ChildOsWindow.deinit` freed the backend first and then the `dvui.Window`. The window's deinit
hands its textures (font atlases among them) back to that backend, so closing any `dvui.osWindow`
was a use after free. This swaps the two calls.

### Why
Closing a secondary OS window can crash (`textureDestroy` on freed memory, e.g. a pointer of
`0xaaaa…` in Debug) or corrupt memory silently in release builds. Any app that opens and closes
`dvui.osWindow`s hits it; whether it shows depends on the allocator.

### What changes
- `src/widgets/OsWindowWidget.zig`: `self.dvui_win.deinit()` before `self.backend.deinit()`.
- No API change. Behaviour on SDL3 (the backend with `initWindowSecondary`): closing a child
  window no longer touches freed memory. Backends without child OS windows (web, wio, raylib, …)
  never take this path and are unchanged.

### Where it is used
Every `dvui.osWindow` close goes through this path. (Fizzy hit it while building its own OS window
support: https://github.com/fizzyedit/fizzy/blob/main/backend/src/os_windows.zig#L1)

### How to try it
`zig build sdl3-multi-win`, open a child window, close it, repeat. With a Debug build before the
fix the second or third close segfaults or trips the GPA; after it, clean.

### Testing done
Carried in fizzy since 2026-10-10 (fork commit `a5dbdb90`, branch `oswindow-deinit-order`,
`ad5e75e0`). Cherry-picks cleanly onto current `main` (checked with `git merge-tree`); still to do
before posting: `zig build sdl3-multi-win` run on `main` with Zig 0.17.

---
## FILE: 02-defer-render.md

## render: a custom draw command (`deferRender`), and a blurred floating window in the demo

Updates #988 (as asked there: the blur demo now shows a blurred `floatingWindow`).

### Summary
`dvui.deferRender(ctx, draw)` queues a callback among the current subwindow's render commands
(`RenderCommand.custom`). It runs when the queue replays at the end of the frame, with rendering
immediate and under the clip and alpha in effect when it was queued; when rendering is already
immediate it runs at once. The demo's `BlurBackdrop` gains a "behind" mode built on it.

### Why
dvui records each subwindow's drawing and replays it in subwindow order at `Window.end`. A
floating window that wants a blurred (frosted) background needs the pixels of the windows *under*
it, and those exist only at that point of the replay. Reordering commands does not help:
the sequence has to be "draw what is under, read it back, blur, draw the window". Today an app
cannot run code there at all.

### What changes
- `render.zig`: `RenderCommand.custom: Custom { ctx, draw }`; `dvui.deferRender`.
- `Window.zig`: the replay runs `.custom` commands in order.
- `BlurBackdrop.zig`: blur what is behind a floating window or modal, no bracketing needed.
- `Examples/applets.zig`: "Frosted floating window" and "Modal over a blur" in the blur demo.
- Purely additive. No backend switches on `RenderCommand`, so SDL3, web, wio, raylib and dx11 are
  unaffected; the demo says so where a backend lacks `readPixels`.

### Where it is used
Fizzy's frost and glass queue their read-back-and-blur this way:
https://github.com/fizzyedit/fizzy/blob/main/backend/src/glass/BlurBackdrop.zig#L1078 and
https://github.com/fizzyedit/fizzy/blob/main/backend/src/glass/LiquidField.zig#L418

### How to try it
`zig build sdl3-standalone`, Demo > blur: tick "Frosted floating window" and drag it over the
demo; "Modal over a blur" shows a modal over the blurred window.

### Testing done
Carried in fizzy since 2026-09-15 (fork `6b04d1d9`); demo on fork branch `blur-demos-0.17`
(`f3a020a4`), which merges cleanly onto current `main`. To do before pushing: run the demo on
`main` (SDL3 and web), add a unit test that a queued `custom` runs once, in order.

---
## FILE: 03-target-precision.md

## Texture: precision option for render targets (16-bit float on SDL3)

Updates #989 (rebased onto Zig 0.17: `@backingInt` in the proxy bridge).

### Summary
`Texture.CreateOptions.precision = .high` asks for a render target with more than 8 bits a
channel; `Backend.support_precise_targets` says whether the backend has one. The SDL3 backend
makes `RGBA64_FLOAT` (sRGB colorspace); the proxy backend carries the option to its host.

### Why
A blur renders through a pyramid of targets several times over. Re-quantising dark content to 8
bits at every pass steps it into visible contour bands, most obvious on dark themes. With a float
target the blur stays smooth; with `support_precise_targets` a caller can skip dithering that an
8-bit fallback would round away.

### What changes
- `Texture.zig`: `Precision = enum(u8) { default, high }`, `CreateOptions.precision = .default`.
- `Backend.zig`: `support_precise_targets` (false unless a backend declares it).
- `backends/sdl.zig`: SDL3 tries the float format for `.high` and falls back to the ordinary
  target if the renderer refuses it. SDL2: unchanged.
- `proxy.zig` / `proxy_bridge.zig`: `CreateOptions` (extern) gains `precision: u8`. Host and
  plugin must be built from the same dvui (already true for the bridge).
- Default-preserving: `.default` everywhere is exactly today's target. Web, wio, raylib, dx11
  ignore the field and report `support_precise_targets = false`.

### Where it is used
https://github.com/fizzyedit/fizzy/blob/main/backend/src/glass/BlurBackdrop.zig#L400 (pyramid
levels), checked at https://github.com/fizzyedit/fizzy/blob/main/backend/src/glass/BlurBackdrop.zig#L856

### How to try it
With 02's demo: let `BlurBackdrop` ask for `.high` targets; on SDL3 a dark gradient behind the
frosted window shows no banding (compare with `.default`).

### Testing done
Carried in fizzy since 2026-09-15 (fork `5720698f`). Merges cleanly onto current `main`. To do:
the demo comparison above on SDL3 (Metal, D3D, Vulkan renderers) and SDL2 unchanged.

---
## FILE: 04-floating-window-background.md

## floatingWindow: the backend may draw a floating window's background

Depends on #TBD (02, `deferRender`) for the demo; the hook itself stands alone.

### Summary
An optional backend hook, `Backend.floatingWindowBackground(id, rect, corners) bool`, asked by
`FloatingWindowWidget` exactly where it would fill its background: after its shadow and border,
with its own subwindow current, before any content, given the fill's rect and corner radii in
physical pixels. True: the backend drew it (or queued it with `dvui.deferRender`) and dvui draws
no fill. False, or no such decl: today's theme fill.

### Why
An app may want every floating window and dialog to be "made of" a material (frosted, blurred,
translucent) rather than an opaque theme colour, without every call site wrapping its windows in
blur code. That needs the backend's render targets at that point of the replay, which a theme
fill cannot express. The hook lets a backend own the look while widgets stay unchanged.

### What changes
- `Backend.zig`: `floatingWindowBackground` (comptime `@hasDecl`; returns false otherwise).
- `FloatingWindowWidget.zig`: asks before filling; modal windows too (after their dimming).
  Not asked for ninepatch backgrounds or non-uniform borders (they keep `borderAndBackground`).
- Default-preserving: no existing backend declares it, so SDL3, web, wio, raylib and dx11 draw
  the same rect, corners, colour and fade in the same order as before.

### Where it is used
https://github.com/fizzyedit/fizzy/blob/main/backend/src/SDLBackend.zig#L1349 (fizzy's backend
fills a plain app's floating windows with the window's material).

### How to try it
To add: in the SDL3 example backend, a demo-only option (or a tiny example backend wrapper) that
returns true and calls 02's `BlurBackdrop` behind; every Demo window then frosts.

### Testing done
Carried in fizzy since 2026-10-18 (fork `3d90fdda`). Conflicts only by context with the stack
below it; to rebase alone onto `main`. To do: a testing-backend test that a backend returning
true suppresses the fill and false keeps it byte-for-byte.

---
## FILE: 05-draw-retained.md

## Window: drawRetained and renderSubwindow, so an app can draw subwindows elsewhere

### Summary
`endRendering` does two things: draw what dvui keeps between frames (dialogs, toasts, the debug
window), then replay every subwindow to the screen. `Window.drawRetained()` is the first half on
its own; `endRendering` calls it if the app has not. `Window.renderSubwindow(sw, .{ .take })`
replays one subwindow's queues in dvui's order and, by default, empties them.

### Why
An app or backend that shows some subwindows somewhere else (another OS window, a texture, a
pop-out view) takes their commands before `endRendering`. But dialogs do not exist yet then, so a
dialog opened from a popped-out window could never follow it; and replaying a subwindow means
copying dvui's internal command order, which breaks when that order changes.

### What changes
- `Window.zig`: `pub fn drawRetained(self, opts)`, and a flag so it runs once a frame;
  `pub fn renderSubwindow(self, sw, RenderSubwindowOptions{ .take = true })`.
- Frame timing unchanged: the render phase still starts where dialogs are drawn.
- Default-preserving: an app that never calls either gets the identical `endRendering`. No
  backend change; SDL3, web, wio, raylib, dx11 behave the same.

### Where it is used
https://github.com/fizzyedit/fizzy/blob/main/backend/src/os_windows.zig#L599 and
https://github.com/fizzyedit/fizzy/blob/main/backend/src/os_windows.zig#L504 (a floating window
shown in an OS window of its own replays its subwindow there).

### How to try it
Test "drawRetained draws dialogs once, before any subwindow is drawn" (`zig build test
-Dbackend=testing`). To add: a `renderSubwindow` test, and in `sdl3-ontop` a toggle that draws one
floating window into a `Picture`/texture to show the pattern.

### Testing done
`drawRetained`: carried in fizzy since 2026-10-09 (fork `f4e43837`, branch
`window-draw-retained`), merges cleanly. `renderSubwindow` comes from `ca8d4f84`, where it also
replays front-to-back blocks (PR 12); for this PR it is cut back to `render_cmds` then
`render_cmds_after`, which is exactly what `endRendering` does on `main`.

---
## FILE: 06-screens-set.md

## screensSet: floating widgets can be kept on screens besides the window

### Summary
`dvui.screensSet(rects)` lists, each frame, areas besides the window that are screens of their
own. `dvui.screenFor(r)` returns the nearest of them (the window's own among them) to the middle
of `r`. Floating windows, menus, tooltips and the text layout's touch popups use it wherever they
used `windowRect` to place, size, clip and dim.

### Why
A floating window, menu or tooltip is kept inside `windowRect` and clipped to
`windowRectPixels`. That is right when everything is in one OS window. An app that shows parts
of its frame somewhere else (popped-out panels in other OS windows, monitors laid out side by
side in one big frame) draws them past the window edge and copies that area out; a menu opened
there is pulled back onto the main window, or clipped away entirely.

### What changes
- `dvui.zig`: `screensSet`, `screenFor`. `Window.zig`: `screens` (arena, reset each frame).
- `FloatingWidget`, `FloatingMenuWidget`, `FloatingTooltipWidget`, `FloatingWindowWidget`,
  `TextLayoutWidget`: `windowRect` -> `screenFor(rect)`.
- Default-preserving: with no call to `screensSet`, `screenFor` is `windowRect` and every widget
  behaves exactly as before on all backends.

### Where it is used
https://github.com/fizzyedit/fizzy/blob/main/backend/src/SDLBackend.zig#L2157 and
https://github.com/fizzyedit/fizzy/blob/main/backend/src/viewports.zig#L464 (each OS window's
part of the frame is a screen).

### How to try it
Test "a floating window on another screen (dvui.screensSet) stays on it". To add: in the demo, a
checkbox that declares the right half of the window a second screen and outlines it; a menu or
floating window opened there stays and clips there.

### Testing done
Carried in fizzy since 2026-10-09 (fork `db51f933`, branch `screens-set`), plus "nearest screen"
from `bd7736d7` (a combo box menu set off above its box no longer jumps screens). Merges cleanly.
Check before posting: interaction with upstream's `floatingWindow` docs change (`475280a6`).

---
## FILE: 07-oswindow-fallback.md

## osWindow: the fallback floating window is the window that was asked for

### Summary
Where a backend makes no OS window (or past the OS-window cap), `dvui.osWindow` falls back to a
floating window. That window now honours what the app passed for the OS window: its starting
size (centred), min and max size, `id_extra`, and a close button bound to the same `open_flag` an
OS window's close clears, with the next frame requested at once so it closes promptly. These are
the fallback's own TODOs in `OsWindowWidget.zig`.

### Why
An app written with `dvui.osWindow` should behave sensibly on web, wio and the other backends
without child windows. Today the fallback ignores the requested size and limits, and it has no
way to close, so the user is stuck with a window the app expected the OS to let them close.

### What changes
- `OsWindowWidget.osWindowFallback(src, child_opts, win_opts)` forwards the options above;
  `dvui.osWindow` passes `win_opts`.
- Only the fallback changes; SDL3 child windows are unchanged.
- Behaviour change on the fallback (web, wio, raylib, dx11, SDL3 past the cap): it now uses
  options the app already passes. Nothing is removed. One item is new without the app asking:
  `.window_avoid = .nudge` (steps a second window off the first, as an OS cascades). Offered as
  a separate commit so it can be dropped if unwanted.
- The fizzy fork's `os_window = true` flag on this floating window belongs to PR 08 and is not
  in this PR.

### Where it is used
Any `dvui.osWindow` on a backend without `initWindowSecondary`; fizzy's backend is one, and shows
these in OS windows of its own: https://github.com/fizzyedit/fizzy/blob/main/backend/src/os_windows.zig#L70

### How to try it
To add: an "Open OS window" button in the Demo (with a size and min size), so `zig build web-app`
or a wio build shows the fallback: the child opens at its asked size, resizes within its limits
and closes from its header. `sdl3-multi-win` past the OS-window cap shows it on SDL3.

### Testing done
Carried in fizzy since 2026-10-10 (fork `2c899d18`, minus its `osWindowFloating` hook, which
PR 08 replaced). To do: run the multi-window content on web; a testing-backend test of the close.

---
## FILE: 08-floating-window-os.md

## floatingWindow: a backend may show one in an OS window of its own

Depends on #TBD (07) for the `dvui.osWindow` path; useful with #TBD (05, 06).

### Summary
An optional backend hook asked as a (non-modal) floating window begins:
`Backend.floatingWindowOs(id, asked, open_flag, min, max) ?FloatingWindowOs`. Null: an ordinary
floating window. Non-null: the backend shows it in an OS window and says what that window
provides, `.{ .chrome = .os_title_bar | .frameless, .insets = Rect }`, and dvui draws it
accordingly: no border, margin, rounded corners or edge resizing of its own, inset by what the OS
chrome covers. With `.os_title_bar`, `windowHeader` hands its title to the backend
(`floatingWindowTitle(id, header) bool`) and draws nothing. `FloatingWindowWidget.InitOptions
.os_window` marks windows that asked for one (`dvui.osWindow`'s fallback sets it).

### Why
A single `dvui.Window` can host every view, and a backend that can map part of the frame into
another OS window can make floating windows real OS windows (pop-out panels, tool windows),
including on platforms where a second `dvui.Window` is costly. Today the floating window
would double up its frame inside the OS one and fight the OS for resizing and closing.

### What changes
- `Backend.zig`: `floatingWindowOs`, `floatingWindowTitle` (both `@hasDecl`, default none).
- `FloatingWindowWidget.zig`: asks at init; frameless and background-free when shown in an OS window.
- `OsWindowWidget.zig`: the fallback sets `.os_window = true`.
- Default-preserving: no existing backend declares the hooks; SDL3 child windows, web, wio,
  raylib, dx11 behave as before.
- To do before posting: the fork returns `bool`; write the struct return (chrome + insets).

### Where it is used
https://github.com/fizzyedit/fizzy/blob/main/backend/src/SDLBackend.zig#L1320 and
https://github.com/fizzyedit/fizzy/blob/main/backend/src/SDLBackend.zig#L1333

### How to try it
Needs a backend that implements it: `-Dbackend=fizzy` (fizzy's backend as a dvui backend,
proposed in the issue) with `sdl3-multi-win`'s content. To add: a testing-backend stub returning
`.frameless` and a test that the frame is not drawn.

### Testing done
Carried in fizzy since 2026-10-16 (fork `bd7736d7`, `98a0e077`, `59c45df7`). Conflicts with the
stack only by context.

---
## FILE: 10-rendertext-cull-glyphs.md

## renderText: don't output triangles for glyphs outside the clip

Later set (not windowing). Replaces the last part of #945 that #992 did not cover.

### Summary
Glyphs wholly outside the clip horizontally emit no quads. Their x, kerning and selection are
still worked out; rotated text, which can swing a glyph back into view, opts out.

### Why
`renderText` emits four vertices a glyph, numbered by `Vertex.Index`, which is u16 wherever the
web, raylib or dx11 backend is built. One call panics past 16383 glyphs even when nearly all are
off screen. A text layout with `cache_layout` off lays a long unwrapped line out as one run
(#992's horizontal skipping needs the previous frame), so one 60k-character line of minified
JSON crashes the frame.

### What changes
- `render.zig` `renderText`: skip the quad for a glyph outside the clip (11 lines).
- No API change. Visible output is identical (the skipped quads were clipped away). Fewer
  vertices on every backend; the panic goes on u16 builds (web, raylib, dx11).

### Where it is used
Every text layout; fizzy's text editor on long lines.

### How to try it
To add: a demo/test that `dvui.label`s a 20k-character line with `cache_layout = false` on the
testing backend with u16 indices; panics before, renders after.

### Testing done
Carried in fizzy since 2026-08-17 (fork `660414a9`, branch `rendertext-cull-glyphs`,
`8aeefa19`); merges cleanly. Fizzy's integration test "wider than the view" covers it.

---
## FILE: 11-frame-capture-names.md

## debug: frame capture records tag, role, label and a label's text

Later set (not windowing).

### Summary
Each `Debug.CapturedWidget` in `captureFrame` / `dumpFrame` also holds `Options.tag`, `.role`,
`.label` (as given) and the text the widget shows as its own (`LabelWidget` records its string
through a new `Debug.captureText`). They appear in the JSON dump and in `dumpDiff`.

### Why
A frame dump records ids, rects, style and source location, but nothing that says what a widget
*is* to a person. Tests, scripts and tools that read a dump ("click the Save button") need a
name. AccessKit has one, but it is built only on request, never on the testing or web backends,
and only while assistive technology is on.

### What changes
- `Debug.zig`: four optional fields, filled while capturing; `captureText`.
- `LabelWidget.zig`: one call after `register`.
- Additive: capture is off unless asked for; dumps gain fields, nothing is renamed. No backend
  involvement.

### Where it is used
Fizzy's automation reads widget names from dumps (the widget snapshot it serves to tools).

### How to try it
`zig build frame-dump`: the dump now names each button by its label's text.

### Testing done
Fork `712abef8`; test "dumpFrame records tag, role, label and a label's text"
(`zig build test -Dbackend=testing`). Merges cleanly onto `main`.

---
## FILE: 12-front-to-back-after-draw-last.md

## RenderFrontToBack: closed blocks are drawn after draw-last commands

Later set (rendering order fix). Depends on #TBD (05) for `renderSubwindow`.

### Summary
A closed `RenderFrontToBack` block went in at the start of `render_cmds_after`, and draw-last
commands (`focusBorder`, a text entry's error ring, `.after` strokes) were appended after it.
Closed blocks now go in a list of their own per subwindow, drawn after `render_cmds_after`, in
the order the existing code intends (the first closed is drawn last).

### Why
A widget drawn front to back over others (a corner button, a floating toolbar) is meant to cover
them, but a focus ring or error ring drawn after the block closed lands on top of it.

### What changes
- `Subwindow.render_cmds_front: RenderFrontToBack.Blocks` (append-only, O(1) close).
- `RenderQueues` (commands, draw-last, blocks) with one `render` that says the order; used by
  `Picture.stop` and `renderSubwindow`.
- Behaviour: draw-last commands outside a block now draw under it. `Debug`'s widget outline is a
  draw-last stroke, so it too draws under such a block.
- **Constraint flag:** the fork replaces the public fields `Window.defer_render_cmds` and
  `defer_render_cmds_after` with one `defer_render: ?*RenderQueues`. Additive form for upstream:
  keep both fields as they are and add `defer_render_cmds_front: ?*Blocks` beside them, with the
  fork's earlier fallback (a block closed where no front list is installed goes at the start of
  the after queue, as today). Code that sets the two fields keeps today's behaviour.
- No backend involvement.

### Where it is used
https://github.com/fizzyedit/fizzy/blob/main/app/layout/Region.zig#L757

### How to try it
Test "closed RenderFrontToBack blocks are drawn after draw-last strokes, before or after they
closed" (fails on `main`'s order). To add: a demo with a focused text entry under a front-to-back
overlay.

### Testing done
Fork `7157ef48`, `f54228eb`, `ca8d4f84`, `8fa9b9c9` (squash to one commit). Conflicts with
`main` only by context in `Window.zig` (tests at the file end, 05's code beside it).

---
## FILE: 13-pointer-kind.md

## Window: the pointer kind, and a lifted finger can hover nothing

Later set (input). Must be rebased onto upstream's per-finger capture and gesture work
(#1000, #1014), which touch the same code.

### Summary
`dvui.pointerKind()` is `.touch` or `.mouse`: what the last pointer event came from, set as the
backend adds events. The window also keeps which touch buttons are down.

### Why
Code that wants a tap to behave differently from a click (show a hover look only for a mouse,
open on tap) has to infer the device by scanning events and keeping state of its own, and two
widgets can disagree. `mouseType()` answers a different question (wheel vs trackpad).
Separately, after a tap the pointer stays where the finger lifted, so the tapped button, menu row
or tab stays lit and its tooltip appears until the next touch elsewhere.

### What changes
- `enums.PointerKind`, `dvui.pointerKind()`, set in `addEventPointer`/`addEventTouchMotion`/
  mouse events. Additive.
- **Constraint flag:** the fork also makes the frame's `.position` event target no widget after
  a touch with no finger down, on every backend that sends touch (web, SDL3, Android). That is a
  behaviour change. Additive form for upstream: put it behind `Window.InitOptions
  .touch_lift_clears_hover = false` (or a runtime setter), default today's behaviour; the
  maintainer can flip the default later.
- `mouse_pt` is unchanged either way.

### Where it is used
https://github.com/fizzyedit/fizzy/blob/main/backend/src/touch_slots.zig#L4

### How to try it
Test "a finger that lifts hovers nothing, and a mouse hovers again" (with the option set). On
`web-app` on a phone: tap a button; with the option it is not left highlighted.

### Testing done
Fork `48496b77`. Conflicts with `main` by context in `Window.zig`; the touch-slot code must be
reconciled with upstream's `captureId(.touch0)` slots.

---
## FILE: 14-cursor-priority.md

## cursorSet: a priority, so a resize handle's cursor wins

Later set (input).

### Summary
`dvui.cursorSetPriority(cursor, priority)` keeps the highest-priority cursor asked for in a frame
(between equals, the first). `cursorSet` asks at `.normal`, exactly as today. `.resize` is for
handles that resize what is beside them, `.drag` for a carried thing; the enum is non-exhaustive
for an app's own levels. Only the cursor changes; which widget gets a press does not.

### Why
`cursorSet` keeps the first cursor asked for, so a widget drawn before a splitter decides the
cursor where they overlap: a tab asking for `.hand` beside a sash hides the sash's resize arrow.
The only workaround is for the earlier widget not to ask.

### What changes
- `enums.CursorPriority`, `dvui.cursorSetPriority`, `Window` keeps the priority per frame.
- Commit 1, additive: the API only; `cursorSet` unchanged.
- Commit 2, opt-in by widget: `PanedWidget` sash, `GridWidget` column border and a
  `FloatingWindowWidget`'s bottom-right corner ask at `.resize`. **Constraint flag:** this
  changes which cursor shows where such a handle overlaps a widget that asked first (on every
  backend). It is offered as its own commit so it can be dropped; the floating window's edges
  stay at `.normal` because its children take a press there first (fork `1b29a16d`).
- Check against upstream's `2604404f` ("paned: make target bigger"), same lines.

### Where it is used
https://github.com/fizzyedit/fizzy/blob/main/app/layout/Layout.zig#L253 and
https://github.com/fizzyedit/fizzy/blob/main/core/widgets/Split.zig#L441

### How to try it
Test "cursorSetPriority: the higher asked wins, whichever asked first". In the demo, a paned
layout with a button against the sash shows the arrow over the sash.

### Testing done
Fork `186a87f5` + `1b29a16d`. Conflicts with `main` by context in `Window.zig` and
`FloatingWindowWidget.zig`.
