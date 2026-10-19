# Forked and patched dependencies

Fizzy builds on other people's code with changes of its own on top of an upstream release, and has
to keep taking upstream's releases. dvui and sdl_zig are forks; SDL is upstream's release with
fizzy's patches applied at build time. This file is the record of what each changes and how to
bump it; keep it current whenever a pin or a patch moves.

| Dependency | Upstream | Fizzy's changes | Pinned in | Carries |
|---|---|---|---|---|
| [`foxnne/dvui-dev`](https://github.com/foxnne/dvui-dev) | [`david-vanderson/dvui`](https://github.com/david-vanderson/dvui) | branch `zig-0.17` (on 0.16, `fizzy-dev`) | `sdk/build.zig.zon` | dvui changes fizzy needs |
| SDL | [`libsdl-org/SDL`](https://github.com/libsdl-org/SDL) `release-3.4.16` | `backend/patches/sdl` | `backend/build.zig.zon` (`.sdl_source`) | SDL C patches, applied by [zig-patch](https://github.com/marler8997/zig-patch) (below) |
| [`fizzyedit/sdl_zig`](https://github.com/fizzyedit/sdl_zig) | [`Games-By-Mason/sdl_zig`](https://github.com/Games-By-Mason/sdl_zig) | branch `fizzy` | `backend/build.zig.zon` (`.sdl`) | the Zig build of SDL, taking the patched tree |
| [`fizzyedit/nightwatch`](https://github.com/fizzyedit/nightwatch) | [`neurocyte/nightwatch`](https://github.com/neurocyte/nightwatch) | branch `fizzy` | `build.zig.zon` | a fix to its macOS FSEvents backend |

SDL is fizzy's own dependency, not dvui's: fizzy's native backend (the `backend/` package) pins it
in `backend/build.zig.zon` and translates its own `sdl3-c.h`. dvui's SDL pin is used only by the
`-Dnative-backend=sdl3` build (dvui's SDL_Renderer backend). Plugins draw through dvui's proxy
backend and never link SDL, so an SDL bump is never an SDK release and never moves
`recorded_sdk_shape_fingerprint`.

## Rules

1. **Fizzy's changes are upstream plus a short stack of described changes, rebased (not merged)
   onto each upstream release.** Each change says what it does, why, its upstream PR if there is
   one, and when it can go. In jj: `jj rebase -s <first fizzy change> -d <new upstream tag>`; a
   conflict stays on the change that caused it. A fork keeps the stack as its branch; SDL's stack
   is the patch files, exported from and imported into a checkout (`scripts/sdl-patches.sh`).
2. **Tag, then pin.** GitHub serves `/archive/<sha>.tar.gz` only while the commit is reachable from
   a ref, and a rebase leaves the old commits unreachable. Every pinned commit of a fork gets a tag
   that is never moved or deleted; branches rebase freely. (The dvui rule in `docs/PLUGINS.md`,
   "Repinning dvui", for every fork.) Patch files live in this repository and need neither.
3. **One pin per dependency, held by whoever uses it.** dvui in `sdk/build.zig.zon`; SDL, its
   patches, sdl_zig and zig-patch in `backend/build.zig.zon`, with zig-objc and zigwin32, which
   fizzy's own code reaches through the backend package (`objcModule`, `win32Module`). sdl_zig's
   own `.sdl` is the same upstream release as `.sdl_source`: the same tarball, fetched once.
4. **Upstream first.** A patch that upstream would take goes up as a PR, from a branch of
   [`fizzyedit/SDL`](https://github.com/fizzyedit/SDL) (or of the fork); once merged it comes out
   empty at the next rebase and is dropped.

## foxnne/dvui-dev

`fizzy-dev` = upstream `main` (`9b372ab`, 2026-10-02) plus:

1. **render: a custom draw command (`deferRender`)** (`c703519`). A callback queued among a
   subwindow's render commands, run when they replay. The frost and liquid glass read back what
   the windows under them drew, which only exists at that point (`backend/src/glass/BlurBackdrop.zig`,
   `core/widgets/DropZones.zig`, `backend/src/glass/programs.zig`). Upstream: david-vanderson/dvui#988, open.
2. **Texture: precision option for render targets** (`f091da0`). `CreateOptions.precision =
   .high` and `Backend.support_precise_targets`: float targets for the blur pyramid, which 8 bits
   a channel steps into contour blobs. Upstream: david-vanderson/dvui#989, open.
3. **render: dont output triangles for culled glyphs** (`4428108`). `renderText` numbers its
   vertices with a u16 and panicked on a line of more than 16k glyphs even when nearly all were
   off screen, which a text layout with `cache_layout` off draws as one run. Was part of
   david-vanderson/dvui#945; upstream's own long-line work (#992) replaced the rest of that PR
   but not this. Upstream: wants its own PR. Test: `zig build test-integration
   -Dtest-filter="wider than the view"`.
4. **debug: frame capture records tag, role, label and a label's text** (`f8b32db`). Each
   `Debug.CapturedWidget` in a `captureFrame` / `dumpFrame` now holds `Options.tag`, `.role`,
   `.label` (as given), and the text the widget shows as its own: `LabelWidget` records its
   string through the new `Debug.captureText`. A dump can then name widgets without AccessKit,
   which is never built on the testing or web backends. A button's name is the text of the
   label inside it; an icon-only button's is its `label`. The agents plan's widget snapshot is
   built on this (`plans/AGENTS_PLAN.md`, "Accessible names"). Upstream: worth proposing as is,
   once fizzy's snapshot uses it. Test: dvui's `zig build test -Dbackend=testing`, "dumpFrame
   records tag, role, label and a label's text".

5. **Window: drawRetained, so an app can see dialogs before they are drawn** (`e1c6ef1`).
   `endRendering` drew dialogs and toasts and then replayed every subwindow, with nothing between.
   `drawRetained` is the first half on its own, called by `endRendering` if the app did not.
   Popout calls it before taking subwindows into their OS windows, so a dialog exists by then
   (`plans/WINDOWING_FOUNDATION_PLAN.md`). Upstream: branch `window-draw-retained`, to propose.
   Test: dvui's `zig build test`, "drawRetained draws dialogs once".
6. **screensSet: floating widgets can be kept on screens besides the window** (`a90bc70`).
   `dvui.screensSet(rects)` lists areas besides the window that are screens of their own;
   floating windows, menus and tooltips place, clip and dim against `dvui.screenFor` (the one
   holding their middle, else `windowRect`). Popout sets each float window's band as one (#325),
   and the backend's `os_windows` each `dvui.osWindow`'s. Upstream: branch `screens-set`, to
   propose. Test: "a floating window on another screen (dvui.screensSet) stays on it".
7. **OsWindowWidget: a child window is deinit before its backend** (`f0f498a`). `ChildOsWindow.deinit`
   freed the backend first, then the `dvui.Window`, whose deinit gives its textures (the font
   atlases) back to that backend: closing any `dvui.osWindow` on a backend with secondary windows
   crashed. Upstream: worth proposing on its own.
8. **osWindow: the fallback floating window is the window asked for, and its backend hears of it**
   (`f646ec0`). Where a backend makes no OS window of its own, `dvui.osWindow` falls back to a
   floating window, which now takes the window's size, least and most size, `id_extra`, a close
   button on its `open_flag` (the next frame asked for at once), and steps past one already there;
   and the backend hears of it each frame (`Backend.osWindowFloating`: its id, the header it is
   moved by, the options). Fizzy's backend makes no secondary `dvui.Window`, so every
   `dvui.osWindow` takes this path, and `backend/src/os_windows.zig` shows the floating window in
   an OS window of its own. Upstream: to propose with `run-dvui` (fizzyedit/example-app) as the
   demonstration.
9. **testing.snapshot: port to std.Io** (`e2c9a85`). Upstream's own port (`30adbcaa` to
   `2fc3f883`), taken whole: `dvui.testing.snapshot` was still on the pre-0.16 file API, so a
   test calling it failed to compile (#526). It takes `SnapshotOptions` now, and logs through
   `std.log`. Upstream: already there; comes out empty at the next rebase.
10. **RenderFrontToBack: closed blocks are drawn after draw-last commands** (`f07c334`, reworked
   in `fdc03d4`, `cc60612` and `44010a3`). A closed block went in at the start of
   `render_cmds_after` and draw-last strokes (`focusBorder`, a text entry's error ring) were
   appended after it, so a focus ring drawn later lay on top of a block meant to cover it: the
   pane corner button's glass under the explorer filter's ring (#519). Closed blocks now go in a
   list of their own, `Subwindow.render_cmds_front` (a `RenderFrontToBack.Blocks`), drawn after
   `render_cmds_after`. Closing a block appends its commands (amortized constant time a command;
   a nested block's commands are copied again at each enclosing level), and they are drawn the
   other way round, so the first closed is drawn last. A `Picture` or a block records into a
   `RenderQueues` (commands, draw-last commands, blocks) installed as one unit,
   `Window.defer_render`, which replaces `defer_render_cmds` and `defer_render_cmds_after`.
   `RenderQueues.render` is the one place that says the order queued drawing is drawn in;
   `Picture.stop` and `Window.renderSubwindow` use it, and fizzy draws a subwindow into a viewport
   with `renderSubwindow` (`.take` empties the subwindow's queues before drawing them).
   `Debug`'s widget outline, a draw-last stroke, now draws under such a block. Upstream: worth
   proposing. Test: dvui's `zig build test -Dbackend=testing`, "closed RenderFrontToBack blocks
   are drawn after draw-last strokes, before or after they closed".

11. **Window: the pointer kind, and a lifted finger hovers nothing** (`e04bccc`).
   `dvui.pointerKind()` is `.touch` or `.mouse`: what the last pointer event came from, set as the
   backend adds events (a touch button is `.touch`; mouse motion, a mouse button or the wheel is
   `.mouse`). It is the window's, so the app and every plugin dylib or wasm side module read the
   same answer. The window keeps which touch buttons are down; after a touch with none, the
   frame's `.position` event is off every window and targets no widget, so a tapped button, menu
   row or tab is not left lit. Fizzy's hover looks and the corner button's tap (#555) read it.
   Upstream: worth proposing. Test: "a finger that lifts hovers nothing, and a mouse hovers again".
12. **cursorSet: a priority, so a resize handle's cursor wins** (`20e56f1`).
   `dvui.cursorSetPriority(cursor, priority)` keeps the highest asked in a frame (between
   equals, the first); `cursorSet` asks at `.normal`. Resize handles ask at `.resize` (dvui's
   `PanedWidget`, `GridWidget` columns, a floating window's bottom-right corner; fizzy's
   `Split`), a carried thing at `.drag` (fizzy's view drag), so a hover cursor such as a tab's
   hand never takes a split's arrow. Which widget takes a press is unchanged. Upstream: worth
   proposing. Test: "cursorSetPriority: the higher asked wins, whichever asked first".
13. **FloatingWindowWidget: edges ask for their arrow at normal priority** (`40e664c`). Its
   edges are handled after the window's children, which take a press there first, so their arrow
   stays at `.normal` and a child under the band keeps both its cursor and its press. Only the
   bottom-right corner, handled before the children, asks at `.resize`. Upstream: with 12.

Each of 5 and 6 is also a branch of its own on upstream `main` (`window-draw-retained`,
`screens-set`), from which the upstream PR is opened.

**Since fizzy moved to Zig 0.17 (#575)** the pin is `foxnne/dvui-dev` branch `zig-0.17`, by tag and
as `git+https`: the eight above rebased onto upstream `main` (`41f6703`), then:

9. **floatingWindow: a backend may show one in an OS window of its own** (`bd7736d`). Patch 8's
   `osWindowFloating` became `Backend.floatingWindowOs(id, open_flag, min, max)`, asked as
   any floating window (not modal) begins, and `floatingWindowTitle(id, header)`, asked by
   `windowHeader`: true, and the backend shows it in an OS window with the OS's title bar, and
   dvui draws it with no frame of its own. `screenFor` takes the nearest screen.
10. **floatingWindow: an OS window only for a floating window that asks** (`98a0e07`):
   `FloatingWindowWidget.InitOptions.os_window`, set by `dvui.osWindow`'s floating window, passed
   to `floatingWindowOs` as `asked`. The backend's `floating_os_windows` (`.asked`, `.all`,
   `.none`) says which it shows.
11. **render: front-to-back blocks and deferred queues** (`ca8d4f8`, `8fa9b9c`): blocks close in
   O(1), `Window.renderSubwindow` takes a subwindow's commands, and the deferred queues are one
   unit, replayed in one place.
12. **floatingWindow: one shown in an OS window draws no background of its own** (`59c45df`): the
   OS window's material shows through.
13. **The pointer and its cursor** (`48496b7`, `186a87f`, `1b29a16`): `Window` knows the pointer's
   kind and a lifted finger hovers nothing; `cursorSet` takes a priority, so a resize handle's
   cursor wins, and a floating window's edges ask at normal priority.

Tags: `fizzy-sdk-0.2.13` → `712f7f7` (the stack before this rebase, still what SDK ≤ 0.2.15
builds); `fizzy-sdk-0.2.16` → `4428108` (SDK 0.2.16 to 0.2.18); `fizzy-sdk-0.2.19` →
`f8b32db`; `fizzy-sdk-0.2.19-2` → `a90bc70` (0.2.19 was not released yet, and a tag never
moves, so the second pin of one version takes a suffix, as the SDL fork's tags do; SDK 0.2.19 to
0.2.22); `fizzy-sdk-0.2.23` → `f646ec0` (SDK 0.2.23 to 0.2.29); `fizzy-sdk-0.2.30` → `f07c334`
(never pinned on `main`: its counter was reworked before merge); `fizzy-sdk-0.2.30-1` →
`e2c9a85` (item 9 alone, never pinned); `fizzy-sdk-0.2.30-2` → `fdc03d4` (pinned by #540);
`fizzy-sdk-0.2.30-3` → `cc60612` (never
pinned); `fizzy-sdk-0.2.30-4` → `44010a3`; `fizzy-sdk-0.2.30-5` →
`20e56f1` (never pinned on `main`); `fizzy-sdk-0.2.30-6` → `40e664c`, the last pin on Zig 0.16;
`fizzy-sdk-0.2.30-7` → `1b29a16` on `zig-0.17`, what `sdk/build.zig.zon` pins now (SDK 0.2.30, the
first on Zig 0.17).

Fizzy builds dvui in its `custom` backend mode on every target and links its own backends
(`backend/`, `src/backend/WebBackend.zig` + `web/web.js`), so dvui's `sdl3` and `web`
backends are only built by `-Dnative-backend=sdl3`. A dvui change to those backends is not a
change to fizzy: anything fizzy wants from one is merged into its own by hand.

Fizzy adapts to two upstream behaviours rather than patching them:

- **Long lines** (#992): `TextLayoutWidget.cacheLayoutNext` hands out the byte regions a layout
  actually runs, and `addText` counts and drops the rest. The text plugin queries tree-sitter
  region by region (`TextEntryWidget.draw`).
- **A text layout's first frame** (`f719b09`): a wrapping layout assumes it is 1000 wide on its
  first frame, whatever width it was given. The markdown preview treats a block holding one as
  not yet measured (`render_ast.Stats.fresh_text_layouts`).

## SDL: `backend/patches/sdl`

Upstream `release-3.4.16`, patched at build time: `backend/build.zig` (`patchedSdl`) hands the
release and `patches/sdl/*.patch`, in name order, to zig-patch, and sdl_zig builds the tree it
writes (`-Dsdl_source`). Each patch is `git format-patch` output whose header is the change's
description — what it does, why, how it was measured and whether it is worth proposing upstream —
so the list here only names each and says what in fizzy uses it.

zig-patch ignores line numbers: each hunk's old lines must appear exactly once in the file, or the
build stops (`HunkNotFound`, `HunkFoundMoreThanOnce`). Nothing is applied by guesswork. The patches
are exported with 8 lines of context (6 is the least that makes every hunk unique today); a hunk an
update makes ambiguous is fixed by exporting with more (`-U` in `scripts/sdl-patches.sh`).

- `0001` **GPU: let each driver decide whether it can claim a transparent window.** Fizzy's
  backend claims its transparent window on macOS and Linux. Upstream: not yet proposed.
- `0002` **GPU: D3D12 presents a transparent window through DirectComposition.** The Acrylic
  backdrop fizzy asks for on Windows (`win32_titlebar.zig`). Upstream: worth proposing.
- `0003` **Metal: present with the Core Animation transaction when the layer asks for it.** Needed
  by `0004`; upstream with it.
- `0004` **Cocoa: draw each step of a live resize in the transaction that commits it**
  (`SDL_HINT_VIDEO_MAC_SYNC_LIVE_RESIZE`, set in `macos_monitor.install`;
  `docs/MACOS_LIVE_RESIZE.md`). Was five changes of the fork (`displayLayer:`, and the ends of a
  live resize AppKit never posts), one now. Upstream: once it has been run on a range of Macs.
- `0005` **Wayland: frame insets, for a shadow the application draws round its own decorations**
  (`linux_titlebar.zig`), with its fixes from #280 C2b (recreated windows, the opaque region,
  toplevel bounds, the input band's property, insets published before show, framing after a hide).
  Upstream `main` (not `release-3.4.x`) gained its own version on 2026-09-24 (`5d7167cb`): at the
  update onto a release that has it, move `linux_titlebar.zig` to upstream's API and keep here only
  what upstream lacks.
- `0006` **Windows: draw each step of a live resize before the loop goes on**
  (`SDL_HINT_VIDEO_WIN_SYNC_LIVE_RESIZE`, set in `win32_titlebar.zig`;
  [`docs/WINDOWS_LIVE_RESIZE.md`](WINDOWS_LIVE_RESIZE.md)). Measured only in a Windows on Arm VM.
- `0009` **Wayland: make `xkb_keymap_mod_get_mask()` optional at runtime** (#289): the Wayland
  driver loads where the system's libxkbcommon is older than the headers SDL was built with
  (Ubuntu 24.04, Debian 12). Upstream: worth proposing.

`0007`, `0008` and `0010` are fizzy's suites on SDL's own test harness (`test/testfizzy.c`,
`test/testautomation_fizzy_*.c`), test files only. Each checks one patch and fails on the release
without it:

- `0007` FizzyGPU (`0001`): a transparent window claimed and presented on Metal and Vulkan;
- `0008` FizzyXkb (`0009`): the Wayland driver loads on an older libxkbcommon, and a German
  keymap's Shift, Caps Lock and AltGr levels come out right;
- `0010` FizzyWayland (`0005`): read from libwayland's request trace under headless weston, the
  floating, maximized and fullscreen geometry, input and opaque regions, published insets, popup
  anchoring, and each fix's case. Headless weston can't show a floating size the compositor
  chooses, toplevel bounds, tiled states, fractional scale or xdg-decoration.

`cd backend && zig build test-sdl` builds and runs them against the patched library (`--
--filter <suite|test>`, `--require-gpu <driver>`). On macOS the Metal tests run and the rest skip.
CI runs them only when SDL's patches or the backend's build changed (`ci.yml`, `changes`' `sdl`
output): on Linux in the `sdl` job (Ubuntu 26.04 runs every suite on X11 under Xvfb and on
headless weston, FizzyWayland again at scale 2, and FizzyXkb; Ubuntu 24.04 runs FizzyXkb on its
older libxkbcommon), and on macOS as a step of the test job.

[`fizzyedit/SDL`](https://github.com/fizzyedit/SDL) is where the patches are worked on and upstream
PRs are made from; nothing pins it any more. Its `fizzy-3.4` branch and `fizzy-3.4.16-*` tags are
the stack as it was before it moved here, which older fizzy commits still build.

## fizzyedit/sdl_zig

`fizzy` = upstream `main` (`0a9d5c3`, SDL 3.4.16) plus:

1. **macOS: take the SDK paths when they are given** (`efc3583`): `include_path`,
   `framework_path` and `library_path` reached only the iOS and Android builds, so an explicit
   `-Dtarget=*-macos` (the other half of a universal build, `build/common.zig`'s
   `macosSdlPathsForExplicitTarget`) could not find Cocoa. Upstream: worth proposing.
2. **build: the SDL source can be given (`-Dsdl_source`)** (`a99807d`): the library is built from
   that tree instead of the `sdl` dependency, which must be the same release (it sets the SO
   version). Upstream: worth proposing; with 1 upstream too, the fork goes.

Tags: `fizzy-1.0.3+3.4.16-1` to `-11` (`d0c70fe`) are the stack that built `fizzyedit/SDL`, kept
for older fizzy commits; `fizzy-1.0.3+3.4.16-12` → `a99807d`, what fizzy pins now.

## fizzyedit/nightwatch

The file watcher behind `app/watch/` (settings, open folders, documents). `fizzy` = upstream
`master` (`023e79f`) plus:

1. **fsevents: wait for a running callback before freeing its context** (`10c0207`): stopping the
   stream schedules no further callbacks but does not wait for one already running on its
   dispatch queue, and `stop_stream` freed that callback's context straight after (on each stop,
   and each watch added or removed). A watcher stopped while events were arriving
   (`SettingsWatcher.stop`, a folder's `FolderWatcher` closed) could leave a callback reading
   freed memory and calling a handler its owner had let go of; under load it crashed
   `zig build test-integration` (the test after the settings watcher's, with SIGABRT). Regression
   test: "settings watcher: stop waits for a callback already running"
   (`tests/integration.zig`). Upstream: not proposed yet; once it is merged there, the fork goes.

Tags: `fizzy-1.0.0-1` → `10c0207`, what fizzy pins now.

## zig-patch

[`marler8997/zig-patch`](https://github.com/marler8997/zig-patch), pinned by commit (`c3ad78b`):
not fizzy's, so its archive lasts as long as upstream keeps that commit reachable. Zig 0.16 and
0.17. It copies the source tree (once per cache miss) and applies git-style diffs: modifications,
new files, copies and renames; not deletions, mode changes or binary patches, and its copy drops
executable bits, which nothing SDL's build runs needs.

## Bumping

**dvui:** as `docs/PLUGINS.md` "Repinning dvui" describes. SDL is not involved.

**SDL, to a new release:** in a checkout of `fizzyedit/SDL` with libsdl-org as a remote
(`jj git remote add upstream https://github.com/libsdl-org/SDL`, then
`jj git fetch --remote upstream`). The script drives it with jj where it is a jj repository and
jj is installed, and with git otherwise (`git am`, `git format-patch`); git's commands are in
brackets below.

1. `scripts/sdl-patches.sh import <checkout> <old release>`: the patches as a stack of changes on
   the release they were made against, one each, as described and authored in their headers.
2. `jj rebase -s <first imported change> -d <new release>` (`git rebase --onto <new release>
   <old release>`). Resolve each conflict on the change that has it; drop a change that comes out
   empty (upstream took it).
3. `scripts/sdl-patches.sh export <checkout> <new release>`: the stack back over
   `backend/patches/sdl`. A re-export of an unchanged change is byte-for-byte the same file.
4. In `fizzyedit/sdl_zig`: its source lists follow SDL's files, so for a release that adds or
   removes any, rebase `fizzy` onto an upstream sdl_zig that has moved to it (or change
   `src/sdl.zon` in a change of our own). Point its `.sdl` at the new release, push, tag.
5. In `backend/build.zig.zon`, move `.sdl_source` (and `.sdl`, if it moved): `zig fetch <url>`
   prints the hash. Build macOS, Linux and Windows, and run `zig build test-sdl` in `backend/`.

A patch release that touches nothing the patches do needs only step 5 for `.sdl_source`: if every
hunk still applies once and the build passes, the patches came through.

**A change to a patch, or a new one:** import, edit the change (`jj edit`, or `jj new` and
`jj squash`; `git rebase -i`, or a `--fixup` commit) or add one, export. The export is the edit: build fizzy to try it.

**What fizzy relies on that SDL does not promise.** `GpuRenderer` compiles a Metal program's
source on a thread of its own (`Compile`): SDL documents no thread for `SDL_CreateGPUShader`, and
in the pinned SDL it is safe there because `SDL_CreateGPUShader` reads only the device's fixed
fields and `METAL_CreateShader` calls `newLibraryWithSource` on the `MTLDevice` (thread-safe) in its
own autorelease pool. On a bump, check both still hold in `src/gpu/SDL_gpu.c` and
`src/gpu/metal/SDL_gpu_metal.m`.

**Where a rebase conflicts.** `0001` touches one check in `SDL_ClaimWindowForGPUDevice`. `0002`
lives mostly in two functions of its own (`D3D12_INTERNAL_SetCompositionContent`,
`D3D12_INTERNAL_ReleaseComposition`) and otherwise touches the D3D12 swapchain's create, resize,
present and release paths in `src/gpu/d3d12/SDL_gpu_d3d12.c` — the code an upstream D3D12
change is likeliest to move. `0003` touches `METAL_Submit`'s present loop and the tail of
`METAL_RenderPresent`; `0004` the window listener's live-resize notifications and the end of the
Metal view (`SDL_cocoawindow.{h,m}`, `SDL_cocoametalview.m`, one hint in `SDL_hints.h`). For those,
`clang -fsyntax-only -fobjc-arc` on the `.m` files with the macOS SDK is a quick first check, and
the real one is a drag on a Mac: `scripts/live-resize/run.sh` (`docs/MACOS_LIVE_RESIZE.md`).
`0005` touches `SDL_waylandwindow.c`'s toplevel configure, `ConfigureWindowGeometry`, the min/max
sizes and the popup anchoring, beside new fields in `SDL_waylandwindow.h`; its check is
FizzyWayland under headless weston, then a Linux build of fizzy and, on a GNOME desktop, a floating
window whose shadow passes clicks through and whose frame maximizes to the work area (the parts
headless weston can't show). `0009` touches one line of `SDL_waylandsym.h` and the modifier masks
in `SDL_waylandevents.c`'s keymap handler; its check is FizzyXkb. After resolving `0002`, compile
the file for Windows in the checkout; it needs no build of the rest of SDL:
`zig cc -target x86_64-windows-gnu -Iinclude -Iinclude/build_config -Isrc -Isrc/video/khronos -c src/gpu/d3d12/SDL_gpu_d3d12.c -o /dev/null`.
CI's Windows cross-build (`ci.yml`) then builds it into fizzy.

For local work on sdl_zig, point `backend/build.zig.zon`'s `.sdl` at a checkout with
`.path = "../../sdl_zig"`, as `sdk/build.zig.zon` does for `../dvui-dev`.
