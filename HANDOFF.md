# Fizzy Modular-Plugin Refactor — Handoff (Phase 4, after Stage B)

## TL;DR

We are turning the monolithic editor into a **core shell + plugins** layout. Phase 4
makes `core` a real, separately-wired Zig module with no dependency on the `fizzy`
app hub, then (Stages B–E) lifts the pixel-art editor fully behind the plugin SDK so
it can become its own compile-time module.

**Done:** Stage A1, A2, A3, B. **Next:** Stage C (then D, E).

## What Stage B did

Lifted the pixel-art editor state off the shell `Editor` into a plugin-owned
`PixelArt` struct (`src/plugins/pixelart/PixelArt.zig`), reached via a new
`fizzy.pixelart: *PixelArt` global (mirrors the existing `fizzy.packer`).

- **Fields moved:** `tools`, `colors`, `project`, `sprite_clipboard`, `pack_jobs`
  (plus the `SpriteClipboard` type). ~190 `editor.<field>` / `fizzy.editor.<field>`
  call sites repointed to `fizzy.pixelart.<field>` across `Editor.zig`, `Keybinds.zig`,
  `workbench/files.zig`, and the pixel-art tree.
- **`atlas` deliberately stayed on the shell** — it's the shared UI icon spritesheet
  (cursor/pencil/logo/selection icons) the shell uses for its own logo
  (`workbench/files.zig`, `Workspace.zig`), not pixel-art-specific. Moving it would
  invert the dependency. (Its type is still `Internal.Atlas`; relocating that type to
  core is a later structural question, not Stage B.)
- **Lifecycle:** `fizzy.pixelart` is allocated + `PixelArt.init`'d in `App.AppInit`
  *before* `editor.postInit()` so the pixel-art `plugin.register` adopts it as
  `plugin.state`. `PixelArt.init` now owns the tools init + the two `fizzy.hex` palette
  loads (moved out of `Editor.init`). `PixelArt.deinit` (pack-job cancel, palette free,
  project save, tools free) runs from `App.AppDeinit` right after `editor.deinit()`;
  the old interleaved pixel-art teardown blocks were removed from `Editor.deinit`.
- Three Editor helpers (`processHoldOpenRadialMenu`, `isPackingActive`,
  `runWasmPackWorkers`) now ignore their `editor` param (`_: *Editor`) since they only
  reach `fizzy.pixelart`. The pack methods (`startPackProject`/`processPackJob`/…) and
  the copy-paste / radial-menu draw code still live on `Editor` — they relocate later.
- Type aliases on `Editor` (`pub const Tools/Colors/Project/Transform`) were left in
  place; they're used as type paths (`Editor.Tools.Tool`) and move in Stage D.

Verified green: `zig build`, `zig build check-web`, `zig build test`. (No live GUI
run — pure refactor.)

All three build configs are green right now:

```
zig build            # native exe
zig build check-web  # wasm
zig build test       # unit/integration tests
```

Run all three after every stage. Note: `zig build` for this repo currently needs to
run outside the sandbox (network/file access), so expect to pass elevated permissions.

---

## What `core` is now (Stage A3 result)

`src/core/` is a standalone module (`src/core/core.zig` is its root). It holds shared
infrastructure and **never imports `src/fizzy.zig`**:

```
src/core/
  core.zig            # module root: gpa + trackpad hook + re-exports
  dvui.zig            # generic dvui hub: dialog framework, helpers, generic widgets
  fs.zig  paths.zig  platform.zig  Fling.zig
  gfx/    image.zig  perf.zig  water_surface.zig
  math/   math.zig  color.zig  direction.zig  easing.zig  layout_anchor.zig
  widgets/ CanvasWidget  PanedWidget  ReorderWidget  FloatingWindowWidget
           TreeWidget  TreeSelection
  generated/ atlas.zig   # written by the build's process-assets step
```

### Decoupling mechanisms (important invariants)

- **Allocator injection.** `core.gpa` is a `std.mem.Allocator` set once at startup in
  `App.init` (`fizzy.core.gpa = allocator;`). Core code (e.g. `gfx/image.zig`) allocates
  through `core.gpa` instead of reaching into `fizzy.app.allocator`.
- **Trackpad hook.** `core.takeTrackpadPinchRatio` is a `*const fn () f32` set in
  `App.init` to `fizzy.backend.takeTrackpadPinchRatio`. `CanvasWidget` calls the hook so
  it doesn't depend on the heavy native backend. Defaults to a `1.0` no-op for headless/test.
- **Dialog chrome state moved into core.** `core.dvui.modal_dim_titlebar: bool` and
  `core.dvui.dialog_close_rect_override: ?dvui.Rect.Physical` replaced the old
  `Editor.dim_titlebar` field and `workbench/files.zig: new_file_close_rect` var. The
  shell reads `fizzy.dvui.modal_dim_titlebar` in `Editor.setTitlebarColor`.
