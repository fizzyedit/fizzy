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
        │                        Shell (Editor)                   │
        │  window · frame loop · menu/sidebar/panel layout · docs │
        │                                                         │
        │   ┌──────────────┐        ┌──────────────────────────┐  │
        │   │     Host     │◄──────►│        EditorAPI         │  │
        │   │  registries  │  reach │ (shell read/util surface │  │
        │   │  + services  │  back  │  arena, folder, docs, …) │  │
        │   └──────┬───────┘        └──────────────────────────┘  │
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

### Required files (checklist)

A plugin is a small, fixed set of files. The SDK owns the boilerplate — the C entry symbols
and the allocator/`*Host` injection — so you really implement just one file.

| File | Required? | You implement? |
|------|-----------|----------------|
| `build.zig` / `build.zig.zon` | **required** | yes — declare the `fizzy` dep, call `fizzy.plugin.create` + `.install` |
| `root.zig` | **required** | **no** — copy `fizzy/src/plugins/root.zig` (one `exportEntry` call) |
| `src/plugin.zig` | **required** | **yes** — `register(host)` + the `Plugin` vtable; owns your state |
| `src/State.zig`, … | as needed | yes — your feature code |

**Minimum viable plugin:** `build.zig`, `build.zig.zon`, `root.zig` (copied), `src/plugin.zig`.
The host injects the allocator + `*Host` into the SDK itself (read via `sdk.allocator()` /
`sdk.host()`), so there is no storage file — everything else is optional structure around your
one implementation file.

