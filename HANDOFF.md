# Fizzy Modular-Plugin Refactor — Handoff (Phase 4 COMPLETE → Phase 5: runtime dylib plugins)

## TL;DR

We turned the monolithic editor into a **core shell + plugins** layout. **Phase 4 (compile-time
modular separation) is COMPLETE:** `core`, `pixelart`, and `workbench` are all decoupled build
modules; the shell imports plugins only via `@import("pixelart")` / `@import("workbench")` and
talks to them through the SDK vtable + `Host`/`EditorAPI` registries. All three configs green.

**The next phase (Phase 5) is runtime dylib plugins** — desktop dynamic libraries
(macOS/Linux/Windows, `arm64` + `x86_64`), web static, built-ins bundled with the app.
See **"Phase 5 — Runtime dylib plugins"** below. Everything under "Phase 4 history"
further down is DONE reference material.

---

### Phase 4 history (all DONE — reference)

Phase 4 made `core` a standalone Zig module, then (Stages B–E) lifted the pixel-art editor fully
behind the plugin SDK, then (Stage W) did the same for workbench.

**Stage A1–A3, B, C (full)** — `core` module; per-plugin settings, docs/tabs storage inversion,
save/pack/editor-action decoupling, platform detection, explorer pane lift, sprites bottom-panel lift.

**Stage D — DONE** — module scaffold, `Globals` injection, Workspace decoupling, zero `fizzy.zig`
imports in plugin, `b.addModule("pixelart")` wired.

