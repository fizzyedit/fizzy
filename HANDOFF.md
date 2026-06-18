# Fizzy Modular-Plugin Refactor — Handoff (Phase 4, mid Stage C)

## TL;DR

We are turning the monolithic editor into a **core shell + plugins** layout. Phase 4
makes `core` a real, separately-wired Zig module with no dependency on the `fizzy`
app hub, then (Stages B–E) lifts the pixel-art editor fully behind the plugin SDK so
it can become its own compile-time module.

**Done:** Stage A1, A2, A3, B, and **Stage C part 1 (per-plugin settings)**.
**Next:** Stage C remainder (doc/tab/host/arena/folder decoupling) + the sprite/atlas →
`core` extraction. Then D, E.

> **Read this first if you're a fresh agent:** the immediately actionable work is in
> "Stage C — remaining work" and "Next big rock: sprite/atlas → core" near the bottom.
> Several items there are now low-effort because the SDK surface they need already exists.

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

## What Stage C part 1 did — per-plugin settings (VSCode-style)

Goal (set by the user): pixel-art-specific settings should **belong to the pixel-art
plugin**, and the Settings tab should be a registry that each plugin contributes its own
section to, grouped by plugin. The shell stores plugin settings opaquely but never
interprets them.

### New SDK surface (all in `src/sdk/`)

- **`SettingsSection`** (`regions.zig`, exported from `sdk.zig`): `{ id, owner, title, draw }`.
  The Settings sidebar view renders each registered section under its `title` heading.
- **`Host` additions** (`Host.zig`):
  - `settings_sections` registry + `registerSettingsSection`.
  - `plugin_settings: PluginSettings` (= `StringArrayHashMapUnmanaged([]const u8)`): the
    opaque per-plugin blob store (id → serialized JSON). `loadPluginSettings(id)` /
    `storePluginSettings(id, json)` (the latter dupes + marks shell settings dirty). Host
    owns + frees the key/value strings in `deinit`.
  - `shell_api: ?ShellApi` + `installShell(api)` + thin forwarders: `arena()`, `folder()`,
    `paletteFolder()`, `markSettingsDirty()`, `contentOpacity()`.
- **`ShellApi`** (`ShellApi.zig`): vtable + ctx the shell installs so plugins reach shared
  shell state without importing `Editor`. The shell's vtable impl lives in `Editor.zig`
  (`shell_api_vtable` + `shellArena`/`shellFolder`/… ; ctx is `*Editor`), installed in
  `Editor.postInit`.

### Storage / persistence (`src/editor/Settings.zig`)

- On-disk format gained a `"plugins"` object: `{ <shell fields…>, "plugins": { id: <blob> } }`.
- `Settings.serialize(settings, plugin_store, alloc)` serializes the struct, drops the
  trailing `}`, and **textually splices** `,"plugins":{…}}` with each plugin's already-
  serialized blob inline. (Robust — avoids `std.json.Value` lifetime hazards. Round-trip
  validated with a standalone test: valid JSON, shell parses back via `ignore_unknown_fields`,
  blobs re-extract cleanly.)
- `Settings.save(...)` and the autosave **dedup snapshot** (`settings_last_saved_json`) and
  the three Editor save sites all now go through `serialize` so plugin-only changes still
  trigger a write. (Watch: `Settings.save` is called from `saveSettingsGuarded`,
  `saveSettingsRaw`, and the init snapshot — all four-arg now.)
- `Settings.loadPluginStore(alloc, path, store)` re-parses settings.json as a `Value`,
  extracts the `"plugins"` object into the store. Called from `Editor.init` right after
  `Settings.load`, before `PixelArt.init` runs (so the plugin can read its blob).
- **One-time migration:** a legacy *flat* settings.json (no `"plugins"`) seeds the
  `"pixelart"` blob from the **whole root** — pixel art ignores unknown keys, so its moved
  fields (`show_rulers`, `input_scheme`, …) survive; the next save rewrites the blob clean.
  (Self-healing, no data loss. The blob is temporarily bloated with shell keys until then.)

### Pixel-art side

- New **`src/plugins/pixelart/Settings.zig`** (`PixelArt.Settings`, `pub`): owns the moved
  fields + `InputScheme`/`ResolvedPanZoomScheme`/`TransparencyEffect` enums +
  `resolvedPanZoomScheme`. `load(host)` parses its blob (defaults if absent/garbage; no
  heap fields so returning by value after `parsed.deinit()` is safe). `save(host)`
  serializes + `host.storePluginSettings`. `draw(_)` renders the section (Canvas group:
  transparency effect, show rulers, cover-flow cards; Controls group: control scheme).
- `PixelArt` struct gained `host: *sdk.Host` and `settings: Settings`, both set in
  `PixelArt.init(allocator, host)` (App now passes `&fizzy.editor.host`).
- `plugin.register` registers the `"pixelart"` settings section ("Pixel Art").

### Fields moved off shell `Settings` → `PixelArt.Settings`

