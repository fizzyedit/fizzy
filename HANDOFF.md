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

**Next:** Stage E — trim `fizzy.zig` re-exports; route copy/paste/pack through plugin vtable.

> **Read this first if you're a fresh agent:** start at "Stage D — remaining work"
> below. All three build configs are green right now.

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

**Still remaining:**
- Shell `Editor` still types `*Internal.File` in helpers (`activeFile`, `fileFromDoc`) — shrink as multi-plugin doc types arrive.
- `pixelart.internal.File` in workbench tab paths — type-agnostic `DocHandle` only at boundary.
- Integration test shim updated for `pixelart.State` settings; `check-integration` still blocked on native `backend_native` SDL import under dvui-testing (pre-existing).

---

## Next big rock: sprite / atlas → `core` (parallel track)

Resolves `editor.atlas` coupling and the shell reaching into the plugin for UI icons.

- Shell only needs a static atlas sprite draw (logo/icons) — `workbench/files.zig`,
  `workbench/Workspace.zig`.
- **`core`:** generic atlas type + "draw sprite N" primitive.
- **Plugin:** `renderSprite`, composites, reflections, `water_surface`.
- End-state: **shell → core**, **plugin → core**, neither depends on the other.

(User signed off; sequenced after settings, can proceed alongside late Stage D.)

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
| `src/editor/Editor.zig` | Shell; still uses `fizzy.pixelart.*` and `Internal.File` helpers |
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
