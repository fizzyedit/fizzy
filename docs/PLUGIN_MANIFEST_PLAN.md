# Plugin Manifest — Living Plan (Revised)

> **Status:** core complete (revision 2026-07-20). External plugin repos still need pin + reshape.
> R7 (`sdk-v*` tag namespace) planned, not yet landed.
> **Owner:** Fizzy core (this repo). External plugin re-releases are coordinated after the SDK lands.
> **Agents:** update this file as you land work — flip status, amend decisions, log blockers.
> **Related:** [`CLAUDE.md`](../CLAUDE.md), [`PLUGINS.md`](PLUGINS.md), SDK at `src/sdk/`.

---

## How to use this document

1. Read **Locked decisions** before coding.
2. Work phases in order (R1→R6); do not start mid-phase without its prerequisites.
3. When a phase lands, flip its status and note what changed.
4. Keep `docs/PLUGINS.md` / `CLAUDE.md` updates in R6 (or earlier if docs would otherwise lie).

| Phase | Status | Notes |
|-------|--------|-------|
| R1 — Rewrite living plan | done | 2026-07-20 — this document |
| R2 — Identity-only zon + no sidecars | done | 2026-07-20 — built-in `plugin.zig.zon`s slimmed to identity; `Manifest`/`readManifest` identity-only; `Host` enforcement (`checkContribution`/`checkCapability`/`pending_manifest`/`plugin_manifests`/`manifest_violation`/`bindManifest`/`manifestFor`/`takeManifestViolation`) removed; `install()`/`installBuiltinPlugin` no longer emit an on-disk `.zon` sidecar. sdk 0.33.0 (fingerprint moved — see version.zig's changelog — because removing `Host` struct fields, unlike 0.32.0 adding data-pointer-valued ones, does change the shape hash). |
| R3 — Shell config JSON → ZON | done | 2026-07-20 — `Recents.zig`/`Settings.zig` load/save via `std.zon.parse`/`std.zon.stringify` against `recents.zon`/`settings.zon`; one-shot `RecentsMigration.zig`/`SettingsMigration.zig` (json→zon, delete json, isolate all remaining `std.json` usage on these paths); `Settings.loaded: ?Disk` replaces `parsed: ?std.json.Parsed(Settings)`; `Editor.zig` paths + `settings_last_saved` renamed; `Host.storePluginSettings`/`loadPluginSettings` docs + `Plugin.VTable.settingsChanged` param already spoke of zon blobs (no signature/fingerprint change — `[]const u8` throughout); text plugin `Settings.zig` already zon-based. Fix: `Settings.Disk` (17 fields) blew the default 1000-branch eval quota in `std.zon.parse`'s generic `parseStruct`/`parseExprInner` instantiation — added `@setEvalBranchQuota(10_000)` to `Settings.load`/`loadPluginStore`/`serialize`. Verified: `zig build`, `zig build test`, `zig build test-sdk-version` all clean after `rm -rf .zig-cache`. |
| R4 — Comptime settings API + embed + probe | done | 2026-07-20 — **loaded-only** + **shell-drawn UI**. `sdk.settings.make(T)` → `Field`/`Schema`/`Access`; plugins register `.title` + `.value` only (no `draw`). `PluginSettingsPane` renders shared controls. Disabled plugins: Enabled toggle only. `text` migrated (`tab_size` as enum for dropdown). sdk **0.35.0** (fingerprint `0x8f96eaa903ae417c`). Verified: `zig build`, `zig build test`, `zig build test-sdk-version`, `zig build check-web`. |
| R5 — Store + CI SoT | done | 2026-07-20 — PluginLoader probes embedded `fizzy_plugin_manifest_zon` for disabled-plugin name/version (fallback to C exports); PluginStore docs updated; plugin-build-action README/example describe `plugin.zig.zon` as CI SoT (tag == `.version`). Action still takes workflow inputs until a follow-up reads zon directly. |
| R6 — Docs + external migration | done | 2026-07-20 — PLUGINS.md §2/settings/CI + CLAUDE.md updated. External repos zig/json/ghostty/pixi reshaped locally against `../../fizzy` path pin (sdk 0.35); switch back to URL+hash when fizzy 0.35 lands on a publishable commit. |
| R7 — `sdk-v*` tag namespace | planned | 2026-07-20 — legible, auto-maintained pin point for the `fizzy` dependency in a plugin's `build.zig.zon`, replacing "pin an arbitrary commit SHA." See below. |
| R9 — Built-ins read identity from `plugin.zig.zon` | done | 2026-07-22 — every built-in's `plugin.zig` (`plugin_id`, `display_name`) now reads `pub const plugin_options = @import("fizzy_plugin_options")` (the build-injected identity module, see `src/plugins/shared/build/helpers.zig`'s `pluginOptions`) instead of duplicating the id/name as string literals also present in `plugin.zig.zon`. This module was previously wired only for the dylib link mode; `addStaticModule` (all 4 built-ins' `static/integration.zig`) now attaches it too, via `pluginOptionsFor` — a per-manifest-path memoization in `helpers.zig` so a plugin's static and dylib builds, which each call `addStaticModule`/`addDylib` independently in the same `zig build` graph, don't redundantly re-read the manifest. **Build-graph bug found + fixed** (both `helpers.zig` and `plugin_sdk.zig`, the third-party path): once `plugin.zig` actually references `@import("fizzy_plugin_options")` and that same file is compiled into more than one module rooted differently in the same graph, Zig refuses a second attachment of the identity options step to the generated dylib root ("file exists in modules 'fizzy_plugin_options' and 'fizzy_plugin_options0'") — regardless of naming or object sharing. Fixed in both `generatedDylibRoot`s by reaching identity through `plugin_impl`'s own `pub const plugin_options` export instead of importing the module a second time on the generated root. **This makes `pub const plugin_options = @import("fizzy_plugin_options");` a required declaration for every plugin using `fizzy.plugin.create`** (documented in `docs/PLUGINS.md` §2.5) — a deliberate SDK-contract change; `pixi`/`ghostty`/`zig`/`json` (`~/dev/fizzyedit/*`) were updated to add it (mechanical: `.id`/`.display_name` now read `plugin_options.id`/`.name` instead of hardcoded strings, matching the built-ins). **Separately found + fixed a real segfault**, surfaced only once these external plugins could load again for the first time against this session's earlier `Host` changes: `Host.loadPluginSettings` read the settings file directly using `dvui.io` — a `pub var` dvui global, freshly `undefined` in *each separately-compiled dylib* until the host syncs it (`dvui_context.zig`), which only happens around draw/tick, not before `register()`. Since `sdk.settings.make(T).load` calls `loadPluginSettings` from within `register()`, and that call executes using the *calling* dylib's own compiled copy of `Host.loadPluginSettings` (not the host's), any dynamically-loaded plugin reading its settings at register time dereferenced the still-undefined `dvui.io` and crashed — invisible until today because dynamically-loaded plugins had been rejected by an unrelated `AbiMismatch` (stale dylibs) up to this point, so `register()` had never actually run against the new `Host` shape for any of them. Fixed the same way this codebase already fixes this exact class of bug for `drawMenuItem`: added `EditorAPI.VTable.loadPluginSettingsFile` (implemented in `Editor.zig` as `shellLoadPluginSettingsFile`, which always executes as the host's own compiled code regardless of which dylib triggered the call) and had `Host.loadPluginSettings` forward to it instead of touching the file directly. `flushPluginSettings` was checked and confirmed safe as-is (only ever called from `Editor.zig`, never from a plugin's own code path, so it always already runs as the host). sdk **0.1.37** (fingerprint `0xbde63b4971975fd5` — `EditorAPI.VTable` gained a field). Verified: `zig build`, `zig build test`, `zig build test-sdk-version`, `zig build check-web` clean on a fully cleared `.zig-cache`; standalone builds of `text`/`image`/`workbench` (root `zig build` too) all clean; all 4 external plugins rebuilt clean against the new pin; a live run confirmed `pixi`/`ghostty`/`zig`/`json` all load successfully with no crash (previously segfaulted in `pixi`'s `register()`). **Known remaining gap, unrelated to any of the above:** the standalone `cd src/plugins/markdown && zig build` hits a distinct, pre-existing `root.@build`/`root.@dependencies` module-graph conflict — not investigated, not caused by this work. |
| R8 — Per-plugin settings files | done | 2026-07-22 — replaced the escaped-zon-text-in-a-list-in-settings.zon design with one real `<plugins_dir>/<id>.settings.zon` file per plugin (`{config}/plugins/{id}.settings.zon`, beside `{id}.{dylib,so,dll}`). `Host.loadPluginSettings` reads the file fresh (no cache — only ever called once, at `register()`); `storePluginSettings` buffers into `Host.plugin_settings_pending` and rides the existing debounced-autosave timer via `markSettingsDirty`; `Host.flushPluginSettings` (called from `Editor.saveSettingsGuarded`/`saveSettingsRaw`) writes the buffer out. `Host.plugins_dir` set once in `Editor.init`, null on wasm/headless (no-op settings load/store, matching "no filesystem" elsewhere). `Settings.zig`'s `Disk`/`Extend`/`PluginEntry` machinery is gone — `settings.zon` now serializes `Settings` directly, no per-plugin blobs at all. One-shot `SettingsMigration.splitEmbeddedPluginsIfNeeded` splits a pre-R8 settings.zon's embedded `plugins` list out to per-id files (skips an id whose file already exists, so it never clobbers a live edit); the legacy-JSON migration path writes straight to per-id files instead of embedding. sdk **0.1.36** (fingerprint `0x9fa106c6800c1fc2` — `Host` field shape changed). Verified: `zig build`, `zig build test`, `zig build test-sdk-version`, `zig build check-web`, standalone `src/plugins/text` build, and a live run confirming the split + `<id>.settings.zon` files land correctly. |
| Old Phase 2 (sidecar enforcement) | **cancelled** | superseded by this revision |

---

## What stays from work already landed (A–C)

- Root `plugin.zig` as module root; generated hidden dylib root; hub/`root.zig` removed
- Build helper reading root `plugin.zig.zon` at configure time into `fizzy_plugin_options`
- sdk **0.35.0** fingerprint (R2: identity-only `Manifest`, no `Host` enforcement guards, no on-disk `.zon` sidecar. R4: `Host.settings_schemas`/`registerSettingsSchema` + `sdk/settings.zig`'s `Schema`/`Field`/`Access` — shell-drawn settings UI; no settings probe export, per the loaded-only simplification below)

---

## Locked decisions

| Decision | Choice |
|----------|--------|
| Author-facing `plugin.zig.zon` | **Identity only**: `id`, `name`, `version`, `min_sdk_version`. No `hooks`, `contributes`, `settings`, or `profile` (removed — zero consumers, see decision log). |
| Capability SoT | `plugin.zig` (`register*` + vtable) — no declare-and-audit against a zon list |
| On-disk sidecar `{id}.zon` | **Gone** — author never manages one; install dir is dylib only |
| Settings authoring | Comptime Zig API (build-system style), not text schema |
| Disabled-plugin settings | **Loaded-only** — field controls only when the plugin is successfully loaded; disabled plugins get Enabled toggle only (no schema probe / no embedded settings zon) |
| On-disk user config | **ZON everywhere** for shell state — not JSON |
| Per-plugin settings storage (R8) | **One real file per plugin** (`{config}/plugins/{id}.settings.zon`), not a blob embedded in the shell's own `settings.zon` — no escaping, trivially hand-editable, and it's just a normal file sitting next to that plugin's own dylib |
| CI SoT | `plugin-build-action` reads `plugin.zig.zon` for id/version/min_sdk; tag must match `.version`; `minimum_zig_version` stays in `build.zig.zon` |
| Integrity / sandbox | Drop hard-reject-undeclared; keep ABI fingerprint + sdk version gates |
| `fizzy` dependency pin (external plugins) | **`sdk-v<sdk_version>` git tag**, not an arbitrary commit SHA. Kept in this repo (no separate SDK package/repo) — the tag is just a legible ref into the existing monorepo, auto-created by CI so it can never drift from `recorded_sdk_shape_fingerprint` |

### ZON on disk (drop JSON for app config)

| File | Role |
|------|------|
| `{config}/settings.zon` | Shell `Settings` fields only |
| `{config}/plugins/{id}.settings.zon` | That plugin's own settings (see R8) — a real, unescaped zon file sitting beside `{id}.{dylib,so,dll}`, not a blob embedded in `settings.zon` |
| `{config}/recents.zon` | Recent folders list |
| (existing) `window_frame.zon` | Unchanged |

- No `std.json` on these load/save paths after migration.
- Host plugin settings APIs speak zon (not JSON); `settingsChanged` blob is zon.
- One-shot migration from `*.json` → write ZON → delete JSON after successful migrate.

**Still JSON (out of scope):** store `manifest.json`, theme stubs `themes/*.json`, json language plugin.

---

## Settings: comptime API (landed R4)

```zig
const MySettings = sdk.settings.Schema(struct {
    insert_spaces_on_tab: bool = true,
    tab_size: u8 = 4,
    format_on_save: bool = false,
});
// register():
MySettings.load(host, plugin.id, &values);
try MySettings.register(host, &plugin, .{ .title = "Text Editor", .value = &values });
// Shell PluginSettingsPane draws shared controls — plugins do not supply `draw`.
```

`Schema(T)` comptime-walks `T`'s fields into a `Setting` table (name, label, a `Kind` union
tagged by `TypeTag` — bool/int/float/string/enum/color — carrying only the metadata that type
actually needs: `IntKind{min,max,choices}`, `FloatKind{min,max,step}`, `EnumKind{choices}`, void
for bool/string/color) and generates
`load`/`store`/`applyZon` (a zon round-trip on `T`) alongside `register`, which wires a
`SettingsSchema` + typed `Access` vtable into `Host.settings_schemas`. Plugins register metadata + a
living value only; the shell draws every control so settings share one appearance. The schema
exists in the Host's registry only while the owning plugin stays registered — no
`fizzy_plugin_settings_zon` export, no dylib probe, no on-disk sidecar.
`src/editor/PluginSettingsPane.zig` draws every registered schema plus an Enabled-toggle-only
row per disabled plugin and a reason per failed-to-load plugin.

---

## Explicitly cancelled (prior plan)

- Hard-reject undeclared `register*` / hooks against zon lists
- Author-written settings schema in `plugin.zig.zon`
- On-disk `{id}.zon` sidecar, self-heal, byte-compare tamper
- “Transparency manifest of every contribution”
- Keeping plugin settings blobs as JSON through a late phase
- Disabled-plugin schema via dylib probe / embedded settings zon (simplified away 2026-07-20)

---

## Phases

### R2 — Identity-only zon + no sidecars
Slim built-in `plugin.zig.zon`; slim Manifest/readManifest; remove sidecar install; keep identity injection.

### R3 — Shell config JSON → ZON
`Settings.zig` / `Recents.zig` / `Editor.zig` → `settings.zon` + `recents.zon`; Host holds zon; migrate from JSON.

### R4 — Comptime settings (loaded-only UI)
`src/sdk/settings.zig` (`make` + register); migrate text; settings pane shows fields only for loaded plugins (Enabled toggle for disabled).

### R5 — Store + CI SoT
PluginStore identity probes as needed; describe plugin-build-action reading `plugin.zig.zon`.

### R6 — Docs + external
PLUGINS.md / CLAUDE.md; zig/json/ghostty/pixi on new pin.

### R7 — `sdk-v*` tag namespace

**Problem.** §2.3's `zig fetch --save=fizzy https://github.com/fizzyedit/fizzy/archive/<commit>.tar.gz`
pins the whole fizzy repo by an opaque commit SHA. Nothing about the ref communicates which
`sdk_version` it corresponds to, and there's no tooling (bot or human skim) that can reason about
bumping it the way a tagged semver dependency can.

**What was considered and rejected.** Splitting `src/sdk/**` into its own repo/package so plugins
depend on something smaller than the whole monorepo — rejected: fizzy's `build.zig.zon` already
plays double duty as "full app" / "sdk-only" via the `plugin_sdk` build option
(`b.dependency("fizzy", .{ .plugin_sdk = true })`), so a second package would only trim fetch
size, at the cost of a second place to develop the SDK. Not worth it while nothing is straining
on fetch size or on the leak guard in `CLAUDE.md`'s "Keep the plugin build free of app-only
dependencies" (that guard is enforced by discipline — `lazy = true` + `b.lazyDependency` inside
`build/app.zig` — independent of how many repos the SDK lives in).

