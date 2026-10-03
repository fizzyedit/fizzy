# Forked dependencies

Fizzy builds on three forks of other people's code. Each carries a few changes of fizzy's own on top
of an upstream release, and each has to keep taking upstream's releases. This file is the record of
what each fork changes and how to bump it; keep it current whenever a pin or a patch moves.

| Fork | Upstream | Fizzy's branch | Pinned in | Carries |
|---|---|---|---|---|
| [`foxnne/dvui-dev`](https://github.com/foxnne/dvui-dev) | [`david-vanderson/dvui`](https://github.com/david-vanderson/dvui) | `fizzy-dev` | `sdk/build.zig.zon` | dvui changes fizzy needs |
| [`fizzyedit/SDL`](https://github.com/fizzyedit/SDL) | [`libsdl-org/SDL`](https://github.com/libsdl-org/SDL) | `fizzy-3.4` | `fizzyedit/sdl_zig`'s `build.zig.zon` | SDL C patches (below) |
| [`fizzyedit/sdl_zig`](https://github.com/fizzyedit/sdl_zig) | [`Games-By-Mason/sdl_zig`](https://github.com/Games-By-Mason/sdl_zig) | `fizzy` | root `build.zig.zon` (`.sdl`) | the Zig build of SDL, pointed at `fizzyedit/SDL` |

SDL is fizzy's own dependency, not dvui's: fizzy's native backend (`src/backend/native`) takes it
from the root `build.zig.zon` and translates its own `sdl3-c.h`. dvui's SDL pin is used only by the
`-Dnative-backend=sdl3` build (dvui's SDL_Renderer backend). Plugins draw through dvui's proxy
backend and never link SDL, so an SDL bump is never an SDK release and never moves
`recorded_sdk_shape_fingerprint`.

## Rules

1. **A fork is upstream plus a short stack of described changes, rebased (not merged) onto each
   upstream release.** Each change says what it does, why, its upstream PR if there is one, and
   when it can go. In jj: `jj rebase -s <first fizzy change> -d <new upstream tag>`; a conflict
   stays on the change that caused it.
2. **Tag, then pin.** GitHub serves `/archive/<sha>.tar.gz` only while the commit is reachable from
   a ref, and a rebase leaves the old commits unreachable. Every pinned commit gets a tag that is
   never moved or deleted; branches rebase freely. (The dvui rule in `docs/PLUGINS.md`, "Repinning
   dvui", for every fork.)
3. **One pin per dependency, held by whoever uses it.** dvui in `sdk/build.zig.zon`, SDL (through
   sdl_zig) in the root `build.zig.zon`. A fork pins at most its own source, as sdl_zig pins
   `fizzyedit/SDL`.
4. **Upstream first.** A patch that upstream would take goes up as a PR; once merged it comes out
   empty at the next rebase and is abandoned.

## fizzyedit/SDL

`fizzy-3.4` = `release-3.4.16` plus:

1. **GPU: let each driver decide whether it can claim a transparent window** (`a4b021c`).
   `SDL_ClaimWindowForGPUDevice` refused every `SDL_WINDOW_TRANSPARENT` window, though the Cocoa
   Metal view is already made non-opaque for one and the Vulkan driver already picks a
   premultiplied composite alpha for one. The refusal moves into `D3D12_ClaimWindow`, whose HWND
   swapchain ignores alpha. Lets fizzy's backend claim its transparent window on macOS (where it
   used to clear the flag in SDL's private window struct for the claim) and on Linux.
   Upstream: not yet proposed.

2. **GPU: D3D12 presents a transparent window through DirectComposition** (`3d6e802`). A
   transparent window's swapchain is made with `CreateSwapChainForComposition` (premultiplied
   alpha, stretch scaling, sequential flip, an explicit size) and shown as the content of a
   DirectComposition visual on a topmost target for the HWND, so DWM composites its alpha over
   the desktop or the Acrylic backdrop fizzy asks for (`win32_titlebar.zig`). `dcomp.dll` is loaded
   with the first transparent window; `dcomp.h` is C++-only, so the three interfaces it calls are
   declared by vtable slot. Resizes pass the window's pixel size; it never tears. Xbox and DXVK
   still refuse. Compiled for x86, x64 and arm64 Windows; run on Windows 11 on Arm (D3D12 on
   WARP, in a VM): the window's alpha reaches DWM, Acrylic shows through. Upstream: worth
   proposing.

3. **Metal: present with the Core Animation transaction when the layer asks for it** (`5882e2b`).
   When a window's `CAMetalLayer` has `presentsWithTransaction` set, the GPU driver
   (`METAL_Submit`) and the renderer (`METAL_RenderPresent`) commit the command buffer, wait until
   it is scheduled and present the drawable on the calling thread, so it joins the Core Animation
   transaction open there; otherwise exactly as before. SDL never sets the property itself.
   Upstream: worth proposing with 4.

4. **Cocoa: draw each step of a live resize in the transaction that commits it** (`80bdc7d`).
   `SDL_HINT_VIDEO_MAC_SYNC_LIVE_RESIZE` (default off): for the length of a live resize the
   window's Metal view gets the redraw policy `NSViewLayerContentsRedrawDuringViewResize`, and the
   app's frame runs when AppKit displays the view at each step, presented with that step's
   transaction (needs 3), so the window's new size and the frame drawn for it reach the screen
   together. The 60 Hz timer only asks for a display while the pointer rests, and draws as before
   if AppKit never displays the view. Fizzy turns it on in `macos_monitor.install`; the
   measurements are in `docs/MACOS_LIVE_RESIZE.md`. Upstream: worth proposing once it has been run
   on a range of Macs.

5. **Cocoa: draw a live-resize step from the Metal view's `displayLayer:`, not `updateLayer`**
   (`8455e58`). AppKit never calls `updateLayer` for a view whose layer is a `CAMetalLayer` it
   makes itself, so 4 as first written never drew in a step. Squash into 4 at the next rebase.

6. **Wayland: frame insets, for a shadow the application draws round its own decorations**
   (`2d6efde`). `SDL_PROP_WINDOW_CREATE_WAYLAND_FRAME_INSET_{LEFT,TOP,RIGHT,BOTTOM}_NUMBER` give the
   margins of a window's surface outside its frame. While an xdg-shell toplevel floats the size
   the compositor configures is the frame's and the surface grows by the insets round it, the
   window geometry (`xdg_surface.set_window_geometry`) is the frame, the input region is the frame
   and a band of up to 8 units round it, the min/max sizes are the frame's, and popups anchor to
   the parent's frame; maximized, tiled or fullscreen the insets are zero. The insets in effect
   are published as `SDL_PROP_WINDOW_WAYLAND_FRAME_INSET_*_NUMBER`. libdecor windows are
   untouched. Fizzy draws its Linux window's shadow in them (`linux_titlebar.zig`). Upstream:
   worth proposing; a public API would want a setter as well.

Tags: `fizzy-3.4.16-1` → `a4b021c`; `fizzy-3.4.16-2` → `3d6e802`; `fizzy-3.4.16-3` → `8455e58`;
`fizzy-3.4.16-4` → `2d6efde`, what sdl_zig pins now.

## fizzyedit/sdl_zig

`fizzy` = upstream `main` (`0a9d5c3`) plus:

1. **Build fizzyedit/SDL** (`3a1f74e`): the `sdl` dependency is `fizzyedit/SDL` at the commit
   above instead of libsdl-org's `release-3.4.16` tarball. `.version` stays the SDL release it is
   based on — `build.zig` reads it for the library's SO version. Fizzy-only.
2. **macOS: take the SDK paths when they are given** (`60114a1`): `include_path`,
   `framework_path` and `library_path` reached only the iOS and Android builds, so an explicit
   `-Dtarget=*-macos` (the other half of a universal build, `build/common.zig`'s
   `macosSdlPathsForExplicitTarget`) could not find Cocoa. Upstream: worth proposing.

3. **Build fizzyedit/SDL `fizzy-3.4.16-2`** (`5950760`): the pin moves to SDL's second patch.
   Squash into 1 at the next rebase.
4. **Build fizzyedit/SDL `fizzy-3.4.16-3`** (`48468b7`): the pin moves to SDL's macOS live-resize
   patches (3–5). Squash into 1 at the next rebase.
5. **Build fizzyedit/SDL `fizzy-3.4.16-4`** (`58abe38`): the pin moves to SDL's Wayland frame
   insets (6). Squash into 1 at the next rebase.

Tags: `fizzy-1.0.3+3.4.16-1` → `60114a1`; `fizzy-1.0.3+3.4.16-2` → `5950760`;
`fizzy-1.0.3+3.4.16-3` → `48468b7`; `fizzy-1.0.3+3.4.16-4` → `58abe38`, the commit fizzy pins now.

## Bumping

**dvui:** as `docs/PLUGINS.md` "Repinning dvui" describes. SDL is not involved.

**SDL, to a new 3.4.x release:**

1. In `fizzyedit/SDL` (with libsdl-org as a remote:
   `jj git remote add upstream https://github.com/libsdl-org/SDL`): `jj git fetch --remote upstream`, then
   `jj rebase -s <first fizzy change> -d release-3.4.N`, resolve, describe, move `fizzy-3.4`, push,
   and tag the new tip `fizzy-3.4.N-1`.
2. In `fizzyedit/sdl_zig`: if upstream sdl_zig has moved to the same SDL release (its source lists
   follow SDL's files, so bump SDL when the wrapper does), rebase `fizzy` onto it. Point `.sdl` at
   the new SDL commit's archive (`zig fetch <url>` prints the hash), push, tag.
3. In fizzy: `zig fetch --save=sdl https://github.com/fizzyedit/sdl_zig/archive/<sha>.tar.gz`,
   then build macOS, Linux and Windows.

**A fizzy-only SDL change:** the same, with only step 1's new change instead of a rebase.

**Where a rebase conflicts.** Patch 1 touches one check in `SDL_ClaimWindowForGPUDevice`. Patch 2
lives mostly in two functions of its own (`D3D12_INTERNAL_SetCompositionContent`,
`D3D12_INTERNAL_ReleaseComposition`) and otherwise touches the D3D12 swapchain's create, resize,
present and release paths in `src/gpu/d3d12/SDL_gpu_d3d12.c` — the code an upstream D3D12
change is likeliest to move. Patch 3 touches `METAL_Submit`'s present loop and the tail of
`METAL_RenderPresent`; 4 and 5 the window listener's live-resize notifications and the end of the
Metal view (`SDL_cocoawindow.{h,m}`, `SDL_cocoametalview.m`, one hint in `SDL_hints.h`). For those,
`clang -fsyntax-only -fobjc-arc` on the `.m` files with the macOS SDK is enough to push, and the
real check is a drag on a Mac: `scripts/live-resize/run.sh` (`docs/MACOS_LIVE_RESIZE.md`). Patch 6
touches `SDL_waylandwindow.c`'s toplevel configure, `ConfigureWindowGeometry`, the min/max sizes
and the popup anchoring, beside two new fields in `SDL_waylandwindow.h`; its check is a Linux
build of fizzy and, on a GNOME desktop, a floating window whose shadow passes clicks through and
whose frame maximizes to the work area. After resolving, compile the file for Windows before pushing; it
needs no build of the rest of SDL:
`zig cc -target x86_64-windows-gnu -Iinclude -Iinclude/build_config -Isrc -Isrc/video/khronos -c src/gpu/d3d12/SDL_gpu_d3d12.c -o /tmp/d3d12.o`.
CI's Windows cross-build (`ci.yml`) then builds it into fizzy.

For local work on either fork, point the pin at a checkout with `.path = "../sdl_zig"` (and the
wrapper's `.sdl` at `../SDL`), as `sdk/build.zig.zon` does for `../dvui-dev`.
