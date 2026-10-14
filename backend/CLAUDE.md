# backend/: fizzy's native backend

SDL3, the SDL_GPU renderer (`GpuRenderer.zig`) and the platform pieces (`platform/`: title bars,
the OS's glass, OS windows for floats, menus, dialogs). A package of its own (`build.zig` says
how an app wires it).

- **dvui is the caller's.** It is never pinned here; the backend compiles against the app's dvui.
- **SDL is patched here,** not in a fork: `patches/sdl/*.patch`, applied by zig-patch. How to
  change, add or bump them is `docs/DEPENDENCIES.md` ("SDL", "Bumping"). Touching a patch or this
  `build.zig` runs CI's `sdl` job, the suites for the patches (`zig build test-sdl` here).
- **std-only tests are listed in `build.zig`'s `unit_tests`,** and fizzy's `zig build test` runs
  them. Window rules that can be stated without a window go in such a file
  (`platform/window_layout.zig`, `viewport_map.zig`).
- **Verify on the platform you changed.** CI's Windows cross-compile proves fizzy links, not that
  it works. `docs/MACOS_LIVE_RESIZE.md` and `docs/WINDOWS_LIVE_RESIZE.md` show how a resize
  was measured.