**Decision.** Keep the SDK inside this repo. Add a second tag namespace, distinct from the app's
`v*` release tags: **`sdk-v<sdk_version>`** (e.g. `sdk-v0.1.35`), pushed at the exact commit where
that `sdk_version` (and its matching `recorded_sdk_shape_fingerprint`) was recorded in
`src/sdk/version.zig`. `release.yml`'s trigger (`tags: - "v*"`) is a glob on the ref's start;
`sdk-v0.1.35` does not start with `v`, so it can never fire the app release/package pipeline —
the two tag namespaces are non-colliding by construction. Plugin authors (and
`docs/PLUGINS.md` §2.3's `zig fetch` instructions) pin against the tag instead of a commit SHA.

The tag is created automatically, not by an operator remembering to: `.github/workflows/
sdk-tag.yml` runs on push to `main`, parses `sdk_version` out of `src/sdk/version.zig`, and
pushes `sdk-v<version>` if that tag doesn't already exist. This mirrors how
`recorded_sdk_shape_fingerprint` itself is enforced mechanically (`zig build test-sdk-version`
fails at compile time on drift) rather than by review discipline — the tag now moves in lockstep
with the version bump instead of trailing it. No build/package/artifact step is needed for this
tag (unlike `v*`/`release.yml`); it's a plain ref push, no GitHub Release required.

**Renumbering alongside this (also R7):** `sdk_version` shifted from the old "bump minor on
every boundary change" scheme (0.5.0 → 0.35.0, patch always 0) to `patch` = ordinary
boundary-change counter, `minor` = manually-bumped compatibility epoch, `major` = reserved for
1.0 — see `src/sdk/version.zig`'s doc comment on `sdk_version` and its 0.1.35 changelog entry for
the full rationale. Done as a one-time renumbering (0.35.0 → 0.1.35, not on to 0.36.0) because it
was free: no `sdk-v*` tag existed yet and no in-repo `plugin.zig.zon` pins a non-empty
`min_sdk_version`. Will not repeat once a real tag or external pin exists.

---

## External migration checklist (zig / json / ghostty / pixi)

Local reshape done 2026-07-20 against sdk **0.35** (`.path = "../../fizzy"` until fizzy publishes the commit). Re-release when ready:

1. ~~Add identity-only `plugin.zig.zon`~~ done
2. ~~Move `src/plugin.zig` → root `plugin.zig`; delete `root.zig` + package-root hub~~ done (pixi keeps `src/pixi.zig` as an intra-plugin type hub, renamed from `src/mod.zig`)
3. ~~Drop `pub const manifest`; `fizzy.plugin.create(b, .{ .target, .optimize })` only~~ done
4. ~~Prefs → `sdk.settings.make` + zon blobs (pixi); shell-drawn UI~~ done
5. Rebuild / re-release: flip `build.zig.zon` fizzy pin back to URL+hash; `release.yml` is slim (`@v3`, no hand-copied sdk/fingerprint); tag == `plugin.zig.zon` `.version`

## Verification

1. `zig build` / `test` / `test-sdk-version` / `check-web`
2. `zig build install` → dylib only in plugins dir (no `.zon` sidecar)
3. Config dir: `settings.zon` + `recents.zon`
4. Disabled plugin: Enabled toggle only (no field controls)
5. Loaded plugin edit → zon persist + settingsChanged
6. CI: document `plugin.zig.zon` as SoT (action still takes workflow inputs until it reads zon)

---

## Decision log

| Date | Decision |
|------|----------|
| 2026-07-20 | Original capability-manifest + sidecar plan approved |
| 2026-07-20 | **Revised:** identity-only zon, no sidecars, comptime makeSettings, ZON user config |
| 2026-07-20 | Drop JSON for settings/recents/plugin blobs |
| 2026-07-20 | **Simplify:** settings UI loaded-only — drop dylib settings probe + embedded settings zon |
| 2026-07-20 | R4 landed: `sdk.settings.make(T)` + `Host.settings_schemas` + `PluginSettingsPane`; `text` migrated. sdk 0.34.0 |
| 2026-07-20 | **R7 planned:** replace commit-SHA fizzy pin with auto-created `sdk-v<sdk_version>` git tags; rejected splitting the SDK into a separate repo/package (fizzy's `plugin_sdk` build option already scopes the dependency; a second repo would only trim fetch size, not worth the added dev-location split) |
| 2026-07-20 | **R7:** one-time `sdk_version` renumbering 0.35.0 → 0.1.35 — patch now counts ordinary boundary changes (what minor used to do), minor reserved as a manually-bumped compatibility epoch. Safe only because no `sdk-v*` tag or external `min_sdk_version` pin existed yet; not to be repeated |
| 2026-07-20 | Removed `Manifest.profile` (`.editor`/`.utility`/`.other`) — zero consumers anywhere (no runtime read, no UI grouping, no comptime capability check; that's `Plugin.assertEditorVTable`/`assertUtilityVTable`, unrelated and unaffected). `Manifest` is off `sdk_boundary_types`, so no `sdk_version`/fingerprint bump needed. Dropped from every built-in and external `plugin.zig.zon` in the same pass |
