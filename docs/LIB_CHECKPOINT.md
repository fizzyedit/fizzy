# fizzy-lib checkpoint

Resume point for the "fizzy as a library" work. Written to be picked up cold by any agent or
person. **Read `CLAUDE.md` first**, then this file. Last updated 2026-09-11 at bookmark
`fizzy-lib` (jj change pending, endless example owns its layout; no max_trays).

## Ground rules that are easy to get wrong

- This repo is **jj**, not git. `jj new` *before* starting a change, `jj describe` when done,
  never `git commit`. For messages with backticks use `jj describe --stdin < file` — `-m` lets
  zsh execute them. Work on bookmark `fizzy-lib`; move it with `jj bookmark set fizzy-lib -r @-`
  after describing. Do not touch `main`, graphl, or dvui.
- Another agent session may commit in the same working copy. Check `jj log` before assuming a
  change is yours; describe only what a change actually contains.
- **Do not publish the SDK version bump / force a store-wide plugin rebuild** while this is
  experimental. The fingerprint has moved (sdk 0.1.63, `0x36440c0ce10a6c97`); pixi (4 calls),
  brain (1), ghostty (1) still use legacy `register*View` and need source edits + rebuild before
  any release. Breaking the ABI is agreed while unreleased — arc (b) below took it deliberately.
- No single-line wrapper functions; write the library call at the site. Prefer root-cause fixes
  over another patch to the same mechanism; use dvui's public API over touching its state.
- Gates after any change: `zig build`, `zig build test`, `zig build test-integration`,
  `zig build check-web`, `zig build test-sdk-version`. All green at this checkpoint.
- A Zig `error` **does not survive the dylib boundary with its name** (errors are integers
  numbered per compilation). Never `@errorName` an error returned from a plugin vtable; the
  plugin logs the reason on its side. A shared SDK error enum would fix this (ABI change,
  not started).

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
src/       fizzy the application: Entry, editor/ (Editor, presets ide/minimal/studio, panel/,
           explorer/, LayoutSettings), backend/.
build/     app build API (`wireAppModule`, `buildOptsModule` in build/sdk.zig).
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
  while no card is selected. `draw_workspace` and `WorkbenchPaneView` are deleted; **pixi's
  packer must become** `{keywords = {"main"}, takeover_when = "pixi.project"}` when pixi is
  updated.
- `Workbench.activeDoc` is what the active pane showed last frame (`Workspace.active`);
  `setActiveDocIndex` selects by name (`Host.selectInRegion`). `EditorAPI` gained
  `regionMatching/regionSelected/regionSelect/assignSurfaces/assignedSurfaces/
  assignedRegionNames/selectInRegion`.
- sdk 0.1.64, fingerprint `0xb65d3fe1e02bc4a2`. Tests: same-keyword plugin regions keep
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
- Known leftovers: `Workspace.center` / `clearAllWorkspaceCenter` (panel-animating centring)
  are vestigial; `swapDocs`/`docByIndex` order in `EditorAPI` no longer means tab order;
  "main rendered twice" reported once with an emptied panel, not reproduced — main draws once
  in the headless shape test; ask for the exact state if it recurs.

## Landed: endless handles (`examples/endless-app`, `-Dapp-layout=`)

A shape whose layout is data, owned by the example — not a shipped fizzy preset.

- `examples/endless-app/src/layout.zig`: blank Center plus a dormant `Split` on each window
  edge. Dragging a handle inward past 48pt and releasing appends `edge-{side}-{n}` to that
  edge (extent persisted in `layout.zon`); a new dormant handle stays on the outer side.
  Indices are never reused, so assignments stay keyed by name. Created regions accept `slot`
  and resolve `by_name` — nothing matches by keyword until the picker fills them.
- A handle that would leave Center smaller than 80pt does not exist. There is no `max_trays`:
  the container tracks resizable ids in an arena list, and the example refuses a new region
  when leftover space on that axis is below the commit threshold.
- The tree is reconstructed from extent names (`edge-left-1`, …). No new on-disk format.
- `-Dapp-layout=` is a LazyPath. When set, `presets.run` calls `app_layout.layout(*Layout)`
  (the file imports `dvui` / `app` / `core` only — not `Editor`). Fizzy's shipped shapes stay
  `ide | minimal | studio`.
- `app/layout/Picker.zig`: a Store section lists catalog plugins that are not installed;
  choosing one queues an install and assigns that plugin's surfaces to the region once they
  load (`State.requestStoreInstall`). The store is a hook on `State` so the picker does not
  import `PluginStore` (that module graph is a cycle).
- Example: `examples/endless-app` (`endlessapp`). CI builds it beside the other two.
- Tests: names increment per side; promoting is enough for the next frame to declare the
  region; dragging the left dormant handle past the threshold appends `edge-left-1`; a
  handle does not commit when Center would be left too small.

## Also queued (in rough priority)

- **Settings and keybinds as app opt-ins**: move the machinery (schema → ZON persistence →
  settings tree → watcher reconcile; keybind table → chord matching → command dispatch) from
  `src/editor/` to `app/`; fizzy registers its own sections/bindings the way a plugin does.
- **Native menu as a runtime app-supplied model**: `src/backend/backend_native.zig` still builds
  the menu from a comptime `menu_model` with `fizzy.editor()` refs. Then backend chrome → `app/`.
- Titlebar as configuration (height, menu, traffic lights, caption buttons).
- `Editor` → `App` rename (~460 refs; do not touch `EditorAPI`).
- Keep peeling `EditorAPI` into services (`showSaveDialog`, `drawFileKindGlyph`, `revealPosition`).
- Update pixi/brain/ghostty to the new SDK so the store, placement and services can be tested
  end to end (touches three repos; do as its own pass).
- `PanedWidget`/`core.widgets.paned` have zero callers → delete. `Atlas`/`Sprite` → pixi.
- `DocumentWatcher` stays in src until a document-reload seam exists.

## Recently landed (for orientation, newest first)

- Endless-handles example: dormant edge handles create persisted `edge-{side}-{n}` regions;
  picker Store section installs and assigns.
- Loading card sizes from content; image checkerboard survives zoom-out.
- Animated GIF plays in the image viewer (`core.image.Animation`, dvui timer per frame).
- `.gif/.bmp/.tga` claimed by `image`; `text` refuses binary (`textcore.encoding.looksBinary`);
  a failed load no longer deinits an unwritten document buffer; user gets a toast.
- Every region registers (Main was missing from the placement pane).
- Region assignments + Regions settings table (replaced the Phase 4b per-surface pane).
- Native dialogs ask the app for start dirs; AppInfo + backend allocator in `app/`; self-update,
  window geometry, singleton, watchers, store all in `app/`; `files` is a service.
