# Plugin Author Rough Edges

A punch list of friction points a third-party author hits when building a *complex*
editor plugin (a second real editor alongside pixelart). Ordered by pain, with file
references and fix sketches. Cheap correctness fixes (#4, #6, #7) are being done first;
the rest are tracked as backlog.

Status legend: 🔴 not started · 🟡 in progress · 🟢 done

---

## 1. 🟢 The "stable contract" is pixel-art-shaped — *large* — DONE

The intermediate `canvas_ext` (a relocated grab-bag that still *named* pixelart concepts) was
replaced with two clean mechanisms, so the SDK names zero domain features:

1. **Command registry** ([`regions.Command`](../src/sdk/regions.zig) + `Host.registerCommand` /
   `runCommand` / `commandEnabled`). Invocable features register as namespaced commands the shell
   triggers by id (`"pixelart.transform"`, `"pixelart.gridLayout"`, `"pixelart.packProject"`)
   without knowing what they do. Folded into the ABI fingerprint.
2. **Generic per-frame / lifecycle / save protocol** on `Plugin.VTable`, renamed from the
   pixelart-flavored hooks: `prepareFrame`, `tickActiveDocument`, `drawOverlay`, `endFrame`,
   `needsContinuousRepaint`, `persistProjectState`/`restoreProjectState`, and
   `saveNeedsConfirmation`/`requestSaveConfirmation` (mode enum `SaveConfirmMode`).

Pixelart's pack lifecycle (`tickPackJobs`/`runPackWorkers`) folded into its own `beginFrame`
(the plugin self-drives background work); its pack-status check reads its own state instead of
round-tripping through the host. Dead pack plumbing removed from `EditorAPI`/`Host`/`Editor`.
`EditorAPI.requestCompositeWarmup` → `requestPrepareFrame` to match the new phase name.
`Plugin.CanvasEditorExt` deleted. Verified: native build, `test`, `test-plugin-loader`, `check-web`
all green; a grep of `src/sdk/` shows no residual domain vocabulary on the typed surface.

Follow-up pass (hook honesty + docs): audited each renamed hook against its real call site —
9/10 are genuinely generic across editor types; `prepareFrame` is borderline and is now
documented as an opt-in `[requested]` pre-draw pass (only fires after `host.requestPrepareFrame`).
Found & fixed a real generality bug: `tickKeybinds` was invoked only on `pixelartPlugin(editor)`,
so a second plugin's per-frame keybinds would never fire — now broadcast to all plugins. Added a
**required-vs-optional** map (the document cluster you must implement to be an editor) and a
`[broadcast]`/`[active-doc]`/`[requested]` invocation tag + call-site/timing table to
[`Plugin.zig`](../src/sdk/Plugin.zig) and [`PLUGINS.md`](PLUGINS.md). This also closes the
original "no map of which of N hooks to implement" complaint.

Active-doc owner dispatch + verbs-as-commands (done): a design review concluded the editing
actions (`copy`/`paste`/`transform`/`acceptEdit`/`cancelEdit`/`deleteSelection`) are *not*
universal — they're user-invoked and mean different things per editor — so they were **removed
from `Plugin.VTable` and registered as `Command`s** (`"pixelart.copy"`, …). The shell's Edit
menu / keybinds and *Grid Layout* dispatch to `"<active_owner_id>.<action>"` via
`Editor.runActiveDocCommand`, so every editing action routes to whichever editor owns the focused
tab; an owner that registered none is a clean no-op. The `EditorAPI` verb reach-backs are
unchanged (they funnel through `editor.<verb>()`, now per-owner command dispatch).

Folder lifecycle rename (done): the pixelart-flavored `persistProjectState`/`restoreProjectState`
became the shell-event-named `onFolderClose` / `onFolderOpen` (the shell has a *folder* concept;
"project" was pixelart's layer on top).

**Still open (smaller follow-ups):**
- **New File chooser** — with multiple `requestNewDocumentDialog` providers, present a typed "New > \<kind\>" chooser (rough-edge #9 / existing `Plugin.zig` TODO). Single-provider dispatch via `Host.requestNewDocument` is done.

**Resolved in SDK hardening pass:**
- ~~**New File is single-owner**~~ — `Editor.requestNewFileDialog` dispatches via `Host.requestNewDocument`.
- ~~**`initPlugin` not broadcast**~~ — `postInit` calls `initPlugin` on every registered plugin.
- ~~**Menu enablement by owner**~~ — Edit menu gates on `commandEnabled` for active-doc owner commands.
- ~~**No comptime editor profile check**~~ — `Plugin.assertEditorVTable` / `assertUtilityVTable` + templates.

---

### Original note

[`Plugin.VTable`](../src/sdk/Plugin.zig) is ~60 optional hooks; a large fraction are
pixel-art concepts presented as the neutral SDK: `transform`, `copy`, `paste`,
`startPackProject`, `isPackingActive`, `tickPackJobs`, `runPackWorkers`,
`persistProjectFolder`, `reloadProjectFolder`, `requestGridLayoutDialog`,
`requestFlatRasterSaveWarning`, `shouldConfirmFlatRasterSave`,
`warmupActiveDocumentComposites`, `resetDocumentPeekLayers`, `removeCanvasPane`,
`radialMenu*`, `tickActiveDocumentPlayback`. [`EditorAPI`](../src/sdk/EditorAPI.zig) does
the same (`transform`, `startPackProject`, `isPackingActive`, `requestCompositeWarmup`).

Every hook is `?`-optional, so the compiler gives zero guidance — a missing hook surfaces
at runtime as a feature silently doing nothing. There is no delineated "minimal editor
plugin" subset.

**Fix sketch:** split the vtable into a core *editor protocol* (the ~8 hooks every editor
needs) and an optional *pixelart extension* surface; or at minimum document the required
subset and add a comptime check that flags an editor plugin missing a core hook.

## 2. 🔴 Document-load staging protocol is intricate and thread-unsafe-by-comment — *medium*

Opening one file requires a correctly-ordered cluster of cooperating hooks whose contract
lives only in field comments: `documentStackSize`/`documentStackAlign` → shell allocates a
raw buffer → `loadDocument(path, out_doc)` constructs in place into shell-owned memory **on
a worker thread** → `documentIdFromBuffer` → `registerOpenDocument` to move to a stable
pointer → plus a separate `loadDocumentFromBytes` for web. Wrong size/align or touching
dvui/globals from the worker thread is UB with no compile-time protection.

**Fix sketch:** provide an SDK helper that owns the happy path (size/align from the doc
type via comptime), and lift the threading rule out of a field comment into a documented
contract / debug assertion.

## 3. 🔴 ABI compatibility is all-or-nothing, opaque, pins to an exact commit — *large*

The structural fingerprint ([`dylib.zig`](../src/sdk/dylib.zig)) rejects every third-party
plugin on *any* dvui bump / boundary-struct tweak / new vtable hook, with a bare
`error.AbiMismatch`. No version range, no skew tolerance, no tool telling the author what
changed or which fizzy build their `.dylib` matches. A plugin is dead the instant the user
updates fizzy.

**Fix sketch:** keep the fingerprint as the hard gate but layer a human-readable
(fizzy-version, dvui-version) tuple alongside it so diagnostics can say *why* and *what to
rebuild against*; consider a documented "compatible host build" stamp.

## 4. 🟢 Failure is invisible to the user — *cheap* — DONE

Implemented: `Editor.loadUserPlugins` now records each failure into `editor.failed_user_plugins`
(`{id, reason}`, owned strings, freed in `unloadPluginLibs`), logs at `.err` with an
actionable reason (`pluginLoadFailureReason` maps each `LoadError` — e.g. AbiMismatch →
"rebuild against this Fizzy build"), and a one-shot startup dialog
(`dialogs/PluginLoadFailures.zig`) lists them so the author isn't left reading logs.

---

### Original note

[`Editor.loadUserPlugins`](../src/editor/Editor.zig) logs `dvui.log.warn` and silently
skips on every failure (open failed, ABI mismatch, register rejected, OOM). A user whose
plugin doesn't load sees nothing in the UI. ABI mismatch — the most common case — surfaces
only as a log line.

**Fix sketch:** record `{plugin_id, path, error}` for each failed load on the Editor/Host,
and surface it (settings panel section and/or a startup notice). At minimum keep a
queryable list so the UI can show "N plugins failed to load."

## 5. 🔴 No hot-reload / unload — brutal dev loop — *large*

[`PluginLoader.loadAndRegister`](../src/editor/PluginLoader.zig) keeps the DynLib open for
the app lifetime; `registerPlugin` only appends; `deinit` is never called mid-session. Plugin
development means quit + relaunch (and reopen project/files) on every change.

**Fix sketch:** an unregister path (drop registry entries owned by a plugin id, call
`deinit`, close the lib) + a dev "reload plugin" affordance. Non-trivial because open
documents may be owned by the plugin being unloaded.

## 6. 🟢 `set_globals` slot overload is a latent footgun — *cheap* — DONE

Implemented: the two post-`gpa` slots are renamed `arg_b`/`arg_c` across `sdk.dylib.SetGlobalsFn`,
`PluginLoader.PreRegister`, and all `Editor.zig` call sites (matching the existing
`syncLoadedPluginGlobals` vocabulary), each with a doc comment + inline comment stating the
per-plugin convention (third-party: `arg_b` = `*Host`). No more field literally named `.state`
carrying the host.

---

### Original note

The C entry `set_globals(gpa, state, packer)` has three positional `*anyopaque` slots whose
meaning differs per plugin. Third-party [`exportEntry`](../src/sdk/dylib.zig) reads them as
`(gpa, host, state-ignored)`, so [`Editor.zig`](../src/editor/Editor.zig) smuggles `&host`
through the field named `.state` and `.packer` is dead. Built-ins use the slots differently
again. Works only by convention; it's a raw pointer reinterpret.

**Fix sketch:** rename `PreRegister`/`SetGlobalsFn`/`installRuntime`/`exportEntry` params to
a single clear contract — `gpa`, `host`, `plugin_state` — and update all call sites. Naming
only; no behavior change.

## 7. 🟢 Plugin identity vs folder name conflated; no dedup — *cheap* — DONE

Implemented: `Host.registerPlugin` now rejects a duplicate declared `id` with
`error.DuplicatePluginId` (built-ins register first, so they always win). The dylib loader
turns that into a failed load surfaced via #4, and the declared `id` — not the folder name —
is the source of truth for routing.

---

### Original note

[`Editor.loadUserPlugins`](../src/editor/Editor.zig) derives `plugin_id` from the directory
name and keys its collision guard on `pluginById(entry.name)`, but plugins register under
their own declared `plugin.id`, and [`registerPlugin`](../src/sdk/Host.zig) does no dedup. A
plugin in folder `foo` declaring `id = "pixelart"` passes the folder guard then
double-registers `"pixelart"`; routing (`pluginById`/`pluginForExtension`) becomes
ambiguous.

**Fix sketch:** make `registerPlugin` reject a duplicate id (return an error the loader
treats as a failed load — feeds #4), and treat the declared id as the source of truth.

## 8. 🔴 Service discovery is stringly-typed and unversioned — *medium*

[`Host.getService(name) -> ?*anyopaque`](../src/sdk/Host.zig) then
`@ptrCast(@alignCast(...))`. The author must know the magic string and the exact cast type,
with nothing binding the two, and the service struct's layout is not in the ABI fingerprint —
so a shape change silently corrupts. Only workbench's service is documented.

**Fix sketch:** a typed service helper (`getService(T)` keyed on `T.service_name`) and fold
registered service struct layouts into the fingerprint, or attach a per-service version.

## 9. 🔴 Smaller items — *cheap-ish, batched*

- **`core.gpa` global** — docs say "sync `core.gpa = sdk.allocator()` if you use core
  helpers," but `core` is a first-class import a complex plugin will use; forgetting is UB
  with no reminder. Consider asserting/initializing it at load.
- **"New File" is single-owner** — existing TODO in [`Plugin.zig`](../src/sdk/Plugin.zig):
  `requestNewDocumentDialog` dispatches to "a plugin that provides one"; a second editor
  collides. Needs a typed "New > \<kind\>" chooser.
- **Install ergonomics / no manifest** — `zig build install --prefix <platform config
  dir>/plugins/<id>/` is hand-assembled; no `fizzy install-plugin`, no manifest declaring
  name/version/author/min-fizzy-version. Identity comes from the folder the user drops it in.
- **dvui globals across the boundary** — context is re-injected each frame
  ([`syncLoadedPluginDvuiContexts`](../src/editor/Editor.zig)); a plugin caching
  `currentWindow()`, a font, or an ft2 handle across frames is in undocumented territory.

## 10. 🟢 Built-in plugins didn't look like third-party plugins — *medium* — DONE

A built-in's folder used to carry files a third-party plugin never has (an embed-stub
`build.zig` + a separate `build_standalone.zig`, `module.zig`, `dylib.zig`, `Globals.zig`)
and its `build/integration.zig` ran from two roots via dual-path (`repo_paths`/`pkg_paths`)
machinery — so "what files does a plugin need?" had two different answers.

Now every plugin folder — the built-ins (pixi/workbench/code), the new in-repo `example`
template, and external plugins like markdown — is the **same canonical third-party shape**
(`build.zig` via `fizzy.plugin.create`, `build.zig.zon`, `root.zig` → `src/plugin.zig`,
`src/…`) and builds standalone with `cd src/plugins/<name> && zig build`. The only
fizzy-internal extras are a root `<name>.zig` (the conventional package module + import hub,
forced to the root by Zig's module-import boundary) and a self-contained `static/` subfolder
(`static/integration.zig`) holding the static-embed + bundled-dylib build graph; the embed stub,
`build_standalone.zig`, `module.zig`, `src/hub.zig`, `dylib.zig`, `Globals.zig`, and the
dual-root path machinery are all gone. Vendored C deps use the reusable `fizzy.plugin.addCModule`
helper. The [`example`](../src/plugins/example/) plugin is the always-compiling copy-me
template. See [PLUGINS.md](PLUGINS.md) §2.

**Caveat (monorepo only):** building a built-in that vendors C deps shared with fizzy's own
build graph (pixi's `build/deps.zig`) standalone from *inside* the repo would put one file in
two build modules, so pixi's `build.zig` inlines its vendored-dep wiring. A genuine
third-party plugin in its own repo has no such overlap.