**Stage E — polish complete** (see "Stage E polish — DONE" below): shell no longer imports
`pixelart.internal`; `pixelart_state` field access fully routed to lifecycle + vtable;
`Plugin.beginFrame` hook removes the last shell→`pixelart.render` poke; dead imports pruned.
**Sprite/atlas → `core` big rock: DONE** (verified — generic atlas type + sprite-draw
primitive + sprite-id index all in `core`; neither shell nor plugin reaches the other's atlas).

**Dialog-registry lift — DONE** (see "Multi-plugin readiness"): the shell no longer names any
pixel-art dialog. `pixelart.dialogs` is gone from `src/editor` + `src/plugins/workbench`.

**Workbench lift (Stage W1–W5) — DONE** (see "Stage W" below): workbench is now a real
`@import("workbench")` build module (`wireWorkbenchModule` in `build.zig`, native/web/test).
**Zero live `fizzy.*` refs in `src/plugins/workbench/**`** (was 225). Workspace/grouping/tab-drag
state moved onto the `Workbench` struct; doc-collection + folder/settings/etc. route through
`Globals.host` (EditorAPI) and `doc.owner`. Shell imports both plugins ONLY via
`@import("pixelart")` / `@import("workbench")`.

> **Read this first if you're a fresh agent:** the **compile-time modular-separation phase is
> complete** — `core`, `pixelart`, `workbench` are all decoupled build modules; the only shell
> path-import into a plugin tree is the documented build-time `process_assets.zig → Atlas.zig`.
> Shell→plugin is now just the vtable/registry boundary plus the shell owning each plugin's
> state struct on `Editor` (`pixelart_state`, `workbench`) for lifecycle — the same arrangement
> for both. All three build configs are green.
>
> **Next big rock:** Phase 5 runtime dylib plugins — see **"Phase 5 — Runtime dylib plugins"**
> above. Optional polish first (5a): break workbench→pixelart compile-time link and route
> remaining `editor.workbench.*` field pokes (workbench Stage E).

All three build configs are green:

```
zig build            # native exe
zig build check-web  # wasm
zig build test       # unit/integration tests
```

Run all three after every stage. `zig build` for this repo currently needs to run outside
the sandbox (network/file access).

---

## Phase 5 — Runtime dylib plugins (NEXT — not started)

### Goal

**One source, two link modes:** each plugin compiles from the same Zig sources, but the
link mode depends on the target:

| Target | Link mode | Loader |
|--------|-----------|--------|
| macOS / Linux / Windows (`arm64` + `x86_64`) | **Dynamic** — plugin is a `.dylib` / `.so` / `.dll` | Host `dlopen`s at startup (built-ins) or on demand (3rd-party) |
| Web (`wasm32`) | **Static** — plugin is a Zig module linked into the exe | No runtime loader; same as today |

Phase 4 proved the **vtable + `Host` registry boundary** is the right seam. Phase 5 makes
that boundary cross a real dynamic-library load on desktop without changing plugin logic.

### Product decisions (locked for this phase)

- **Built-in plugins always ship with Fizzy.** Pixelart, workbench, and future built-ins
  (e.g. textedit) live in this repo under `src/plugins/`. We are **not** planning a
  "shell-only" Fizzy distribution stripped of plugins.
- **Built-in dylibs are bundled, not separately versioned.** The release artifact is one
  Velopack/update unit: the exe plus its built-in plugin dylibs at matching versions.
  Velopack does **not** sign or distribute each plugin independently; plugin dylibs ride
  inside the same app package the exe does.
- **3rd-party plugins are a later concern, but the architecture must allow them.** An
  external Zig project should eventually be able to `@import` a published Fizzy plugin SDK,
  write dvui-driven UI through the same `Plugin` vtable, build a dylib, and have Fizzy
  load it at runtime — registering menus, sidebar views, bottom views, and doc handlers
  through the same `Host` registries built-ins use today. A plugin store + hot-load path
  is out of scope for the first Phase-5 milestones but should not be designed away.
- **Reference plugins to demonstrate complexity:**
  - **pixelart** — full editor plugin: docs, save/dirty, explorer panes, bottom panel,
    dialogs, pack jobs; consumes **workbench-api** for tabs/splits (inter-plugin service).
  - **textedit** (future built-in) — lighter editor plugin for `.txt` / `.json` / `.atlas`
    etc., coexisting in tabs beside pixel-art docs (see "Multi-plugin readiness").
  - **workbench** — infrastructure plugin (file tree, workspaces); likely stays a
    built-in static or early-loaded dylib since it owns the center layout.

### Dylib mechanism — Option 2: context injection (validated)

The `spikes/shared-globals` spike ruled out **Mechanism A** (one shared `libdvui` /
`rdynamic` symbol interposition — globals are not auto-shared across the dylib boundary on
macOS two-level namespace, and the same applies on Linux/Windows).

**Mechanism B (context injection) is the chosen approach:**

- Host and plugin each compile their **own copy** of `dvui` + `sdk` + `core` (same pinned
  Zig + source versions → identical struct layouts).
- Host owns the live `dvui.Window`, arena, backend, and GPU path.
- Before calling into a plugin's draw/tick hooks, the host **injects** the plugin-side
  dvui globals (`current_window` per frame; `io` / `ft2lib` / `debug` at init — all
  `pub var`, no dvui patch needed) with pointers into the host's live state.
- Cross-boundary vtable types (`Plugin`, `DocHandle`, `Host`, `EditorAPI`, workbench-api
  `Api`, …) are normal Zig structs, not strict C-ABI — host and plugin are pinned to the
  same SDK build. Only the **dlopen entry symbols** need `callconv(.c)`.
- Load-time **ABI version gate** rejects mismatched plugin builds before any vtable call.

See `spikes/shared-globals/README.md` and `spikes/shared-globals/build.zig` for the
minimal host+plugin dylib harness.

### What already exists (Phase 4 carry-over)

| Piece | Location | Phase-5 role |
|-------|----------|--------------|
| Plugin vtable | `src/sdk/Plugin.zig` | Same shape static or dylib; hooks already optional fn pointers |
| Host registries | `src/sdk/Host.zig` | Menus / sidebar / bottom / center / settings — hot-load target |
| EditorAPI | `src/sdk/EditorAPI.zig` | Shell reach-through; plugins never import `fizzy.zig` |
| Globals injection | `src/plugins/*/src/Globals.zig` | Pattern for post-`dlopen` pointer wiring |
| Inter-plugin service | `Workbench.Api` in `src/plugins/workbench/src/Workbench.zig` | pixelart → workbench without compile-time coupling (goal) |
| Static registration | `Editor.postInit` | `workbench_mod.plugin.register` + `pixelart.plugin.register` — replace with loader on native |

**No dylib build targets yet** — `build.zig` has no `addLibrary(.linkage = .dynamic)`.
Plugins are still compile-time modules on all targets.

### Remaining Phase-4 polish (do before or alongside Phase-5a)

These are not blockers for a spike, but should be cleared so built-in and 3rd-party
plugins share the same rules:

1. **Break workbench → pixelart compile-time link (blocker for independent dylibs).**
   - `build.zig` `wireWorkbenchModule` adds `pixelart` as a module dep.
   - `workbench/src/files.zig` reads `pixelart.Globals.state.colors.palette` for file-row
     tinting — the only live cross-plugin import in the workbench tree.
   - Fix: register a file-row fill-color hook on **`Host`** (`registerFileRowFillColor`) that
     pixelart contributes during `register()`; drop the `pixelart` import from the workbench
     module. (Host registry chosen over workbench-api to avoid service init ordering and a
     pixelart→workbench compile-time dep.)

2. **Workbench "Stage E" — route shell `editor.workbench.*` field pokes.**
   Pixelart Stage E is done (`pixelart_state` is lifecycle-only in `App.zig`). Workbench
   still has ~24 direct `editor.workbench.<field>` reaches in `Editor.zig` plus a few in
   `Explorer.zig`, `Keybinds.zig`, `WebFileIo.zig`, `singleton_native.zig` (mostly
   `open_workspace_grouping` — callers should use `editor.currentGroupingID()` instead).
   Extend `EditorAPI` / thin `Editor` delegators so the shell never names workbench internals.

3. **Minor hygiene** (non-blocking): `web_main.zig` force-imports `pixelart.widgets.FileWidget`
   for wasm link; `fizzy.zig` globals (`app`, `editor`, `packer`) shrink as the loader owns
   more lifecycle.

### Phase-5 implementation plan (incremental; all three configs green after each step)

Each step ends with `zig build`, `zig build check-web`, `zig build test`.

#### 5a — Pre-dylib decoupling (Phase-4 tail)

| Step | Work | Done when |
|------|------|-----------|
| **5a.1** | Break workbench→pixelart link (`Host.registerFileRowFillColor`; remove `pixelart` from `wireWorkbenchModule`) | `grep pixelart src/plugins/workbench` → 0; all configs green |
| **5a.2** | Workbench Stage E: route `editor.workbench.*` / `fizzy.editor.workbench.*` through EditorAPI | `grep 'editor\.workbench\.' src/` → lifecycle + delegators only |

#### 5b — Dylib scaffolding (native only; web unchanged)

| Step | Work | Done when |
|------|------|-----------|
| **5b.1** | SDK **export surface** — `src/sdk/dylib.zig` (`abi_version`, `RegisterStatus`, symbol names); `src/plugins/pixelart/dylib.zig` exports `fizzy_plugin_abi_version` / `fizzy_plugin_register`; `zig build pixelart-dylib` | ✅ Done |
| **5b.2** | **`build.zig` dual link** — add `addLibrary(.dynamic)` target for one plugin (start with pixelart or a minimal `plugins/hello` example); web root keeps static `@import("pixelart")` | Native builds `.dylib`/`.so`/`.dll` beside exe; web still static |
| **5b.3** | **Host loader** — `src/editor/PluginLoader.zig`; `Host.pluginById`; `FIZZY_PLUGIN_PATH`; `-Dstatic-pixelart` / `FIZZY_STATIC_PIXELART`; `zig build test-plugin-loader` | ✅ Done |
| **5b.4** | **Dvui context injection** — `sdk/dvui_context.zig`, `fizzy_plugin_set_dvui_context`, `Host.syncPluginDvuiContext` in frame loop | ✅ Done |

Build all six native release triples (`x86_64`/`arm64` × macOS/Linux/Windows) once 5b.2
lands; linkage suffixes differ (`.dylib` / `.so` / `.dll`) but the loader API is the same.

#### 5c — Built-in plugins as bundled dylibs (desktop)

| Step | Work | Done when |
|------|------|-----------|
| **5c.1** | Built-in pixelart dylib loaded by host on native; static on web; Editor routes via `pixelartPlugin()` / `host.pluginById` | ✅ Done |
| **5c.2** | Built-in workbench dylib loaded by host on native; `workbenchPlugin()` / `workbench_files_view` routing | ✅ Done |
| **5c.3** | Install step bundles built-in dylibs next to exe (same `zig-out` / Velopack tree) | Release package contains exe + `pixelart.{dylib,so,dll}` etc.; single update channel |

Built-ins can remain **statically linked during 5b** and flip to dylib in 5c — the
`register()` path is identical either way.

#### 5d — Reference plugins + 3rd-party path (later milestones)

| Step | Work | Notes |
|------|------|-------|
| **5d.1** | **textedit** built-in plugin | Exercises multi-editor tabs, `fileTypePriority`, `registerBottomView`; forces "New > kind" chooser |
| **5d.2** | **Published plugin SDK** (`fizzy-plugin-sdk` or similar) | External Zig project: import SDK + dvui, implement vtable, `zig build` → dylib |
| **5d.3** | **User plugin directory** + discovery | Scan `~/.fizzy/plugins/` (or platform equivalent); load + ABI-gate |
| **5d.4** | **Hot load** + plugin store | Reload dylib, refresh Host registries; trust/signing model TBD |

### 3rd-party / distribution considerations (figure out later, don't block 5a–5c)

- **Trust:** built-ins are co-signed with the app; 3rd-party plugins need a separate policy
  (user opt-in, hash allowlist, dev-mode only, etc.) — not decided yet.
- **Velopack:** app updates replace the whole `zig-out` tree including built-in dylibs; no
  per-plugin update channel for built-ins.
- **Version skew:** ABI gate + documented "built with Fizzy X.Y" requirement for 3rd-party
  dylibs; plugin store would pin compatible versions.
- **Hot load:** `Host` registries already support append; unload needs vtable `deinit` +
  registry removal + no dangling `DocHandle.owner` — design when approaching 5d.4.

### Phase-5 sanity greps (add to the checklist)

```
# no cross-plugin compile-time imports (after 5a.1)
grep -rn '@import("pixelart")' src/plugins/workbench     → 0
grep -rn 'pixelart\.'         src/plugins/workbench     → 0

# shell workbench field pokes routed (after 5a.2)
grep -rn 'editor\.workbench\.' src/                       → lifecycle/delegators only
grep -rn 'fizzy\.editor\.workbench\.' src/                → 0

# dylib entry exists (after 5b.1)
grep -rn 'fizzy_plugin_' src/sdk src/plugins             → export symbols present

# web stays static (always)
grep -rn 'DynLib\|dlopen' src/                           → 0 on web code paths
```

### On-disk layout (locked)

Fizzy already separates **install dir** from **user config** (`core/paths.zig` →
`configFolder()`; `App.zig` chdirs to the executable dir on native). Phase 5 keeps that
split and adds two plugin locations:

| Kind | Path | Writable | Updated by |
|------|------|----------|------------|
| **Built-in dylibs** | `<exe_dir>/plugins/<id>.{dylib,so,dll}` | No (install tree) | Velopack / app update (same unit as exe) |
| **User / 3rd-party dylibs** | `<config_folder>/plugins/<name>/plugin.{dylib,so,dll}` | Yes | User / future plugin store |
| **Plugin settings** | `<config_folder>/settings.json` → `"plugins": { … }` | Yes | App (already via `Host.plugin_settings`) |

`<exe_dir>` is where the binary lives (and where the app chdirs on launch). `<config_folder>`
is the OS user config dir + `fizzy/` (e.g. `~/Library/Application Support/fizzy`,
`~/.config/fizzy`) — **not** beside the exe.

**Loader search order (native):**

1. Built-ins — fixed list from `{exe_dir}/plugins/<id>.<ext>`
2. User plugins — scan `{config_folder}/plugins/*/plugin.<ext>`
3. Dev override — env var e.g. `FIZZY_PLUGIN_PATH` (optional, for local dylib hacking)

Web: no loader; plugins stay statically linked into the wasm binary.

Built-in dylibs ship inside the same Velopack package as the exe (no per-plugin signing or
update channel). User plugins survive app updates because they live under config, not install.

Repo source tree `src/plugins/` is **build layout only** — unrelated to these runtime paths.

### Where to begin (next session)

**5c.1–5c.2** — done (pixelart + workbench built-in dylibs on native). **Next: 5c.3** (Velopack bundle polish) or **5d**.

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
| `module.zig` | Compile-time module root; shell imports via `@import("pixelart")` / `@import("workbench")` |
| `pixelart.zig` / `workbench.zig` | Hub named after the plugin folder; files in `src/**` import as `../<name>.zig` or `../../<name>.zig` |
| `src/State.zig` (pixelart) / `src/Workbench.zig` (workbench) | Plugin runtime state struct (owned on `Editor`) |
| `src/Globals.zig` | Runtime injection — pixelart: `gpa`/`state`/`packer`; workbench: `gpa`/`host`/`workbench` |
| `src/plugin.zig` | Plugin registration + draw entry points |
| `src/deps/` | Third-party deps (`pixelart` only) |

Both plugins keep their state struct on `Editor` (`editor.pixelart_state`, `editor.workbench`)
for lifecycle; plugin code reaches it + the Host through its `Globals`.

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

## Stage D — remaining work — DONE (historical)

All items below were completed in Stage D/E/W. Kept for archaeology only.

1. ~~Route straggler shell path imports through `pixelart_mod` / `@import("pixelart")`.~~ DONE
2. ~~Wire `b.addModule("workbench", …)`.~~ DONE (Stage W5)
3. ~~Stage E cleanup in shell `Editor.zig`.~~ DONE (pixelart); workbench Stage E → Phase 5a.2

Do **not** re-introduce a duplicate `@import("plugins/pixelart/module.zig")` from both
`App.zig` and `fizzy.zig` via a third path; shell code uses `@import("pixelart")` /
`@import("workbench")` build modules.

---

## Stage E — strip pixel-art names from shell hubs — COMPLETE

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

## Stage W — workbench lift — COMPLETE (signed off 2026-06-19)

Workbench was the last "half-shell" plugin: it started this stage at **225 `fizzy` refs**
(163 `fizzy.editor`) across `files.zig`, `Workspace.zig`, `Workbench.zig`, `FileLoadJob.zig`,
`plugin.zig`, with no state-injection (`plugin.state = undefined`, draw hooks calling
`fizzy.editor.*`), the `Workbench` struct on `Editor`, and tab order living in
`Editor.open_files` (mutated in place via `std.mem.swap`). After W1–W5 below:
**zero live `fizzy.*` refs remain** (comments only), workbench is a `@import("workbench")`
build module, and all three configs are green. Verified 2026-06-19.

**Plan (mirrored pixelart Stage C–E), each stage built all 3 configs green:**

- **W1 — host-injection seam + doc-collection routing — DONE.** Added
  `workbench/src/Globals.zig` (`host: *sdk.Host`, `gpa`), injected in `App.zig` (path import
  until W5). Added `EditorAPI.swapDocs(a,b)` primitive (+ Host forwarder + shell impl) — the
  only mutation of open-doc *order* plugins do; replaces workbench's in-place `std.mem.swap`
  on `open_files`. Converted in `Workspace.zig` + `files.zig`: `open_files.count/.values().len`
  → `Globals.host.openDocCount()`, `open_files.values()[i]`/`docAt` → `docByIndex`,
  `open_files.getIndex` → `docIndex`, `setActiveFile` → `setActiveDocIndex`,
  `fizzy.editor.host` → `Globals.host`. **Workbench `fizzy.editor` refs: 163 → 106.**
- **W2 — workspace/grouping ownership — DONE.** Moved `workspaces`, `open_workspace_grouping`,
  `grouping_id_counter`, `tab_drag_from_tree_path`, `file_tree_data_id` onto `Workbench`;
  added `Globals.workbench`, `workbench_layout.zig` (`rebuildWorkspaces`/`drawWorkspaces`),
  and `Plugin.removeCanvasPane` (pixelart implements; `Workspace.deinit` iterates host plugins).
  Shell `Editor` delegates `activeDoc`/`setActiveFile`/`rebuildWorkspaces`/`drawWorkspaces`/
  grouping helpers through `editor.workbench`. Workbench plugin code uses `Globals.workbench`
  for workspace state; `setDocGrouping` → `doc.owner.setDocumentGrouping` in tab-drag paths.
- **W3 — remaining `fizzy.editor.*` → EditorAPI/Host — DONE.** Extended `EditorAPI`/`Host`
  with doc/file ops (`docFromPath`, `openFilePath`, `openOrFocusFileAtGrouping`,
  `closeDocById`), project folder (`setProjectFolder`, `closeProjectFolder`, `isPathIgnored`,
  `recentFolderCount`/`recentFolderAt`, `openInFileBrowser`), explorer state
  (`explorerViewportWidth`, `explorerBranchIsOpen`, `setExplorerBranchOpen`), and
  `drawWorkspaces`. Workbench `files.zig`/`Workspace.zig`/`Workbench.zig`/`plugin.zig`
  now route through `Globals.host` + `Globals.workbench`; zero runtime `fizzy.editor`
  refs remain in workbench draw paths (comments only).
- **W4 — `fizzy.dvui`/`fizzy.app`/`fizzy.math`/`fizzy.backend` → sdk/core — DONE.**
  Workbench hub (`workbench.zig`) re-exports `wdvui` (= `core.dvui`), `math`, `atlas`,
  `platform`, `Sprite`, `perf`. Plugin sources use `Globals.allocator()` instead of
  `fizzy.app`; native open dialogs via `host.showOpenFolderDialog`/`showOpenFileDialog`.
  `workbench-api` service ctx is `*Host` (no `fizzy.Editor` in workbench).
- **W5 — `b.addModule("workbench")` + shell `@import("workbench")` — DONE.**
  `wireWorkbenchModule` in `build.zig` (native, web, test). `Editor.zig`/`App.zig`/
  `Explorer.zig` import the module; path imports removed.

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
- Workbench draws the logo via `Globals.host.uiAtlas()` (not `fizzy.editor.atlas`).

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
| `spikes/shared-globals/` | Dylib + dvui context-injection spike (Mechanism B) |
| `src/sdk/dvui_context.zig` | Mechanism B — inject host dvui globals into plugin dylib copy |
| `src/sdk/dylib.zig` | Dylib ABI version + entry symbol names (`fizzy_plugin_*`) |
| `src/plugins/pixelart/dylib.zig` | Pixelart dynamic-library root (exports only) |
| `src/plugins/workbench/dylib.zig` | Workbench dynamic-library root (exports only) |
| `src/sdk/Plugin.zig` | Plugin vtable; dylib entry wraps `register()` |
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

**Phase 4 committed** through the workbench lift (`stage w4` + follow-up). **Phase 5a
(5a.1–5a.2) complete** — plugins decoupled; shell workbench field pokes routed.

Sanity greps (Phase-5 targets in **"Phase 5 sanity greps"** above):

```
# pixelart — fully decoupled from fizzy
grep -rn 'fizzy\.editor\.' src/plugins/pixelart     → 0 live (comments only)
grep -rn '@import.*fizzy'  src/plugins/pixelart     → 0

# workbench — decoupled from fizzy and pixelart (5a.1 done)
grep -rn 'fizzy\.'         src/plugins/workbench/src → comments only, 0 live
grep -rn 'pixelart'         src/plugins/workbench     → 0
grep -rn '@import("workbench")' src/editor src/App.zig → module import (no path imports)

# shell workbench field pokes routed (5a.2 done)
grep -rn 'fizzy\.editor\.workbench\.' src/            → 0
grep -rn 'editor\.workbench\.' src/                  → lifecycle + Editor delegators only (Editor.zig, App.zig Globals inject)

# shell imports plugins only via build modules; only build-time exception:
grep -rn 'plugins/.*/src' src/ *.zig (excl. src/plugins) → process_assets.zig → Atlas.zig
```

All three configs green: `zig build`, `zig build check-web`, `zig build test`.
