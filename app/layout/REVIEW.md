# Region + split design review

A pass over the docking/splitting arc (`app/layout/*`, `core/widgets/{Split,Panes,PanedWidget}`,
the workbench pane row) against three goals: a simpler and more stable API, one sizing model
instead of several, and a low-level split-tree widget fizzy could contribute back to dvui
(the shape dvui #985 asks for). Findings first, then the proposal, then the order to land it.

## What holds up

- **Keyword matching is proven and should not move.** `Layout.matching / selected / draw`, the
  claim rule (`claimedElsewhere`), per-region assignments, takeovers, and `Shows` all passed the
  Phase 5 test (three shapes, zero plugin edits). None of this is about geometry, and the
  proposal below leaves it alone.
- **`Drop.zig` is the right shape for a rule.** Forty lines, pure, both preview and release read
  it. This is the standard the rest of the geometry should be held to.
- **The lessons in `SPLITS.md` "Settled"** (every edge splits; no create-handles; a preview
  never remounts; the map is frozen at lift) are hard-won and all survive the proposal.

## What does not

### 1. There are three live sizing models and one dead one

| Where | Unit | Who moves when you drag a divider |
|---|---|---|
| `Split` + `Region` (shape trays: sidebar, panel) | points, one `_size` per resizable region | the *last resizable neighbour*; the leftover absorbs; `push_out` shrinks trays *behind*; when the flex gap is gone the *opposite* side yields (`Split.resolve`) |
| `SplitTree` runtime branches (`Region.initTree`) | points on the branch box, minted leaf `resize=true`, origin `expand=.both` | same tray model — one flexible pane, everything else fixed |
| `Panes` (workbench document row) | share of the row | the pane touching the boundary, cascading outward |
| `core.widgets.PanedWidget` | ratio | *(zero callers — dead code, 534 lines)* |

The inconsistency you feel is documented in `Panes.zig`'s own header: under the tray model,
"dragging the boundary between panes 2 and 3 grew pane 3 while pane 2 kept its width and
*slid*… with one flexible pane, a boundary is not a boundary." Runtime splits of `Main` use
exactly that model, while the document panes *inside* `Main` use shares. Two nested splits,
two feels. The recursive-`PanedWidget` era felt right for documents because a ratio per
branch *is* "a boundary is a boundary": a divider only ever moves its own two children.

### 2. Geometry state lives in dvui's data store under string keys

`_size` (33 sites), `_shown`, `_drag_anchor`, `_org`, `_end`, `_drag`, `_ease`, `_open`,
`_share*` — spread across `Split.zig`, `Panes.zig`, `Region.zig`, keyed by widget ids that
derive from `@src()` + a name hash. Every "pop" bug in the log (`a new sentinel resets _org`,
`the next frame recreates a sentinel under the pointer`, `packed handle with the same id paints
a red duplicate`) is a widget id changing under stored state. `SplitTree` is geometry-free, but
that only moved the geometry into a store nothing can test as a value: `Split.resolve` looks
pure but reads `dataGet` for every sibling.

### 3. `Region.init` is two trees spliced at a name

The shape declares a static tree by call order; `SplitTree` is a runtime tree keyed by region
name; `Region.init` dispatches between them. The seams are visible as flags whose only purpose
is to tell the two apart: `tree_origin`, `leftover_leaf`, `omit_edge`, `by_name`, `kind_slot`,
the `slot` keyword exemption in `regionKeywords`/`placePrefix`, `initTree` re-implementing sixty
lines of `init`, `packTreeSplit` needing its own `@src()`. Each was a correct local fix; together
they are the sign that geometry does not belong in the region layer at all.

### 4. Blur is a smear, and upstream already has the real thing

`core.anim.blit` is an offset-sample smear over a captured texture. Upstream dvui now ships
`BlurBackdrop` (dual-Kawase, cached, `init`/`deinit` bracket around the content to blur, redraws
one quad when nothing changed) — added after the current pin (`7f0957ef`, 2026-08-17; upstream
is 59 commits ahead). Its bracket shape is precisely the "region underneath draws first, tray
draws over it" model `LAYERS.md` chose, and it is what a scroll area needs to blur its own
overflow. `LAYERS.md` step 1 ("bump dvui to a pin with blur") is now just a bump.

### 5. dvui already has most of the widget we would contribute

The pinned dvui has `DockingWidget` + `DockingWidget/Layout.zig` (`DockLayout`): a node tree of
ratio splits and tabbed leaves, floats, drop zones (`tab` / `split` on a leaf side /
`split_root`), mutations queued during the walk and applied in `deinit` (indices stay valid all
frame), and a format-agnostic `Snapshot`. `SplitTree` + `ViewDrag` + `Drop` + `Picker.split`
re-implement a subset of it (no floats, no tab-strip drop) on a different sizing model.

#985 asks for the split-tree part of that *without* the tabs: `recursiveSplit`, "an opinionated
generalization of `dvui.paned`", with animated creation left open. That is a factoring of what
dvui has, not a new widget — which is also what makes it likely to be accepted.

## Proposal

Split the problem where it actually splits: **what goes where** (fizzy, keywords, surfaces —
keep) and **who is beside whom and how big** (a tree widget — one, in dvui).

### A. `dvui.SplitTreeWidget` — the contribution (answers #985)

Factor the split-tree core out of `DockingWidget` so `DockingWidget` = `SplitTreeWidget` + tabbed
leaves + floats. The core is:

```zig
pub const SplitTree = struct {                 // a value: no widgets, no allocator on the hot path
    pub const Node = union(enum) {
        leaf: LeafId,                          // caller-owned identity, stable across splits
        branch: struct {
            dir: Direction,
            ratio: f32,                        // first child's share; 0 or 1 = collapsed, handle stays
            fixed: ?struct { side: enum{first,second}, points: f32 } = null,  // sidebar-style
            first: NodeIndex, second: NodeIndex,
        },
    };
    pub fn splitLeaf(leaf, side, new: LeafId) !void   // keeps `leaf`'s index, as DockLayout does
    pub fn removeLeaf(leaf) void                       // sibling takes the branch's index
    pub fn snapshot / fromSnapshot                     // unchanged from DockLayout
};

var tree = dvui.splitTree(@src(), .{ .tree = &state.tree, .leaf_min = 0 }, .{ .expand = .both });
defer tree.deinit();                 // applies queued mutations, sets tree.changed
while (tree.leaf()) |l| {            // walks leaves; one PanedWidget per branch
    defer l.end();
    drawLeaf(l.id, l.rect);          // caller's content; l.rect is what BlurBackdrop brackets
}
```

Plus, as pure functions on the type so they are unit-testable: `dropAt(rect, point) -> {leaf,
Side | .middle}` (the `Drop.kindAt` band rule, already written and tested), and a
`preview: ?{leaf, side, t}` field the widget lays out *for real* this frame at ratio `t/2` —
which is what `ViewDrag.pullBack` does today with margins, done at the level that owns the ratio.

Two things #985 leaves open, answered:

- **Animated creation/removal**: a branch's ratio eases from 0 (or to 0 before the sibling
  takes its index). This is the tray slide from the `PanedWidget` era, and it is one number per
  branch rather than `_size`/`_shown`/`_ease` per region.
