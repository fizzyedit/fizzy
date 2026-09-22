# fizzy-lib checkpoint

Resume point for the "fizzy as a library" work. Written to be picked up cold by any agent or
person. **Read `CLAUDE.md` first**, then this file. Last updated 2026-09-22 at bookmark
`fizzy-lib` (SDK at 0.2.0, unreleased).

Since the 2026-09-16 pass below, the bookmark has also gained: plugins loading at runtime in the
browser as wasm side modules (`app/store/PluginLoader_web.zig`, `web/index.html`'s `loadPlugin`)
with the store installing, updating, enabling and uninstalling them there; `core.work` (a stepped
task run on a thread natively and from the frame on the web) and `core.fs` (one seam for the
small config files, localStorage in a browser) — so `settings.zon`, `recents.zon`, `keybinds.zon`
and `layout.zon` all persist on both; the account flyout and `core.widgets.Popover`; `archive`
and `drive` beside the four bundled plugins named below; and `-Dapp-layout=<file>.zon`, a static
shape as data (`app/layout/Shape.zig`). `docs/REVIEW_NAYSAYER_2026-09-22.md` is the standing
review of that work — its open items are the ones its "Suggested order" still lists.

## Ground rules that are easy to get wrong

- This repo is **jj**, not git. `jj new` *before* starting a change, `jj describe` when done,
  never `git commit`. For messages with backticks use `jj describe --stdin < file` — `-m` lets
  zsh execute them. Work on bookmark `fizzy-lib`; move it with `jj bookmark set fizzy-lib -r @-`
  after describing. Do not touch `main`, graphl, or dvui.
- Another agent session may commit in the same working copy. Check `jj log` before assuming a
  change is yours; describe only what a change actually contains.
- **The SDK is 0.2.0 and unreleased.** The ABI fingerprint may move freely under it: update
  `recorded_sdk_shape_fingerprint` in `sdk/src/version.zig` from the compile error, leave the
  version alone. The first release of 0.2.0 is the first release of the library-shaped SDK;
  pixi, brain, ghostty and zig are rebuilt against it (not migrated) — see the queue below.
- No single-line wrapper functions; write the library call at the site. Prefer root-cause fixes
  over another patch to the same mechanism; use dvui's public API over touching its state.
- **Tag a dvui commit before pinning it.** `sdk/build.zig.zon`'s pin resolves through
  `/archive/<sha>.tar.gz`, which GitHub serves only while the commit is reachable, so every
  pinned commit carries an immutable `fizzy-sdk-<version>` tag in the fork (`fizzy-sdk-0.2.0`
  is the first). Rebase `fizzy-dev` as freely as ever; never move or delete those tags.
- Gates after any change: `zig build`, `zig build test`, `zig build test-integration`,
  `zig build check-web`, `zig build test-sdk-version`. All green at this checkpoint.
- Draw icons with `core.icon.icon` (cached texture), never `dvui.icon` (a mesh replayed every
  frame). Profile with `sample` on a sandbox instance (see the perf memory notes) before
  optimising anything; the frame is measured, not guessed.
- A Zig `error` **does not survive the dylib boundary with its name** (errors are integers
  numbered per compilation). Never `@errorName` an error returned from a plugin vtable; the
  plugin logs the reason on its side. **Settled 2026-09-22:** this is the contract, written
  into `Plugin.VTable`'s doc comment and `docs/PLUGINS.md`, and the host's five offending log
  lines now say "see the plugin's own log" instead of printing another compilation's error
  name. A shared status *enum* would let a reason travel, but that means converting ~250
  `anyerror` sites across six repos and editing every plugin's source, for the ability to
  distinguish failures nothing currently distinguishes — not worth it, in 0.2.0 or later. If a
  reason must travel, send it as data.

## Shape of the repo now (the part that is done)

```
core/      shared floor: compiled into the app AND every plugin. Widgets (Split, Tabs, Tree,
           Canvas), anim, dialogs, draw, image (incl. GIF Animation), fs, paths, math, fuzzy.
           May never depend on app.
sdk/       the plugin contract, crosses dlopen, fingerprinted. `sdk.core` re-exports core so a
           plugin names one dependency. Host has versioned, multi-provider services
           (`registerService(T, impl, owner)`, `servicesNamed`, `getServiceTyped` refuses on
           `service_version` mismatch). `Surface` is the only drawable contribution.
app/       framework an application switches on; never in a dylib. `AppInfo`, `layout`
           {Layout, Region, State}, `watch` {FolderWatcher, SettingsWatcher, wake}, `update`,
           `window`, `single_instance`, `store` {Store, Manager, Loader, registry}. Every
           place it needed to name fizzy is a `{ctx, vtable}` seam the app fills in
           (PluginManager, FolderWatcher.Sink, singleton.Sink, auto_update.Hooks, DialogDirs…).
plugins/   bundled plugins in third-party shape (workbench, text, image, markdown, shared).
src/       fizzy the application: Entry, editor/ (Editor, layout.zig, panel/,
           explorer/, LayoutSettings), backend/. Examples own their layouts.
build/     app build API (`wireAppModule`, `buildOptsModule` in build/sdk.zig). A consumer is an
           independent package: `b.dependency("fizzy", .{ .@"app-name", .@"app-layout", … })`
           and `fizzy.artifact(name)` — `examples/*` are exactly that and build standalone.
```

Layout vocabulary: `Layout` is per-frame (`.init(host, state, gpa, arena)`), `State` persists
(regions registry double-buffered: `regions` = last completed shape, `regions_building`;
`publishRegions()` after the shape). `Layout.region(...)` returns a `Region` (a box: scope it,
`defer r.deinit()`); `Layout.split(...)` a `Split` (end before the next pane). Every region with
keywords registers, resizable or not. A surface draws where a region **accepts** its keywords
(`sdk.keywords.accepts`, asymmetric; a region nested in another qualifies its keywords with the
enclosing region's name — see arc (a) below).

## Verification workflow (what actually works on this machine)

Run a throwaway instance beside the user's:
```sh
SB=<scratch dir>; mkdir -p /tmp/fzsb          # TMPDIR must be short: unix socket path limit
HOME=$SB/home TMPDIR=/tmp/fzsb ./zig-out/arm64-macos/fizzy <folder> <files...> &
```
Capture its window by pid with a Swift `CGWindowListCopyWindowInfo` script + `screencapture -x -l
<wid>`. Fails (black/none) when the display is locked — fall back to headless integration tests.
Kill by pid, not `%1`. A second launch hands argv to the first (singleton) and exits.

## Landed: region-centric surface placement

- Model: `State.assignments` (region name → surface ids), persisted in `layout.zon` as
  `SavedRegion {name, extent?, surfaces?}`; keyword matching is the default, an assignment
  overrides wholesale; `Layout.matching` answers from it, `unplaced()` reads the registry.
- `app/layout/Picker.zig`: the surface picker, on `State` (`openPicker(name, anchor)`), drawn
  once per frame by the app after the shape (`layout.captureUnplaced(); state.picker.draw(&layout)`).
  Cards carry **snapshots**: a placed surface is photographed where it draws on the next
  frame (`Layout.draw` → `drawCaptured`, through `dvui.Picture` — a bare render-target switch
  misses dvui's deferred draw queues); an unplaced one is drawn offscreen for 10 warm-up
  frames, then photographed (first-frame layout is unsettled and reveals start hidden).
  `Layout.drawn` decides "drew nowhere". Snapshots are discarded on close/reopen.
- `Region.init` draws a corner button (hover near top-right) that opens the picker for that
  region — framework, every app gets it.
- Settings > Layout > Regions is a table by region that opens the same picker.

Remaining from this arc: none. The endless-handles example landed (see below).

Known gaps: sidebar surfaces still read fizzy's `explorer.scroll_info` through `EditorAPI`
(`explorerViewportWidth`), so an offscreen photograph of one is taken against the live
sidebar's width; fine today, and one more reason to peel that API. The picker's popup is
`dvui.popup`, which centres when unanchored and clamps to the window otherwise.

## Next arc after placement: plugins declare regions, documents are surfaces (agreed 2026-09-11)

Workbench's private subdivision of Main (workspaces, tab groups, tab drag/drop) and the app's
regions are the same idea at two depths. Unify them:

- A tab group *is* a region accepting `document`; its tabs are `matching(region)`, the active
  tab is the region's existing selection. Opening a file = registering a surface
  (`<plugin>.doc:<path>`) and assigning it to the active document region; moving a tab =
  reassigning; a split = a new region; the same doc in two groups = duplication; session
  restore = the assignment list.
- Cost: the region registry moves from `app/layout/State` into `Host` beside surfaces so a
  plugin can declare one across the dylib boundary (vtable on Host: declare region, read/set
  extent — an ABI fingerprint bump, fine while unpublished); surfaces become dynamic
  (register/unregister per open file); workbench's Workspace/tab-group code is replaced by
  regions + assignments — the big rewrite and the one that pays.
- Order: (a) keyword semantics; (b) registry → Host, plugin-declarable; (c) workbench tab
  groups → regions, documents → surfaces. **ABI breakage is agreed** (2026-09-11): nothing
  ships until all three land and the out-of-tree plugins are rebuilt, so (b) need not contort
  itself to keep the fingerprint.

### (a) Keyword semantics — **done** (`sdk/src/keywords.zig`, `app/layout/`)

Keywords no longer just *attract*; a region **accepts** a surface, asymmetrically, and a keyword
may name a place inside another (`main.document`). `keywords.Fit` orders the relation:

| Fit | Region | Surface | Meaning |
|---|---|---|---|
| `exact` | `main.document` | `main.document` | the same word |
| `kind` | `main.document` | `document` | the shape says where the plugin's kind lives — the ordinary sub-region case |
| `place` | `main` | `main.document` | the sub-place does not exist here, so the enclosing region takes it — a plugin written for a nested shape works in a flat one |
| `none` | `main` | `document` | unrelated. Segment boundaries only: `mainly` is not inside `main` |

- `accepts(region, surface)` / `strength(region, surface)` replace `intersects` everywhere the
  question is "does this surface belong here" (`Layout.matching`/`unplaced`, `Surface.matches`,
  `Host.selectedSurface`). `intersects` survives for *vocabulary lookup* — `State.regionFor`,
  where a command holds `ide.sidebar` and wants whichever region speaks it.
- **Nesting qualifies automatically.** `Layout.Container.prefix` carries the enclosing region's
  first keyword (not all its synonyms — `accepts` reaches the sub-place by kind anyway), and
  `Region.init` runs the child's keywords through `State.qualify`. A container region with no
  keywords of its own is not a place: it passes its parent's prefix through, which is why
  fizzy's own shape (`work`/`content` are bare boxes) is unchanged.
  `qualify` **interns** — the registry is read a frame later than it is written, so arena
  strings would dangle; it also leaves an already-qualified word alone (no `main.main.document`).
- **The more specific region claims the surface** (`Layout.claimedElsewhere`), so a document pane
  inside Main takes what Main would otherwise also draw behind it. Only a *strictly* stronger
  claim wins: equal acceptance still means both regions show it (icon rail + sidebar), and a
  region with an explicit assignment does not claim at all. Ties are a visible ambiguity the
  picker can fix, which beats silently emptying the loser.
- Tests: `sdk/src/keywords.zig` (fit table, synonyms don't stack), `tests/integration.zig`
  ("a nested region qualifies its keywords, and keeps them across frames", "the more specific
  region claims a surface, an equal one shares it").

### (b) A plugin can declare a region — **done** (sdk 0.1.63, fingerprint `0x36440c0ce10a6c97`)

The registry stayed in `app/layout/State`; what moved is the *ability to declare*, as three
vtable calls, because a region is the app's — it registers in the app's registry, persists its
size and assignment under the app's name, and answers the app's picker.

- `sdk.RegionSpec` (name, unqualified keywords, `shows`, `dir`, `key`, `hide_when_empty`,
  `expand`, `min_extent`) + `EditorAPI.beginRegion`/`drawRegionContents`/`endRegion`.
  `Region.Shows` is now an alias of `RegionSpec.Shows` — one definition.
- Plugin-facing: `host.region(spec) ?Host.Region`, scoped like the box it is
  (`defer pane.deinit()`), with `pane.drawContents()` **where the plugin wants the accepted
  surfaces** — separate from `begin` because a tab strip has to be laid out before the document
  it labels. App-side that is `Region.InitOptions.manual_contents`, for a caller that cannot pass
  a `content` fn pointer taking a `*Layout` it does not have.
- `Layout.beginPluginRegion`/`drawPluginRegionContents`/`endPluginRegion` hold the open regions
  on a second stack (`plugin_regions`, LIFO, bounded by `max_nesting`, out-of-order close
  reported here rather than as a dvui stack mismatch two widgets later). The id is this
  function's `@src()` plus `spec.key`, which is why `key` must be stable and unique per caller
  per parent. `Editor.frame_layout` publishes the frame's `*Layout` for the duration of the
  shape and is cleared after the picker draws.
- Keywords are qualified on the way in, so a plugin **cannot name a place outside the one it was
  given**: `{"document"}` declared in Main becomes `main.document`. Collision is structural, not
  policed.
- Test: "a plugin declares a region inside the one it was given" — a real frame, a surface
  keyworded `document`, asserting the registry entry reads `main.document` and that the surface
  drew once, inside the pane rather than behind it in Main.

### (c) The workbench's panes are regions, its documents are surfaces — **done**

- **Documents are surfaces the app registers** (`Editor.insertOpenDoc` → `registerDocSurface`;
  `sdk.document.surfaceId` = `<owner>.doc:<path>`, keywords `{"document"}`, `Surface.document`
  carries the handle, `draw` = canvas box + `owner.drawDocument`). Taken back on close
  (`Host.unregisterSurface`). Document plugins are untouched.
- **A pane is a plugin-declared region** (`plugins/workbench/src/Workspace.zig`): `host.region`
  named `Pane <grouping>`, `shows = .many`, inside `core.widgets.Panes`. Tabs are
  `region.matching()`, the active tab is `region.selected()`, a reorder or cross-pane drag is
  `Host.assignSurfaces` on the panes involved, an empty pane leaves (`rebuildWorkspaces`).
  A document nobody holds is seated in the pane of the grouping the app stamped on it — the
  `grouping` hooks on the document vtable survive only as that hint.
- **By-name resolution** (`Region.by_name`, `Layout.matchingIn/selectedIn/selectIn`,
  `Host.selectionForKey`) because every pane accepts the same qualified keywords. App regions
  stay keyword-resolved for the icon rail.
- **Session restore is the assignment list**: first `rebuildWorkspaces` reads
  `Host.assignedRegionNames`, recreates each `Pane <n>`, reopens its paths. A path reopening
  under another owner replaces the stale id in place (`Workspace.removeTabsForPath`).
- **Takeover surfaces** (`Surface.takeover_when`, agreed with the user over keeping the hook):
  a surface exists only while the named surface is some region's selection, and then it *is*
  the selection of any region accepting it (`Layout.visibleNow`, `pick`). Trigger lookup
  excludes takeovers so it terminates. Store README: `takeover_when = store tab` + `hidden`
  while no card is selected. **pixi's packer must become**
  `{keywords = {"main"}, takeover_when = "pixi.project"}` when pixi is updated.
- `Workbench.activeDoc` is what the active pane showed last frame (`Workspace.active`);
  `setActiveDocIndex` selects by name (`Host.selectInRegion`). `EditorAPI` gained
  `regionMatching/regionSelected/regionSelect/assignSurfaces/assignedSurfaces/
  assignedRegionNames/selectInRegion`.
- sdk 0.1.65, fingerprint `0x14061b7c63fe0b38` (`Host.layout_ctx`). Tests: same-keyword plugin regions keep
  separate contents/selections; takeover appears only while triggered.
- **Verified by the user's screenshots** after landing: panes, tabs, open-to-the-side. Fixed
  from those screenshots (commits after `nllllosx`): `Surface.document` removed (a document
  is found from its surface id via `sdk.document.pathOfSurfaceId` + `host.docFromPath` — no
  editor concept on `Surface`); a split is drawn by the region *after* it
  (`Layout.drawPendingSplit`) so a `hide_when_empty` region leaves no orphan handle, and an
  emptied region stays in the registry so the picker can refill it; plugin region names are
  interned (`State.internName` — "Pane N" was a stack buffer read a frame later); `Panes.dragTo`
  resolved into a slice alias of this frame's widths (pane after the boundary ran under the
  next handle); only the active pane's tab wears active chrome.
- **Still to eyeball**: drag a tab between panes; drop on the right half of the last pane to
  split; close every tab in a pane (pane should leave); quit and relaunch (session restore
  from `layout.zon`); a pane emptied through its corner-button picker and refilled.
- Settled: `docByIndex` is *open* order, and says so — tab order belongs to whichever plugin
  lays documents out, and the host cannot answer in it.

## Landed: endless handles (`examples/endless-app`, `-Dapp-layout=`)

A shape whose layout is data, owned by the example — not a shipped fizzy preset.

- `examples/endless-app/src/layout.zig`: the middle is leftover space (`slot`, no default
  surface) and can be dragged to nothing. Each edge already has a collapsed region; dragging
  its split any amount opens it and a new collapsed region appears on the outer side. Edge
  regions accept `slot` and resolve `by_name` — they stay empty until the picker fills them.
- `Region.drawContents` uses `selectedIn` for by-name regions, so two trays with the same
  keywords do not draw the same assignment. `id_extra` includes the side, so a loop of
  splits from one `@src()` does not collide.
- There is no `max_trays`: the container tracks resizable ids in an arena list. The flex
  gap has no reserved floor.
- `zig build run` works from `examples/endless-app`. An empty region's corner button stays
  visible; a filled one still hides until the pointer is near.
- The tree is reconstructed from extent names (`edge-left-1`, …). No new on-disk format.
- `-Dapp-layout=` is a LazyPath. When set, Editor calls `app_layout.layout(ctx, *Layout)`
  (the file imports `dvui` / `app` / `core` / `fizzy_sdk` — not `Editor`). `ctx` is
  `context()` if exported, else `Host.layout_ctx`; fizzy passes `*Editor`. There is no
  `-Dlayout=` enum: fizzy uses `src/editor/layout.zig`; minimal, studio and endless
  each own `examples/*/src/layout.zig`.
- Empty edge trays dragged shut are forgotten (`forget_when_empty`); a tray with an
  assigned surface closes to the window edge and can reopen. Dragging past zero
  `push_out`s only the tray behind it, not the opposite side.
- `app/layout/Picker.zig`: a Store section lists catalog plugins that are not installed;
  choosing one queues an install and assigns that plugin's surfaces to the region once they
  load (`State.requestStoreInstall`). The store is a hook on `State` so the picker does not
  import `PluginStore` (that module graph is a cycle).
- Example: `examples/endless-app` (`endlessapp`). CI builds it beside the other two.
- Tests: names increment per side; the first frame declares a collapsed sentinel on each
  edge; dragging the left split opens `edge-left-1` during the drag and appends a collapsed
  `edge-left-2`; a full axis still has an outer sentinel.

## In progress: `Editor.zig` → `app/App.zig` (agreed 2026-09-16)

`src/editor/Editor.zig` (6100 lines, 250 functions) is almost entirely the host runtime an app
on fizzy needs unchanged: plugin lifecycle, file-type ownership, the document model and its
save/close flows, the `EditorAPI` adapters, settings persistence and reconcile, keybind
dispatch, region/surface bookkeeping, and the four seams `app/` already calls back through
(`SettingsWatcher.Sink`, `FolderWatcher.Sink`, `PluginManager`, `auto_update.Hooks`). What is
fizzy's own is small: `layout.zig` (the shape), `menu_model`/`Menu`, `fizzy_commands` in
`Keybinds`, `explorer/settings.zig`, themes and fonts, `Entry.zig`, and the chrome widgets.

Target: `app/App.zig` is the runtime, holding that state and owning `Host`; `Editor` is
fizzy's contributions, registered the way a plugin does (commands, settings groups, surfaces
for its chrome, the shape), holding a `*App`. `Entry.zig` stays fizzy's dvui entry and builds
both. Not a rename: files hold `app: *App`, and the framework module is `@import("app")`.

Done: `app.settings` (Settings, migration, ZON surgery, row chrome, plugin pane),
`app.Recents`, `app.keymap` moved as-is — they had no fizzy coupling. `app/App.zig` exists and
holds the runtime *state* (43 fields: allocators, config folders, `host`, `file_table`,
plugin lists and pending flags, extension ownership, keymap state, settings, recents,
folder, open documents, save/close/quit bookkeeping, watchers, `layout`); `Editor` embeds it
as `app` and every reader says `editor.app.x`. Fifty methods that touch only that state are
`App`'s now (plugin id/lib bookkeeping, `.plugins.<id>` readers, extension ownership,
failure records, settings reconcile, the flat-layout migration, document lookups). Every
method still on `Editor` reaches something fizzy-only — the next step is seams, not moves:
`/tmp/movable.py`-style analysis (a fn is movable iff its body touches only `app` fields and
`App` methods and none of the fizzy imports) now returns only vtable adapters.

What blocks a wholesale move is that `Editor.zig` imports what `app/` cannot see; each is a
seam to add, then the section moves. Inventory (from grepping the file):
- **Bundled plugins** — *the list is build data now*: `build/sdk.zig`'s
  `bundledPluginsModule` generates a `bundled_plugins` module (`pub const modules = .{
  @import("workbench"), … }`) that the runtime iterates for registration, the bundled-id
  check, each built-in's manifest, the dylib-or-static load (`App.bundledDylibEnabled`,
  `App.loadBundledDylib`) and per-frame hooks. Nothing in the runtime names a plugin except
  the workbench (agreed 2026-09-16: an app should be able to embed whatever plugins it lists
  in its `build.zig.zon`). **Done:** `fizzy.plugin.create` exports the plugin's source as the
  `"plugin"` module; a consumer passes `defer-app` to `b.dependency("fizzy")` and calls
  `fizzy.buildApp(fizzy_dep, app_plugins)` (`build/app.zig` is split into `readConfig` +
  `construct` so the deferred build still consumes its options); `build/exe.zig` copies each
  app plugin's module per executable (the packaged exe has its own framework modules).
  `examples/hello-plugin` + `examples/minimal-app` are the acceptance test and CI builds them.
  **Left:** the `workbench: Workbench` field, `Workspace`, `FileLoadJob`, `view_files` — the
  app must not hold a plugin's state, and the workbench's own state has to live behind its
  services and `Host` (the "static/dylib duplicate globals" note in memory is the same
  problem).
- **fizzy's contributions** referenced directly: `Keybinds.register/registerCommands/tick/
  buildKeymap`, `menu_model.menu_bar`, `Menu.drawModelMenu`, `Sidebar.drawOption`,
  `SettingsTree.draw`, `OutputPanel.draw`, `Explorer.settings`, `Dialogs.*`. Each becomes an
  `App.Hooks` member or a registration the application performs in its own init.
- **Assets and platform**: fonts (`assets`), `objc`, `fizzy.backend`, `fizzy.entry()`,
  `Constants`. Fonts and window constants belong on `AppInfo`; backend calls behind a seam
  like the existing `DialogDirs`.
- `DocumentWatcher`, `FilesService`, `file_glyphs`: framework, move with the sections that
  use them (`DocumentWatcher` needs no seam once documents live on `App`).

Order that keeps every change green: (1) `App` struct in `app/App.zig` holding `gpa`,
`arena`, `config_folder`, `host`, `file_table`, `layout`, settings/recents/keymap state,
watchers — `Editor` embeds it and its methods move over one `// ----` section at a time,
callers rewritten `editor.x` → `editor.app.x`; (2) the bundled-plugin and contribution
hooks; (3) documents and save/close flows; (4) `EditorAPI` adapters last, at which point
`Editor` is the thin layer and `Entry` constructs `App{ .info, .hooks }`.

## Also queued (in rough priority)

- **Update pixi/atlas/ghostty/zig to SDK 0.2.0** so the store, placement and services can be
  tested end to end (touches four repos; do as its own pass). pixi's packer becomes
  `{keywords = {"main"}, takeover_when = "pixi.project"}`; its `dvui.icon` calls become
  `core.icon.icon`; `Atlas`/`Sprite` move from `core` into pixi with it.
- **Settings and keybinds as app opt-ins**: the machinery is in `app/` now; the state and the
  dispatch move with the App extraction above, and fizzy registers its own sections/bindings
  the way a plugin does.
- **Native menu as a runtime app-supplied model**: `src/backend/backend_native.zig` still builds
  the menu from a comptime `menu_model` with `fizzy.editor()` refs. Then backend chrome → `app/`.
- Titlebar as configuration (height, menu, traffic lights, caption buttons).
- `Editor` → `App` rename (~460 refs; do not touch `EditorAPI`).
- Keep peeling `EditorAPI` into services (`showSaveDialog`, `drawFileKindGlyph`, `revealPosition`).
- Layered regions (`.blur_behind`) — design in `app/layout/LAYERS.md`; `BlurBackdrop` and
  frosted floating windows exist, the region property does not.
- `DocumentWatcher` stays in src until a document-reload seam exists.

## Recently landed (for orientation, newest first)

- Cleanup pass: dead SDK members (`swapDocs`, `splitState`) and unreferenced functions gone,
  Editor pass-throughs written at their call sites, stale docs (`FINDINGS`, `REVIEW`, `PHASE4`,
  `PHASE5`, `PACKAGES`) deleted, `CLAUDE.md`/`PLUGINS.md` describe the tree as it is.
- Perf: `FrameTarget` no longer serializes CPU behind GPU (window clear off, copy-blend blit);
  frost pyramid persistent and half-res, re-read every frame; `core.icon`; palette, output log
  and settings tree bounded by what is visible.
- Picker cards drag out as a loose `ViewDrag`; frosted floating windows and dialogs
  (`BlurBackdrop.frostPane`); the workbench pane row is a `DockingWidget` split tree.
- Endless-handles example: collapsed edge splits, by-name surfaces, `zig build run`.
- Loading card sizes from content; image checkerboard survives zoom-out.
- Animated GIF plays in the image viewer (`core.image.Animation`, dvui timer per frame).
- `.gif/.bmp/.tga` claimed by `image`; `text` opens unknown and binary files as plain text
  (NULs / bad UTF-8 become U+FFFD);
  a failed load no longer deinits an unwritten document buffer; user gets a toast.
- Every region registers (Main was missing from the placement pane).
- Region assignments + Regions settings table.
- Native dialogs ask the app for start dirs; AppInfo + backend allocator in `app/`; self-update,
  window geometry, singleton, watchers, store all in `app/`; `files` is a service.
