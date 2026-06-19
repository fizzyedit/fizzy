# Fizzy Plugin System

Fizzy is a near-empty **shell** that owns a window, a menu/sidebar/panel layout, and a
document model — but no features of its own. Everything the user sees (the pixel-art editor,
the file explorer, tabs/splits) is contributed by **plugins** that register against a stable
SDK. The same plugin source compiles two ways: statically into the app, or as a runtime
dynamic library.

---

## 1. General structure

```
        ┌─────────────────────────────────────────────────────────┐
        │                        Shell (Editor)                    │
        │  window · frame loop · menu/sidebar/panel layout · docs  │
        │                                                          │
        │   ┌──────────────┐        ┌──────────────────────────┐   │
        │   │     Host     │◄──────►│        EditorAPI         │   │
        │   │  registries  │  reach │ (shell read/util surface │   │
        │   │  + services  │  back  │  arena, folder, docs, …) │   │
        │   └──────┬───────┘        └──────────────────────────┘   │
        └──────────┼──────────────────────────────────────────────┘
                   │ register(host) + vtable calls
        ┌──────────┴───────────────┐        ┌────────────────────────┐
        │   workbench plugin       │        │   pixelart plugin      │
        │  file tree · tabs/splits │        │  canvas editor         │
        └──────────────────────────┘        └────────────────────────┘
         plugins never import each other — they meet only at the SDK
```

The SDK (`src/sdk/`) is the entire contract between shell and plugins:

| Type | Role |
|------|------|
| `Host` | What the shell hands every plugin. Holds the **registries** (the shell iterates these instead of hardcoding panes) + a **service locator** for inter-plugin APIs. |
| `Plugin` | A plugin's identity + **vtable** of optional hooks. The shell calls these; a plugin implements only what it needs. |
| `DocHandle` | Opaque handle to an open document: `{ ptr, id, owner: *Plugin }`. The shell stores these per tab and **routes every document operation to `owner`** — it never inspects `ptr`. |
| `EditorAPI` | The shell's read/utility surface a plugin reaches back through (`arena`, `folder`, open-doc collection, save dialogs, …). Reached via `Host`. |
| `regions` | The contribution structs a plugin registers: `SidebarView`, `BottomView`, `CenterProvider`, `MenuContribution`, `SettingsSection`. |
| `dylib` / `dvui_context` | The C-ABI entry contract + dvui-context injection used when a plugin is loaded as a runtime library. |

**The shell owns no features.** Each frame it iterates the Host registries and draws whatever
plugins contributed. Adding a pane, panel tab, menu, document type, or settings section is a
`Host.register*` call from inside a plugin's `register` — never a shell edit.

### Two link modes (one source)

| Mode | Who | Targets | How it registers |
|------|-----|---------|------------------|
| **Static** | Built-in plugins (pixelart, workbench, …) — always shipped with the app | all, incl. web | shell calls `plugin.register(&host)` directly at startup |
| **Dynamic** | Third-party plugins | desktop only (no dlopen on web) | shell `dlopen`s the library and calls its `fizzy_plugin_register` C entry, which calls the same `register(&host)` |

Built-in plugins live in this repo and ship inside the signed app bundle; they are never
distributed or versioned separately. The dynamic path exists so an external Zig project can
depend on the SDK, implement the same `Plugin` interface, and ship a loadable library.

---

## 2. Anatomy of a plugin

### Directory layout

```
src/plugins/<name>/
  module.zig     # static build root — what the shell imports as @import("<name>")
  dylib.zig      # dynamic build root — exports the C entry symbols only
  <name>.zig     # intra-plugin hub: re-exports sdk/core/dvui + shared types
  src/
    plugin.zig   # register(host) + the vtable + draw entry points
    Globals.zig  # runtime-injected pointers (allocator, host, plugin state)
    State.zig    # the plugin's own runtime state (whatever it needs)
    …            # implementation
```

