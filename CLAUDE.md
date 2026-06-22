# Fizzy

Cross-platform, open-source general editor written in Zig, UI via [DVUI](https://github.com/david-vanderson/dvui). Targets native (macOS/Linux/Windows) and web (wasm32). Layout/UX is IDE-shaped (VSCode-like): sidebar rail + explorer, menubar, center tabs/splits, bottom panel, infobar.

**Read this file first, then go deeper via the links below — don't re-derive the architecture from scratch.**

## The core idea: shell + plugins

Fizzy the app is a near-empty **shell** (window, frame loop, menu/sidebar/panel layout, document model) that owns **no editing features**. Everything the user sees — pixel-art editing, the file explorer/tabs/splits, text editing — is contributed by **plugins** that register against a stable SDK. Plugins never import each other; they meet only at the SDK.

```
Shell (Editor)  ←── Host registries + EditorAPI ──→  Plugin (register(host) + vtable)
```

- **`src/sdk/`** — the entire contract. `Host` (registries + service locator), `Plugin` (identity + vtable of hooks the shell calls), `DocHandle` (opaque `{ptr, id, owner}` — shell routes every doc op to `owner`, never inspects `ptr`), `EditorAPI` (shell read/util surface plugins reach back through), `regions.zig` (sidebar/bottom/center/menu/settings/command contribution structs), `dylib.zig`/`dvui_context.zig` (runtime-library C-ABI + dvui injection).
- **`src/editor/`** — the shell itself: `Editor.zig` (frame loop, plugin registration/loading), `PluginLoader.zig` (dlopen), `Menu.zig`, `Sidebar.zig`, `Settings.zig`, etc.
- **`src/core/`** — shared infra (Atlas/Sprite, math, gfx, fs, paths, platform detection) used by shell *and* plugins. Not plugin-owned; don't move it.
- **`src/plugins/`** — bundled built-in plugins. Each is file-for-file the **same shape a third-party plugin would use**: `build.zig`, `build.zig.zon`, `root.zig` (dylib entry, copy-only), `src/plugin.zig` (the one file you actually implement: `register(host)` + `Plugin.VTable`), plus fizzy-internal glue isolated in a `static/` subfolder + a root `<name>.zig` hub. Builds standalone with `cd src/plugins/<name> && zig build`.

**Two link modes, one source:** built-in plugins compile **static** (linked directly, all targets incl. web) or **dynamic** (`.dylib`/`.so`/`.dll`, desktop-only, `dlopen`'d — this is how third-party plugins ship too). `FIZZY_STATIC_<NAME>=1` env var forces static for a given built-in (useful when debugging dylib loading).

## Currently bundled plugins (check `ls src/plugins/` — this list moves)

- **`workbench`** — file tree, tabs/splits, center provider; owns no documents. Exposes a `workbench-api` service other plugins use to open/close/manage files without importing workbench.
- **`text`** — generic text/code editor; fallback owner for any file extension nothing else claims. (Recently renamed from `code`.)
- **`image`** — read-only PNG/JPG/JPEG viewer with zoom/pan (fallback when pixi is not installed).
- **`markdown`** — `.md` preview utility plugin.
- `shared` — build helpers used across plugins' `static/integration.zig` (not a plugin itself).

**Pixi (pixel-art editor) has been extracted out of this repo** into an external, third-party-style plugin ([`fizzyedit/pixi`](https://github.com/fizzyedit/pixi), `~/dev/fizzyedit/pixi`) — it ships and updates purely through the plugin store (`docs/PLUGINS.md` §6), with no special treatment in the shell. Older docs/handoffs (`HANDOFF.md`) still describe pixi as in-tree — that's historical, not current. **Trust `ls src/plugins/` and `git log` over any doc's plugin list.**

## Writing a plugin

1. Copy `src/plugins/text/` as your template (or `src/plugins/image/` for a document-owning viewer).
2. Implement `src/plugin.zig`: a `Plugin` value (id, display_name, vtable), `register(host)` (wires state, calls `host.registerPlugin` + any `host.register{SidebarView,BottomView,CenterProvider,Menu,SettingsSection,Command,Service}`), and a `VTable` with only the hooks you need.
3. Editor plugins (open/save/draw files) implement the document vtable cluster: `fileTypePriority`, `loadDocument`, `drawDocument`, `saveDocument`, `isDirty`, undo/redo, etc. Shell plugins (workbench-style) skip all of that and register a center provider + sidebar views instead.
4. User-invoked actions (copy/paste/transform/delete, plugin-specific features) are **`Command`s**, not vtable hooks — registered by id, dispatched by the shell via `host.runCommand("<id>")` without knowing what they do. Editing verbs follow the convention `"<active_owner_id>.<action>"`.
5. `zig build install` builds for the current OS and drops the plugin straight into the fizzy plugins dir (`~/Library/Application Support/fizzy/plugins/` on macOS) — no manual copying, just relaunch.
6. Memory: `host.allocator` (persistent, you own frees) vs `host.arena()` (per-frame scratch, never hold past the frame). Never touch `dvui.currentWindow().gpa` directly.
7. There's no ABI version negotiation — a structural **fingerprint** over every boundary type is computed at compile time on both sides; any mismatch is a hard reject at load (`fizzy_plugin_abi_fingerprint`). Fingerprint bumps are meant to be rare/deliberate (pinned dvui + zig version).

Full contract — from an empty `zig init`-style folder through the SDK, ABI/versioning, and publishing to the in-app store — progressively in one doc: **[`docs/PLUGINS.md`](docs/PLUGINS.md)**.

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
zig build            # native exe
zig build check-web  # wasm
zig build test       # unit/integration tests
zig build test-sdk-version   # CI lock: ABI fingerprint bump must bump sdk_version too
```

Run all of these after touching the SDK boundary (`src/sdk/**`) or a plugin's vtable usage.

### Keep the plugin build free of app-only dependencies

Every plugin build (including third-party ones like pixi) compiles this repo's root `build.zig` via `b.dependency("fizzy", .{ .plugin_sdk = true })`. Because `@import` is **comptime + transitive**, anything the root `build()` can reach at comptime is pulled into *every* plugin build — even code guarded by a runtime `if (plugin_sdk) return;`. So an app-only dependency reached through a plain top-level `@import("<dep>")` (like Velopack, the host's self-installer/updater) leaks its whole graph — wrapper + prebuilt archives — into plugin builds that never use it.

Rule: **app-only deps must never be reachable via comptime `@import` from the root build graph.** The pattern (see Velopack):

- Mark the dep `.lazy = true` in `build.zig.zon`.
- Never `@import("velopack_zig")` anywhere in the build graph. The helper surface is **vendored** in `build/velopack.zig` (pure `std.Build` glue) and takes the dependency as a handle.
- Resolve it lazily *inside the app build only*: `const vz = b.lazyDependency("velopack_zig", .{}) orelse return;` in `build/app.zig`, then thread `vz` through `build/exe.zig` / `build/package.zig`.

Acceptance test after any build-graph change: cross-build the image plugin and confirm no leak —

```sh
cd src/plugins/image && rm -rf .zig-cache zig-out zig-pkg && zig build -Doptimize=ReleaseFast
ls zig-pkg | grep -i velo   # must be empty
```

CI builds plugins for all 6 host targets by cross-compiling with `-Dtarget=` (see `fizzyedit/plugin-build-action`); pure-Zig + vendored-C plugins don't need per-arch runners.

## When you need more than this file

- Full plugin contract + lifecycle/hook tables → `docs/PLUGINS.md`
