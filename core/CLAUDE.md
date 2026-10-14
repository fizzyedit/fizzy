# core/: the shared floor

What fizzy *and* every plugin dylib draw with: widgets, animation, dialogs, drawing, icons, math,
paths, fuzzy matching, the LSP client, the profiler.

- **App-agnostic.** Nothing here imports `app/`, `src/` or `AppInfo`; what differs per app comes
  in as a parameter (`paths.configFolder` takes the directory name).
- **Its imports are wired in one place,** `sdk/core_module.zig`, called by both the app build and
  the plugin SDK so the two can't drift. A new dependency of `core` goes there.
- **A change here reaches store plugins only at the next SDK release,** even when the fingerprint
  doesn't move, because they build `core` from the released SDK tarball.
- **Use the shared pieces:** `core.fuzzy` for any filter box (lower scores are better);
  `core.icon.icon` rather than `dvui.icon` (cached as a texture).
- **Tests:** std-only files (`math/*`, `reveal.zig`, `crossfade.zig`, `FrameClock.zig`, `fuzzy.zig`,
  …) have roots in `build/app.zig`'s unit list. Put pure logic in such a file. Tests that need a
  real `dvui.Window` are reached from `sizing_tests.zig`, a root one directory up so the whole of
  `core/` is inside its module.
