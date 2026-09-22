# Fizzy

Cross-platform, open-source general editor written in Zig, UI via [DVUI](https://github.com/david-vanderson/dvui). Targets native (macOS/Linux/Windows) and web (wasm32). Layout/UX is IDE-shaped (VSCode-like): sidebar rail + explorer, menubar, center tabs/splits, bottom panel, infobar.

**Read this file first, then go deeper via the links below — don't re-derive the architecture from scratch.**

## The core idea: fizzy + plugins

Fizzy the app is itself a near-empty host (window, frame loop, layout shape, document model) that owns **no editing features**. Everything the user sees — pixel-art editing, the file explorer/tabs/splits, text editing — is contributed by **plugins** that register against a stable SDK. Plugins never import each other; they meet only at the SDK.

```
Fizzy (Editor) ←── Host registries + EditorAPI ──→ Plugin (register(host) + vtable)
```

- **`sdk/src/`** — the entire contract. `Host` (registries + service locator), `Plugin` (identity + vtable of hooks Fizzy calls), `Surface` (the one drawable contribution: keywords say where it may go, the app's regions accept it), `RegionSpec` (a plugin declaring a place of its own inside the one it was given), `DocHandle` (opaque `{ptr, id, owner}` — Fizzy routes every doc op to `owner`, never inspects `ptr`), `EditorAPI` (Fizzy's own read/util surface plugins reach back through), `keywords.zig` (how a region accepts a surface), `dylib.zig`/`dvui_context.zig` (runtime-library C-ABI + dvui injection).
- **`app/`** — the framework an application switches on, never in a dylib: `App` (the host runtime state — host, documents, settings, keymap, layout state, watchers; fizzy's `Editor` embeds one as `editor.app`), `layout` (Layout/Region/State, the picker, view drags, split trees), `settings`, `keymap`, `Recents`, `store`, `update`, `watch`, `window`, `single_instance`. The module root is `app/root.zig`. Everywhere it needed to name fizzy is a `{ctx, vtable}` seam the app fills in.
- **`src/editor/`** — Fizzy itself: `Editor.zig` (frame loop, plugin registration/loading), `layout.zig` (fizzy's shape), `Menu.zig`, `Sidebar.zig`, `Settings.zig`, etc.
- **`core/`** — the shared floor used by Fizzy *and* plugins: `widgets` (Split, DockingWidget, Tabs, Tree, Canvas, BlurBackdrop), `anim`, `dialogs`, `draw`, `icon`, `image`, math, fs, paths, platform detection. Not plugin-owned; don't move it. (`Atlas`/`Sprite` are there only because pixi still loads its packed UI atlas through them — see the note in `core/core.zig`.) `core.fuzzy` is the one matcher behind every filter box in the app (settings tree, file tree, plugin store, LSP completions) — wrap zf through it rather than matching by hand, and remember **lower scores are better**. Draw icons with `core.icon.icon`, not `dvui.icon` — same arguments, cached as a texture.
- **`plugins/`** — bundled built-in plugins. Each is file-for-file the **same shape a third-party plugin would use**: root `plugin.zig` + identity-only `plugin.zig.zon` + `build.zig` + `build.zig.zon` (optional `src/**`), plus fizzy-internal glue in `static/`. No author `root.zig` or `<name>.zig` hub — the build helper generates the dylib entry; files use named imports (`fizzy_sdk`/`dvui`/…). Builds standalone with `cd plugins/<name> && zig build`.

**Two link modes, one source:** built-in plugins compile **static** (linked directly, all targets incl. web) or **dynamic** (`.dylib`/`.so`/`.dll`, desktop-only, `dlopen`'d — this is how third-party plugins ship too). `FIZZY_STATIC_<NAME>=1` env var forces static for a given built-in (useful when debugging dylib loading).

## Currently bundled plugins (check `ls plugins/` — this list moves)

- **`workbench`** — file tree and the document panes (each pane is a region the plugin declares; each open document is a surface the app registers); owns no documents. Exposes a `files` service other plugins use to open/close/manage files without importing workbench.
- **`text`** — generic text/code editor; fallback owner for any file extension nothing else claims.
- **`image`** — read-only PNG/JPG/GIF/BMP/TGA viewer with zoom/pan (fallback when pixi is not installed).
- **`markdown`** — `.md` preview utility plugin.
- **`archive`** — opens a `.zip` as a mounted folder (the web's "open a vault" path, too).
- **`drive`** — Google Drive as a mount; OAuth in the browser and on the desktop.
- `shared` — build helpers used across plugins' `static/integration.zig` (not a plugin itself).

**Pixi (pixel-art editor) lives outside this repo** as a third-party-style plugin ([`fizzyedit/pixi`](https://github.com/fizzyedit/pixi), `~/dev/fizzyedit/pixi`) — it ships and updates purely through the plugin store (`docs/PLUGINS.md` §6), with no special treatment in Fizzy itself. **Trust `ls plugins/` and `jj log` over any doc's plugin list.**

## Writing a plugin

1. Copy `plugins/text/` as your template (or `plugins/image/` for a document-owning viewer).
2. Add identity-only `plugin.zig.zon` (`id`/`name`/`version`/`min_sdk_version`). Implement root `plugin.zig`: `Plugin` + `register(host)` + vtable; call `host.register{Surface,Menu,Command,Service,…}` as needed. A surface's keywords (`sdk.keywords`) say where it may go; the app's regions accept it, and the user can move it with the picker.
3. Plugin prefs: `sdk.settings.Schema(struct { … })` then `.register(host, &plugin, …)` — Fizzy draws them only while the plugin is loaded. User config on disk is ZON (`settings.zon` / `recents.zon`).
4. Editor plugins implement the document vtable cluster; a plugin that lays out documents itself declares its panes with `host.region(spec)` and draws the accepted surfaces where it wants them.
5. User-invoked actions are **`Command`s** — `"<active_owner_id>.<action>"`.
6. `zig build install` drops `{id}/{id}.dylib` (its own directory) into the fizzy plugins dir (no sidecar `.zon`).
7. Memory: `host.allocator` vs `host.arena()`; never touch `dvui.currentWindow().gpa` directly.
8. ABI: structural fingerprint at `dlopen` (`fizzy_plugin_abi_fingerprint`). The SDK is at 0.2.0, unreleased: the fingerprint may move freely under it (update `recorded_sdk_shape_fingerprint`), the version does not until it ships.

Full contract: **[`docs/PLUGINS.md`](docs/PLUGINS.md)**. Living reshape plan: **[`docs/PLUGIN_MANIFEST_PLAN.md`](docs/PLUGIN_MANIFEST_PLAN.md)**.

## Bundling plugins into an app

Which plugins an executable links in is build data: `build/sdk.zig`'s `bundledPluginsModule`
generates `bundled_plugins` (`pub const modules = .{ @import("workbench"), … }`) and the
runtime iterates it — nothing in `app/` or `src/` names a plugin except the workbench (its
state still lives on the Editor). An app built on fizzy adds its own with `defer-app` +
`fizzy.buildApp(fizzy_dep, &.{ .{ .name, .module = dep.module("plugin") } })`; see
`examples/README.md` and `examples/minimal-app`, which bundles `examples/hello-plugin`.

## Plugin store: built, not forward-looking

The plugin registry/install flow (author repo → release CI → `fizzyedit/plugins` registry →
in-app store) is fully built and is the canonical publishing path for every third-party
plugin, `pixi` included. It's documented end-to-end in `docs/PLUGINS.md` §6; the registry
repo itself is [`fizzyedit/plugins`](https://github.com/fizzyedit/plugins) and the reusable
release CI is [`fizzyedit/plugin-build-action`](https://github.com/fizzyedit/plugin-build-action).
Don't trust older narrative docs that call this forward-looking/not-yet-built.

## Shipped shapes, meant to be copied (dvui's methodology)

Fizzy follows dvui's approach to widgets, one level up: it ships a handful of **layout shapes**
(fizzy's own in `src/editor/layout.zig`; `examples/{minimal,studio,endless}-app/src/layout.zig`) rather than a configurable layout engine. An app
either picks one as-is and writes no layout code at all, or **copies** the closest one into its
own source and edits it.

That constrains how these are written, and the constraint is the point:

- A shape is ordinary code over the public `Layout` API — a couple of dozen lines. Nothing in it
  may be privileged or reach into fizzy internals a copier could not reach, or copying becomes
  forking.
- Prefer adding a *new shape* over adding an option to an existing one. A mode flag is declared
  policy; a second file the user can read end to end is not.
- Anything a shape needs that only fizzy can provide is a bug in `Layout`, not a reason for a
  special case. A plugin that needs something from the shape asks the framework (a region by
  its keywords, `host.region`), never a widget the shape happened to create.

## Where things live

```
core/      the shared floor both an app and a plugin dylib draw with — widgets (Split,
           DockingWidget, Tabs, Tree, Canvas), anim, dialogs, draw, icon, image, fs, paths,
           math, fuzzy, lsp
sdk/       the plugin contract: `sdk/src/**` is the SDK itself, the files beside it are its
           build surface (this directory ships standalone as `fizzy-sdk-v*.tar.gz`)
app/       the framework an application switches on — layout, store, update, watch, window,
           single_instance; never compiled into a dylib
plugins/   the bundled plugins, in the exact shape a third-party plugin has
examples/  apps built on fizzy (minimal, studio, endless), each owning its own layout shape
src/       fizzy the application — `Entry`, `editor/`, `backend/`
build/     the app build API
```

A plugin reaches for `core/` and `sdk/`; an app additionally for `app/`; `src/` is fizzy's own
source and nothing outside fizzy should need to look in it.

## File naming: a file is a struct

Zig files *are* structs, so the repo follows that literally and you should too:

- **`CapitalName.zig` IS the struct.** Fields are declared at the top level of the file, with
  `const Self = @This();`, and consumers write `const Surface = @import("Surface.zig");` — not a
  file containing `pub const Surface = struct { ... }`, which nests the type one level deeper for
  no reason. Existing examples: `Host.zig`, `Plugin.zig`, `DocHandle.zig`, `Surface.zig`,
  `RegionSpec.zig`.
- **`lowercase.zig` is a namespace** of related declarations with no single type at its centre:
  `keywords.zig`, `paths.zig`, `document.zig`, `fingerprint.zig`.

### Case-renaming an existing file is a CI trap

macOS and Windows filesystems are case-insensitive; Linux CI is not. Renaming a *tracked* file
from `surface.zig` to `Surface.zig` looks like a no-op to git locally, so the rename is never
staged — and then CI fails to resolve `@import("Surface.zig")` on a case-sensitive filesystem.
Use `git mv -f old.zig tmp && git mv -f tmp New.zig` (two steps) when changing only case, and
check `git status --porcelain` actually shows the rename before committing.

The same case-insensitivity will silently destroy work: `rm sdk/src/surface.zig` deletes
`sdk/src/Surface.zig`, and *writing* `app/App.zig` overwrites `app/app.zig`. Watch for it when
converting a file to the capitalized form, and never keep two names differing only by case in
one directory — that is why the `app` module root is `app/root.zig`, not `app/app.zig`.

## Build

```sh
zig build              # native exe
zig build check-web    # wasm
zig build test         # unit/integration tests
zig build test-sdk-version  # CI lock: ABI fingerprint bump must bump sdk_version too
```

Run all of these after touching the SDK boundary (`sdk/src/**`) or a plugin's vtable usage.

### Keep the plugin build free of app-only dependencies

Plugins depend on the **`sdk/` package** (its own `build.zig` + `build.zig.zon`), not the repo root. The root zon owns the editor build and may list app-only deps (Velopack, nightwatch, …). A root-zon `.lazy = true` URL dep is **not** enough by itself: Zig eagerly unpacks lazy URL deps that already sit in the global cache into every consumer's `zig-pkg`, so after any app build a plugin depending on the root package would grow a Velopack tree even though `lazyDependency` never runs on the plugin path.

Pattern:

- **Plugins** (built-in + third-party): `.fizzy = .{ .path = ".../sdk" }` locally, or the `fizzy-sdk-v*` **release asset** URL from the matching `sdk-v*` tag (not the git archive — that is the monorepo root zon with Velopack). Call `fizzy.plugin.create` / `.install` as before; `b.dependency("fizzy", .{ .plugin_sdk = true })` still works (the option is accepted and ignored — `sdk/` always exports modules). Packing: `scripts/pack-sdk.sh` / `.github/workflows/sdk-tag.yml`.
- **App**: repo-root `zig build` as usual. The app **consumes `sdk/` as a dependency** (`.fizzy_sdk = .{ .path = "sdk/" }`), so build scripts reach `plugin`/`core_module`/`sdk_version` through `@import("fizzy_sdk")` and never by relative path into `sdk/` — a file may belong to only one module, so a path import claims it for the root build module and breaks the dependency outright. The same applies in reverse: nothing under `src/` may relative-import an `sdk/` file. Velopack stays `.lazy = true` in the root zon; never `@import("velopack_zig")` — the helper surface is vendored in `build/velopack.zig` and resolved only in `build/app.zig` via `lazyDependency`.
- **dvui is pinned in exactly one place — `sdk/build.zig.zon` — and is deliberately absent from the root zon.** The app borrows it via `build/sdk.zig`'s `dvuiDependency` (which forwards backend/target/optimize normally), and build scripts get dvui's build API from `@import("fizzy_sdk").dvui`. Do **not** "fix" the missing root dep by re-adding `.dvui`: two pins that drift make `recorded_sdk_shape_fingerprint` unsatisfiable by *both* the app and plugin-SDK builds at once, and the resulting error tells you to bump `sdk_version`, which cannot help. Bump or swap to a local checkout in `sdk/build.zig.zon` only.
- Shared `core` import wiring lives in `sdk/core_module.zig` and is called from the app build *and* `sdk/plugin_sdk.zig`'s `exportModules` so the import set can't drift. Note the `with_tui = false` on the zf dependency: without it, zf's standalone terminal binary drags `libvaxis` into every plugin build.

Acceptance test after any build-graph change:

```sh
cd plugins/image && rm -rf .zig-cache zig-out zig-pkg && zig build -Doptimize=ReleaseFast
ls zig-pkg | grep -i velo   # must be empty
```

CI builds plugins for all 6 host targets by cross-compiling with `-Dtarget=` (see `fizzyedit/plugin-build-action`); pure-Zig + vendored-C plugins don't need per-arch runners.

## When you need more than this file

- **Resuming the library/framework work (bookmark `fizzy-lib`)** → [`docs/LIB_CHECKPOINT.md`](docs/LIB_CHECKPOINT.md):
  ground rules, what is done, the verification workflow, and the agreed next steps.

- Full plugin contract + lifecycle/hook tables → `docs/PLUGINS.md`
- Living reshape plan (identity `plugin.zig.zon`, comptime `settings.Schema`, ZON user config, no sidecars) → [`docs/PLUGIN_MANIFEST_PLAN.md`](docs/PLUGIN_MANIFEST_PLAN.md)