- **`fizzy.zig` re-exports core** so existing `fizzy.<x>` call sites keep working:
  `fizzy.image/fs/perf/water_surface/math/platform/paths/dvui/Fling/atlas` all alias
  `core.*`, plus `pub const core = @import("core");`.
- **Widget split.** Generic widgets live in `core/widgets/` and are exposed as
  `core.dvui.CanvasWidget` etc. The **pixel-art** `FileWidget` and `ImageWidget` stayed
  in `src/plugins/pixelart/widgets/` (ImageWidget is still pixel-art-coupled). Consumers
  import them locally, not via the hub. `src/editor/widgets/Widgets.zig` was deleted.

### Build wiring

`core` is created three times (one per target/backend variant) in `build.zig`:
- native exe: `core_module` (dvui_sdl3) — search `addImport("core"`
- web exe: `core_module_web` (dvui_web)
- test: `core_module_test` (dvui_testing)

Each gets `dvui`, `known-folders`, and (lazy) `icons`. The generated atlas now writes to
`src/core/generated/`, and the inline test modules point at `src/core/math/*`.

### Gotchas discovered (don't repeat these)

- **Build-script / module file-ownership trap.** `build.zig` imports
  `src/tools/process_assets.zig`, which imports `src/plugins/pixelart/Atlas.zig` to
  generate the atlas index *at build time*. A file may belong to only one module within a
  single compilation. Routing `Atlas.zig`'s file read through `fizzy.fs`/`core.fs` (a)
  dragged the whole `fizzy`+`core` graph into the build-runner compilation (no `core`
  module there) and (b) caused "file exists in modules 'core' and 'root'". **Fix applied:**
  `Atlas.zig` now imports nothing but `std` and inlines its file read. Keep build-time
  tools (`process_assets.zig` and anything it imports) free of `fizzy`/`core` module imports.
- **macOS case-insensitive FS.** `sprite.zig` vs `Sprite.zig` collide. The atlas-render
  library is named `sprite_render.zig` for this reason.
- **Lazy top-level imports.** An unused `const fizzy = @import(...)` is fine (never
  analyzed). Problems only appear when build-*reachable* code forces analysis.

---

## Remaining stages

The plan tasks are tracked as todos `b`, `c`, `d`, `e`. The pixel-art plugin still has a
large coupling surface to the shell: ~250 `fizzy.editor.` / `fizzy.backend.` /
`fizzy.platform.` references across `src/plugins/pixelart/**` (biggest offenders:
`widgets/FileWidget.zig` ~80, `dialogs/Export.zig`, `internal/File.zig`,
`explorer/tools.zig`). Stages B–D systematically remove these.

### Stage B — lift pixel-art editor state off the shell `Editor`
Move the pixel-art-specific fields (tools, colors, atlas, project, buffers, transform)
off `src/editor/Editor.zig` (~83 refs) into a `PixelArt` plugin-state struct owned by the
plugin. Update `Editor.zig`, `Keybinds` (~15 refs), and the `Menu`, plus the pixel-art
references that read those fields. Build green (all 3).

### Stage C — expand the SDK Host + a `workbench` service vtable
Grow `src/sdk/sdk.zig` Host surface to cover the ~110-ref shell surface the plugin still
needs: arena access, settings, folder access, doc/tab access, command registration. Then
replace remaining pixel-art `fizzy.editor` / `fizzy.backend` / `fizzy.platform` calls with
SDK calls. Build green.

### Stage D — make `pixelart` its own module
Add a `src/plugins/pixelart/pixelart.zig` module root; repoint all pixel-art imports from
`fizzy.zig` to `core` / `sdk` / `dvui` / local files; wire `b.addModule("pixelart", ...)`
in `build.zig` (3 configs, mirroring how `core` is wired); have `App` call
`pixelart.register(host)`. Build native + test + web.

### Stage E — strip pixel-art names from shell hubs
Remove pixel-art names from `fizzy.zig` / Dialogs / `Editor` / Explorer / Panel; route all
contributions through the SDK only. Final verification across the 3 configs.

---

## State of the tree

Uncommitted. Stage A3 touched: `build.zig`, `src/App.zig`, `src/fizzy.zig`,
`src/web_main.zig`, `src/editor/Editor.zig`, the moved `src/core/**` files, and the
pixel-art/workbench consumers (`Atlas.zig`, `CanvasData.zig`, `PackJob.zig`,
`FileLoadJob.zig`, `files.zig`, `plugin.zig`, `dialogs/GridLayout.zig`,
`widgets/{CanvasBridge,FileWidget,ImageWidget}.zig`). Deleted: `editor/widgets/Widgets.zig`,
`tools/timer.zig`, `core/gfx/gfx.zig` (empty), `core/font_awesome.zig` (unused — `fa`
re-exports removed from `core.zig`/`fizzy.zig` and the web probe). Nothing has been committed.