Files inside `src/**` import the hub (`../<name>.zig`) for `sdk`/`core`/`dvui`, **never**
`fizzy.zig`. That import-discipline is what lets the plugin compile as a standalone library.

### The `register(host)` entry — the one required surface

`register` wires the plugin into the shell. A minimal plugin just registers itself; a
real one adds contributions:

```zig
pub fn register(host: *sdk.Host) !void {
    plugin.state = …;                       // adopt the plugin's runtime state
    try host.registerPlugin(&plugin);       // identity + vtable
    try host.registerSidebarView(.{ … });   // a left-rail pane
    try host.registerBottomView(.{ … });    // a bottom-panel tab
    try host.registerSettingsSection(.{ … });
    // …whatever else it contributes
}
```

`Host.register*` methods: `registerPlugin`, `registerSidebarView`, `registerBottomView`,
`registerCenterProvider`, `registerMenu`, `registerSettingsSection`, `registerService`,
`registerFileRowFillColor`. Each takes a struct with a stable, namespaced `id`, the owning
`*Plugin`, and a `draw`/resolver fn. The shell renders the set (and shows a **tab strip**
automatically when more than one plugin contributes to a region).

### The `Plugin` vtable — optional hooks the shell calls

Every field is an optional fn pointer taking the plugin's opaque `state`. Group by purpose:

- **Lifecycle** — `deinit`, `initPlugin`.
- **Document ownership** — `fileTypePriority(ext)` (claim file extensions), `loadDocument` /
  `loadDocumentFromBytes` / `createDocument`, `saveDocument`, `closeDocument`, `isDirty`,
  `undo`/`redo`/`canUndo`/`canRedo`, plus opaque document-buffer management for the async
  load path.
- **Document metadata at the workbench boundary** — `bindDocumentToPane`, `documentGrouping`,
  `documentPath`, `setDocumentPath`, dirty/save indicators. These keep `DocHandle` opaque so
  the file-management plugin never sees a plugin-specific type.
