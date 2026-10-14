# app/: the framework an application switches on

Compiled into an application, never into a plugin dylib, so it may use what a plugin must not
link: the network, the filesystem, an installer, `dlopen`. `root.zig`'s doc comment lists what
each directory is.

- **The module root is `root.zig`, not `app.zig`.** On a case-insensitive filesystem `app.zig` and
  `App.zig` are one file (root `CLAUDE.md`, "Case-renaming").
- **Nothing here names fizzy.** Where the framework needs the application it asks through a
  `{ctx, vtable}` seam the app fills in. Never import `src/`; an app built on fizzy has no `src/`.
- **Layout** (`layout/`): read `layout/SPLITS.md` before changing splits, moving or floating
  views. It is the contract, and it lists the rules a change must keep. `layout/LAYERS.md` is an
  agreed design that isn't built yet, with the rejected alternatives. Shapes are copied, not
  configured (root `CLAUDE.md`, "Shipped shapes"): a shape needing something only fizzy has is
  a bug in `Layout`.
- **Tests:** the std-only rule files (`layout/float_rules.zig`, `watch/folder_events.zig`,
  `RecentCommands.zig`, …) each have a root in `build/app.zig`'s unit list. Pure decisions go in
  such a file, so they test without a Window. Everything else is reached from `root.zig`'s
  `test` block (`fizzy-app-tests`, under `zig build test-integration`).

## Pitfalls

- **macOS charges ~110–140 ms for the first `dlopen` of a newly written file,** whatever its size,
  and caches the result per file. The loader therefore maps a stable per-build copy
  (`.load-copy/{mtime}-{size}-{name}`) and copies again only on a genuine re-open. It never maps
  the installed file: Windows couldn't rename an update into place, and on POSIX a rebuild would
  rewrite bytes under a live mapping (SIGBUS). Startup that looks like N × 120 ms is this.
- **Motion handing over to an OS window must be at rest on the window's rect when it shows.** An
  OS window can't animate its size per frame cheaply, so an overshoot still swinging then gets
  cut. Use `core.motion.arrive(t, swing)`, and size any overshoot in points, not as a share of the
  window.
- **The dragged view's glass moves only as the hand does** (`ViewDrag`'s `holdHand`, 3 pt). No
  springs, easing or trails driven by the pointer: merged Liquid Glass necks re-form visibly
  under tremor. A one-shot, time-driven curve started by a discrete event (the aimed bubble
  changing) is fine.