`input_scheme`, `show_rulers`, `scrolling_cards`, `ruler_padding`, `zoom_sensitivity`,
`zoom_steps`, `max_file_size`, `checker_color_even/odd`, `transparency_effect` (+ the
three enums + `resolvedPanZoomScheme`). All ~27 pixel-art read sites repointed to
`fizzy.pixelart.settings.<field>`; type refs (`fizzy.Editor.Settings.TransparencyEffect`,
`…resolvedPanZoomScheme`) → `fizzy.PixelArt.Settings.…`.

**`content_opacity` deliberately stays on the shell** — it's also read by `workbench/
Workspace.zig` and `panel/Panel.zig`, so it's genuinely shell-level. Pixel art's 3 reads
go through `fizzy.pixelart.host.contentOpacity()` (the ShellApi). The pixel-art settings
*UI controls* were removed from `editor/explorer/settings.zig` (the shell "Editor" section
now only has theme/fonts/window+content opacity/hold-timing/debugging).

### Settings UI

`Editor.drawSettingsPane` now iterates `host.settings_sections` and renders each under a
heading label (registration order = display order; shell "Editor" registered first in
`postInit`, before plugins). The shell section draw = `Explorer.settings.draw` (trimmed);
the pixel-art section draw = `PixelArt.Settings.draw`.

Verified green: `zig build`, `zig build check-web`, `zig build test`. Persistence splice
round-trip checked with a throwaway `zig run` harness (valid JSON + clean extraction). No
live GUI run.

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

### Stage C — expand the SDK Host (settings done; rest below)
Grow the SDK Host surface so the plugin reaches shell state via the SDK, not
`fizzy.editor`. **Part 1 (per-plugin settings) is done** — see "What Stage C part 1 did"
above. The remaining coupling and a recommended order are in "Stage C — remaining work".

### Stage D — make `pixelart` its own module
Add a `src/plugins/pixelart/pixelart.zig` module root; repoint all pixel-art imports from
`fizzy.zig` to `core` / `sdk` / `dvui` / local files; wire `b.addModule("pixelart", ...)`
in `build.zig` (3 configs, mirroring how `core` is wired); have `App` call
`pixelart.register(host)`. Build native + test + web.

### Stage E — strip pixel-art names from shell hubs
Remove pixel-art names from `fizzy.zig` / Dialogs / `Editor` / Explorer / Panel; route all
contributions through the SDK only. Final verification across the 3 configs.

---

## Stage C — remaining work (start here)

Settings is fully decoupled (`grep -r 'fizzy.editor.settings' src/plugins/pixelart` → 0).
Here is the **current** `fizzy.editor.*` / `fizzy.backend.*` / `fizzy.platform.*` surface
still in `src/plugins/pixelart/**` (run the greps to refresh):

```
33 fizzy.editor.activeFile     11 fizzy.editor.open_files   6 fizzy.editor.newFileID
31 fizzy.editor.atlas          11 fizzy.editor.host         6 fizzy.editor.folder
17 fizzy.editor.explorer       10 fizzy.editor.arena        2 fizzy.editor.palette_folder
+ doc/save-flow tail: setActiveFile, getFile, getFileFromPath, newFile, open_file_index,
  requestCompositeWarmup, startPackProject, isPackingActive, requestSaveAs,
  requestWebSaveDialog, requestGridLayoutDialog, cancelPendingSaveDialog, abortSaveAllQuit,
  copy/paste/accept/cancel, save, transform, buffers, panel, allocNextUntitledPath,
  pending_*/quit_* (all 1–3 refs each)
