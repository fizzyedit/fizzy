# Fizzy Plugin System

Fizzy is a near-empty **shell** — a window, a frame loop, and a menu/sidebar/panel layout — with
no editing features of its own. Everything the user sees (the file explorer, tabs/splits, the
pixel-art editor, the text editor) is contributed by **plugins** that register against a stable
SDK. The same plugin source compiles two ways: statically into the app, or as a runtime dynamic
library (`.dylib`/`.so`/`.dll`) that any third-party author can build and ship independently.

This doc is written **progressively**: it starts from an empty folder and ends with your plugin
installable from the in-app store. Skim §1 for the mental model, then follow §2 onward in order
the first time; use it as reference after that.

1. [The mental model](#1-the-mental-model)
2. [Your first plugin, from an empty folder](#2-your-first-plugin-from-an-empty-folder)
3. [Making it do something: the SDK contract](#3-making-it-do-something-the-sdk-contract)
4. [Two plugins working together](#4-two-plugins-working-together-pixi--workbench)
5. [Compatibility: SDK version and the ABI fingerprint](#5-compatibility-sdk-version-and-the-abi-fingerprint)
6. [Publishing to the store](#6-publishing-to-the-store)
7. [Reference](#7-reference)

---

## 1. The mental model

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
        │   workbench plugin       │        │  pixi plugin           │
        │  file tree · tabs/splits │        │  canvas editor         │
        └──────────────────────────┘        └────────────────────────┘
         plugins never import each other — they meet only at the SDK
```

| Type | Role |
|------|------|
| `Host` | What the shell hands every plugin. Holds the **registries** (the shell iterates these instead of hardcoding panes) + a **service locator** for inter-plugin APIs. |
| `Plugin` | A plugin's identity + **vtable** of optional hooks. The shell calls these; a plugin implements only what it needs. |
| `DocHandle` | Opaque handle to an open document: `{ ptr, id, owner: *Plugin }`. The shell stores these per tab and **routes every document operation to `owner`** — it never inspects `ptr`. |
| `regions` | The contribution structs a plugin registers: `SidebarView`, `BottomView`, `CenterProvider`, `MenuContribution`, `Command`, `LanguageSupport`, … There is no settings region here — see `sdk.settings` below. |
| `sdk.settings` (`settings.zig`) | Comptime settings API: `sdk.settings.Schema(struct { … })` derives a persisted-values type + a `SettingsSchema` you register with the Host. The shell's settings pane draws it for you — no hand-rolled dvui settings section. |
| `dylib` / `dvui_context` | The C-ABI entry contract + dvui-context injection used when a plugin is loaded as a runtime library. |

**The shell owns no features.** Each frame it iterates the Host registries and draws whatever
plugins contributed. Adding a pane, panel tab, menu, document type, or settings section is a
`Host.register*` call from inside a plugin's `register` — never a shell edit.

### Two link modes, one source

| Mode | Who | Targets | How it registers |
|------|-----|---------|------------------|
| **Static** | Built-in plugins (`text`, `image`, `workbench`, `markdown`) — always shipped with the app | all, incl. web | shell calls `plugin.register(&host)` directly at startup |
| **Dynamic** | Third-party plugins (e.g. [`pixi`](https://github.com/fizzyedit/pixi)) | desktop only (no `dlopen` on web) | shell `dlopen`s the library and calls its `fizzy_plugin_register` C entry, which calls the same `register(&host)` |

Built-in plugins live in this repo and ship inside the signed app bundle; they are never
distributed or versioned separately. The dynamic path is the one this doc is mostly about: an
external Zig project depends on the SDK, implements the same `Plugin` interface, and ships a
loadable library — no different from a built-in except *where* it's registered from.

---

## 2. Your first plugin, from an empty folder

A plugin is a small, fixed set of files — no scaffolding tool needed. This section builds the
smallest possible one by hand so every piece is visible; §3 grows it into something useful.

### 2.1 Layout you're building toward

```
my-plugin/
  plugin.zig.zon   # identity only: id, name, version, min_sdk_version
  build.zig.zon    # fizzy dependency + .paths listing everything below
  build.zig        # fizzy.plugin.create + .install
  plugin.zig       # register(host) + Plugin vtable + your state — the one file you write
  src/             # optional — split plugin.zig's code across files as it grows
```

Four files at the root, full stop. There is no `root.zig` and no per-plugin hub module to
maintain — the build generates the dylib's C-ABI entry point for you (see §2.4), and identity
lives in exactly one place: `plugin.zig.zon`.

### 2.2 `plugin.zig.zon` — identity, and nothing else

```zig
// plugin.zig.zon
.{
    .id = "my_plugin",
    .name = "My Plugin",
    .version = "0.1.0",
    .min_sdk_version = "",
}
```

This is **identity only** — `id`/`name`/`version`/`min_sdk_version`. There is no
`hooks`/`contributes`/`settings` list: capability is unaudited, and
`plugin.zig`'s `register(host)` + vtable is the sole source of truth for what your plugin
actually does.

- **`id`** — stable, snake_case, must match the installed dylib's basename (`my_plugin.dylib`/
  `.so`/`.dll`). This is also the `Plugin.id` you set in `plugin.zig` — nothing enforces the two
  match beyond the loader's filename check, so keep them identical by hand.
- **`name`** — user-facing display name (store listing, plugin settings section header).
- **`version`** — your own release semver, validated (must parse as `std.SemanticVersion`).
  Bump it on every release; the CI tag must equal it (see §6).
- **`min_sdk_version`** — minimum host SDK version required to load. Empty string (`""`) means
  "whatever SDK this build was compiled against, no floor enforced" — the build fills that in
  from the fizzy commit you pinned.

The build reads this file at configure time (`fizzy.plugin.create`, via `readManifest`) and also
embeds its raw text verbatim into the dylib (`fizzy_plugin_manifest_zon`), so a disabled/unloaded
plugin's identity can still be probed without a full `register`. There is no on-disk `.zon`
sidecar next to the installed dylib — the plugins directory holds only the built binary.

### 2.3 `build.zig.zon` — declare the fizzy dependency

Fizzy isn't a package you install separately — a plugin depends on **the fizzy repo itself** as a
Zig package, pinned by a **`sdk-v<sdk_version>` tag** (e.g. `sdk-v0.1.35`), not an arbitrary
commit SHA. That tag is pushed automatically at the exact commit where the matching `sdk_version`
was recorded in `src/sdk/version.zig` (see §5) — pin against it and the ref you're reading in
`build.zig.zon` tells you, at a glance, which SDK contract you're building against. Use
`zig fetch` to fill in the hash:

```sh
mkdir my-plugin && cd my-plugin
zig fetch --save=fizzy https://github.com/fizzyedit/fizzy/archive/refs/tags/sdk-v0.1.35.tar.gz
```

which produces:

```zig
// build.zig.zon
.{
    .name = .my_plugin,
    .version = "0.1.0",
    .minimum_zig_version = "0.16.0",
    .paths = .{ "build.zig", "build.zig.zon", "plugin.zig", "plugin.zig.zon", "src" },
    .fingerprint = 0x0000000000000000, // zig fills this in on first `zig build`
    .dependencies = .{
        .fizzy = .{
            .url = "https://github.com/fizzyedit/fizzy/archive/refs/tags/sdk-v0.1.35.tar.gz",
            .hash = "<hash zig fetch printed>",
        },
    },
}
```

Pick the `sdk-v*` tag that matches the SDK version you intend to support (see §5) — every
`sdk_version` bump gets one automatically, so there's no need to go spelunking through commit
history for the right SHA. Built-in plugins in this repo use `.path = "../../.."` instead of a
URL, since they live next to the fizzy checkout — a real third-party plugin always pins a
**URL + hash** against an `sdk-v*` tag, because CI and other users won't have a sibling checkout.

`sdk-v*` tags are a separate namespace from fizzy's own `v*` app-release tags (§5) — they don't
trigger the app's build/package pipeline and never will (the release workflow's trigger is a glob
on the ref's start, and `sdk-v...` doesn't start with `v`). They exist purely as a pin point for
this dependency; there's no separate "SDK package" to install and nothing to `zig build` from a
`sdk-v*` checkout directly.

### 2.4 `build.zig`

```zig
const std = @import("std");
const fizzy = @import("fizzy");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const created = fizzy.plugin.create(b, .{ .target = target, .optimize = optimize });
    fizzy.plugin.install(b, created.lib, .{});
}
```

`fizzy.plugin.create`/`.install` (defined in fizzy's `plugin_sdk.zig`, exposed as `fizzy.plugin`
in `build.zig`) are the entire "built-in function" surface a plugin needs — there's no separate
SDK package to import, and no `name`/`version` to pass: `create` reads both (plus `id` and
`min_sdk_version`) straight from `plugin.zig.zon` (§2.2), so there is exactly one source of truth.
Under the hood, depending on `fizzy` with `.plugin_sdk = true` makes fizzy's root `build.zig` skip
the whole app build and just export the `fizzy_sdk`/`core`/`dvui` modules your plugin links against.

`create` returns `.{ lib, module }`: `lib` is the dylib artifact to pass to `.install`;
`module` is *your* `plugin.zig` module — attach any extra imports/options there (not to
`lib.root_module`, which is a generated wrapper, not your code) if your plugin needs extra
libraries (vendored C, packed assets). See `fizzy.plugin.addCModule` and
[pixi's `build.zig`](https://github.com/fizzyedit/pixi/blob/main/build.zig) for a worked example
with vendored C deps.

Under `create`, the dylib's C-ABI entry point (the five symbols the host looks up at `dlopen`
time — ABI fingerprint check, the `register` entry, and injection hooks for the
allocator/`*Host`/dvui-context/render-bridge — see §7 for the full list) is a tiny **generated**
root module, not a file in your repo: there is no `root.zig` to copy or maintain. It reads your
plugin's identity from `plugin.zig.zon` and calls straight into your `plugin.zig`'s `register`.

### 2.5 `plugin.zig` — the one file you actually write

The smallest plugin that compiles and loads — no visible UI yet, just registration. **Must**
declare `pub const plugin_options = @import("fizzy_plugin_options");` — the build-injected module
carrying `plugin.zig.zon`'s parsed identity (`.id`, `.name`, `.version`, `.min_sdk_version`,
`.manifest_zon`). The generated dylib root (§2.4) reaches its own copy of that identity through
*this* export rather than importing the module itself, so it must be present verbatim under this
exact name even if you never read it yourself:

```zig
const sdk = @import("fizzy_sdk");

pub const plugin_options = @import("fizzy_plugin_options");

var plugin: sdk.Plugin = .{
    .state = undefined,
    .vtable = &vtable,
    .id = plugin_options.id,
    .display_name = plugin_options.name,
};

const vtable: sdk.Plugin.VTable = .{
    .deinit = deinit,
};

var plugin_state: State = .{};
const State = struct {};

pub fn register(host: *sdk.Host) !void {
    plugin.state = @ptrCast(&plugin_state);
    try host.registerPlugin(&plugin);
}

fn deinit(_: *anyopaque) void {}
```

No `pub const manifest`, no C-ABI boilerplate, and no hand-typed `id`/`display_name` string that
has to be kept in sync with `plugin.zig.zon` by convention — `plugin_options` is the single source
of truth for both this file and the generated dylib root.

**Why `pub const plugin_options` is required, not optional:** attaching the identity options
module to two separately-rooted modules within one build graph (the generated root *and*
`plugin.zig`) makes Zig's build system refuse it outright — "file exists in modules
'fizzy_plugin_options' and 'fizzy_plugin_options0'" — the moment either one actually references
the import. Exposing it once on `plugin.zig` and having the generated root reach through that
single export avoids the double attachment entirely.

### 2.6 Build it and load it

```sh
zig build install
```

This builds the plugin for your current OS and drops `my_plugin.<ext>` straight into the fizzy
plugins directory the editor scans on startup — no `--prefix`, no manual copy:

| OS | Plugins directory |
|----|--------------------|
| macOS | `~/Library/Application Support/fizzy/plugins/` |
| Linux | `~/.config/fizzy/plugins/` |
| Windows | `%LOCALAPPDATA%/fizzy/plugins/` |

Relaunch Fizzy. Your plugin registers, but since it contributes no sidebar view or menu yet,
there's nothing to see — that's expected. Section 3 adds a visible pane.

`zig build install` also leaves `zig-out/my_plugin.<ext>` behind, which is what packaging / the
release CI in §6 grabs.

> **Fastest way to start a real plugin:** copy [`src/plugins/text/`](../src/plugins/text/)
> instead of typing all of the above by hand. It's an always-compiling document-owning editor
> plugin with every file already in the right place. For a minimal utility plugin (menus/views
> only), see [`src/plugins/markdown/`](../src/plugins/markdown/).

---

## 3. Making it do something: the SDK contract

### 3.1 `register(host)` — what you can contribute

```zig
pub fn register(host: *sdk.Host) !void {
    plugin.state = @ptrCast(&plugin_state);
    try host.registerPlugin(&plugin);               // identity + vtable — always first

    try host.registerSidebarView(.{ .id = "my_plugin.hello", .owner = &plugin, .title = "My Plugin", .draw = drawHello });
    try host.registerBottomView(.{ … });             // a bottom-panel tab
    try host.registerCenterProvider(.{ … });         // takes over the whole center region (workbench-style)
    try host.registerMenu(.{ … });                   // a top-level menubar entry
    try host.registerMenuSection(.{ … });             // inject an item into a menu you don't own
    try host.registerNativeMenuItem(.{ … });          // native macOS NSMenu leaf (mirrors a Menu*/MenuSection item)
    try host.registerService("my_plugin", &api, &plugin); // an API other plugins can look up
    try host.registerCommand(.{ … });                 // an invocable action (see 3.4)
    try host.registerFileRowFillColor(.{ … });         // tint file-tree rows for your file types
    try host.registerFileIcon(.{ … });                 // draw a custom file-tree icon
    try host.registerPluginIcon(.{ … });               // optional loaded-plugin store icon fallback
}
```

Each contribution struct (defined in [`src/sdk/regions.zig`](../src/sdk/regions.zig)) takes a
stable, namespaced `id`, the owning `*Plugin`, and a `draw`/resolver fn. The shell renders the
set — and shows a tab strip automatically when more than one plugin contributes to the same
region. Everything registered here is torn down automatically on unload (disable/uninstall via
the plugin store) and re-added on load.

**Store card icons (`ICON.png`).** The Plugins tab fetches `ICON.png` from your plugin
repository (same `homepage` URL and subdirectory convention as `README.md`) so icons appear in
the store *before* installation. Commit `ICON.png` at your repo root (or under
`src/plugins/<id>/` for built-ins in the fizzy monorepo). No copy goes into the central
[`fizzyedit/plugins`](https://github.com/fizzyedit/plugins) registry — only `README.md` and
`ICON.png` are pulled from your repo at browse time. `registerPluginIcon` remains an optional
fallback when a loaded plugin has no fetchable `ICON.png` (e.g. a sideloaded dylib with no known
`homepage`).

### 3.1.1 Settings — `sdk.settings.Schema`

There is no `registerSettingsSection` and no author-written settings schema in
`plugin.zig.zon`. Persisted settings are declared as a plain Zig struct (build-options-style,
comptime-derived), then registered from `register(host)`:

```zig
const MySettings = sdk.settings.Schema(struct {
    insert_spaces_on_tab: bool = true,
    tab_size: enum(u8) { two = 2, four = 4, eight = 8 } = .four,
    format_on_save: bool = false,
});
var settings: MySettings.Value = .{};

pub fn register(host: *sdk.Host) !void {
    plugin.state = @ptrCast(&plugin_state);
    try host.registerPlugin(&plugin);

    MySettings.load(host, plugin.id, &settings);           // apply any persisted blob
    try MySettings.register(host, &plugin, .{
        .title = "My Plugin",
        .value = &settings,                                // shell draws shared controls
    });
}
```

`Schema(T)` comptime-walks `T`'s fields (`bool`/`int`/`float`/`enum`/`[]const u8`) into a
`Setting` table — each entry's `kind: Kind` is a `union(TypeTag)` carrying only the metadata that
type actually uses (`IntKind{min,max,choices}`, `FloatKind{min,max,step}`, `EnumKind{choices}`,
void for bool/string/color), rather than one flat struct with every type's bounds fields present
on every entry — and generates `Value` (= `T`), `load`/`store` (a zon round-trip through
`Host.loadPluginSettings`/`storePluginSettings` — each plugin gets its own real, human-editable
`<plugins_dir>/<id>.settings.zon` file, sitting right beside `<id>.{dylib,so,dll}` in the same
`plugins/` directory a third-party plugin installs into; not a blob embedded in the shell's own
settings.zon), `applyZon` (parse+apply a blob directly, e.g. from `Plugin.VTable.settingsChanged`
for live edits), and `register` (wires a `SettingsSchema` + typed `Access` vtable into the Host).
`storePluginSettings` buffers the write and debounces through the shell's autosave
(`Host.flushPluginSettings`), which also skips the `writeFile` entirely when the pending blob
hashes the same as what's already on disk (or was last written this session) — a `persist()`/
`save()` call that didn't actually change anything doesn't touch disk. The file survives a
disabled or uninstalled plugin (only the dylib is deleted on uninstall), so reinstalling — or
fixing a plugin stuck in a load-failure loop and reloading it — picks the settings back up
unchanged.

**Plugins do not draw settings.** They register a typed value + field metadata only. The shell's
`PluginSettingsPane` renders shared controls (checkbox / slider / enum dropdown / …) so every
plugin's settings look the same. Edits go through `Access` and call `persist`, which stores the
zon blob and notifies `Plugin.VTable.settingsChanged`.

**Loaded-only.** A schema only exists in the Host's registry while the owning plugin is actually
registered — there's no dylib settings probe and no embedded settings-zon export. A disabled
plugin gets an Enabled-toggle-only row instead of its fields.

### 3.2 The `Plugin` vtable — the universal editor protocol

`Plugin.vtable` is generic: every field is an optional fn pointer taking the plugin's opaque
`state`, and none names a domain feature. Group by purpose:

- **Lifecycle** — `deinit`, `initPlugin`.
- **Document ownership** — `fileTypePriority(ext)` (claim file extensions), `loadDocument` /
  `loadDocumentFromBytes` / `createDocument`, `saveDocument`, `closeDocument`, `isDirty`,
  `undo`/`redo`/`canUndo`/`canRedo`, plus opaque document-buffer management for the async load path.
- **Document metadata at the workbench boundary** — `bindDocumentToPane`, `documentGrouping`,
  `documentPath`, `setDocumentPath`, dirty/save indicators. These keep `DocHandle` opaque so the
  file-management plugin never sees a plugin-specific type.
- **Rendering** — `drawDocument(doc)` (the document's content in a tab/pane),
  `drawDocumentInfobar(doc)`.
- **Per-frame phases** — `beginFrame`, `prepareFrame`, `tickKeybinds`, `tickOpenDocuments`,
  `tickActiveDocument`, `drawOverlay`, `endFrame`, `needsContinuousRepaint`. A plugin does its own
  domain work *inside* these generic phases (see the lifecycle table below for exactly when each
  fires).
- **Folder lifecycle** — `onFolderClose` / `onFolderOpen`.
- **Save protocol** — `saveNeedsConfirmation(doc)` + `requestSaveConfirmation(doc, mode, …)`.
- **Contributions** — `contributeMenu`, `contributeKeybinds`.
- **New document** — `requestNewDocumentDialog`.

**Editing actions are deliberately not hooks.** Copy, paste, transform, delete-selection mean
different things per editor, so they're `Command`s (§3.4), not part of this contract. A
file-management plugin like `workbench` implements *none* of the document hooks; an editor plugin
like `pixi` implements the document + rendering hooks but contributes no file tree.

#### Required vs optional

Every vtable field is an optional fn pointer, so the type system requires nothing. But to
function *as an editor* (open/draw/save files) you must implement the document cluster:

> `fileTypePriority` · `documentStackSize` · `documentStackAlign` · `loadDocument` ·
> `documentIdFromBuffer` · `registerOpenDocument` · `documentPtr` · `deinitDocumentBuffer` ·
> `drawDocument` · `saveDocument` · `isDirty`

Everything else is genuinely optional — implement only what your plugin needs. Use
`Plugin.assertEditorVTable(vtable)` / `Plugin.assertUtilityVTable(vtable)` at compile time to
catch a vtable shaped for the wrong kind of plugin (see §3.7 for the shapes).

#### When & where each hook fires

`[broadcast]` = called for every plugin at that point; `[active-doc]` = called as
`doc.owner.hook(doc)` only for the focused document; `[requested]` = only fires after you call the
paired `host.*` request. Call sites are in `src/editor/Editor.zig` (verify line numbers with
`grep` — they drift):

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
fire `[active-doc]` from the save / close / quit-all paths; `loadDocument` runs on a **background
load-worker thread** (touch only the host allocator + the given buffer, no dvui).

### 3.3 Reaching the shell: SDK-held injection, no storage file

Plugin code can't import the shell, so the shell **injects pointers** into the plugin once at
load — the allocator and the `*Host` — via the `fizzy_plugin_set_globals` C export. `exportEntry`
catches them into the SDK itself, so your code just reads:

- **`sdk.allocator()`** — the persistent host allocator.
- **`sdk.host()`** — the shell `*Host`: registries, services, and the `EditorAPI` read surface
  (open folder, active doc, arena allocator, save dialogs).
- **`sdk.refresh()`** — wake the app event loop for another frame. **Safe from any thread**
  (LSP workers, load jobs, PTY readers). Call this when background work finishes and the UI
  may be idle with no mouse/keyboard events — otherwise a sleeping draw loop will not pick up
  the new state until unrelated input arrives. Prefer this over `dvui.refresh` from plugin
  dylibs — it doesn't require capturing a `*dvui.Window` pointer. Equivalent to
  `sdk.host().refresh()`.

Your own state is just a variable you own — a module-level `var`, adopted into `plugin.state`
during `register` and read back via `@ptrCast` in your vtable functions. There is no separate
`Globals`/storage file to write.

### 3.4 Commands — how a plugin contributes its *own* features

Anything a plugin **invokes** rather than implements as a shell callback — plugin-specific
features (pixi's *Pack Project*) and editing actions whose meaning varies per editor (*Copy*,
*Paste*, *Transform*, *Delete Selection*) — is a `Command`, not a vtable hook. Register it once;
the shell triggers it by id via `host.runCommand("<id>")` **without knowing what it does**:

```zig
try host.registerCommand(.{
    .id = "pixi.packProject",       // plugin-namespaced
    .owner = &plugin,
    .title = "Pack Project",
    .run = packProjectCommand,      // fn(state) anyerror!void — resolves its own context
    .isEnabled = packProjectEnabled, // optional gate
});
```

**Per-owner action convention.** The shell's built-in Edit menu/keybinds (*Copy* `copy`, *Paste*
`paste`, *Transform* `transform`, accept `acceptEdit`, cancel `cancelEdit`, delete
`deleteSelection`) and *Grid Layout* (`gridLayout`) dispatch to `"<active_owner_id>.<action>"`. So
focusing a pixi doc runs `"pixi.copy"`; a second editor answers the same shell actions by
registering its own `"<its_id>.copy"`, `…transform`, etc. An action the owner didn't register is
simply a no-op for its documents.

### 3.5 Memory: one allocator, one arena

- **`host.allocator`** (== `sdk.allocator()`) — the persistent heap allocator. Use it for anything
  that outlives a frame (documents, caches, registry entries). You own every allocation and must
  free it.
- **`host.arena()`** — a per-frame scratch allocator, reset at the end of every frame. Never free
  from it, never hold a pointer into it past the current frame.

**Do not capture `dvui.currentWindow().gpa` as "the allocator."** The shell creates the dvui
window with `host.allocator` — today they're the same instance, but treat `host.allocator` as the
contract. Mixing allocators is the one memory bug the type system can't catch.

### 3.6 Import discipline

Files inside `src/**` must **not** `@import("fizzy")` or reach into the shell. Allowed:
`@import("fizzy_sdk")`, `@import("core")`, `@import("dvui")` (wired onto your module by
`fizzy.plugin.create`), and sibling files in your own `src/` tree. This is what lets the same
sources compile as a standalone dylib whether they ship in-repo or from a third-party project.

### 3.7 Plugin shapes

Informal categories, not a declared field — `plugin.zig.zon` carries identity only (§2.2).
What actually determines a plugin's shape is which vtable hooks it implements, checked at
compile time by `Plugin.assertEditorVTable`/`assertUtilityVTable` (§3.6).

| Shape | Implements | Example |
|---------|------------|---------|
| **Editor** | Document vtable cluster + optional panes/commands | `pixi`, `text` |
| **Shell** | Center provider + file tree, no documents | `workbench` |
| **Utility** | Menus/commands/settings only, no document hooks | `markdown` (preview only) |

### 3.8 Language support — highlighting and preview without owning documents

The `text` plugin remains the sole owner of every text-like file (`.txt`, `.md`, `.zig`,
`.json`, …). Language/format plugins are **utility** plugins that register a
`LanguageSupport` entry — optional hooks looked up by file extension:

```zig
try host.registerLanguageSupport(.{
    .id = "json",
    .owner = &plugin,
    .vtable = &.{
        .supportsPreview = jsonPreview.supportsPreview,
        .treeSitterHighlight = jsonHighlight.treeSitterHighlight,
        .previewPane = jsonPreview.previewPane,
    },
});
```

Every hook is optional and independent — implement only what your plugin offers:

| Hook | Purpose |
|------|---------|
| `treeSitterHighlight(state, ext) ?TreeSitterHighlight` | Tree-sitter grammar, query, and capture→style table for syntax highlighting |
| `previewPane(state, ext, bytes, id_extra, gpa) !void` | Draw a read-only preview pane (markdown render, JSON tree, …) |
| `supportsPreview(state, ext) bool` | Optional gate; defaults to checking whether `previewPane` is populated |
| `hover(state, ext, path, bytes, byte_offset) ?HoverResult` | Non-blocking; hover text for the token at `byte_offset`. Called every frame the mouse dwells over a token — see §3.9 |
| `gotoDefinition(state, ext, path, bytes, byte_offset) ?DefinitionLocation` | May block briefly; Ctrl/Cmd-click jump target |
| `completion(state, ext, path, bytes, byte_offset) ?[]const CompletionItem` | Non-blocking; ghost-text + dropdown candidates at the cursor |
| `resolveCompletionDocumentation(state, ext, path, bytes, byte_offset, index) ?[]const u8` | Non-blocking; lazy-loaded doc text for one completion candidate |
| `signatureHelp(state, ext, path, bytes, byte_offset) ?SignatureHelpResult` | Non-blocking; active-call signature while the cursor sits inside open parens |
| `supportsFormat(state, ext) bool` | Non-blocking gate for a "Format Document" menu item |
| `format(state, ext, path, bytes) ?[]const u8` | May block briefly; whole-document reformat on explicit user action |

The text editor calls `host.treeSitterHighlightFor(ext)` and `host.previewProviderFor(ext)` —
first registered provider that answers for the extension wins. When a preview provider exists,
`TextEditor` splits the tab into raw editor + preview panes. The `hover`/`gotoDefinition`/
`completion`/`signatureHelp`/`format` hooks follow the same first-registered-provider-wins
lookup, keyed off `ext`.

See `src/sdk/language.zig` for every hook's full doc comment (three-state hover convention,
why `gotoDefinition` returns an LSP `Position` instead of a resolved byte offset, the
completion ghost-text/dropdown split, …) — those types are the single source of truth, not
duplicated here.

### 3.9 LSP-backed language plugins — `core.lsp.Client`

If your language plugin talks to an existing language server (zls, clangd, rust-analyzer,
gopls, omnisharp, …) rather than implementing hover/completion/etc. itself, you don't write a
JSON-RPC client from scratch. `core.lsp.Client` — a Fizzy-provided module every plugin build
already imports (`core` is wired into `Modules` for every plugin, same as `fizzy_sdk`/`dvui`) — is a
complete, server-agnostic LSP client: process lifecycle, JSON-RPC framing, per-request-kind
caching/debouncing/negative-caching, capability negotiation (position encoding,
`completionItem/resolve` support), and answering server-initiated requests
(`workspace/configuration`, `client/registerCapability`, …). It backs the bundled `zig` plugin
(zls) today; See `src/core/lsp/Client.zig`'s own doc comments for the full threading model.

Your plugin supplies only what's specific to your server, via `Client.Config`:

```zig
const core = @import("core");
const Client = core.lsp.Client;

var client: Client = .{};

fn isCppFile(ext: []const u8) bool {
    return std.ascii.eqlIgnoreCase(ext, ".cpp") or std.ascii.eqlIgnoreCase(ext, ".hpp");
    // ... etc
}

fn getFolder() ?[]const u8 {
    return sdk.host().folder();
}

fn logWarn(source: []const u8, msg: []const u8) void {
    sdk.host().logLine(.warn, source, msg);
}

pub fn configure() void {
    client.configure(.{
        .command = &.{ "clangd", "--background-index" },
        .language_id = "cpp",
        .allocator = sdk.allocator(),
        .getFolder = getFolder,
        .logWarn = logWarn,
        .refresh = sdk.refresh,
        // Optional — most servers treat an absent/null value as "use defaults". Several
        // (rust-analyzer, gopls) are near-unusable without server-specific settings here.
        .initialization_options = null,
    });
}
```

Then:

1. Call `configure()` once from your `register(host)` — that's the earliest point
   `sdk.allocator()`/`sdk.host()` are valid; `Config` can't be a comptime default on the
   file-scope `var client: Client = .{};` every plugin declares for exactly that reason.
2. Wire `client.onFolderOpen` / `client.onFolderClose` / `client.deinit` into your `Plugin`
   vtable's `onFolderOpen` / `onFolderClose` / `deinit` — the client spawns/restarts the
   server against the project root on folder open and tears it down on close/unload.
3. Register a `LanguageSupport` whose hooks are thin wrappers: gate on your extension list,
   then delegate straight to the matching `client.*` method (`client.hover`, `.gotoDefinition`,
   `.completion`, `.resolveCompletionDocumentation`, `.signatureHelp`, `.format`) — see
   [`fizzyedit/zig`](https://github.com/fizzyedit/zig)'s `src/Lsp.zig` for the ~80-line
   reference wrapper this pattern produces end to end, and its `plugin.zig` for wiring it into
   `register(host)`.

You do not need to handle JSON-RPC framing, threading, request/response id correlation,
position-encoding negotiation, or server-initiated requests yourself — all of that is generic
LSP-spec behavior `core.lsp.Client` already implements once, for every server.

---

## 4. Two plugins working together (`pixi` + `workbench`)

**The crucial property: they do not import each other.** They collaborate entirely through the
SDK — `grep` confirms zero cross-imports in either tree. This is the model to copy for any second
editor plugin.

`pixi.register`:
- Claims its file types via `fileTypePriority` (`.fiz`, `.png`, …).
- `registerSidebarView` ×3 — Tools, Sprites, Project.
- `registerBottomView` — the Sprites panel tab.
- `sdk.settings.Schema(…).register`, `registerFileRowFillColor`.
- Implements the document + rendering vtable hooks (load/save/undo/`drawDocument`/…).

`workbench.register`:
- `registerSidebarView` — the Files tree.
- `registerCenterProvider` — owns the entire center region: tabs/splits + canvas layout.
- `registerService("workbench", …)` — the file-management API other plugins use instead of
  importing workbench (open/close/save a doc, list open docs, file-tree ops, row decorators).

### Opening and drawing a document

```
user clicks foo.fiz in workbench's Files tree
        │
        ▼
host.pluginForExtension(".fiz")  ──►  pixi  (highest fileTypePriority)
        │
        ▼
pixi.loadDocument(path)          ──►  builds its File, returns an opaque buffer
        │
        ▼
shell inserts DocHandle{ id, ptr=File, owner=pixi } into Editor.open_files
        │
        ▼
workbench (center provider) draws a tab for it, and to render the body calls
        doc.owner.drawDocument(doc)
        │
        ▼
pixi draws its canvas inside the workbench tab/split
```

Every later action follows the same rule — save, dirty-dot, undo/redo, grouping, path, and the
infobar status all route to `doc.owner`; workbench never knows it's a pixel-art file. A new editor
plugin drops in with **no shell or workbench changes**: register its file types, implement the
document + `drawDocument` hooks, and its documents coexist in the same tabs/splits.

---

## 5. Compatibility: SDK version and the ABI fingerprint

Fizzy uses three independent versions:

| Version | Owner | Purpose |
|---------|-------|---------|
| **App version** | Fizzy release (`build.zig.zon`) | User-facing editor release; does **not** gate plugin loading |
| **SDK version** | `src/sdk/version.zig` (`sdk_version`) | ABI contract; bumps when the plugin boundary changes. Every bump gets an `sdk-v<version>` git tag (auto-pushed by CI — see §2.3) as the pin point for plugin `build.zig.zon`s |
| **Plugin version** | Author `plugin.zig.zon` `.version` | Plugin's own release semver — the single source of truth, forwarded into the build (`fizzy_plugin_options`) and embedded in the dylib's `fizzy_plugin_manifest_zon`/`fizzy_plugin_version` exports |

At load time the host checks, in order:

1. **ABI fingerprint** (`fizzy_plugin_abi_fingerprint`) — a compile-time **structural hash** over
   every type that crosses the boundary (`Host`/`Plugin`/`DocHandle`/`EditorAPI` vtables, the dvui
   types passed through them, the C entry-symbol signatures). Host and plugin each compute it from
   their own sources; any mismatch is a **hard reject** — this is the real compatibility gate, not
   a semver check. There is no ABI version to hand-bump.
2. **SDK version** — `host.sdk_version` must satisfy `plugin.min_sdk_version`.
3. **Filename ↔ id** — the plugin's `plugin.zig.zon` `.id` (== `Plugin.id`) must match the
   installed filename's basename.

### Cadence: keep fingerprint bumps rare

A prebuilt plugin dylib is valid for exactly one `(zig version, dvui version, SDK contract)`
tuple — a plugin links its own `dvui` and operates on the host's injected `dvui` globals, so host
and plugin must share the same `dvui` and the same compiler. The goal is to make that coupling
rare and deliberate, not something that breaks on every release:

- **App version ≠ SDK version.** A Fizzy release that doesn't touch the boundary, the pinned
  `dvui`, or the compiler keeps the same fingerprint, so already-installed plugins keep loading.
- **`dvui` and zig are pinned** and bumped deliberately/batched, not tracked at tip.
- **The store matches binaries on the fingerprint.** When it changes, that's the (announced)
  signal for authors to rebuild; until they do, the store shows "needs a rebuild for Fizzy SDK
  x.y" instead of offering an incompatible binary.

CI enforces the pairing on the fizzy side: `zig build test-sdk-version` fails at compile time if
the live shape fingerprint (`dylib.sdk_shape_fingerprint`) drifts from the recorded literal
(`recorded_sdk_shape_fingerprint` in `src/sdk/version.zig`) without an accompanying `sdk_version`
bump.

On the plugin side, `fizzy.plugin.install` wires a `check` build step that prints what your
*pinned `sdk-v*` tag* computes for `sdk_version` + ReleaseFast `abi_fingerprint`. The release
action derives those from the built dylib — you do not copy them into workflow YAML. A *legacy*
`release.yml` that still hand-copies them is still diffed here so a stale pin fails at
`zig build` time.

---

## 6. Publishing to the store

Continuing the tutorial: your plugin builds and loads locally. Making it installable by anyone
else from Fizzy's in-app **Plugins** tab is three steps — pin fizzy properly, add one CI workflow,
and register once.

**`plugin.zig.zon` is the identity source of truth for CI.** The reusable release action reads
`id` / `version` / `min_sdk_version` from that file; the pushed **tag must equal `.version`**.
`fizzy_sdk_version` and `abi_fingerprint` are read from the built ReleaseFast dylib (they are
whatever your pinned `sdk-v*` tag embeds) — never hand-copied into workflow YAML. There is no
sidecar asset to publish alongside the dylib — the release only ships one binary per target plus
`manifest.json` (§6.3).

### 6.2 Add the release workflow

Drop this in as `.github/workflows/release.yml` — a thin caller into
[`fizzyedit/plugin-build-action`](https://github.com/fizzyedit/plugin-build-action) `@v3`:

```yaml
name: Release
on:
  push:
    tags: ["v*"]

jobs:
  build:
    uses: fizzyedit/plugin-build-action/.github/workflows/build.yml@v3
    permissions:
      contents: write
    with:
      zig-version: "0.16.0"
```

Bump the `sdk-v*` tag your `build.zig.zon` pins when you want a new SDK; the next tag's manifest picks up
the new fingerprint automatically. Tagging is all it takes to ship:

```sh
git tag v0.1.0 && git push origin v0.1.0
```

### 6.3 What the workflow produces

```
tag v0.1.0
     │
     ▼  build.yml — cross-compiles all 6 targets from ubuntu (ReleaseFast); sdk-meta.json → fingerprint
per-target binary + sha256, for each of:
     macos-aarch64   macos-x86_64
     linux-x86_64    linux-aarch64
     windows-x86_64  windows-aarch64
     │
     ▼  assemble_manifest.py — merges fragments, accumulates prior releases from the last manifest
GitHub Release assets:
     my_plugin-<os-arch>.<ext>  × 6
     manifest.json
```

`manifest.json` lists one `releases[]` entry **per `(version, abi_fingerprint)`** — never
rewritten, only appended to — so users on an older SDK keep matching an older binary instead of
seeing "incompatible":

```json
{
  "id": "my_plugin",
  "releases": [
    {
      "version": "0.1.0",
      "min_sdk_version": "0.9.0",
      "abi_fingerprint": "0x...",
      "fizzy_sdk_version": "0.9.0",
      "published": "2026-07-02",
      "downloads": {
        "macos-aarch64": { "url": "https://github.com/<you>/<repo>/releases/download/v0.1.0/my_plugin-macos-aarch64.dylib", "sha256": "..." },
        "macos-x86_64":  { "url": "...", "sha256": "..." },
        "linux-x86_64":  { "url": "...", "sha256": "..." },
        "linux-aarch64": { "url": "...", "sha256": "..." },
        "windows-x86_64":{ "url": "...", "sha256": "..." },
        "windows-aarch64":{ "url": "...", "sha256": "..." }
      }
    }
  ]
}
```

### 6.4 Register once with the store

[`fizzyedit/plugins`](https://github.com/fizzyedit/plugins) is a **decentralized registry** — it
builds nothing and hosts no binaries, just a pointer to your self-hosted `manifest.json`. Open a
one-time PR adding `registry/<id>.json`:

```json
{
  "id": "my_plugin",
  "name": "My Plugin",
  "description": "What it does, one line.",
  "author": "you",
  "homepage": "https://github.com/you/my-plugin",
  "tags": ["editor"],
  "manifest_url": "https://github.com/you/my-plugin/releases/latest/download/manifest.json"
}
```

Required: `id` (must equal the filename stem and your `plugin.zig.zon`'s `.id`), `name`, `manifest_url`.
Also commit `README.md` and `ICON.png` in your plugin repo (repo root for standalone plugins) —
the store fetches both from `homepage` for the card icon and README viewer; nothing is duplicated
into this registry.
Plugin ids are globally unique. The PR runs a validation workflow that checks the entry
structurally (hard fail) and tries to fetch your manifest (warning only — brief hosting downtime
doesn't block the PR). **This is the only PR you ever open** — every future release is just a new
tag; your manifest republishes itself and the aggregator picks it up automatically.

### 6.5 How it reaches the app

```
registry/<id>.json  ──manifest_url──►  your GitHub Release's manifest.json
        │
        │  scheduled "store ingest" (on merge, every 6h, or manual)
        ▼
registry.db  (SQLite — durable history; one author's outage never affects another)
        │  store export
        ▼
plugins/catalog/summary.json                    ← every plugin's browse metadata, no releases
plugins/catalog/<abi_fingerprint>/releases.json ← one shard per SDK generation, newest release only
        │
        │  published to GitHub Pages
        ▼
https://plugins.fizzyed.it/catalog/
        │
        │  fetched by the running app
        ▼
Fizzy's in-app Plugins tab:
  1. fetch summary.json → the browse list
  2. fetch releases.json for MY abi_fingerprint
  3. pick the release's download for my os-arch, verify its sha256
  4. write {config}/plugins/{id}.{ext}  →  dlopen on next launch
```

The catalog is split by fingerprint on purpose: each running Fizzy build only ever needs — and
only ever fetches — its own shard, which by construction holds at most one release per plugin, not
the whole version history. Development installs (`zig build install`) skip the store entirely and
drop straight into the plugins directory, exactly like §2.6.

---

## 7. Reference

### Key files

| Path | Role |
|------|------|
| `src/sdk/sdk.zig` | SDK entry — re-exports everything below |
| `src/sdk/Host.zig` | Registries + service locator + `register*` methods |
| `src/sdk/Plugin.zig` | Plugin identity + the vtable of hooks |
| `src/sdk/DocHandle.zig` | Opaque document handle (`owner`-routed) |
| `src/sdk/EditorAPI.zig` | Shell read/utility surface plugins reach back through |
| `src/sdk/regions.zig` | Sidebar/bottom/center/menu/settings/command contribution structs |
| `src/sdk/language.zig` | `LanguageSupport` registry — hover/goto-definition/completion/signature-help/format/highlighting/preview hooks looked up by file extension |
| `src/core/lsp/Client.zig` | Server-agnostic LSP client (JSON-RPC framing, caching, threading) shared by every language plugin — see §3.9 |
| `src/sdk/dylib.zig`, `dvui_context.zig` | Runtime-library C entry contract + dvui injection |
| `src/sdk/version.zig` | SDK version + ABI fingerprint CI lock |
| `src/sdk/manifest.zig` | `Manifest` — the identity-only `plugin.zig.zon` shape (`id`/`name`/`version`/`min_sdk_version`) + `parse`/`free`, read back out of a loaded dylib at runtime. The typed shape actually baked into a dylib's C-ABI exports is `dylib.Identity` (build-injected, never runtime-parsed) |
| `src/sdk/settings.zig` | Comptime settings API (`sdk.settings.Schema(T)`) — see §3.1.1 |
| `plugin_sdk.zig` (repo root) | `fizzy.plugin.create` / `.install` / `.addCModule` — the build-side API a plugin's `build.zig` calls |
| `src/plugins/text/` | Canonical document-owning editor plugin — copy to start a new editor plugin |
| `src/plugins/image/` | Read-only image viewer (PNG/JPG/JPEG) with zoom/pan |
| `src/plugins/workbench/` | Reference file-management (shell-profile) plugin |
| [`fizzyedit/pixi`](https://github.com/fizzyedit/pixi) | Reference third-party editor plugin, incl. vendored C deps + packed assets |
| [`fizzyedit/zig`](https://github.com/fizzyedit/zig) | Reference LSP-backed language plugin (zls) — see §3.9 |
| [`fizzyedit/plugins`](https://github.com/fizzyedit/plugins) | The store registry/aggregator |
| [`fizzyedit/plugin-build-action`](https://github.com/fizzyedit/plugin-build-action) | Reusable release CI (6-target build + manifest) |

### C exports every dylib has (from `sdk.dylib.exportEntry`, called by the generated dylib root)

| Export | Purpose |
|--------|---------|
| `fizzy_plugin_abi_fingerprint` | Must match host or load is rejected |
| `fizzy_plugin_sdk_version` / `_min_sdk_version` / `_version` / `_id` / `_name` | Identity, read from `plugin.zig.zon` at build time (`fizzy_plugin_options`) |
| `fizzy_plugin_manifest_zon` | The plugin's embedded `plugin.zig.zon` source text — lets the loader probe identity (and self-heal a missing on-disk sidecar, historically) without a full `register` |
| `fizzy_plugin_register` | Calls your `plugin.zig`'s `register(host)` |
| `fizzy_plugin_set_globals` | Host injects allocator + `*Host` into the SDK (`sdk.allocator()` / `sdk.host()`) |
| `fizzy_plugin_set_dvui_context` | Host injects live dvui window/io before draw |
| `fizzy_plugin_set_render_bridge` | Host injects the dvui proxy render bridge |

### Plugin dylib layout

```
{config}/plugins/{id}.dylib   # macOS
{config}/plugins/{id}.so      # Linux
{config}/plugins/{id}.dll     # Windows
{exe}/plugins/{id}.{ext}      # bundled built-ins
```

Flat only — there is no legacy `{id}/plugin.dylib` layout, and no on-disk `.zon` sidecar next to
it. The plugin's `plugin.zig.zon` `.id` must match the filename basename.

### How built-in plugins are wired (fizzy-internal — not needed for third-party authors)

Built-ins ship inside the signed app and compile **two ways** — statically into the
native/web/test binaries *and* (desktop) as a bundled dylib. Their folder matches the
canonical §2 shape (`plugin.zig` + `plugin.zig.zon` + `build.zig` + `build.zig.zon`), and each
builds standalone with `cd src/plugins/<name> && zig build`. The only extra is fizzy-internal
glue kept out of the plugin contract:

```
src/plugins/<name>/
  plugin.zig         # register + vtable (+ shell re-exports for static @import("<name>"))
  plugin.zig.zon     # identity only
  build.zig          # fizzy.plugin.create + install
  build.zig.zon
  src/               # optional implementation files (named imports: sdk/dvui/…)
  static/            # fizzy-internal: static embed + bundled dylib wiring
    integration.zig
```

`static/integration.zig` defines `addStaticModule` (linked into the app) and `addDylib` (the
bundled dylib); the root build aggregates every plugin's integration in
[`build/plugins.zig`](../build/plugins.zig). Built-ins register in
[`Editor.zig`](../src/editor/Editor.zig) `postInit` via `try <name>_mod.register(&editor.host)`.
(`pixi` used to be built-in; it now ships only through the store path in §6.)
