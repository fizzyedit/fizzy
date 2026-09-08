# Phase 4: surfaces and keyword binding — landed, and what remains

## Landed

**`src/sdk/Surface.zig`** is the shape-agnostic successor to the
`SidebarView` / `BottomView` / `CenterProvider` trio, which differed only in *where the host
chose to call them*. A surface carries one identifier plus `keywords` describing what kind of
place its content belongs — never where it goes. **`src/sdk/keywords.zig`** documents the
conventional sets fizzy's own regions accept (`sidebar`/`explorer`, `bottom`/`panel`/`output`,
`main`/`center`/`workspace`); they are conventions, not an enum, so a plugin inventing a new
kind of panel never bumps the ABI.

**Existing plugins need no source change.** `registerSidebarView`, `registerBottomView` and
`registerCenterProvider` still work and now *also* register a surface with the conventional
keywords for their old region, so a keyword-matching layout sees every existing contribution.
Verified at runtime — all six surfaces appear with correct keywords:

```
workbench.files       Files       kw=2      workbench.workspaces  kw=3
fizzy.store           Plugins     kw=2      fizzy.store.readme    kw=3
fizzy.settings        Settings    kw=2      fizzy.output          Output kw=3
```

**`Frame`** now reads the real registry rather than synthesizing surfaces:
`matching(keywords)`, `selected`, `select`, `isSelected`, `surface(id)`, `draw`, `region`, and
`unplaced(declared)` — the last so a surface matching no region an app declared is listed rather
than silently lost, which is the failure mode that makes string matching tolerable at all.

**User keyword overrides** are read from `Editor.surface_keyword_overrides`
(`.plugins.<id>.surfaces.<sid>.keywords` in `settings.zon`) and win over the plugin's defaults.

**ABI bumped once, as planned:** `recorded_sdk_shape_fingerprint` → `0xebd185d529afc877`,
`sdk_version` → 0.1.53. The guard in `version.zig` caught the shape change unprompted and
refused to build until both moved together, which is the mechanism working.

## Remaining Phase 4 work, deliberately not bundled

Each of these is a substantial change in its own right, and none is a prerequisite for the
Phase 5 example apps:

0. ~~**The Explorer/Panel chrome split.**~~ **Done for the sidebar path (Phase 4c).**
   `Sidebar.draw` now lists `f.matching(keywords)` instead of `host.sidebar_views`, and
   `Explorer.draw` / `drawHeader` resolve their body through `f.selected(keywords)` instead of
   `host.activeSidebarView()`. Selection goes through `f.select`, so it still lands in the same
   host state and the two shells cannot disagree.

   Verified end to end. With `.surface_keywords = .{ .@"workbench.files" = .{ "bottom" } }` in
   `settings.zon`:

   ```
   without override            with override
   RAIL LISTS workbench.files  RAIL LISTS fizzy.store          <- file tree gone from the rail
   RAIL LISTS fizzy.store      RAIL LISTS fizzy.settings
   RAIL LISTS fizzy.settings   EXPLORER DRAWS fizzy.store      <- degraded to first match
   EXPLORER DRAWS workbench... BOTTOM LISTS workbench.files    <- moved to the bottom panel
   BOTTOM LISTS fizzy.output   BOTTOM LISTS fizzy.output
   ```

   A user moved a plugin's surface from the sidebar to the bottom panel by editing a text file,
   with no plugin change and no fizzy release. That is the escape hatch the whole
   keyword-matching design rests on, now actually working.

   **Still to do on this thread:** `Panel.draw` (the bottom tab strip) resolves through
   `host.active_bottom_view` the same way the explorer used to, so a surface that *arrives* in
   the bottom region by override is listed by `f.matching` but not yet drawn by the panel's own
   strip. Same fix, one file over.

1. **The three-way service split (§E).** `workbench-api` is still one service doing three jobs:
   document lifecycle (which `EditorAPI` already duplicates), file-tree mutation, and
   tabs/splits presentation. Splitting it is what frees a document plugin from depending on
   workbench at all.
2. **Doc/view split for multiple views of one document.** Needs a stable `view_id` on
   `bindDocumentToPane` and per-view state separated from per-document state in `text` and
   `image`. New capability, not a rename — and the plan flags text's cursor/buffer entanglement
   as the cost to measure first.
3. **Per-service versioning + optional-service degradation (§D4).** Required before any
   third-party app ships its own service, or the failure mode is a silent vtable-shape mismatch
   across a dylib boundary.
4. **Deleting the `center: bool` leak** from `bindDocumentToPane` — trivial, but it is a vtable
   change and should ride with (2) rather than causing a second bump.
5. **Explorer/Panel chrome split** and the live rebinding UI (Phase 4b). Both depend on moving
   fizzy's rail/tab-strip behavior into the app layer; see `src/editor/shell/FINDINGS.md`.

## Ecosystem note

This bump would break pixi, zig, ghostty, batch2d, markworld and gauntlet **if released**. It
must not be: the compat sugar keeps them compiling, and the coordinated rebuild-and-release
happens only once this branch is proven. A store-wide plugin rebuild is a one-way door.
