# fizzy-lib checkpoint

Resume point for the "fizzy as a library" work. Written to be picked up cold by any agent or
person. **Read `CLAUDE.md` first**, then this file. Last updated 2026-09-11 at bookmark
`fizzy-lib` (jj change `zkxnvzqm`, "The loading card fits its rows…").

## Ground rules that are easy to get wrong

- This repo is **jj**, not git. `jj new` *before* starting a change, `jj describe` when done,
  never `git commit`. For messages with backticks use `jj describe --stdin < file` — `-m` lets
  zsh execute them. Work on bookmark `fizzy-lib`; move it with `jj bookmark set fizzy-lib -r @-`
  after describing. Do not touch `main`, graphl, or dvui.
- Another agent session may commit in the same working copy. Check `jj log` before assuming a
  change is yours; describe only what a change actually contains.
- **Do not publish the SDK version bump / force a store-wide plugin rebuild** while this is
  experimental. The fingerprint has moved (sdk 0.1.62); pixi (4 calls), brain (1), ghostty (1)
  still use legacy `register*View` and need source edits + rebuild before any release.
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
keywords registers, resizable or not. Surfaces draw where their keywords intersect a region's.

## Verification workflow (what actually works on this machine)

Run a throwaway instance beside the user's:
```sh
SB=<scratch dir>; mkdir -p /tmp/fzsb          # TMPDIR must be short: unix socket path limit
HOME=$SB/home TMPDIR=/tmp/fzsb ./zig-out/arm64-macos/fizzy <folder> <files...> &
```
Capture its window by pid with a Swift `CGWindowListCopyWindowInfo` script + `screencapture -x -l
<wid>`. Fails (black/none) when the display is locked — fall back to headless integration tests.
Kill by pid, not `%1`. A second launch hands argv to the first (singleton) and exits.

## Next: region-centric surface placement (agreed 2026-09-11, not started)

Replaces the surface-centric "Panel placement" pane (`src/editor/LayoutSettings.zig`) and the
per-surface keyword override (`State.keyword_overrides`, `Editor.setSurfaceKeywords`,
`.plugins.<id>.surface_keywords`). The user's question is "what goes *here*", not "where does
this go"; inverting also gives duplication (one surface in two regions) and deliberately-empty
regions for free.

1. **Model** (`app/layout/State.zig`): `assignments: region name → []surface id`, persisted at
   `.layout.regions.<name>`. Keyword matching remains the *default* when a region has no
   assignment; an assignment overrides wholesale. Delete the keyword-override mechanism (one
   mechanism, not two). `Layout.matching(keywords)` consults assignments first. Drawing one
   surface in two regions works as-is: dvui ids differ by parent chain, plugin state is shared.
   Add integration tests beside the existing "keyword override moves surface" ones in
   `tests/integration.zig` (which will be rewritten to assignments).
2. **Picker widget**: scrollable cards, one per surface — a **snapshot** preview (render the
   surface once into a texture target when the menu opens; cache; never live-draw it in the
   card — widgets would run twice a frame and unplaced surfaces have no live pixels), title,
   owner plugin, checked if already in this region. Multi-select (a region shows tabs).
3. **Settings pane as a table**: rows = regions from the live registry (`editor.layout.regions`),
   each with its surfaces as chips and the picker behind a button. Replace `LayoutSettings.zig`
   in place; keep its registration in `src/editor/explorer/settings.zig` (group "Layout").
4. **Corner button** in `app/layout/Region.zig`: in `deinit`, if the mouse is near the region's
   top-right, draw a small floating button that opens the same picker for that region. Framework
   code — every app gets it.
5. **Endless-handles example app** (`examples/`, its own piece): blank window, dormant split
   handles at the four edges; dragging one out appends a region to a *persisted tree* and a new
   dormant handle appears. The tree names its regions (`edge-left-2`) so assignments stay keyed
   by name. The picker gains a section of store surfaces not yet installed; choosing installs
   and assigns. This is a shape whose layout is data — acceptable as one example file, not as
   a mode on the ide shape.

Build 1–3 as one arc, then 4, then 5.

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

- Loading card sizes from content; image checkerboard survives zoom-out.
- Animated GIF plays in the image viewer (`core.image.Animation`, dvui timer per frame).
- `.gif/.bmp/.tga` claimed by `image`; `text` refuses binary (`textcore.encoding.looksBinary`);
  a failed load no longer deinits an unwritten document buffer; user gets a toast.
- Every region registers (Main was missing from the placement pane).
- Phase 4b: panel placement pane with persistence (to be replaced, see above).
- Native dialogs ask the app for start dirs; AppInfo + backend allocator in `app/`; self-update,
  window geometry, singleton, watchers, store all in `app/`; `files` is a service.