- **Rendering** — `drawDocument(doc)` (the document's content in a tab/pane),
  `drawDocumentInfobar(doc)`.
- **Per-frame** — `beginFrame`, `tickKeybinds`, `tickOpenDocuments`, … (the shell calls these
  for every plugin each frame).
- **Contributions** — `contributeMenu`, `contributeKeybinds`.
- **Dialogs** — `requestNewDocumentDialog`, `requestGridLayoutDialog`,
  `requestFlatRasterSaveWarning` (the shell dispatches; the plugin owns the dialog).

A file-management plugin (workbench) implements none of the document hooks. An editor plugin
(pixelart) implements the document + rendering hooks but contributes no file tree.

### Reaching the shell: `Globals` injection

Plugin code can't import the shell, so the shell **injects pointers** into the plugin once at
startup (`Globals.gpa`, `Globals.host`, and the plugin's own `state`). Plugin code then uses
`Globals.host.<EditorAPI>` to read shell state (open folder, active doc, arena allocator) and
`Globals.state` for its own data. In a dynamic build the host pushes these across the library
boundary via the `fizzy_plugin_set_globals` C export.

### Building as a dynamic library

`dylib.zig` exports the C entry symbols the loader looks up (`src/sdk/dylib.zig`):

- `fizzy_plugin_abi_version` → must equal the host's `dylib.abi_version` or the load is rejected.
- `fizzy_plugin_register(*Host)` → calls the plugin's `register`.
- `fizzy_plugin_set_globals` / `fizzy_plugin_set_dvui_context` → host injects allocator/state
  and its live dvui context into the plugin image (host and plugin each compile their own
  `dvui`/`sdk`/`core`; the host's pointers are pushed in before draw/tick each frame).

Bump `abi_version` whenever the `Host`/`Plugin`/`DocHandle`/`EditorAPI` layouts or an entry
symbol's meaning change.

---

## 3. How pixelart flows — and uses workbench

**The crucial property: pixelart and workbench do not import each other.** They collaborate
entirely through the SDK. `grep` confirms zero cross-imports in either `src/` tree.

### What each contributes

`pixelart.register` (`src/plugins/pixelart/src/plugin.zig`):
- Claims its file types via the `fileTypePriority` vtable hook (`.fiz`, `.png`, …).
- `registerSidebarView` ×3 — **Tools**, **Sprites**, **Project**. (Project also sets
  `draw_workspace`, letting it take over the center pane to show the packed atlas.)
- `registerBottomView` — the **Sprites** panel tab.
- `registerSettingsSection` — "Pixel Art".
- `registerFileRowFillColor` — a resolver the file tree calls to tint pixel-art file rows.
- Implements the document + rendering vtable hooks (load/save/undo/`drawDocument`/…).

`workbench.register`:
- `registerSidebarView` — the **Files** tree.
- `registerCenterProvider` — owns the entire center region: the tabs/splits + canvas layout.
- `registerService("workbench", …)` — the file-management API (see below).

### Opening and drawing a pixel-art document

```
user double-clicks foo.fiz in workbench's Files tree
        │
        ▼
host.pluginForExtension(".fiz")  ──► pixelart  (highest fileTypePriority)
        │
        ▼
pixelart.loadDocument(path)      ──► builds its File, returns an opaque buffer
        │
        ▼
shell inserts DocHandle{ id, ptr=File, owner=pixelart } into Editor.open_files
        │
        ▼
workbench (center provider) draws a tab for it, and to render the body calls
        doc.owner.drawDocument(doc)        // Workspace.zig
        │
        ▼
pixelart draws its canvas inside the workbench tab/split
```

Every later action follows the same rule — the shell and workbench only ever call
`doc.owner.<hook>(doc)`. Save, dirty-dot, undo/redo, grouping, path, and the infobar status
all route to pixelart because it is the `owner`; workbench never knows it's a pixel-art file.
Reordering a tab is the one mutation of document order, done through `EditorAPI.swapDocs`.

### The `workbench-api` service (inter-plugin file management)

Workbench registers a service (`Workbench.Api`, key `"workbench"`) so any plugin can drive the
file explorer without importing workbench:

```zig
const api: *Workbench.Api = @ptrCast(@alignCast(host.getService(Workbench.Api.service_name).?));
_ = try api.open(path, api.currentGrouping());   // open a file into the focused tab group
```

Its vtable covers open/close/save, listing open docs by path/index (no plugin type crosses the
boundary), file-tree ops (create/rename/delete/move), and `registerBranchDecorator` for drawing
a per-row icon (the built-in "unsaved" dot is one). Pixelart doesn't need it today, but it's the
sanctioned way a second editor plugin would place documents into tabs and decorate file rows.

### Why this is the model to copy

A new editor plugin (e.g. textedit) drops in with **no shell or workbench changes**: register
its file types, implement the document + `drawDocument` hooks, and optionally contribute
sidebar/bottom/settings panes. Its documents then coexist in the same tabs/splits beside
pixel-art documents, because the whole system is keyed on `DocHandle.owner` and the Host
registries — not on any plugin knowing about another.

---

### Key files

| Path | Role |
|------|------|
| `src/sdk/sdk.zig` | SDK entry — re-exports everything below |
| `src/sdk/Host.zig` | Registries + service locator + `register*` methods |
| `src/sdk/Plugin.zig` | Plugin identity + the vtable of hooks |
| `src/sdk/DocHandle.zig` | Opaque document handle (`owner`-routed) |
| `src/sdk/EditorAPI.zig` | Shell read/utility surface plugins reach back through |
| `src/sdk/regions.zig` | Sidebar/bottom/center/menu/settings contribution structs |
| `src/sdk/dylib.zig`, `dvui_context.zig` | Runtime-library C entry contract + dvui injection |
| `src/plugins/pixelart/` | Reference editor plugin (owns documents, renders canvas) |
| `src/plugins/workbench/` | Reference file-management plugin (tree + tabs/splits + service) |
| `src/editor/Editor.zig` | The shell: frame loop, `postInit` plugin registration, dylib loading |
