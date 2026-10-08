# One drag: everything carried as the view drag is

Status: proposed. Step 1 is #248.

Fizzy has one drag that looks and behaves the way a drag should: the view drag (`ViewDrag`).
- It carries what you lifted in liquid glass.
- Its drop bubbles say where it will land.
- It crosses every window fizzy has open: the main window, floats popped out into windows of their
  own, and the carry window between them.

Everything else that drags (rows in the file tree, folders, pixi's layers, frames and animations)
uses a widget's own drag: a frosted row clipped to one window that can only land in the list it
came from. So a file tree in one window can't hand a folder, or several files, to a workspace in a
float's window, and a pixi layer drag doesn't look like any other drag in the app.

This plan makes the view drag the only drag, with:
- a carried payload broad enough for files, folders, selections and a plugin's own items;
- a way for any widget, not only a place, to take a drop.

The scope is fizzy's own windows. Drag and drop with other apps is out of scope; its seam is named
at the end.

## Where it stands

| Drag | Mechanism | What it draws | Lands | Crosses windows |
|---|---|---|---|---|
| A view, a tab, a rail icon, a picker card, a file opened from the tree | `ViewDrag` (`begin`, `beginLoose`; `Host.beginViewDrag`) | liquid glass card, bubble or tab face; carry window | places (`RegionSpec.on_drop`), strips (`offerChooser`) | yes |
| A selection of files, a folder (#248) | `ViewDrag` (`Host.beginViewDragMany`, held when no place takes it) | stacked rows in the glass | places, with `Drop.others`; back over the tree through `TreeWidget.carriedOver` | yes |
| A move inside the file tree | `TreeWidget`'s own drag (`drag_name = "workbench.file_row"`) | a `FloatingWidget` row in `dialogs.carriedGlass`, clipped to one screen | the same tree only | no |
| pixi's layers, frames, animations | `TreeWidget`'s own drag, gestures driven by pixi (`tools.zig`, `sprites.zig`) | the same frosted row; pixi's canvas previews the order | the same list only | no |
| pixi's ruler columns and rows | `ReorderWidget`, a named dvui drag (`CanvasData.zig`) | a collapsed floating widget; glass cells in the canvas | the same ruler | no |
| pixi's sprite cells, the sample button | raw dvui drags in the canvas | previews in the canvas | the same canvas | no |
| A dock tab (`"dvui_dock"`) | `DockingWidget` | a frosted zone | dormant: both dockspaces have no header | — |

The same thing ends up in several places:
- **Starting a drag:** three calls (`ViewDrag.begin`, `beginLoose`, `Host.beginViewDrag`, plus
  `beginViewDragMany` in #248).
- **Releasing one:** two sites (`Region.zig` and `Picker.zig`).
- **A widget saying where a carried thing would go in it:** two bridges (`Host.Region.offerChooser`
  for strips, `TreeWidget.carriedOver` for the tree).
- **A ghost:** three different ones (`ViewDrag`'s glass, `TreeWidget`'s and `ReorderWidget`'s
  floating widgets).

Only the first of each crosses windows.

## The design

### 1. One carry

`ViewDrag` stays the engine. It already owns everything crossing windows takes:
- the bands every OS window draws from;
- the held pointer read in whichever window it is over (`SDLBackend.heldPoint`);
- `followAcross`;
- the overlay drawn on every screen;
- the carry window.

Nothing in this plan copies any of that into another widget. Every drag becomes a view drag, so
every drag gets it.

### 2. What is carried

`EditorAPI.Carried` (#248) grows a kind:

```zig
pub const Carried = struct {
    what: union(enum) {
        /// A surface, or a document by the id it will have: what places take today.
        surface: []const u8,
        /// A file or folder, by path. The explorer's rows; places take files they can open.
        path: struct { path: []const u8, folder: bool },
        /// A plugin's own thing: only targets that name its type take it.
        item: struct { owner: []const u8, kind: []const u8, key: []const u8 },
    },
    label: []const u8,
    icon: ?Icon = null,
};
```

Several are carried at once, in order, and the first is the one in hand. #248's `held_id` becomes
the general rule: the drag is held, so no place's bubbles show, unless at least one place takes the
item in hand. A pixi layer carried over the canvas shows no bubbles. Carried back over its layer
list it reorders, as a folder carried back over the tree moves.

### 3. One start call

```zig
host.beginDrag(.{ .items = items, .from = rows_rect, .grabbed = p });
```

This replaces `beginViewDrag` and `beginViewDragMany`, which stay as wrappers until step 7.
- The app's own `begin` (a place's view) and `beginLoose` (a picker card) call the same thing
  inside `ViewDrag`.
- One release path, `ViewDrag.apply`, for every drag: `Picker.zig` and `Region.zig` stop
  releasing drags of their own.
- The card's picture is still taken by the app (a pane's preview, a row stack, a pill), never
  drawn by the widget that lifted.

### 4. Who takes it: places, and offers

**Places** keep taking drops as now, through keywords (`sdk.keywords.accepts`) and `on_drop`.

**Offers** are new, and replace both bridges. While a drag is in the air, any widget can offer to
take it, each frame, where it is drawn:

```zig
if (host.dragOffer(.{
    .id = tree_id,
    .bounds = rows_rect,
    .takes = &.{ .{ .path = .any }, .{ .item = .{ .kind = "pixi.layer" } } },
    .shape = .between(.vertical), // or .into, .point
})) |over| {
    // `over.point`: draw the slot or highlight under it.
    // `over.released`: take `over.items` now.
}
```

- `offerChooser` is an offer with `.between` along the strip.
- `TreeWidget.carriedOver` becomes the tree's own offer: `.between` rows, `.into` a folder.
- The app picks the target once a frame. Uncovered offers (an offer under a float is behind it)
  come before places, and an offer's bounds are what the place's drop zones leave out, as a
  chooser's are today.
- The release is delivered to that one target: an offer or a place, never both.

### 5. `TreeWidget` on the carry

The core tree stops drawing a ghost.
- **At lift**, it calls `beginDrag` with its selection, as `Carried` items the tree's owner names.
  The workbench gives paths; pixi gives `.item`s of kind `pixi.layer`, `pixi.frame` or
  `pixi.animation`.
- **While carrying**, it offers its rows.
- **On release**, its existing results (`removed()`, `insertBefore()`, `dropInto`) come out as they
  do now. The callers' move code (`applyFileMove`, pixi's layer reorder and history) doesn't
  change.

This one change does the work of the plan. In-tree moves, a folder carried to a float's window,
and a layer reordered from a popped-out Layers panel all happen in the glass, across windows.
pixi gets it by repinning to the SDK release that carries the new core.

### 6. Crossing windows

This comes for free once everything is a view drag:
- An offer is registered where its widget is drawn, in the band of the window it is in. The app's
  pick reads them all in frame coordinates, as it reads places now.
- The plan relies on the windowing foundation's typed coordinate spaces
  (`WINDOWING_FOUNDATION_PLAN.md` §4) for keeping band and main-window points apart, rather than
  adding conversions of its own.

### 7. How it fits the windowing foundation

`WINDOWING_FOUNDATION_PLAN.md` §5 makes the drag one model resolved once a frame:
`DragModel.resolve(targets, occluders, offers, aim, now)`. This plan supplies what that model reads:
- what is carried (§2);
- who offers to take it (§4);
- the one release (§3).

The steps below that change how targets are picked land on that model, not beside it. Step 4 here
and step 7 there are written together.

## Steps

Each step is a PR of its own, under 800 lines outside tests and docs. The SDK steps (3, 4, 5) move
the fingerprint and go out as one SDK release, before pixi's step 6.

1. **A selection and a folder carried out of the explorer, all landing.** #248.
2. **This plan.**
3. **`Carried` kinds and `beginDrag`.**
   - `Carried.what`; `beginViewDrag` and `beginViewDragMany` become wrappers.
   - One release path in `ViewDrag`.
   - The rule that the drag is held when no place takes the item in hand.
4. **Offers.**
   - `Host.dragOffer`; `offerChooser` and `TreeWidget.carriedOver` on it.
   - The workbench's strips and tree offer.
   - Tests for the pick: offers before places, uncovered first, one target per release.
   - Written with the foundation plan's step 7.
5. **`TreeWidget` on the carry.**
   - The tree lifts with `beginDrag`, offers its rows, and draws no ghost.
   - `KeybindSettings` and the workbench adopt it.
   - A file tree in the main window drops a selection or a folder into a float window's workspace.
6. **pixi.** Repinned to the SDK release; its layer, frame and animation trees carry `pixi.*`
   items, so they reorder in the glass from wherever the panel is.
7. **What is left goes.**
   - The wrappers.
   - `TreeWidget`'s floating ghost.
   - The dormant `"dvui_dock"` tab drag.
   - `ReorderWidget`: pixi's rulers are its only user. It moves into pixi, or onto the carry if a
     ruler column should ever leave its ruler.

Tests: each step adds unit tests where its logic is pure (the pick, held drags, the order `others`
lands in). A tape that carries a selection from the tree into a float's window waits on the
foundation plan's fake backend (§9) and comes with it.

## Not in this plan

- **Drag and drop with other apps** (to Finder or Explorer, or from the desktop into the tree).
  - Its seam is `Carried.what.path`, the one kind another app understands. An OS drag starts from
    the same `beginDrag` when the pointer leaves every fizzy window with path items in hand, and
    ends as an offer of the OS's.
  - Each OS needs its own source and target (`NSDraggingSource`, OLE `IDropSource`, Wayland and X11
    data devices). That's a plan of its own.
- **pixi's canvas drags:** ruler columns, sprite cells and the sample button never leave the
  canvas. They keep their in-canvas previews.
- **Gesture drags** that aren't drag and drop: sashes, float headers, canvas pans, marquees.