> **Built-in plugins use this exact same shape.** A built-in's folder is, file-for-file, a
> third-party plugin (`build.zig`, `build.zig.zon`, `root.zig`, `src/plugin.zig`, …) and it
> builds standalone the same way (`cd src/plugins/<name> && zig build`). The *only* extra is a
> small amount of fizzy-internal glue, separated out so it never clutters the plugin contract:
> a root `<name>.zig` (the conventional package module + import hub) plus a `static/` subfolder. See [*How built-in plugins are wired*](#how-built-in-plugins-are-wired-fizzy-internal)
> at the end of this section. The in-repo [`example`](../src/plugins/example/) plugin is the
> canonical, always-compiling template — copy that folder to start a new plugin.

### Layout

```
my-plugin/
  build.zig
  build.zig.zon    # fizzy dependency + .paths listing root.zig, src/, …
  root.zig         # dylib entry — copy from fizzy/src/plugins/root.zig (one exportEntry call)
  src/
    plugin.zig     # register(host) + Plugin vtable; owns its State
    State.zig      # optional but typical
    …
```

No storage/`Globals` file: the host injects the allocator + `*Host` into the SDK, so plugin
code reads them through `sdk.allocator()` / `sdk.host()`. The in-repo
[`example`](../src/plugins/example/) plugin is a complete minimal example you can copy;
[markdown](https://github.com/fizzyedit/markdown) is an external one.

### What each file must contain

#### `root.zig` (third-party only — copy, don't invent)

The entire dylib entry is one call to `sdk.dylib.exportEntry`, which emits the five C
symbols the host looks up:

```zig
const sdk = @import("sdk");

comptime {
    sdk.dylib.exportEntry(@import("src/plugin.zig"));
}
```

| Export | Purpose |
|--------|---------|
| `fizzy_plugin_abi_fingerprint` | Must match host or load is rejected |
| `fizzy_plugin_register` | Calls your `src/plugin.zig` `register(host)` |
| `fizzy_plugin_set_dvui_context` | Host injects live dvui window/io before draw |
| `fizzy_plugin_set_render_bridge` | Host injects dvui proxy render bridge |
| `fizzy_plugin_set_globals` | Host injects allocator + `*Host` into the SDK (`sdk.allocator()` / `sdk.host()`) |

Copy **`fizzy/src/plugins/root.zig`** into your project root; the `@import("src/plugin.zig")`
is relative to **your** tree (not fizzy's). The export bodies live in the SDK
(`sdk.dylib.exportEntry`), so there is nothing to maintain or keep in sync here.

Built-in plugins use this **same** `root.zig` (their dylib build goes through it too); they no
longer carry a separate `dylib.zig` or typed `Globals.zig` — they read `sdk.allocator()` /
`sdk.host()` exactly like a third-party plugin.

#### `src/plugin.zig` — **the contract you own**

Must provide:

1. A **`sdk.Plugin` value** — stable `id` (snake_case), `display_name`, `vtable`, and
   `state` (set during `register`).
2. **`pub fn register(host: *sdk.Host) !void`** — wire `plugin.state`, call
   `host.registerPlugin(&plugin)`, then any `host.registerSidebarView` /
   `registerBottomView` / `registerCenterProvider` / `registerMenu` /
   `registerSettingsSection` / `registerService` contributions.
3. A **`vtable: sdk.Plugin.VTable`** — only fill hooks your plugin needs; unset fields
   stay `null`.

Minimal skeleton (registers identity only — no documents, no panes):

```zig
const sdk = @import("sdk");

var plugin: sdk.Plugin = .{
    .state = undefined,
    .vtable = &vtable,
    .id = "my_plugin",
    .display_name = "My Plugin",
};

const vtable: sdk.Plugin.VTable = .{
    .deinit = deinit,
};

var plugin_state: State = .{}; // your own singleton; the SDK holds gpa/host for you

pub fn register(host: *sdk.Host) !void {
    plugin.state = @ptrCast(&plugin_state);
    try host.registerPlugin(&plugin);
}

fn deinit(_: *anyopaque) void { plugin_state.deinit(sdk.allocator()); }
```

**Editor plugins** (open/save/draw files) also implement document vtable hooks —
`fileTypePriority`, `loadDocument`, `drawDocument`, `saveDocument`, `isDirty`, etc.
**Shell plugins** (workbench-style) skip document hooks and instead register a center
provider or sidebar views. See `Plugin.VTable` in [`src/sdk/Plugin.zig`](../src/sdk/Plugin.zig)
for the full hook list.

#### Runtime access — **no storage file**

The shell cannot be imported from plugin code, so the host pushes the allocator and the
`*Host` across the dylib boundary at load (`fizzy_plugin_set_globals`). `exportEntry`
catches them **into the SDK itself**, so plugin code just reads:

- **`sdk.allocator()`** — the persistent host allocator (see *Memory* below).
- **`sdk.host()`** — the shell `*Host`: registries, services, and the `EditorAPI` read
  surface (open folder, active doc, arena allocator, save dialogs).

Your **own** state is just a variable you own. A singleton is a module-level `var`:

```zig
var plugin_state: State = .{};
// in register:  plugin.state = @ptrCast(&plugin_state);
// in deinit:    plugin_state.deinit(sdk.allocator());
```

If your plugin uses `core`'s allocating helpers (most don't), sync that module's allocator
once in `register`: `core.gpa = sdk.allocator();`.

Built-in plugins do the same — they call `register(&host)` directly at startup and read
`sdk.allocator()` / `sdk.host()`. (Earlier built-ins kept a typed `Globals.zig` poked from
`App.zig`; that is gone — there is one injection path for everyone now.)

#### `build.zig` / `build.zig.zon` (third-party)

`build.zig.zon` — declare **fizzy** as the only shell dependency (dvui arrives
transitively). List every shipped path in `.paths` (`root.zig`, `src`, …).

`build.zig` — call `fizzy.plugin.create`, attach any extra libs on `lib.root_module`, then
`fizzy.plugin.install`:

```zig
const lib = fizzy.plugin.create(b, .{
    .name = "<id>", // = your manifest.id; the installed file is <id>.<ext>
    .version = @import("build.zig.zon").version, // forwarded to manifest.version
    .target = target,
    .optimize = optimize,
});
lib.root_module.linkLibrary(…);
lib.root_module.addIncludePath(…);
fizzy.plugin.install(b, lib, .{});
```

`create` injects a `fizzy_plugin_options` module carrying the parsed `version`, which
`src/plugin.zig` reads for `manifest.version` (see below). Pass
`@import("build.zig.zon").version` so your release version lives in **exactly one place** — bump
`build.zig.zon` and the store sees the update. Omitting `.version` defaults it to `0.0.0`.

**To develop/test a plugin, run `zig build install`.** It builds the plugin for the current OS
and drops `<id>.<ext>` straight into the fizzy plugins dir the editor scans —
`~/Library/Application Support/fizzy/plugins/` (macOS), `~/.config/fizzy/plugins/` (Linux),
`%APPDATA%/fizzy/plugins/` (Windows) — so it loads on the editor's next launch (no `--prefix`,
no `cp`). It also leaves `zig-out/<id>.<ext>` for packaging / the store build action. (The
plugins-dir copy is skipped silently on a host with no resolvable config home, e.g. a bare CI
runner, so a packaging `zig build` never fails on it.)

### Import discipline

Files inside `src/**` must **not** `@import("fizzy")` or reach into the shell. Allowed:

- `@import("sdk")`, `@import("core")`, `@import("dvui")` — wired on the dylib module by
  `fizzy.plugin.create`
- `@import("State.zig")`, … — sibling files in your `src/` tree
- Built-in only: `@import("../<name>.zig")` for an optional local hub file

This is what lets the same sources compile as a standalone dylib.

### The `register(host)` entry

`register` wires the plugin into the shell. A minimal plugin just registers itself; a
real one adds contributions:

```zig
pub fn register(host: *sdk.Host) !void {
    plugin.state = @ptrCast(&plugin_state);  // adopt the plugin's runtime state
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

### The `Plugin` vtable — the universal editor protocol

`Plugin.vtable` is the **universal editor contract**: every field is an optional fn pointer
taking the plugin's opaque `state`, and it holds only hooks that any editor plugin might need.
Group by purpose:

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
- **Per-frame phases** — generic frame callbacks (see the lifecycle table below for exactly
  when each fires): `beginFrame`, `prepareFrame`, `tickKeybinds`, `tickOpenDocuments`,
  `tickActiveDocument`, `drawOverlay`, `endFrame`, `needsContinuousRepaint`. A plugin does its
  own domain work *inside* these generic phases.
- **Folder lifecycle** — `onFolderClose` / `onFolderOpen` (fired when the open root folder
  changes/closes so a plugin can persist & reload state it keyed to that folder).
- **Save protocol** — `saveNeedsConfirmation(doc)` + `requestSaveConfirmation(doc, mode, …)`
  (the owner may present a pre-save confirmation, e.g. a lossy-flatten warning).
- **Contributions** — `contributeMenu`, `contributeKeybinds`.
- **New document** — `requestNewDocumentDialog` (the shell dispatches; the plugin owns the dialog).

Every hook here is generic — none names a domain feature. **Editing actions** (copy, paste,
transform, accept/cancel edit, delete selection) are deliberately *not* hooks: they are
user-invoked and mean different things per editor, so they are `Command`s (see below), not part
of this contract. A file-management plugin (workbench) implements none of the document hooks; an
editor plugin (pixelart) implements the document + rendering hooks but contributes no file tree.

#### Required vs optional

Every vtable field is an optional fn pointer, so the **type system requires nothing**. But to
function *as an editor* (open / draw / save files) you must implement the document cluster:

> `fileTypePriority` · `documentStackSize` · `documentStackAlign` · `loadDocument` ·
> `documentIdFromBuffer` · `registerOpenDocument` · `documentPtr` · `deinitDocumentBuffer` ·
> `drawDocument` · `saveDocument` · `isDirty`

Everything else is genuinely optional — implement only what your editor needs. (A non-editor
plugin like the workbench implements none of these and contributes panes + a center provider.)

#### When & where each hook fires

The model tag tells you how the shell invokes a hook: `[broadcast]` = called for every plugin
at that point; `[active-doc]` = called as `doc.owner.hook(doc)` only for the focused document;
`[requested]` = only fires after you call the paired `host.*` request. The call sites are in
`src/editor/Editor.zig` (verify with `grep` — line numbers drift):

| Hook | Model | When / where |
|---|---|---|
| `beginFrame` | broadcast | top of the draw, before workspace rebuild (`renderFrame`) |
| `prepareFrame` | requested | after layout, before draw — only when `pending_composite_warmup` was set by `host.requestPrepareFrame()` |
| `needsContinuousRepaint` | broadcast | the shell's "should I keep repainting vs idle" decision |
| `tickOpenDocuments` | broadcast | early per-frame tick; return true → request a follow-up anim frame |
| `drawDocument(doc)` | active-doc | center region, when the workbench draws the focused tab |
| `tickActiveDocument(id)` | broadcast | inside the active document container (has the timer-anchor id) |
| `endFrame` | broadcast | `defer` at the end of the document-container block |
| `tickKeybinds` | broadcast | after the center draw, before the shell's global keybinds |
| `drawOverlay` | broadcast | right after `tickKeybinds`, on top of the frame |

Outside the frame loop: `onFolderClose` / `onFolderOpen` fire `[broadcast]` from
`setProjectFolder` / `closeProjectFolder`; `saveNeedsConfirmation` / `requestSaveConfirmation`
fire `[active-doc]` from the `save` / close / quit-all paths; `loadDocument` runs on a
**background load-worker thread** (touch only the host allocator + the given buffer, no dvui).

### Commands — how a plugin contributes its *own* features

Anything a plugin **invokes** rather than implements as a shell callback — both plugin-specific
features (pixel-art's *Grid Layout*, *Pack Project*) and editing actions whose meaning varies per
editor (*Copy*, *Paste*, *Transform*, *Accept/Cancel Edit*, *Delete Selection*) — is a `Command`,
not a vtable hook. The plugin registers a named [`Command`](../src/sdk/regions.zig) with the Host,
and the shell triggers it by id via `host.runCommand("<id>")` **without knowing what it does**:

```zig
try host.registerCommand(.{
    .id = "pixelart.packProject",   // plugin-namespaced
    .owner = &plugin,
    .title = "Pack Project",
    .run = packProjectCommand,       // fn(state) anyerror!void — resolves its own context
    .isEnabled = packProjectEnabled, // optional gate
});
```

This is the seam that keeps the SDK and shell free of any one plugin's vocabulary: the universal
`VTable` above is what *every* editor implements, and `Command`s are what each plugin adds on top.
A plugin's per-frame domain work (animation, atlas packing) runs inside the generic per-frame
phases; its invocable actions are commands. See `src/plugins/pixelart/src/plugin.zig`.

**Per-owner action convention.** The shell's built-in actions on the active document — its Edit
menu / keybinds (*Copy* `copy`, *Paste* `paste`, *Transform* `transform`, accept `acceptEdit`,
cancel `cancelEdit`, delete `deleteSelection`) and *Grid Layout* (`gridLayout`) — dispatch to
`"<active_owner_id>.<action>"`. So focusing a pixel-art doc runs `"pixelart.copy"`; a second
editor answers the same shell actions by registering its own `"<its_id>.copy"`, `…transform`,
etc. An action the owner didn't register is simply a no-op for its documents. This keeps the
shell's standard editing UI while routing every action to whichever editor owns the focused tab.

### Reaching the shell: SDK-held injection

Plugin code can't import the shell, so the shell **injects pointers** into the plugin once at
startup — the allocator and the `*Host`. `exportEntry` catches them into the SDK, so plugin
code reads `sdk.allocator()` and `sdk.host()` directly (e.g. `sdk.host().<EditorAPI>` for the
open folder, active doc, arena allocator). Your own data is whatever variable you own. In a
dynamic build the host pushes these across the library boundary via the
`fizzy_plugin_set_globals` C export.

### Memory: one allocator, one arena

A plugin manages memory with the host through exactly two allocators, both reached from the
`*Host` it is handed in `register`:

- **`host.allocator`** — the persistent heap allocator. Use it for anything that outlives a
  frame (documents, caches, registry entries). You own every allocation and must free it. This
  is the same allocator surfaced as `sdk.allocator()`; the two are interchangeable.
- **`host.arena()`** — a per-frame scratch allocator. It is reset at the end of every frame, so
  never free from it and never hold a pointer into it past the current frame.

**Do not capture `dvui.currentWindow().gpa` as "the allocator."** The shell deliberately creates
the dvui window with `host.allocator`, so today they are the same instance — but treat
`host.allocator` as the contract. Mixing allocators (allocate with one, free with another) is the
one memory bug the type system can't catch and it corrupts the heap. Pick `host.allocator` and
stay with it.

### Building as a dynamic library

Your `root.zig`'s `sdk.dylib.exportEntry` emits the C entry symbols the loader looks up
(defined in `src/sdk/dylib.zig`):

- `fizzy_plugin_abi_fingerprint` → must equal the host's `dylib.abi_fingerprint` or the load is
  rejected.
- `fizzy_plugin_register(*Host)` → calls the plugin's `register`.
- `fizzy_plugin_set_globals` / `fizzy_plugin_set_dvui_context` → host injects the allocator +
  `*Host` (into the SDK) and its live dvui context into the plugin image (host and plugin each
  compile their own `dvui`/`sdk`/`core`; the host's pointers are pushed in before draw/tick).

There is **no ABI version to bump.** `dylib.abi_fingerprint` is a compile-time structural hash
over every type that crosses the boundary — the `Host`/`Plugin`/`DocHandle`/`EditorAPI` vtables,
the dvui types passed through them, and the C entry-symbol signatures (see `src/sdk/fingerprint.zig`).
Host and plugin each compute it from their own sources, so changing a vtable hook, a boundary
struct's layout, or the dvui dependency changes the hash automatically and stale plugins are
rejected at load. If you add a brand-new struct that crosses the boundary by value, add it to the
root list in `dylib.zig` so its layout is folded in.

### Third-party quick start

Fastest path: **copy the in-repo [`example`](../src/plugins/example/) plugin folder**, rename
the id/name, and replace `src/plugin.zig` with your feature. It is the canonical, always-
compiling template and already has every required file in the right place. See **Required
files**, **Layout**, and **What each file must contain** above. In short:

1. Copy `fizzy/src/plugins/root.zig` (or `example/root.zig`) → `root.zig` (one `exportEntry`
   call, never edited).
2. Implement `src/plugin.zig` (`register` + vtable). Read the host allocator + `*Host` via
   `sdk.allocator()` / `sdk.host()`; own your state as a plain `var`. No storage file.
3. Add `build.zig` / `build.zig.zon` with a `fizzy` dependency, `fizzy.plugin.create`, and
   `fizzy.plugin.install`.
4. `zig build install` — builds for this OS and installs `<id>.<ext>` into the fizzy plugins dir;
   relaunch the editor to load it.

`fizzy.plugin.create` options:

| Option | Default | When to override |
|--------|---------|------------------|
| `root_source_file` | `root.zig` | Dylib entry is not at project root or not named `root.zig` |
| `name` | `"plugin"` | Dylib artifact name (output is still `plugin.dylib` when installed) |

Pin the **fizzy** dependency to the same revision as the host you run against; ABI
mismatch surfaces as a failed load at `fizzy_plugin_abi_fingerprint`, not a semver check.

### How built-in plugins are wired (fizzy-internal)

The in-tree plugins (pixi, workbench, code, example) ship inside the signed app and compile
**two ways** — statically into the native/web/test binaries *and* (for desktop) as a bundled
dylib. **Their folder is, file-for-file, the same canonical third-party shape** described
above (`build.zig` via `fizzy.plugin.create`, `build.zig.zon`, `root.zig` → `src/plugin.zig`,
`src/…`), and each builds standalone with `cd src/plugins/<name> && zig build`. There is no
embed-stub `build.zig` and no `build_standalone.zig` anymore.

All the fizzy-internal glue is separated out so it never mixes into the plugin contract:

```
src/plugins/<name>/
  build.zig          # canonical third-party build (fizzy.plugin.create + install)
  build.zig.zon
  root.zig           # exportEntry(@import("src/plugin.zig"))
  <name>.zig         # package module root + intra-plugin import hub (see note below)
  src/
    plugin.zig       # register + Plugin vtable — identical shape to any third-party plugin
    …
  static/            # ← fizzy-internal: everything else the static embed needs
    integration.zig  # builds the static @import("<name>") module + the bundled dylib
```

- **`static/integration.zig`** — defines `addStaticModule` (the `@import("<name>")` module the
  shell links in) and `addDylib` (the bundled dylib). The root build aggregates every plugin's
  integration in [`build/plugins.zig`](../build/plugins.zig); `build/exe.zig`, `build/web.zig`,
  and `build/app.zig` (tests) call `addStaticModule`. Shared helpers live in
  [`src/plugins/shared/build/helpers.zig`](../src/plugins/shared/build/helpers.zig). Because
  these only ever run from the fizzy build root, their paths are single fizzy-relative literals
  — the old dual-root (`repo_paths`/`pkg_paths`) machinery is gone.
- **`<name>.zig`** (e.g. `pixi.zig`) — the conventional package root: it is BOTH what the shell
  resolves `@import("<name>")` to (re-exporting `pub const plugin` + any types the shell reaches
  into, e.g. `pixi.State`) AND the intra-plugin import hub that files under `src/` pull in as
  `../<name>.zig` for `sdk`/`core`/`dvui` + sibling types. It must sit at the **plugin root**,
  not under `static/`: a Zig module cannot import files above its root file's directory, so it
  has to be beside `src/` to re-export from it. A purely-dylib third-party plugin only needs it
  if it embeds statically or wants a shared hub; a minimal one (`example`) keeps it tiny.
- **Vendored C deps** — a plugin with native deps builds them with `fizzy.plugin.addCModule`
  (a Zig bindings module + its C sources), the same helper its `build.zig` and its
  `static/integration.zig` both call. See pixi's `zstbi`/`msf_gif` wiring.

A built-in is then registered statically in [`Editor.zig`](../src/editor/Editor.zig)
`postInit` with `try <name>_mod.plugin.register(&editor.host)`. The pixi/workbench/code paths
additionally try a bundled-dylib load first and fall back to the static registration; the
`example` plugin keeps it simple (static registration only, but still builds as a dylib).

The shared contract is exactly `src/plugin.zig` + the `Plugin` vtable; everything else above is
build-mode plumbing. See [`src/plugins/example/`](../src/plugins/example/) for the minimal
template and [`src/plugins/code/`](../src/plugins/code/) for an editor (document) plugin.

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
| `src/plugins/root.zig` | Stock dylib entry template — copy to third-party projects as `root.zig` |
| `src/plugins/pixelart/` | Reference editor plugin (pixi id; owns documents, renders canvas) |
| `src/plugins/workbench/` | Reference file-management plugin (tree + tabs/splits + service) |
| `src/sdk/version.zig` | SDK version + ABI fingerprint CI lock |
| `src/sdk/manifest.zig` | `PluginManifest` embedded in dylibs |
| `src/sdk/document.zig` | Document staging helpers for editor plugins |
| `templates/` | Author starter templates (editor / utility profiles) |

---

## Compatibility & versions

Fizzy uses three independent **versions**:

| Version | Owner | Purpose |
|---------|-------|---------|
| **App version** | Fizzy release (`build.zig.zon`) | User-facing editor release; does **not** gate plugin loading |
| **SDK version** | `src/sdk/version.zig` | ABI contract; bumps when the plugin boundary changes |
| **Plugin version** | Author `build.zig.zon` `.version` → `PluginManifest.version` | Plugin's own release semver; set in `build.zig.zon`, forwarded via `@import("fizzy_plugin_options").version` |

At load time the host checks, in order:

1. **ABI fingerprint** (`fizzy_plugin_abi_fingerprint`) — hard reject on mismatch (memory safety)
2. **SDK version** — `host.sdk_version` must satisfy `plugin.min_sdk_version`
3. **Stale build warning** (debug) — optional soft warning when `built_with_sdk_version < host`

CI enforces that any ABI fingerprint change updates `sdk_version` and `recorded_abi_fingerprint` together (`zig build test-sdk-version`).

### Cadence: keep fingerprint bumps rare (so plugins rebuild rarely)

A prebuilt plugin dylib is valid for exactly one `(zig version, dvui version, SDK contract)`
tuple — the coupling is inherent, because a plugin links its own `dvui` and operates on the host's
injected `dvui` globals (`dvui_context.zig`), so host and plugin must share the same `dvui` and the
same compiler. You cannot make a native dylib survive a `dvui`/zig change; the goal is to make those
changes **rare and deliberate** so plugins only rebuild on intentional SDK bumps, not every release:

- **App version ≠ SDK version.** The app version (`VERSION` / `build.zig.zon`) ships often and is
  *not* an input to the fingerprint. A Fizzy release that does not touch the boundary, the pinned
  `dvui`, or the compiler keeps the **same fingerprint**, so already-installed plugins keep loading.
- **`dvui` and zig are pinned** (the `dvui` dependency in `build.zig.zon`; `ZIG_VERSION` in CI) and
  bumped deliberately/batched. Tracking `dvui`-dev tip would flip the fingerprint constantly.
- The **store matches binaries on the fingerprint**. When it changes, that is the (announced) signal
  for plugin authors to rebuild; until they do, the store shows their plugin as "needs a rebuild for
  Fizzy SDK x.y" rather than offering an incompatible binary.

> Possible later hardening (not done yet): freeze the small `dvui`/zig value surface that crosses the
> boundary behind Fizzy-owned POD types, so incidental `dvui` refactors can't move the fingerprint at
> all — only genuine SDK-contract changes would.

### Plugin dylib layout

User and built-in plugins install as a **flat** file:

```
{config}/plugins/{id}.dylib   # macOS
{config}/plugins/{id}.so      # Linux
{config}/plugins/{id}.dll     # Windows
{exe}/plugins/{id}.{ext}      # bundled built-ins
```

The declared `manifest.id` must match the filename basename. There is no legacy `{id}/plugin.dylib` layout.

### Config folders (lowercase)

```
{config}/plugins/
{config}/palettes/
{config}/themes/
```

### Plugin manifest (dylib + optional sidecar)

Each plugin embeds metadata via C exports from `PluginManifest`, declared in `src/plugin.zig`.
Read the version from the build-injected options module so it stays in sync with `build.zig.zon`
(the store compares this against the registry to offer updates):

```zig
const plugin_options = @import("fizzy_plugin_options");

pub const manifest = sdk.PluginManifest{
    .id = "<id>",
    .name = "<Name>",
    .version = plugin_options.version, // from build.zig.zon — bump it there, not here
};
```

Optional sidecar for store indexing:

```json
{
  "id": "markdown",
  "name": "Markdown Editor",
  "version": "1.2.0",
  "min_sdk_version": "0.1.0",
  "abi_fingerprint": "0x05f167e314742930",
  "author": "…",
  "description": "…",
  "homepage": "…"
}
```

Install for local development with:

```sh
zig build install
# → installs markdown.<ext> into this OS's fizzy plugins dir, e.g.
#   ~/Library/Application Support/fizzy/plugins/markdown.dylib (macOS)
```

### Store registry schema (future)

Hosted registry JSON (Phase 2 Extensions UI):

```json
{
  "sdk_version": "0.1.0",
  "plugins": [
    {
      "id": "markdown",
      "name": "Markdown Editor",
      "releases": [
        {
          "version": "1.2.0",
          "min_sdk_version": "0.1.0",
          "abi_fingerprint": "0x…",
          "published": "2026-06-01",
          "downloads": {
            "macos-aarch64": "https://…/markdown-1.2.0-macos-aarch64.dylib"
          }
        }
      ]
    }
  ]
}
```

---

## Plugin profiles (IDE-shaped contract)

The shell is **IDE-shaped**: sidebar rail + explorer, menubar, center (`CenterProvider`), bottom panel, infobar. Plugins contribute via `Host.register*` — the shell never hardcodes feature panes.

| Profile | Implements | Example |
|---------|------------|---------|
| **Editor** | Document vtable cluster + optional panes/commands | `pixi`, `code` |
| **Shell** | Center provider + file tree, no documents | `workbench` |
| **Utility** | Menus/commands/settings only, no document hooks | external markdown menu plugin |

Use `Plugin.assertEditorVTable(vtable)` / `Plugin.assertUtilityVTable(vtable)` at compile time to catch profile mistakes.

Built-in plugin id renames (pre-release): runtime id **`pixi`** (was `pixelart`); dylib `pixi.dylib`; settings key `plugins.pixi`; env `FIZZY_STATIC_PIXI`.

| `src/editor/Editor.zig` | The shell: frame loop, `postInit` plugin registration, dylib loading |