- **Blur**: not a widget option. `l.rect` + `BlurBackdrop.init/deinit` around whatever is
  underneath is the whole integration; nothing in the tree reverses paint order (the hazard
  `LAYERS.md` names). The one case the tree *does* need to know about is an overlay tray (panel
  over main): a branch flag `overlay: bool` that lays out `first` at the full extent and draws
  `second` after it. Declaration order and event order still agree.

Sizing is **ratio per branch, with an optional fixed-points child**. That expresses all three
current models: a sidebar is `fixed = {first, 260}`; documents are plain ratios; a fully
collapsed tray is ratio 0 with the handle still drawn. A divider only moves its own branch — no
`push_out`, no `base_min`, no `resolve`, no `last_resizable`, no `sign`. That is the consistency
you liked, and it is what dvui's `PanedWidget` already does.

### B. Fizzy on top of it

- **A shape seeds a tree, it does not draw one.** `f.region` / `f.split` calls become the seed
  `SplitTree` built on first run (or on Reset Layout); after that the persisted tree is the
  truth and the shape only maps `LeafId → region spec` (name, keywords, shows, content).
  "Cannot be removed" is a `pinned` bit on the leaf — the tree refuses `removeLeaf` on it and
  collapses the *branch* when a pinned leaf's sibling empties, which is your "if one takes over
  it removes the other."
