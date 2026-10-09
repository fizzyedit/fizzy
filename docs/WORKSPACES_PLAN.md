# Workspaces: many tabbed areas of documents, placed as views

Status: proposed. Steps tracked in #260, each its own PR.

Decided with the user (2026-10-04/05):
- **Groups and workspaces are joined into workspaces.** A workspace is a tabbed area of documents,
  and there can be any number of them. Each is a view placed by the app: in Main, in a split, or in
  a float.
- **Documents are children of workspaces.** Only workspaces take documents, and Main holds one by
  default.
- **Views and workspaces are peers.** A view (Explorer, Output, …) dropped on a workspace replaces
  it, as views swap today, rather than becoming a tab among its documents.
- **When a float holding a workspace closes,** its documents move into the main window's
  workspace.
- **Nothing more for the web.** Floats there stay in the window (`Floats`), as now.
- **A workspace is named by its selected document** wherever views are listed (the picker, a
  float's title).
- **A document may be open in several workspaces at once,** as two views of one shared document,
  as in VS Code. Edits show live in every view, there is one unsaved state, and one save. Only the
  cursor, selection, scroll and zoom are per view.
- **No default workspace unless the layout asks for one:** there is none when no place's keywords
  match a workspace's. Fizzy's Main does (`main`).
- **⌘N opens a new window; ⌘D a new document.** "New Window" opens a window whose place takes a
  workspace, so it opens on an empty one: a new editor, one keystroke away. "New File" is renamed
  "New Document" (`fizzy.newFile`'s title, and the home page).
- **The home page lists New Window first,** above New Document.
- **A dialog opens in the window it was asked from,** not always in the main window (below).

## Why

Fizzy has two of everything for tabs and splits:

| | The app's layout | The workbench plugin's copy |
|---|---|---|
| Places | regions, `State.assignments` | `Pane N` regions (`Workspace.draw`, `Workspace.zig:117`) |
| Splits | `SplitTree` (user splits, `Region.zig` `initTree`) | one `DockLayout` tree (`Workbench.panes`, `Workbench.zig:39`) |
| Tabs | `Chooser.zig` | `Workspace.drawTabs` (`Workspace.zig:188`) |
| Drops | `ViewDrag.place` / `Drop.plan` | `paneDrop`, `paneBeside`, `seatPane` |
| Where things open | assignments by place name | groupings (`newGroupingID`, `open_workspace_grouping`) |
| Saved in | `layout.zon` | `panes.zon` |

The workbench's one `Workspace` surface draws its whole pane tree in whatever place holds it. So
there is one workspace, and "floating" it moves every document at once. Documents are slotted into
its panes, so they cannot reach the app's places:
- **A float can't hold one.** A float's place is a plain one (`Layout.slotted`, `Layout.zig:419`;
  `matchingWith` skips slotted surfaces, `:353`).
- **A tab torn off has nowhere to go.** `canFloat` and `floatAway` refuse loose and slotted drags
  (`ViewDrag.zig:1806-1823`).
- **More workspaces would mean several workbench trees.** That is per-tree
  `seatPane`/`paneBeside`/`solePane`, culling, persistence and closing, all inside the plugin.

It also goes against fizzy's one idea: the framework owns layout, and plugins contribute surfaces
(CLAUDE.md, "The core idea").

## The model

- **A workspace is a view fizzy provides**, one per workspace (surface ids `fizzy.workspace.<n>`,
  keywords `workspace`, `main`; `src/editor/Workspaces.zig`). Like any view, it sits in a place: Main
  has one by default, a float can hold one, and the picker and the view drag move it. Its content is
  the workbench's pane for that workspace (`Workspace.draw`): its document slot, its tabs, its
  selected document. That code already speaks only the SDK (`host.region`, `host.docFromPath`,
  `host.closeDocById`), so tabs, previews, placeholders and the close flow carry over as they are.
  The workbench's own arrangement of panes (`Workbench.panes`, a `DockLayout`, and `panes.zon`) is
  what goes: the app's places, splits and floats arrange workspaces instead. Documents are ordinary
  surfaces their owners register (`<owner>.doc:<path>`), drawn through the owner's vtable as now.
- **Splits are the app's.** Splitting a workspace's place (`SplitTree`) gives the new place a new
  workspace. There is no tree inside a workspace.
- **Documents go only into workspaces.** A document dropped:
  - **on a workspace's tabs** goes in there, where it is let go;
  - **on a workspace's middle** joins that workspace;
  - **on a workspace's edge** splits its place, and the new place gets a new workspace holding the
    document;
  - **over the desktop** (OS windows) opens a float holding a new workspace with the document in it
    (`ViewDrag.floatAway`);
  - **on its own workspace's middle** floats it the same way, as a view dropped on its own place
    floats. This doesn't apply when it is its workspace's only document in an unsplit float.
  - **on the edge of a place showing a view** splits it with a new workspace, as for a workspace's
    edge. Its middle is no target: a document never replaces a view.
- **Views and workspaces are peers.** A view dropped on a workspace's middle replaces it: the
  workspace goes where the view came from, as two views swap today. Its edges split as for any
  place.
- **The active workspace** is the one that last had focus. "Open file", the explorer and document
  commands use it, in place of the grouping. If no workspace is left anywhere, opening a document
  brings back the default one, in the first place whose keywords take a workspace. A shape with no
  such place has no workspaces, and documents have nowhere to open.
- **Two views of one document.** A document can be in several workspaces at once, and every view is
  of the one document (as in VS Code), never an independent copy. Its edits show in every view, it
  has one unsaved state, and saving it from any view saves it. Carrying a tab moves it; a command
  ("Open in New Workspace", splitting with the document) opens a second view.
  Each workspace draws its documents under its own id, so what dvui keeps (scroll position, a text
  field's state) is per view. What an owner keeps on the document itself is shared unless it keys
  it by view (see "SDK"). Closing one view leaves the document open in the others; closing its last
  view closes the document, through its owner.
- **An emptied workspace** in Main, or in a window opened by New Window, stays, and shows the
  workbench's home page (open folder, recent files) as its empty state. Elsewhere, an emptied
  workspace closes its place: a split leaf collapses, and a float closes, as an emptied float does
  now.
- **Closing a float** moves its workspace's documents into the main window's workspace: the active
  one there, else Main's.
- **Two strips, two levels.** A place's tabs are views (`Chooser`); a workspace's tabs are its
  documents, with close, unsaved and saving markers and preview italics. Documents are children of
  workspaces and views are peers of them, so the two strips are two levels, not two copies. Both are
  where the one tab drag starts (#207).
- **Backgrounds.** A workspace stands on the rounded card. Whether a view does is a `Surface` field
  (the explorer does not). The place keeps the card's look (`placeCard`) and stops deciding whether
  it appears. The carried bubble photographs a surface without its card, so the glass's blur shows
  through.

## New windows

- **"New Window" (⌘N, `fizzy.newWindow`)** opens a float whose place is keyworded `workspace`, holding
  a new, empty workspace. Where floats are OS windows (macOS today), that is a new OS window. On the
  web and Wayland it is an in-window float. It opens offset from the window it was asked from, as a
  new window does in any app, and its empty workspace shows the home page.
- **"New Document" (⌘D, `fizzy.newFile` renamed)** asks for a new document in the active workspace.
  ⌘D is free in fizzy today. VS Code binds it to "add the next match to the selection", which the
  text plugin's keybinds plan (VS Code parity) would want; that binding moves to another key.
- **The home page** (the workbench's, the empty state of a workspace) lists New Window, then New
  Document, then Open Folder and Open Files. The workbench runs `fizzy.newWindow` by id and shows
  the entry only when the command exists, so it imports nothing of fizzy's and stays the same in
  an app without new windows.
- **A new window stays when it empties,** as the main window does: its last document closed or
  carried out, its workspace shows the home page. It closes only when the user closes it, its
  documents moving into the main window's workspace, as for any float. A float made by tearing a
  document off still closes when it empties (above); the float remembers which it is.

## Dialogs open in the window asking

Today every dialog (New Document's, Save As, a close prompt, the command palette, plugin dialogs) is
centred on the main window, even when the request came from a float or a float's window. A dialog
belongs to the window it was asked from.

- **The window asking** is the one with focus when the command ran: the OS's key window where floats
  are windows (`viewports`), else the float that took the last press (or the main window). A button
  inside a window (the home page's) asks from that window, whichever has focus.
- **Placing it there.** A float's window shows everything whose middle lies in its part of the frame
  (`Popout.windowFrame` takes those subwindows whole), as menus and tooltips there already do
  (`core.screens.screenFor`). So routing a dialog is centring it on the asking window's part of the
  frame. `core.screens` publishes that rect each frame (`activeScreen`, beside `publishScreens`), and
  `core.dialogs.dialogWindow` centres on it (`FloatingWindowWidget`'s `center_on`). No SDK change:
  `core` is source shared, and a plugin's dialog follows once the plugin is rebuilt.
- **Modal dialogs** dim the window they are in, not the main window and its title bar
  (`modal_dim_titlebar`). dvui's modal still takes the input of every window; blocking only the
  asking window is a later step.
- **The OS's own panels** (open, save, alerts) are given the asking window as their parent
  (`SDL_ShowOpenFileDialog`'s window), so on macOS they are sheets on that window.
- **Independent of workspaces:** it can land before them, as its own change on `main`.

## What a workspace must do: the workbench today (step 1)

Mapped from the code before anything changes, so the framework's workspace reproduces all of it.

**Drawing.** Main shows `workbench.workspaces` (`plugin.zig:64`). Its draw goes through
`host.drawWorkspaces` and `Editor.fizzyDrawWorkspaces` (`Editor.zig:2460`) to the workbench's
`drawWorkspaces` (`workbench_layout.zig:125`): a dockspace over `wb.panes`, one `Workspace.draw`
per leaf. That declares the place `Pane N` (`host.region`, `kind_slot`, `on_drop = paneDrop`),
draws the tabs, and draws the selected surface through `region.drawContents` →
`Layout.drawPluginRegionContents` (warm-ups, the drag's photograph, the cross-fade) → `s.draw`. A
pane never calls an owner: a document's surface (`<owner>.doc:<path>`, `registerDocSurface`,
`Editor.zig:2578`) draws through `Editor.drawDocSurface` (`:2634`):
- a canvas box keyed by the document's id;
- `owner.bindDocumentToPane(doc, canvas_id, handle, false)`. The image plugin keys zoom/pan by
  `canvas_id`; pixi stores it, and keys its per-pane canvas state by `documentGrouping`;
- `owner.drawDocument(doc)`;
- the document's context menu (`documentContextMenu`, `host.drawMenuSections`), and toasts over the
  canvas.

`tickActiveDocument` is broadcast once a frame with the layout root's id; it has nothing to do with
panes.

**Tabs** (`Workspace.drawTabs`, `:188-514`):
- **Look:** icon (`host.drawFileIcon`), title (italic for a preview), and the active-tab chrome only
  in the active pane.
- **Status slot:** the saving spinner (`isDocumentSaving`, `timeSinceSaveCompleteNs`), else a close
  button. The X shows when hovered, or when the tab is selected and clean; otherwise a dirty dot.
- **Close:** `host.closeDocById` → `Editor.closeFileID`, with the unsaved-changes dialog. A loading
  placeholder's close removes its tab, which cancels the load.
- **Context menu:** Keep Open (preview), Close, Close Others / to the Right / to the Left, then
  `fizzy.menu.tab` sections.
- **Press:** selects the tab and makes its pane active.
- **Drag:** past the threshold it un-previews the document and lifts it into the view drag
  (`host.beginViewDrag`), keeping its width.
- **Drop target:** the strip offers itself (`offerChooser`, a gap the carried tab's width) and takes
  a drop where it opens (`insertIndexAt`).
- **Anchor:** `workbench.tab:<path>`, which demos use.
- **Not there:** middle-click and double-click.

**Active document.** `Workbench.open_workspace_grouping` is the active pane (set by a click or a
tab press). `activeDoc` is what that pane showed last frame. It is read by:
- the infobar;
- `"<owner>.<action>"` commands;
- save, undo and menus;
- the keymap's owner scope;
- text's and pixi's own active document;
- save toasts.

`setActiveDocIndex` focuses a document, seating it first if no pane holds it.

**Groupings.**
- `setDocumentGroupingOnBuffer` is written before a load lands. `documentGrouping` is read by
  seating, previews, menus, demos and pixi.
- `setDocumentGrouping` is used only by `openOrFocusFileAtGrouping`, and only stamps.
- **Drift:** moving a tab to another pane never updates the grouping.
- **Grouping 0:** documented as "the pane the user is in", but it is the literal `Pane 0`.
- `services.workbench` (`currentGrouping`, `newGrouping`) has no consumer.

**Opening.**
- `Host.openFile` → `openPath`. If the file is already open it is focused; otherwise a load job
  starts, with the grouping set on the buffer.
- `Openings.begin` registers a placeholder surface `fizzy.loading:<path>` (keyword `document`). It
  takes the slot of a preview it replaces, or the tab a restored session kept; otherwise it adds
  itself to `pane(grouping)`. When the load lands, the placeholder's tab id is swapped for the
  document's, which is selected or drawn once offscreen (`warmIn`). The placeholder lingers two
  frames for the cross-fade.
- **Previews** are the app's (`Editor.preview_docs`): one per grouping, replaced by the next preview
  open, kept by an edit, a drag or Keep Open.
- **Explorer:** Open uses the current grouping, Open to the Side a new one, and a single click
  previews. Rows carried out are the view drag, and an unopened file dropped on a pane opens there
  (`paneDrop` → `openHere`).

**Closing.** `rawCloseFileID` first takes a snapshot of a pane its last document leaves, then
removes the tab from every pane, unregisters the surface and frees the document. An emptied pane
slides shut, drawn from that snapshot, and is culled (`rebuildWorkspaces`). The last pane never
goes. Culling calls every plugin's `removeCanvasPane(grouping)`, which pixi uses.

**Empty.** The sole pane, empty, draws the home page: the logo, New File, Open Folder (not on web),
Open Files into the active pane. A pane in a split, empty, draws an empty card.

**Persistence.**
- `panes.zon` (the workbench's install dir, native only) holds the DockLayout tree, one `Pane N`
  per leaf, and nothing else.
- Each pane's documents are the app's: `layout.zon` assignments under `Pane N`.
- On launch `rebuildWorkspaces` reopens them into their panes, and the placeholders take the kept
  slots.
- The selected tab per pane and the active pane are not saved.

**Coupling.** `Editor.workbench` is referenced across `Editor.zig`, `Entry.zig`, `Openings.zig`,
`Keybinds.zig`, Demo, WebFileIo, DocumentIo, UnsavedClose, CommandPalette and the explorer.
`kind_slot` is what keeps documents in panes (`Layout.slotted`, `ViewDrag.mapTargets`, `place`,
`canFloat`). `pane_cards` gives each pane Main's card when there are two or more. There are no
split commands: splits come from Open to the Side, go-to-definition's side, and edge drops.

**Tests that touch it** (`tests/integration.zig`): `:1897`, `:2075`, `:2392`, `:2671`, `:2921`,
`:3514`, `:3951`, `:3992`, `:4043`, `:5799`, and `:5823`, which imports the workbench's
`Workspace` (tab gap and insert index). Nothing tests `Openings`, previews, `rebuildWorkspaces` or
`panes.zon`.

**What this settles for step 2:**
- **A workspace's id is a grouping.** `documentGrouping` keeps its meaning. A move now sets it,
  which ends the drift. Grouping 0 means the active workspace, as documented.
- **Document drawing stays the surface's draw** (`drawDocSurface`) inside the workspace's canvas,
  so owners see the same `bindDocumentToPane` and `drawDocument` calls as now.
- **A workspace that goes calls `removeCanvasPane`** for every plugin, as a culled pane does.
- **Placeholders, previews, `warmIn`, the close flow and the home page** move into the workspace
  unchanged in behaviour. The tab strip, close, status slot, context menu, drag, gap and anchor
  (`workbench.tab:<path>`, kept for demos) are drawn by the app.
- **The active workspace is the app's** (`State`), and `activeDoc` reads it.
- **A workspace's selection is saved,** which the panes never did.

## SDK

**What the workspaces need is there already.** A workspace draws its tabs from what the host has
for every open document:
- the owner's `isDirty`, `isDocumentSaving` and `documentTitle` (`Plugin.VTable`);
- `Host.documentIsPreview`;
- the host's close flow, with its save prompt, through the owner's `closeDocument`.

Which workspace a document opens in is the grouping it already carries (`documentGrouping`,
`setDocumentGrouping`, `Host.openFile(.grouping)`), now a workspace's id. So the app's workspaces
(steps 2 to 5) land with no SDK change. Retiring names that no longer fit (`grouping` →
`workspace`, `bindDocumentToPane`'s pane, `kind_slot`) waits for a bump that has a reason of its
own.

**One bump, when two views of one document land:**
- **The view being drawn.** A document's draw is told which view it is drawing (its workspace's
  id), so an owner can keep a cursor, a selection or a zoom per view. Those that don't show the same
  state in both views. dvui's own state (scroll, a text field) is per view without it, since each
  workspace draws under its own id.
- **The background field** on `Surface` (above).
- **The renames**, once the old names have no users.

## Steps (each its own PR, `Part of #260`)

1. **Map the workbench's document path** — how a pane draws a document today (`Workspace.drawCanvas`,
   `bindDocumentToPane`, the canvas and its handle, the home page, previews, `Openings`
   placeholders) — into the plan, so step 2 draws documents the same way with nothing lost. No SDK
   change.
2. **Workspaces as views.** Behind `FIZZY_WORKSPACES=1` at first:
   - fizzy registers `fizzy.workspace.<n>` for each workbench pane, drawing that pane
     (`Workbench.drawPane`), titled by its selected document;
   - Main shows `fizzy.workspace.0` in place of `workbench.workspaces`;
   - a new pane (Open to the Side, go-to-definition's side, an edge drop) is a new workspace in a
     split of the place its anchor is in (`Region.splitOn`), not a `DockLayout` leaf;
   - an emptied workspace other than the last is removed and its place closed;
   - "the sole pane" becomes "the only workspace".
3. **Documents through the app.** `openFile` puts a document into the active workspace, and close
   and select go through the app. The drop rules above apply. The workbench stops seating documents
   in its panes (`rebuildWorkspaces`). Its home page becomes the empty state of Main's workspace.
4. **Saved layouts.** `layout.zon` keeps the workspaces (documents, selection) and which place holds
   each. On first load, a `panes.zon` tree becomes the app's split of Main: one workspace per pane,
   its documents in order. Then `panes.zon` is deleted. An older fizzy reads past the new fields
   (`ignore_unknown_fields`), as it does floats.
5. **Floats.** A tab is torn off over the desktop, or dropped on its own workspace's middle, into a
   new float's workspace. An emptied workspace closes its place. A float closing moves its documents
   into the main window's workspace.
6. **Remove the copy.** Delete the workbench's `DockLayout` panes, `Workspace.zig`'s strip and drop
   handling, the groupings, the `workbench.workspaces` surface and `kind_slot`. Update
   `app/layout/SPLITS.md`, `docs/PLUGINS.md` and the example apps' shapes, which get workspaces from
   the framework.
7. **Two views of one document, and the SDK bump** (above): "Open in New Workspace", the view a
   document is drawn for, the background field, the renames.
8. **New windows** (above): `fizzy.newWindow` on ⌘N, New Document on ⌘D, and both on the home
   page, New Window first.

Dialogs routed to the window asking (above) don't depend on any of these, and can land first.

## Answered

- **The picker** lists a workspace by its selected document's title, as a float's title does.
- **Documents in two workspaces:** allowed, as two views of one document (above).
- **App shapes with no workspace place** (fizzyedit/example-app's) have no default workspace. It is placed only
  where a place's keywords match a workspace's.
