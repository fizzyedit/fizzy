# Phase 1 spike findings

The spike ports fizzy's own shell onto the new layout primitives behind `-Dnew-shell`, so both
shells compile into one binary and can be run side by side. Verified on macOS by launching each
in an isolated `HOME`/`TMPDIR` and comparing screenshots.

## Verdict: the layout idiom holds

`layout()` as an ordinary Zig function reads top to bottom and produces a pixel-comparable
shell in ~95 lines (`ide.zig`), against ~215 lines of the legacy in-`tick` layout. Rail,
explorer, tabs, split markdown preview, bottom panel and infobar all render correctly, and the
explorer/panel splits animate and collapse as before.

## 1. A split's PanedWidget is not private layout state — the biggest finding

`fizzy.layout.split` cannot own its `PanedWidget` privately. Three separate subsystems reach
into the shell's paned widgets to coordinate with them:

- `Explorer.open` / `peekClose` / `collapsed` (`explorer/Explorer.zig:53-67`) — the rail's
  click action drives the explorer split.
- `Editor.revealCenter` (`Editor.zig:3237`) — reads `explorer.paned.collapsed()`.
- **`Editor.drawWorkspaces` (`Editor.zig:4552`)** — the host API the *workbench plugin* calls,
  reads `panel.paned.dragging` / `.animating` / `.split_ratio` so the workspace can coordinate
  its own animation with the shell's panel.

The third is the important one: it means **a plugin's rendering depends on the app's split
state**. Not publishing the widgets segfaults on the first frame (`dragging = panel.dragging`
on an uninitialized pointer).

The spike adapts by assigning `editor.explorer.paned` / `editor.panel.paned` from the new
splits, which preserves behavior exactly.

**Phase 4 should invert this rather than keep it.** A plugin should not reach for a widget
pointer; the frame should answer a question — e.g. `f.regionState(keywords)` returning
`{ animating, collapsed, ratio }`. That keeps the coupling as data, survives an app that has no
bottom split at all (today `drawWorkspaces` guards on `bottom_views.len > 0`, which is a proxy
for "the shell drew a panel paned" and would be wrong in a differently-shaped app), and is a
precondition for the differently-shaped example apps in Phase 5.

## 2. Explorer and Panel are app chrome *around* a region, not regions

`Explorer.draw` = header (active view's title) + scroll area with per-view scroll policy + the
active sidebar view's own draw. `Panel.draw` = grouping-aware drag-reorderable tab strip + the
active bottom view's own draw.

Only the inner part is the plugin's surface; the rest is the app's furniture. This is a good
result — it is exactly the split the design predicts — but it means these cannot be swapped for
a bare `f.region` call. Phase 4 rewrites each as "chrome that calls `f.region`", which is also
what turns the tab strip into an ordinary app-side loop.

## 3. Selection state already exists on the host; do not duplicate it

`host.active_sidebar_view` / `active_bottom_view` / `active_center` already are the selection.
`Frame` is therefore a *view over existing state*, not a parallel store — which is what keeps
the two shells from disagreeing. `Editor.shell_selection` is only the fallback for keyword
groups no legacy registry owns.

## 4. The generalized cross-fade works

`f.draw` wrapping its child in a `core.anim.reveal` keyed by **surface id** (never the parent
box id — see the warning at `workbench/src/Workspace.zig:768`) drives the main-area swap with no
visible regression. The bespoke `CaptureCtx` / `center_transition` path in `Editor.zig:2968` is
therefore replaceable, as planned.

## 5. Container nesting expresses fizzy's real layout

Docking order as call order reproduced fizzy's arrangement, including the bottom panel living
*inside* the explorer's remaining width rather than spanning under it, and the infobar
gravity-anchored across the full width. No ordering escape hatch was needed.

## 6. Bug found in the legacy shell: the bottom panel opens at 50%, not `panel_ratio`

`Editor.zig:4325` creates the panel paned **without** a `split_ratio` pointer, so `PanedWidget`
defaults it to `0.5` (`PanedWidget.zig:106`). The animate-open branch at `:4340` only fires when
`split_ratio.* == 1.0`, which never happens on a fresh profile — so the panel opens at 50%
instead of the intended `panel_ratio` (0.25) and only settles once the user drags it.

Verified: on a fresh `HOME`, legacy opens the output panel at ~50% of the content height, the
new shell at ~20-25%.

The new shell passes an explicit persisted ratio slot and so is correct. **This is a deliberate
behavioral difference from the legacy shell** — the one place the spike does not match it,
because matching would mean reproducing a bug.

## Not yet addressed (carried forward)

- **Unified titlebar.** Untouched: the platform chrome at `Editor.zig:4022-4156` sits *above*
  the replaced region, so both shells still share it. Unifying it across macOS/Windows/Linux
  remains the largest single unknown and moves to Phase 3 with `AppInfo`.
- **`fizzy.widgets.list`.** The virtualized list is not built; the explorer still uses its own.
  Moves to Phase 4, where it is needed anyway for the differently-shaped examples.