- **Subdivision is `splitLeaf`, on any leaf, from any entry point** (picker, edge drop). The
  origin keeps its `LeafId`, so its widgets never remount — this is why `DockLayout`'s
  "same index" rule matters and why `SPLITS.md`'s "a self-split may not move the view" stops
  being a special case: the view never moves because the leaf never does. `Main/r1` naming goes
  away; a minted leaf is a fresh `LeafId` whose region spec is `{keywords = slot}`.
- **Region shrinks to the matching layer.** `Region.init` becomes: qualify keywords, register,
  draw the selected surface(s) into the rect the tree handed it. `initTree`, `drawTreeNode`,
  `packTreeSplit`, `sashWidth`, `foldedPadding`, `persistExtent`, `omit_edge`, `tree_origin`,
  `leftover_leaf` and the `slot` exemptions go. Card chrome (`placeCard`) is applied by the
  shape's leaf callback, as it is now.
- **The workbench's document row is the same tree**, nested: `Main`'s leaf content is a
  `SplitTreeWidget` of its own over document `LeafId`s (grouping ids). `Panes.zig` goes. Because
  the widget lives in dvui, a dylib reaches it without `core`.
- **`ViewDrag` keeps its photographs and its preview policy** but loses hit-testing (`dropAt`),
  pull-back (`preview` on the tree) and the frozen-map bookkeeping (leaf rects come from the
  tree walk, which is already a pure function of the tree + pointer). `Drop.plan` stays as is.
- **Blur lands as `LAYERS.md` sequenced it**, with the primitive swapped: bump dvui → scroll-edge
  `BlurBackdrop` in one widget (proves it from a plugin) → `overlay` panel over main →
  `.blur_behind` on a region = bracket the underlying leaf.

  The first target, concretely: **a pane's overflow bleeds under its neighbour.** A text editor's
  scroll area is wider than the pane; today the excess is simply clipped at the sash. Instead,
  the part that runs *under* the pane to the right is drawn there as a very heavy, cached blur —
  just the colour of what is underneath, the window's frosted-glass look applied inside the
  layout — so the right-hand pane's tab strip sits over a hint of the left pane's text. The
  scroll area is the natural capture point (it already knows its content rect vs its viewport),
  and `BlurBackdrop`'s cache keyed on scroll offset is exactly what keeps it cheap. This is the
  scroll-edge step above, done as an "under the neighbour" rather than a shadow at the edge.

### The shape a layout is written in: a tree value *and* a function

People will expect to write a layout as data:

```zig
const default_layout = .{ .vsplit = &.{
    .{ .pane = .{ .name = "sidebar", .plugin = "text-editor" } },
    .{ .hsplit = &.{
        .{ .pane = .{ .name = "main", .plugin = "pixel-editor" } },
        .{ .pane = .{ .name = "bottom", .plugin = "terminal" } },
    } },
} };
```

That is a `DockLayout.Snapshot` with names on the leaves — the *seed* the tree starts from when
nothing is saved, and what Reset Layout returns to. It is the right form for *arrangement*
(which is beside which, ratios, `fixed`, `fit`, `pinned`) and the wrong form for everything the
function form is good at: the rail, the menu bar, the infobar, a filter box above a region, any
widget an app wants between two places. So keep both, each doing the one thing it is good at:

```zig
const seed: Layout.Seed = .{ .split = .{ .dir = .horizontal, .fixed = .{ .child = .first, .points = 260 },
    .first = &.{ .leaf = .{ .name = "Sidebar", .keywords = kw.ide.sidebar, .pinned = true } },
    .second = &.{ .split = .{ .dir = .vertical, .ratio = 0.75,
        .first = &.{ .leaf = .{ .name = "Main", .keywords = kw.ide.main, .pinned = true } },
        .second = &.{ .leaf = .{ .name = "Panel", .keywords = kw.ide.panel, .shows = .many } } } } } };

pub fn layout(ctx: ?*anyopaque, f: *Layout) !dvui.App.Result {
    const rail = try editor.sidebar.draw(...);          // ordinary dvui, before the tree
    var tree = try f.tree(@src(), &seed, .{ .expand = .both });
    defer tree.deinit();
    while (tree.leaf()) |l| {                           // each leaf is a region by name
        defer l.end();
        if (std.mem.eql(u8, l.name, "Sidebar")) try f.regionIn(l, .{ .content = explorerPane })
        else try f.regionIn(l, .{});                   // default: the selected matching surface
    }
    editor.infobar.draw(editor);                        // ordinary dvui, after
    return .ok;
}
```

