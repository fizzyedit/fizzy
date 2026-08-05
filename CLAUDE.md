# Fizzy

Cross-platform, open-source general editor written in Zig, UI via [DVUI](https://github.com/david-vanderson/dvui). Targets native (macOS/Linux/Windows) and web (wasm32). Layout/UX is IDE-shaped (VSCode-like): sidebar rail + explorer, menubar, center tabs/splits, bottom panel, infobar.

**Read this file first, then go deeper via the links below — don't re-derive the architecture from scratch.**

## The core idea: fizzy + plugins

Fizzy the app is itself a near-empty host (window, frame loop, menu/sidebar/panel layout, document model) that owns **no editing features**. Everything the user sees — pixel-art editing, the file explorer/tabs/splits, text editing — is contributed by **plugins** that register against a stable SDK. Plugins never import each other; they meet only at the SDK.

```
Fizzy (Editor) ←── Host registries + EditorAPI ──→ Plugin (register(host) + vtable)
```

- **`src/sdk/`** — the entire contract. `Host` (registries + service locator), `Plugin` (identity + vtable of hooks Fizzy calls), `DocHandle` (opaque `{ptr, id, owner}` — Fizzy routes every doc op to `owner`, never inspects `ptr`), `EditorAPI` (Fizzy's own read/util surface plugins reach back through), `regions.zig` (sidebar/bottom/center/menu/settings/command contribution structs), `dylib.zig`/`dvui_context.zig` (runtime-library C-ABI + dvui injection).
- **`src/editor/`** — Fizzy itself: `Editor.zig` (frame loop, plugin registration/loading), `PluginLoader.zig` (dlopen), `Menu.zig`, `Sidebar.zig`, `Settings.zig`, etc.
- **`src/core/`** — shared infra (Atlas/Sprite, math, gfx, fs, paths, platform detection) used by Fizzy *and* plugins. Not plugin-owned; don't move it. `core.fuzzy` is the one matcher behind every filter box in the app (settings tree, file tree, plugin store, LSP completions) — wrap zf through it rather than matching by hand, and remember **lower scores are better**.
- **`src/plugins/`** — bundled built-in plugins. Each is file-for-file the **same shape a third-party plugin would use**: root `plugin.zig` + identity-only `plugin.zig.zon` + `build.zig` + `build.zig.zon` (optional `src/**`), plus fizzy-internal glue in `static/`. No author `root.zig` or `<name>.zig` hub — the build helper generates the dylib entry; files use named imports (`fizzy_sdk`/`dvui`/…). Builds standalone with `cd src/plugins/<name> && zig build`.

**Two link modes, one source:** built-in plugins compile **static** (linked directly, all targets incl. web) or **dynamic** (`.dylib`/`.so`/`.dll`, desktop-only, `dlopen`'d — this is how third-party plugins ship too). `FIZZY_STATIC_<NAME>=1` env var forces static for a given built-in (useful when debugging dylib loading).

## Currently bundled plugins (check `ls src/plugins/` — this list moves)

- **`workbench`** — file tree, tabs/splits, center provider; owns no documents. Exposes a `workbench-api` service other plugins use to open/close/manage files without importing workbench.
- **`text`** — generic text/code editor; fallback owner for any file extension nothing else claims. (Recently renamed from `code`.)
- **`image`** — read-only PNG/JPG/JPEG viewer with zoom/pan (fallback when pixi is not installed).
- **`markdown`** — `.md` preview utility plugin.
- `shared` — build helpers used across plugins' `static/integration.zig` (not a plugin itself).

**Pixi (pixel-art editor) has been extracted out of this repo** into an external, third-party-style plugin ([`fizzyedit/pixi`](https://github.com/fizzyedit/pixi), `~/dev/fizzyedit/pixi`) — it ships and updates purely through the plugin store (`docs/PLUGINS.md` §6), with no special treatment in Fizzy itself. Older docs/handoffs (`HANDOFF.md`) still describe pixi as in-tree — that's historical, not current. **Trust `ls src/plugins/` and `git log` over any doc's plugin list.**

## Writing a plugin

1. Copy `src/plugins/text/` as your template (or `src/plugins/image/` for a document-owning viewer).
2. Add identity-only `plugin.zig.zon` (`id`/`name`/`version`/`min_sdk_version`). Implement root `plugin.zig`: `Plugin` + `register(host)` + vtable; call `host.register{SidebarView,BottomView,CenterProvider,Menu,Command,Service,…}` as needed.
3. Plugin prefs: `sdk.settings.Schema(struct { … })` then `.register(host, &plugin, …)` — Fizzy draws them only while the plugin is loaded (no SettingsSection). User config on disk is ZON (`settings.zon` / `recents.zon`).
4. Editor plugins implement the document vtable cluster; workbench-style plugins register a center provider + sidebar views instead.
5. User-invoked actions are **`Command`s** — `"<active_owner_id>.<action>"`.
6. `zig build install` drops `{id}/{id}.dylib` (its own directory) into the fizzy plugins dir (no sidecar `.zon`).
7. Memory: `host.allocator` vs `host.arena()`; never touch `dvui.currentWindow().gpa` directly.
8. ABI: structural fingerprint at `dlopen` (`fizzy_plugin_abi_fingerprint`); bumps are rare/deliberate.

Full contract: **[`docs/PLUGINS.md`](docs/PLUGINS.md)**. Living reshape plan: **[`docs/PLUGIN_MANIFEST_PLAN.md`](docs/PLUGIN_MANIFEST_PLAN.md)**.

## Plugin store: built, not forward-looking

The plugin registry/install flow (author repo → release CI → `fizzyedit/plugins` registry →
in-app store) is fully built and is the canonical publishing path for every third-party
plugin, `pixi` included. It's documented end-to-end in `docs/PLUGINS.md` §6; the registry
repo itself is [`fizzyedit/plugins`](https://github.com/fizzyedit/plugins) and the reusable
release CI is [`fizzyedit/plugin-build-action`](https://github.com/fizzyedit/plugin-build-action).
Don't trust older narrative docs that call this forward-looking/not-yet-built.

## Historical docs (not current — don't re-derive architecture from these)

- **`HANDOFF.md`** — historical Phase 4 handoff (compile-time modular separation, predates the
  pixi extraction and the `code`→`text` rename). Superseded by `docs/PLUGINS.md` for anything
  plugin-related; useful only for the older "how did we get here" narrative.

## Build

```sh
zig build              # native exe
zig build check-web    # wasm
zig build test         # unit/integration tests
zig build test-sdk-version  # CI lock: ABI fingerprint bump must bump sdk_version too
```

Run all of these after touching the SDK boundary (`src/sdk/**`) or a plugin's vtable usage.

### Keep the plugin build free of app-only dependencies

Plugins depend on the **`sdk/` package** (its own `build.zig` + `build.zig.zon`), not the repo root. The root zon owns the editor build and may list app-only deps (Velopack, nightwatch, …). A root-zon `.lazy = true` URL dep is **not** enough by itself: Zig eagerly unpacks lazy URL deps that already sit in the global cache into every consumer's `zig-pkg`, so after any app build a plugin depending on the root package would grow a Velopack tree even though `lazyDependency` never runs on the plugin path.

Pattern:

- **Plugins** (built-in + third-party): `.fizzy = .{ .path = ".../sdk" }` locally, or the `fizzy-sdk-v*` **release asset** URL from the matching `sdk-v*` tag (not the git archive — that is the monorepo root zon with Velopack). Call `fizzy.plugin.create` / `.install` as before; `b.dependency("fizzy", .{ .plugin_sdk = true })` still works (the option is accepted and ignored — `sdk/` always exports modules). Packing: `scripts/pack-sdk.sh` / `.github/workflows/sdk-tag.yml`.
- **App**: repo-root `zig build` as usual. The app **consumes `sdk/` as a dependency** (`.fizzy_sdk = .{ .path = "sdk/" }`), so build scripts reach `plugin`/`core_module`/`sdk_version` through `@import("fizzy_sdk")` and never by relative path into `sdk/` — a file may belong to only one module, so a path import claims it for the root build module and breaks the dependency outright. The same applies in reverse: nothing under `src/` may relative-import an `sdk/` file. Velopack stays `.lazy = true` in the root zon; never `@import("velopack_zig")` — the helper surface is vendored in `build/velopack.zig` and resolved only in `build/app.zig` via `lazyDependency`.
- **dvui is pinned in exactly one place — `sdk/build.zig.zon` — and is deliberately absent from the root zon.** The app borrows it via `build/sdk.zig`'s `dvuiDependency` (which forwards backend/target/optimize normally), and build scripts get dvui's build API from `@import("fizzy_sdk").dvui`. Do **not** "fix" the missing root dep by re-adding `.dvui`: two pins that drift make `recorded_sdk_shape_fingerprint` unsatisfiable by *both* the app and plugin-SDK builds at once, and the resulting error tells you to bump `sdk_version`, which cannot help. Bump or swap to a local checkout in `sdk/build.zig.zon` only.
- Shared `core` import wiring lives in `sdk/core_module.zig` and is called from the app build *and* `sdk/plugin_sdk.zig`'s `exportModules` so the import set can't drift. Note the `with_tui = false` on the zf dependency: without it, zf's standalone terminal binary drags `libvaxis` into every plugin build.

Acceptance test after any build-graph change:

```sh
cd src/plugins/image && rm -rf .zig-cache zig-out zig-pkg && zig build -Doptimize=ReleaseFast
ls zig-pkg | grep -i velo   # must be empty
```

CI builds plugins for all 6 host targets by cross-compiling with `-Dtarget=` (see `fizzyedit/plugin-build-action`); pure-Zig + vendored-C plugins don't need per-arch runners.

## When you need more than this file

- Full plugin contract + lifecycle/hook tables → `docs/PLUGINS.md`
- Living reshape plan (identity `plugin.zig.zon`, comptime `settings.Schema`, ZON user config, no sidecars) → [`docs/PLUGIN_MANIFEST_PLAN.md`](docs/PLUGIN_MANIFEST_PLAN.md)
