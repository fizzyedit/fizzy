# Fizzy Modular-Plugin Refactor — Handoff (Phase 4, Stage D in progress)

## TL;DR

We are turning the monolithic editor into a **core shell + plugins** layout. Phase 4
makes `core` a real, separately-wired Zig module with no dependency on the `fizzy`
app hub, then (Stages B–E) lifts the pixel-art editor fully behind the plugin SDK so
it can become its own compile-time module.

**Done:** Stage A1, A2, A3, B, and **Stage C (full)** — per-plugin settings, docs/tabs
storage inversion, save/pack/editor-action decoupling, platform detection, explorer pane
lift, sprites bottom-panel lift.

**In progress:** **Stage D (substantially complete)** — module scaffold, `Globals` injection,
Workspace decoupling, zero `fizzy.zig` imports in plugin, `b.addModule("pixelart")` wired.

**Stage E — polish complete** (see "Stage E polish — DONE" below): shell no longer imports
`pixelart.internal`; `pixelart_state` field access fully routed to lifecycle + vtable;
`Plugin.beginFrame` hook removes the last shell→`pixelart.render` poke; dead imports pruned.
**Sprite/atlas → `core` big rock: DONE** (verified — generic atlas type + sprite-draw
primitive + sprite-id index all in `core`; neither shell nor plugin reaches the other's atlas).

**Dialog-registry lift — DONE** (see "Multi-plugin readiness"): the shell no longer names any
pixel-art dialog. `pixelart.dialogs` is gone from `src/editor` + `src/plugins/workbench`.

**Next:** wire `b.addModule("workbench", …)` + lift workbench off `fizzy.editor`
(logo atlas draw, `fizzy.editor.host.requestNewDocument`, etc.).

> **Read this first if you're a fresh agent:** Stage D/E + the dialog-registry lift are done.
> Shell→pixelart surface is now only `pixelart.plugin` (vtable) + `State`/`Globals` (lifecycle).
> All three build configs are green right now.

All three build configs are green:

```
zig build            # native exe
zig build check-web  # wasm
zig build test       # unit/integration tests
```

Run all three after every stage. `zig build` for this repo currently needs to run outside
the sandbox (network/file access).

---

## Plugin directory layout (convention)

Every plugin follows the same shape:

```
src/plugins/<name>/
  module.zig       # build module root / shell import surface
  <name>.zig       # intra-plugin hub (sdk, core, Globals, shared types)
  src/             # all implementation code
```

**pixelart** and **workbench** both use this layout now.

| File | Role |
|------|------|
| `module.zig` | Compile-time module root; shell reaches it via `fizzy.pixelart_mod` / future `@import("pixelart")` |
| `pixelart.zig` / `workbench.zig` | Hub named after the plugin folder; files in `src/**` import as `../<name>.zig` or `../../<name>.zig` |
| `src/State.zig` | Plugin runtime state (`pixelart` only) |
| `src/Globals.zig` | Runtime injection: `gpa`, `state`, `packer` (`pixelart` only) |
| `src/plugin.zig` | Plugin registration + draw entry points |
| `src/deps/` | Third-party deps (`pixelart` only) |

Shell still uses `fizzy.pixelart: *State` global during migration; plugin code uses
`Globals.state`.

### macOS case-insensitive rename protocol

On APFS (default, case-insensitive), `PixelArt.zig` and `pixelart.zig` are the **same
file**. Never create `pixelart.zig` while `PixelArt.zig` is still in git — it silently
overwrites the state struct.

**Two-step git rename (Option A):**

```bash
git mv src/plugins/pixelart/PixelArt.zig src/plugins/pixelart/__legacy_remove__.zig
git rm -f src/plugins/pixelart/__legacy_remove__.zig
# now safe to add src/plugins/pixelart/pixelart.zig and State.zig
```

**Import paths inside `src/`:**

- `src/foo.zig` → `@import("../pixelart.zig")`
- `src/widgets/bar.zig` → `@import("../../pixelart.zig")`
- View ids (`view_tools`, `view_sprites`) live in `src/plugin.zig` — import as
  `@import("../plugin.zig")` from nested dirs, not through the hub.

---

## What Stage C did (complete)

### Part 1 — per-plugin settings (VSCode-style)

Pixel-art-specific settings belong to the pixel-art plugin; the shell stores them opaquely.

- **`SettingsSection`** in SDK; `Host` registry + `plugin_settings` blob store.
- **`EditorAPI`** vtable for shell reach-through (`arena`, `folder`, `paletteFolder`, …).
- **`Settings`** owns moved fields; `plugin.register` adds the "Pixel Art" section.
- Shell `Settings.serialize` splices `"plugins": { id: blob }` into settings.json.

### Part 2 — docs/tabs storage inversion

The shell no longer owns `Internal.File` values directly.

- **`Docs.zig`**: plugin owns `files: HashMap(u64, Internal.File)`.
- **`Editor.open_files`**: `HashMap(u64, sdk.DocHandle)` — opaque handles with `ptr`/`id`/`owner`.
- **EditorAPI doc surface**: `activeDoc`, `docByIndex`, `docById`, `docIndex`, `openDocCount`,
  `setActiveDocIndex`, `allocDocId`.
- Shell helpers: `fileFromDoc`, `docAt`, `fileAt`, `activeDoc`, `insertOpenDoc`, `closeDocumentResources`.
- Plugin repointed: `fizzy.pixelart.docs.activeFile(host)`, `host.docIndex` / `setActiveDocIndex`,
  `host.allocDocId()`, `docs.fileById`, etc.
- **`State.docs`**: field + `docs.deinit` in teardown.

### Part 3 — save/pack/editor-action decoupling

Pixel-art dialogs and actions reach the shell through `host.*` / `EditorAPI`, not `fizzy.editor.*`.

**EditorAPI additions** (all wired in `Editor.zig` shell vtable + `Host.zig` forwarders):

`accept`, `cancel`, `copy`, `paste`, `transform`, `save`, `requestCompositeWarmup`,
`requestGridLayoutDialog`, `allocUntitledPath`, `createDocument`, `requestSaveAs`,
`requestWebSave`, `cancelPendingSaveDialog`, `setPendingCloseDocId`, `queueCloseAfterSave`,
`trackQuitSaveInFlight`, `resumeSaveAllQuit`, `abortSaveAllQuit`, `startPackProject`,
`isPackingActive`, `showSaveDialog`, `uiAtlas`, `explorerRect`, `explorerVirtualSize`,
`isMaximized`.

### Part 4 — explorer pane + bottom-panel lift

- **`tools_pane`**, **`sprites_pane`**, **`pinned_palettes`**, **`layers_ratio`** moved onto
  `State` (were on shell `Explorer`).
- **`sprites_panel`** moved off `editor.panel.sprites` onto `State`; drawn via
  `Globals.state.sprites_panel.draw()` from `plugin.zig`.

### Part 5 — platform detection

- **EditorAPI**: `isMacOS()`, `appliesNativeWindowOpacity()`.
- Plugin repointed: keybinds, window chrome opacity, `Settings.resolvedPanZoomScheme(settings, host)`.
- **Zero** live `fizzy.platform` / `builtin.os.tag` in `src/plugins/pixelart/**`.

### Stage C sanity greps

```
grep -rn 'fizzy\.editor\.' src/plugins/pixelart   → 0 live (4 commented-out lines in Tools.zig, Project.zig)
grep -rn 'fizzy\.platform' src/plugins/pixelart    → 0
grep -rn 'fizzy\.backend\.' src/plugins/pixelart  → check; native save dialogs go through host.showSaveDialog
```

---

## What Stage D has done so far

### Module root — `src/plugins/pixelart/module.zig`

Canonical export surface for the plugin tree. **`fizzy.zig`** re-exports through
`fizzy.pixelart_mod = @import("plugins/pixelart/module.zig")` instead of scattering
direct `@import("plugins/pixelart/…")` across the hub.

Exports: `Globals`, `State`, `Settings`, `Docs`, `Tools`, `Transform`, `Project`,
`Colors`, `Packer`, `PackJob`, `plugin`, `dialogs.*`, `explorer.project`, `render`,
`sprite_render`, `algorithms`, on-disk types, `internal.*`.

### Intra-plugin hub — `src/plugins/pixelart/pixelart.zig`

Plugin files import this for `sdk`, `core`, `Globals`, shared types, and `internal.*`.
**Not** the build module root — that is `module.zig`.

### Plugin state — `src/plugins/pixelart/State.zig`

Renamed from `PixelArt.zig` / `PixelArt` struct → `State.zig` / `State`.

### Globals injection — `src/plugins/pixelart/Globals.zig`

Runtime pointers set once in `App.AppInit`:

```zig
fizzy.pixelart_mod.Globals.gpa = allocator;
fizzy.pixelart_mod.Globals.state = fizzy.pixelart;
fizzy.pixelart_mod.Globals.packer = fizzy.packer;
```

Plugin tree now uses `Globals.allocator()` / `Globals.state` / `Globals.packer` — **zero**
remaining `fizzy.app.allocator` refs in `src/plugins/pixelart/**`.

### Hub consolidation (partial)

- **`fizzy.zig`**: `State`, `Packer`, `Internal`, on-disk types, `Tools`, `Transform`,
  `PackJob`, `algorithms`, `render`, `sprite_render` all alias `pixelart_mod.*`.
  Global `fizzy.pixelart: *State` kept for shell during migration.
- **`Editor.zig`**: removed public aliases `Colors`, `Project`, `Tools`, `Transform`;
  uses `fizzy.Tools`, `fizzy.pixelart_mod.Project`, `fizzy.pixelart_mod.plugin.*`.
- **Shell imports rerouted** (via `fizzy.pixelart_mod`):
  - `editor/dialogs/Dialogs.zig` → `dialogs.NewFile/Export/GridLayout/FlatRasterSaveWarning`
  - `editor/dialogs/UnsavedClose.zig` → `dialogs.FlatRasterSaveWarning`
  - `editor/explorer/Explorer.zig` → `explorer.project`
- **`Panel.zig`**: removed dead `Sprites` field/import.
- **Plugin import migration**: `bridge.zig` → `pixelart.zig`; `Globals.pixelart` →
  `Globals.state`; subdirectory files use `../pixelart.zig`.

### SDK module wired in `build.zig`

`wireSdkModule` adds `@import("sdk")` to native, web, and test roots. `fizzy.zig` imports
sdk via `@import("sdk")` (not a duplicate file-path import).

### SDK pane layout + workspace decoupling (done)

- **`src/sdk/pane_layout.zig`** — shared `mainCanvasVbox` / `emptyStateCard` helpers.
- **`src/sdk/WorkbenchPane.zig`** — `WorkbenchPaneView { grouping, canvas_rect_physical }`
  passed to sidebar `draw_workspace` hooks (plugins no longer cast back to `Workspace`).
- **`State.canvas_by_grouping`** — pixel-art owns per-pane `CanvasData`; `canvasForGrouping` /
  `removeCanvasPane` replace the old `Workspace.plugin_view_state` opaque slot.
- **`plugin.zig`** — `drawDocument` uses `CanvasData.forGrouping`; `drawProjectView` uses
  `sdk.WorkbenchPaneView` + `sdk.pane_layout`; no `fizzy` import.
- **`FileWidget.zig`** — `canvasData()` reads `Globals.state.canvas_by_grouping`; no `fizzy`.
- **`workbench/Workspace.zig`** — passes `WorkbenchPaneView` to `draw_workspace`; `deinit`
  calls `fizzy.State.removeCanvasPane`; layout helpers delegate to `sdk.pane_layout`.

### Runtime fixes (session)

| Bug | Fix |
|-----|-----|
| Startup crash in `Tools.init` | Use `self.stroke_shape/size`; set `Globals` before `State.init` |
| Duplicate `Globals` module | `module.zig`: `pub const Globals = pixelart.Globals` |
| Crash opening multiple files | Resolve docs by `doc.id`, not cached `doc.ptr` |
| Crash on close with files open | `State.persistProject()` before `editor.deinit` |

### Build module wired (done)

- **`wirePixelartModule`** in `build.zig` — native, web, and test roots import
  `@import("pixelart")` with deps: `core`, `sdk`, `dvui`, `assets`, `zip`, `zstbi`,
  `msf_gif`, `icons`, `backend` (native/test only).
- **`fizzy.zig`** — `pixelart_mod = @import("pixelart")` (no path import).
- **Zero `@import("fizzy.zig")` in plugin** — last shell leaks removed:
  - `dialogs/dimensions_label.zig` + `web_file_io.zig` (plugin-local helpers)
  - `EditorAPI.setExplorerNewFilePath` (replaces `Explorer.files.new_file_path` touch)
  - `web_main.zig` probes `FileWidget` via `@import("pixelart")`

### Still direct-importing pixel-art files (shell)

```
process_assets.zig (repo root)   → Atlas.zig   (build-time, std-only — OK, separate compilation)
src/web_main.zig               → FileWidget.zig force-import (wasm link — migrate later)
```

---

## Stage D — remaining work (start here)

1. **Route any straggler shell path imports** of pixel-art files through `pixelart_mod`
   or `@import("pixelart")` (mostly done; `process_assets.zig` stays separate).

2. **Optional:** wire `b.addModule("workbench", …)` the same way.

3. **Stage E cleanup:** shell `Editor.zig` still uses `fizzy.pixelart.*` extensively —
   shrink as plugin vtable / EditorAPI surface grows.

Do **not** re-introduce a duplicate `@import("plugins/pixelart/module.zig")` from both
`App.zig` and `fizzy.zig` via a third path; always go through `fizzy.pixelart_mod` in
app code until the build module is fully wired.

---

## Stage E — strip pixel-art names from shell hubs (in progress)

**Done this session:**
- **`Editor.pixelart_state`** — shell reaches plugin state through the editor, not scattered `fizzy.pixelart.*` (53 → 0 direct field accesses in shell code; `fizzy.pixelart` global remains only in `App.zig` lifecycle).
- **Plugin vtable hooks** — `tickKeybinds`, `processRadialMenuInput`, `radialMenuVisible`, `drawRadialMenu`; radial menu + tool keybind ticks moved to `pixelart/src/radial_menu.zig` and `keybind_ticks.zig`.
- **Shell `Keybinds.tick`** — pixel-art handlers removed (shell-only binds remain).
- **`editor/dialogs/Dialogs.zig`** — imports `@import("pixelart")` directly.
- **Explorer, UnsavedClose, files, Workspace** — use `fizzy.editor.pixelart_state` or `@import("pixelart")`.
- **`fizzy.zig` hub trimmed** — removed re-export aliases (`Tools`, `Internal`, `render`, `Packer`, on-disk types, …). Shell/workbench/tests/web probes now `@import("pixelart")` (or `fizzy.pixelart_mod` in integration tests). `fizzy.zig` keeps only `pixelart_mod` alias + lifecycle globals (`app`, `editor`, `packer`, `pixelart`).
- **`App.zig`** — wires `pixelart.Globals` directly (not `fizzy.pixelart_mod.Globals`).
- **Copy/paste + pack/project** — moved to `pixelart/src/clipboard.zig` and `pack_project.zig`; plugin vtable hooks (`copy`, `paste`, `startPackProject`, `isPackingActive`, `tickPackJobs`, `runPackWorkers`). Shell `Editor` delegates; `setProjectFolder` uses plugin `persistProjectFolder` / `reloadProjectFolder`.
- **Transform + doc registry** — `transform_op.zig` + `docs_registry.zig`; vtable hooks (`transform`, `registerOpenDocument`, `documentPtr`, `documentByPath`, `unregisterDocument`). Shell `fileFromDoc` / `insertOpenDoc` / `fileById` route through `doc.owner`; no direct `pixelart_state.docs` access in `Editor.zig`.
- **`fizzy.pixelart` global removed** — single ownership on `Editor.pixelart_state` + `Globals.state`; `App.zig` alloc/deinit via `fizzy.editor.pixelart_state` only.
- **DocHandle at workbench boundary** — `doc_bridge.zig` + plugin vtable metadata hooks (`bindDocumentToPane`, `documentGrouping`, `documentPath`, `setDocumentPath`, save/dirty indicators, …). `Workspace.zig` + `files.zig` use `DocHandle` + `doc.owner` only (no `Internal.File`). Shell helpers `docFromPath`, `docPath`, `setDocGrouping`, `bindDocToPane`; `fileFromDoc`/`fileById` are shell-internal.
- **Menu/Infobar off `activeFile()`** — `Menu.zig` + `Infobar.zig` route through `activeDoc()` + plugin hooks (`canUndo`/`canRedo`, `documentHasRecognizedSaveExtension`, `drawDocumentInfobar`). Active-doc infobar UI moved to `pixelart/src/infobar_status.zig`. Shell save/keybind paths (`save`, `saveAll`, quit-save-all, `UnsavedClose`) use `DocHandle` + owner hooks.
- **Shell `Internal.File` removed** — `Editor.zig` no longer types `*Internal.File` (removed `activeFile`, `fileFromDoc`, `fileById`, `getFile`, …). Document create/load/save-as routed through plugin vtable + `doc_lifecycle.zig` (`createDocument`, `saveDocumentAs`, `documentDefaultSaveAsFilename`, frame ticks, accept/cancel/delete). `insertOpenDoc` takes `*anyopaque` + id; `newFile` returns `DocHandle`; `openFileFromBytes` returns doc id. `FileLoadJob` uses opaque staging buffer via `Plugin.allocDocumentBuffer`. Save-queue worker owned by plugin (`initPlugin`/`deinit`).

**Stage E polish — DONE:**
- ✅ Removed dead `Editor.closeReference` (referenced a non-existent `open_references`
  field + `Internal.Reference` type; survived only via Zig lazy analysis). With it gone,
  the `const Internal = pixelart.internal;` import is dropped — **shell no longer imports
  `pixelart.internal` at all.**
- ✅ `editor.pixelart_state` direct field access already routed away: `pixelart_state`
  now appears only as the `Editor` field declaration + `App.zig` lifecycle
  (create/init/persist/deinit/destroy). No shell member access remains.
- ✅ **`Plugin.beginFrame` vtable hook** — shell no longer pokes `pixelart.render.frame_index`
  directly. `Editor.frame` now calls `plugin.beginFrame()` for every registered plugin; the
  pixel-art impl advances its own composite-cache frame clock. **No `pixelart.render` in shell.**
- ✅ Removed dead `pixelart`/`Packer` imports from `editor/panel/Panel.zig`.
- ✅ Removed dead `pixelart.explorer.project` re-export from `editor/explorer/Explorer.zig`
  (the project view is contributed via `Host.registerSidebarView`, not the shell hub).
- ✅ Removed dead `Plugin.drawBottomPanel` / `drawExplorerPane` vtable hooks — superseded by
  the `registerSidebarView` / `registerBottomView` registries (see "Multi-plugin readiness").

- ✅ **Dialog-registry lift** (see "Multi-plugin readiness"): all pixel-art dialogs lifted off
  the shell hub onto plugin vtable hooks. `editor/dialogs/Dialogs.zig` no longer imports
  `pixelart`; owns only shell-level dialogs (UnsavedClose, AppQuitUnsaved, AboutFizzy, Web*).

**Shell → plugin surface now (grep `pixelart\.X` in `src/editor` + `src/plugins/workbench`):**
`pixelart.plugin` ×15 (the vtable boundary — intended), `pixelart.State` ×2,
`pixelart.Globals` ×2, `"pixelart.menu.edit"` ×1 (a registered-menu **id string**, not a
symbol ref). **No concrete pixel-art type (dialogs/render/explorer/Packer) is named in the
shell anymore** — only the plugin vtable boundary + lifecycle.

---

## Multi-plugin readiness (context for the upcoming **textedit** plugin)

> Direction (user, 2026-06-19): a textedit plugin will render `.txt`/`.atlas`/`.json` etc.,
> coexisting in tabs/splits beside pixel-art docs. The bottom panel should likewise host
> per-plugin tabs (a console plugin one day). **This is NOT current scope** — captured here
> so the decoupling doesn't bake in single-plugin assumptions.

**Audit result (this session): the architecture is already positioned for all of it.**

| Concern | Mechanism today | textedit slots in by |
|---------|-----------------|----------------------|
| Which plugin owns an opened file | `Host.pluginForExtension(ext)` picks lowest `fileTypePriority` across **all** plugins (`Host.zig`) | registering `.txt/.atlas/.json` with a priority |
| Per-document ops (save/dirty/undo/path/grouping/…) | all route through `DocHandle.owner` vtable (opaque handle; shell never inspects `ptr`) | implementing the doc vtable hooks |
| Rendering a doc into a tab/split | `Workspace.zig` calls `doc.owner.drawDocument(doc)` — type-agnostic | implementing `drawDocument` |
| Sidebar/explorer panes | `Host.registerSidebarView(.{id,owner,title,draw[,draw_workspace]})`; shell renders the set (`Sidebar.zig`) | calling `registerSidebarView` |
| **Bottom panel tabs** | `Host.registerBottomView(.{id,owner,title,draw})`; `Panel.zig` draws a **tab strip when >1 view** + active-view get/set on `Host` | calling `registerBottomView` (a console is just another bottom view) |
| Menus | `Host.registerMenu` + `contributeMenu` | registering its menus |

So tabs/splits and multi-plugin bottom panels are **already** registry-driven, not
pixelart-hardcoded. No corner-painting risk found.

**Dialogs — lifted (was the one single-plugin seam, now DONE).** All pixel-art dialog launches
moved out of the shell hub onto the plugin; the shell never names a plugin dialog:

- **Doc-scoped dialogs** route through `DocHandle.owner` vtable hooks (added to `sdk/Plugin.zig`):
  - `requestGridLayoutDialog(doc)` — shell `Editor.requestGridLayoutDialog` resolves the active
    doc and dispatches; launch + `presetFromFile` now live in `dialogs/GridLayout.request`.
    Removed the old `prepareGridLayoutDialog` hook and the `EditorAPI.requestGridLayoutDialog`
    round-trip (plugin `CanvasData` calls `GridLayout.request` directly now).
  - `requestFlatRasterSaveWarning(doc, mode, from_save_all_quit)` — `mode` is the new SDK enum
    `Plugin.FlatRasterSaveMode {editor_save, save_and_close}`. The save/quit flag is now captured
    per-dialog in a `_flat_raster_from_quit` data slot instead of an externally-reset module var,
    so `Editor.abortSaveAllQuit` no longer pokes dialog state.
- **Type-selecting dialog** (not doc-scoped): `Host.requestNewDocument(parent_path, id_extra)`
  dispatches to the first plugin advertising `requestNewDocumentDialog` (vtable). Shell
  `Editor.requestNewFileDialog` and `workbench/files.zig` "New File…" call the Host method;
  launch lives in `dialogs/NewFile.request`.
  **TODO(multi-plugin):** with textedit registered, "New File" is ambiguous — turn this into a
  typed `New > <kind>` chooser (each editor plugin contributes a new-doc kind) instead of
  first-provider dispatch. The seam (shell decoupled from the dialog impl) is already in place.

Dead dialog re-exports removed in the same pass: `Dialogs.Export`, `Dialogs.drawDimensionsLabel`
(both had zero shell callers).

---

## Stage W — workbench lift (IN PROGRESS, user signed off 2026-06-19)

Workbench is the last "half-shell" plugin: 225 `fizzy` refs (163 `fizzy.editor`) across
`files.zig`, `Workspace.zig`, `Workbench.zig`, `FileLoadJob.zig`, `plugin.zig`. Unlike pixelart
it has **no state-injection yet** — `plugin.state = undefined`, draw hooks call
`fizzy.editor.*` directly, and the `Workbench` struct instance lives on `Editor`. Tab order *is*
the order of `Editor.open_files`, which workbench mutates in place (`std.mem.swap` on
values/keys at `Workspace.zig:467+`) — that's the deep coupling.

**Plan (mirrors pixelart Stage C–E), each stage builds all 3 configs green:**

- **W1 — host-injection seam + doc-collection routing — DONE.** Added
  `workbench/src/Globals.zig` (`host: *sdk.Host`, `gpa`), injected in `App.zig` (path import
  until W5). Added `EditorAPI.swapDocs(a,b)` primitive (+ Host forwarder + shell impl) — the
  only mutation of open-doc *order* plugins do; replaces workbench's in-place `std.mem.swap`
  on `open_files`. Converted in `Workspace.zig` + `files.zig`: `open_files.count/.values().len`
  → `Globals.host.openDocCount()`, `open_files.values()[i]`/`docAt` → `docByIndex`,
  `open_files.getIndex` → `docIndex`, `setActiveFile` → `setActiveDocIndex`,
  `fizzy.editor.host` → `Globals.host`. **Workbench `fizzy.editor` refs: 163 → 106.**
- **W2 — workspace/grouping ownership.** Move `workspaces`, `open_workspace_grouping`,
  grouping-id counters (`newGroupingID`/`currentGroupingID`), and file-tree tab drag-drop
  state (`tab_drag_from_tree_path`/`file_tree_data_id`/`clearFileTreeTabDragDropState`, today
  shared with shell `Explorer`/`Editor`) onto the `Workbench` struct; shell routes through it.
- **W3 — remaining `fizzy.editor.*` (doc ops, folder/settings/recents/atlas) → EditorAPI/Host.**
  Add missing EditorAPI surface as needed (`folder`, `setProjectFolder`, `openFilePath`, …).
- **W4 — `fizzy.dvui`/`fizzy.app`/`fizzy.math`/`fizzy.backend` → sdk/core**; then
  **W5 — `b.addModule("workbench")`** + `@import("workbench")`, drop the shell path imports
  (`Editor.zig` re-exports of `Workspace`/`FileLoadJob`/`Workbench`) and the `fizzy` import.

---

## Next big rock: sprite / atlas → `core` — DONE

End-state achieved. Verified this session:

- **`core.Atlas`** (`src/core/Atlas.zig`) — generic atlas type, `loadSpritesFromBytes`.
- **`core.atlas`** (`src/core/generated/atlas.zig`) — generated sprite-id index
  (`sprites.logo_default`, …). `fizzy.atlas = core.atlas`.
- **`core.Sprite.draw`** — the "draw sprite N" primitive.
- **Shell** holds its own static atlas instance (`editor.atlas`, loaded via
  `core.Atlas.loadSpritesFromBytes`) for logo/icons and exposes it to plugins as
  `EditorAPI.UiSprite`. Draws via `core.Sprite.draw`.
- **Plugin** consumes `core.Atlas`/`core.Sprite` for its own rendering (composites,
  reflections, `water_surface`) and builds its own packed `internal/Atlas.zig` at pack time.
- **Neither side reaches the other's atlas** — `grep 'editor.atlas|fizzy.atlas' src/plugins/pixelart/src` → 0.

Residual: `workbench/files.zig` + `workbench/Workspace.zig` draw the logo via
`fizzy.editor.atlas` — that's the workbench plugin still routing through `fizzy.editor`
(a separate "workbench off the app hub" concern), not a sprite/atlas-in-core gap.

---

## What `core` is (Stage A3 — unchanged)

`src/core/` is a standalone module; never imports `src/fizzy.zig`. See prior handoff
sections for allocator injection, trackpad hook, dialog chrome state, build wiring, and
the **build-script file-ownership trap** (`process_assets.zig` → std-only `Atlas.zig`).

**macOS case-insensitive FS gotchas:**
- `sprite.zig` vs `Sprite.zig` → use `sprite_render.zig`.
- `pixelart.zig` vs `PixelArt.zig` / `State.zig` → use `module.zig` for the build module
  root; use the two-step git rename when introducing `pixelart.zig` hub.

---

## Key paths

| Path | Role |
|------|------|
| `HANDOFF.md` | This file |
| `src/plugins/pixelart/module.zig` | Pixel-art build module root |
| `src/plugins/pixelart/pixelart.zig` | Pixel-art intra-plugin hub |
| `src/plugins/pixelart/src/` | Pixel-art implementation tree |
| `src/plugins/workbench/module.zig` | Workbench build module root |
| `src/plugins/workbench/workbench.zig` | Workbench intra-plugin hub |
| `src/plugins/workbench/src/` | Workbench implementation tree |
| `src/sdk/EditorAPI.zig`, `Host.zig` | Full shell API surface |
| `src/editor/Editor.zig` | Shell; `DocHandle`-only at UI boundary; no `Internal.File` |
| `src/fizzy.zig` | App hub; mid-migration to `pixelart_mod` re-exports |
| `process_assets.zig` | Build-time asset atlas generator (repo root, beside `build.zig`) |
| `src/backend/` | Platform backend: native/web stubs, singleton, auto-update, objc, MSVC shim |

---

## State of the tree

**Uncommitted** — nothing in this Phase-4 effort has been committed (commit on request).

Beyond Stages A–C, the working tree now also has Stage D scaffold changes:
`module.zig`, `pixelart.zig`, `State.zig`, `Globals.zig`, hub re-exports in `fizzy.zig`,
shell import migration, `State.docs` + explorer/bottom-panel fields, `bridge.zig` removed.

Sanity greps:

```
grep -rn 'fizzy\.editor\.' src/plugins/pixelart     → 0 live
grep -rn 'fizzy\.platform' src/plugins/pixelart     → 0
grep -rn 'fizzy\.app\.allocator' src/plugins/pixelart → 0
grep -rn 'bridge\.' src/plugins/pixelart            → 0
grep -rn '@import.*fizzy' src/plugins/pixelart  → 0
grep -rn 'editor/(dialogs|WebFileIo)' src/plugins/pixelart  → 0
```

All three configs green: `zig build`, `zig build check-web`, `zig build test`.