The seed names leaves by keywords, not by plugin id — `"plugin": "terminal"` is an
*assignment*, and assignments are the user's, kept in `layout.zon`; a seed that hard-wires one
would fight the picker. `f.region` / `f.split` as call-order layout go away; `f.regionIn(leaf)`
is what is left of `Region.init` once geometry is the tree's. Runtime subdivision, drags,
floats and (later) OS windows all operate on the same tree, and the workbench's document row
is a second tree nested in `Main`'s leaf — drags are scoped by keyword acceptance, so a
document cannot land in a region slot or vice versa.

### Status (2026-09-14)

Done: dvui bumped (docking + `BlurBackdrop`); `DockLayout`/`DockingWidget` copied and extended
(`fixed`, `fit`, `pinned`, keys, animated open/close/reopen, accordion drags, stacked sashes,
`zoneAt`/`edgeAt`); the workbench document row is on it; `Panes`/`PanedWidget` deleted;
`pixi`'s layers/palettes split is on it (`fit`); `zig`/`ghostty`/`atlas` migrated to the
current SDK (`Painter`, `registerSurface`, `selectionFor`, `Host` doc queries) and installed.
Next: the shell onto the tree via the seed form above, then `ViewDrag` → surface+kind, then
blur, then floats → `osWindow`.

### What gets deleted

`core/widgets/PanedWidget.zig` (dead now), `core/widgets/Panes.zig`, `Split.resolve` +
`Constraint` + `push_out`, `app/layout/SplitTree.zig` (replaced by dvui's), most of
`Region.initTree`/`drawTreeNode`, `Layout.Container.{resizables,handles,last_resizable,
base_min,saw_base,pending_split}`, and the `_size/_shown/_org/_end/_drag_anchor/_ease/_share*`
data-store keys. `Split.zig` keeps only the handle drawing (`drawSplit`, the approach fade) —
that is the part dvui's paned handle lacks and is worth carrying over to the contribution.

## Order

1. **Bump dvui** to upstream head on its own change (`sdk/build.zig.zon` only). 59 commits,
   includes `BlurBackdrop` and docking API changes; land against a green tree, nothing else in
   the change (`LAYERS.md`'s risk item, unchanged).
2. **Factor `SplitTreeWidget` out of `DockingWidget` in `dvui-dev`**, `DockingWidget` re-based on
   it, PanedWidget handle gets the approach-fade grip. Open the PR referencing #985. Fizzy pins
   the branch meanwhile (single pin, `sdk/build.zig.zon`).
3. **Workbench document row onto the widget** first — smallest consumer, the one whose feel you
   have the clearest memory of, and it validates ratio-per-branch + animated open/close before
   the shell depends on it.
4. **Shell trays and runtime splits onto the widget**; delete the tray model. `ViewDrag` moves to
   `dropAt`/`preview`. Persist via `Snapshot` (replaces `SavedRegion` links + extents).
5. **Blur** in `LAYERS.md` order.

## Risks worth naming

- **The dvui bump is the only step that can regress unrelated things.** Isolate it.
- **Remount.** Everything depends on leaf identity surviving a split. `DockLayout` already
  guarantees it; the factoring must not lose it, and the workbench's grouping ids must be the
  `LeafId`s (never indices — `Panes.zig`'s own warning).
- **Points for sidebars.** `fixed` on a branch is a small addition to dvui's ratio model and the
  one thing upstream might push back on. Fallback: fizzy keeps a ratio and converts on window
  resize — worse, but contained.
- **Two frames of preview truth.** The tree previews by laying out for real; a plugin that
  declares regions inside a previewed leaf will register at the previewed size. Today's fix is
  the frozen map; with the tree it is simply that `dropAt` reads the tree's *committed* rects,
  which the walk can keep beside the previewed ones.