backend: showSaveFileDialog ×5, DialogFileFilter ×4, isMaximized ×3 ; platform: isMacOS ×3
```

**Recommended order (easy → hard):**

1. **`host` (11) — trivial now.** `PixelArt` already holds `host: *sdk.Host` (set in
   `init`). Repoint `fizzy.editor.host.setActiveSidebarView/isActiveSidebarView` →
   `fizzy.pixelart.host.…`. Pure mechanical, no SDK change.
2. **`arena` (10), `folder` (6), `palette_folder` (2) — done-for-you.** The ShellApi
   forwarders already exist: `fizzy.pixelart.host.arena()` / `.folder()` /
   `.paletteFolder()`. Repoint `fizzy.editor.arena.allocator()` → `fizzy.pixelart.host.arena()`,
   etc. (mind that `arena` callers use `.allocator()`; the forwarder already returns the
   `Allocator`).
3. **`backend.isMaximized` (3), `platform.isMacOS` (3).** Add `isMaximized()` to ShellApi
   (shell calls `fizzy.backend.isMaximized(dvui.currentWindow())`). `isMacOS` is just
   `core.platform.isMacOS()` — pixel art can call `fizzy.platform.isMacOS()` until Stage D
   repoints it to `core` directly; low priority.
4. **`explorer` (17).** These read pixel-art state that *lives on the shell `Explorer`*
   (`explorer.tools`, `.sprites`, `.pinned_palettes`, `.layers_ratio`, `.rect`,
   `.scroll_info`). `tools`/`sprites` are pixel-art pane modules; `pinned_palettes`/
   `layers_ratio` are pixel-art UI state. These should **move onto `PixelArt`** (like the
   settings did), not get an SDK accessor. `rect`/`scroll_info` are shell explorer layout —
   expose via ShellApi or pass into the draw.
5. **Native save dialogs (`backend.showSaveFileDialog` ×5, `DialogFileFilter` ×4).** Add a
   small SDK surface for "ask the host to run a native save dialog" (native-only; web has
   its own path). The save-flow tail (`requestSaveAs`, `pending_*`, `quit_*`, `accept`,
   `cancel`, `abortSaveAllQuit`, …) is the shell's save/quit orchestration the pixel-art
   dialogs poke — needs a deliberate "document save service" vtable, the hardest part.
6. **Docs/tabs (`activeFile` ×33, `open_files` ×11, `setActiveFile`, `getFile*`, `newFile*`,
   `open_file_index`, `buffers`, `transform`, `copy/paste`, `requestCompositeWarmup`,
   `startPackProject`, `isPackingActive`).** This is the **deep coupling**: the shell's
   `open_files` is literally `AutoArrayHashMapUnmanaged(u64, Internal.File)` — a map of
   *pixel-art* `Internal.File` values. The shell currently owns and iterates pixel-art docs
   directly. Fully decoupling means the shell stores **opaque documents (`DocHandle`)** and
   the pixel-art plugin owns the `Internal.File` storage. That is a large structural change
   (touches the workspace/tab/save systems) — likely its own stage. Until then, pixel-art
   can reach the active doc through a `host.activeDoc() ?DocHandle` + cast, but the storage
   inversion is the real work.

`atlas` (31) is handled by the sprite/atlas → core extraction below, not by an SDK accessor.

## Next big rock: sprite / atlas → `core`

This resolves the `editor.atlas` (Stage B) and `fizzy.editor.atlas` (×31) coupling and is
the prerequisite for the shell not depending on the pixel-art plugin for its own UI icons.

**Findings (verified in code):**

- The shell (`workbench`) only calls `fizzy.sprite_render.sprite(...)` in two places —
  `workbench/files.zig:~774` and `workbench/Workspace.zig:~300` — both drawing a **static
  atlas sprite** (the logo / UI icons), passing `file = null`. It never uses the heavy path.
- But `src/plugins/pixelart/sprite_render.zig` lives in the plugin and is tangled: the same
  `sprite()` also does layer compositing, file previews, reflections, and `water_surface`
  (all need a full pixel-art `Internal.File`). So today the shell reaches *backwards* into
  the plugin just to draw an icon. `editor.atlas` is typed `Internal.Atlas` (pixel art's).

**Plan:** split by responsibility with `core` as the shared floor.

- → **`core`:** a generic atlas data type + a "draw sprite N (sub-rect of a texture)"
  primitive (the slice the shell's logo/icons need; essentially `dvui.renderImage` + sprite
  rect math). The shell's `editor.atlas` becomes a `core` atlas type drawn via the `core`
  helper, depending on `core` not the plugin.
- → **stays in pixel-art plugin:** `renderSprite` / `render.renderLayers` / composites /
  reflections / `water_surface` — all the editing rendering on top of the primitive.

End-state dependency graph: **shell → core**, **plugin → core**, neither depends on the
other. (User has signed off on this direction; sequenced *after* settings.)

---

## State of the tree

**Uncommitted** (nothing in this whole Phase-4 effort has been committed — commit on
request). Beyond the Stage A3 changes, the working tree now also has:

- **Stage B:** new `src/plugins/pixelart/PixelArt.zig`; `fizzy.pixelart` global in
  `fizzy.zig`; init/deinit wiring in `App.zig`; field removals + ~190 repoints in
  `Editor.zig`, `Keybinds.zig`, `workbench/files.zig`, and the pixel-art tree.
- **Stage C part 1 (settings):** new `src/sdk/ShellApi.zig`,
  `src/plugins/pixelart/Settings.zig`; `SettingsSection` in `sdk/regions.zig` + `sdk.zig`;
  Host store/forwarders/section-registry in `sdk/Host.zig`; persistence rework in
  `editor/Settings.zig`; ShellApi impl + section iteration in `editor/Editor.zig`; trimmed
  `editor/explorer/settings.zig`; settings repoints across the pixel-art tree;
  `App.zig` passes the host to `PixelArt.init`.

Sanity greps for the next agent:
- `grep -rn 'fizzy.editor.settings' src/plugins/pixelart` → **0** (settings decoupled).
- `grep -rhoE 'fizzy\.editor\.[a-zA-Z_]+' src/plugins/pixelart | sort | uniq -c | sort -rn`
  → the remaining Stage C surface (see "Stage C — remaining work").

All three configs green: `zig build`, `zig build check-web`, `zig build test`.
