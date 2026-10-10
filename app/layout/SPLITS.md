# Splitting and moving views

What a user can do to the arrangement of an app's window at runtime, and the rules the
framework holds to while they do it. This is the contract: an app that declares regions gets
all of it without writing any of it, and a plugin that draws a surface never participates.

## Vocabulary

| Term | Meaning |
|---|---|
| **place** | A named area. Either declared by the shape (`Main`, `Panel`) or minted by a split (`Main/r1`). |
| **view** | The surface a place is currently showing. A place with tabs has one view and several surfaces. |
| **assignment** | The user's answer to "what goes here", per place. Overrides keyword matching. An empty assignment is an answer too: *nothing*, deliberately. |
| **origin** | The place that was split. Keeps its name, keywords and assignment. |
| **minted leaf** | The place a split creates. Empty, removable, and gone again when it collapses. |
| **float** | A place of the framework's own, `Float N`: a glass window over the layout holding the view floated into it (`Floats.zig`). |

Places, keywords and assignments are framework. `Main`, `Sidebar` and `Panel` are fizzy's own
shape (`src/editor/layout.zig`) and mean nothing here.

## The one rule

> **The edge you release on is where the dragged view ends up.**

Everything else follows from that sentence, including the case that is easy to get backwards.

| Release | Origin ends up | Minted leaf opens | The leaf holds |
|---|---|---|---|
| Middle of a *slot* (shows one) | the dest's view | — | the dragged view *(they trade)* |
| Middle of a *shelf* (shows many) | nothing back | — | the dragged view, added *(the rest stay)* |
| Middle of the *other half of its split*, carrying its last view | — | — | *(they join: one place, both views, as tabs)* |
| Edge of another place | untouched | that edge | the dragged view |
| Edge of its own place | that edge | the **opposite** edge | empty |
| Middle of its own place | loses the view (a place of several keeps the rest) | — | *(the view floats: a window of its own over the layout)* |

The join row is the undo of a split, reached the same way the split was: by carrying a view.
Only the two halves of one split join, and only when the view is the last one its place holds —
carried out of a place that keeps others it is just moving, and the middle means what it means
anywhere else. The split's origin is the half that stays, whichever way the drag went, since the
half a split minted is the one the tree can drop; it shows both views as tabs, because it now
holds two. Two places the shape declared are never a pair: neither may go.

The own-edge row is the one worth stating out loud. Dropping a view on its own right edge splits
that place and the view must finish on the right — so the *empty* leaf is what opens on the
left. Minting on the right instead would push the view to the left and the split would feel
mirrored.

A self-split also may not move the view onto the new leaf, even though that would put it on
the correct side. Remounting a surface into a fresh place tears down every widget inside it —
its scroll positions, sash sizes, what had focus — for a drop that was only meant to make room
beside it. (What a plugin keeps in its own state survives: fizzy's Workspace keeps its documents
and panes in the workbench, and floated or swapped it still has them.) The origin keeps the
view, and the mint side is what puts it under the pointer.

This table is `Drop.plan`, and it is about forty lines with no drawing and no state in it. The
drop zones and the release both read the same geometry (`Drop.kindAt` over
`core.widgets.DropZones`), which is the reason they cannot disagree.

## Feedback while dragging

A drag is a question ("where does this go?"). The answer is shown as the options, all at once,
and the view you are carrying — never as the view drawn in two places.

- **The app under a drag does not change.** The dragged surface is photographed once, at lift,
  from the draw its place was doing anyway (never a second `drawContents` in the same frame: that
  builds every widget under the place twice, and dvui reports a duplicate id for each of them),
  and a card of it rides the pointer. The place goes on drawing its view underneath: the drop
  zones are what changes, over a window that stays put.
- **The place under the pointer shows its drop zones.** All five of them — the middle and each
  edge — at once, and only there: moving to another place, its zones go as the new place's come
  in, so the one change on screen follows the pointer instead of covering the window in targets.
  They are the dialogs' frosted glass, the app's surface rounding, an even gap around each, and a
  faint icon saying what a drop there does: a pane opening on that side, or the middle's trade
  (one view), add (several) or join (the other half of a split). The one under the pointer
  lights. The middle of the place the view came from shows a window: dropping there floats the
  view (below). Where the view cannot float it is bare glass, and dropping there does nothing.
- **A long, skinny place shows them in a line.** Round the middle they are the size of pixi's
  tool wheel, and a place too narrow for that — the bottom panel, a narrow sidebar — would shrink
  every one to fit its short side. Where a line of them along the place keeps them markedly
  bigger (`DropZones.strip_gain`), that is what it shows: the place's two ends at the ends of the
  line, its other two sides either side of the middle, the trash past the end, each icon saying
  which edge it is. Settled, it is one shape or the other, each zone a bubble of its own. A place
  whose inside changes under the drop — a strip offering itself across its top — and so is given
  the other shape does not cut to it: its bubbles run together into one bar of glass and pull
  apart into the other shape, the glass's own merge doing the joining.
- **A join shows the place it leaves.** Aimed at, the two halves' zones step back and one lit
  pane of the same glass lies across both — the single place the drop will make, the divider
  between them gone under it.
- **Nothing is previewed in place.** No place poses the view as if it had landed, and none pulls
  back to make room: one copy of a view is easier to read than two, and the layout that answers
  the drop moves after it, with the easing every split and swap already has.
- **The zones split out of one pane of glass.** Arriving over a place, its zones come in as one
  solid frosted pane — five tiles that exactly fill it, square where they meet — which swells to
  size and then splits: the gaps open, the corners where the pieces met round off, and each
  piece's edge forms. Leaving, the pieces run back together and fade. Pieces never overlap
  (glass over glass would double its tint), they tile. The glass is `core.liquid_glass`: a drop's
  soft refraction and light at the rim, one smooth field with no crease at the corners. All of
  it runs at the app's motion level and speed, and never by opacity: a frost replaces what it
  covers, and a half-opaque one would show a see-through window's content through it.
- **A drag does not change the map it is read against.** The places, and where they are, are
  photographed at lift, exactly like the view is. A place can still move during a drag — a split
  easing shut, a window resized — and a hit-test read against the live layout would chase it.
  Frozen, it is a pure function of where the pointer is. The one part of it that is live is the
  float a view is carried out of: whether it covers what it lies over follows where the view is
  aimed (below).

## Where the view goes when a place is split

Whoever already holds the view keeps it, and the *empty* place is what moves out of the way.
This holds for both entry points:

- **Picker → Split → Vertical / Horizontal.** The existing view stays; an empty leaf opens
  beside it. The names describe the divider, not the layout axis — "Vertical" is a vertical
  bar, so the two panes sit side by side.
- **Drag onto an edge.** As the table above.

The rule keeps a split feeling like a division of something that already exists, rather than
a replacement of it by two new things.

A split lands as even halves with the sash out of the middle, measured from the place as it
stood when the drag began — the place the user was shown.

## A place a split made shuts when its last view leaves

Carry the last view out of a minted leaf and the leaf slides shut, its neighbour taking the
room back. The shape's own places do not: Main with nothing in it is still where Main is, and
a user who empties one expects to put something back. A minted leaf is not furniture — it was
a container for the view that has just been carried out of it, and leaving a blank rectangle
behind makes the user tidy up after their own drag.

The leaf a split *mints* is the exception, and is not the same case: it is empty because it is
the room being made, not room left over.

A place closing for good reaches nothing, not nearly nothing. Its card's inset folds away with
the last of its extent and the sash beside it closes with it, so the frame the leaf is finally
dropped moves nothing at all. Left whole, the two of them are some twenty-odd points that a
smooth close hands back in one step at the very end — which is the only part of it anyone sees.
A place merely *shut* keeps its sash: that is the handle you drag it back out by.

## Floating a view

Dropped on the middle of the place it was lifted from, a view floats: it leaves that place for a
glass window of its own over the layout, which grows out of the glass it was carried in. The
window is a place like any other — `Float 1`, `Float 2`, the smallest free number — so it has
everything a place has without anything written for it: the corner button the view is dragged out
by again, the drop zones, splits, the picker. A place of several views keeps the others.

- **What cannot float.** A view carried out of the picker (it has no place to float out of), a
  document (its place is the slot its plugin made for it), and a view already alone in a float
  nobody split — floating it again would only move it, which its header already does. For those
  the middle stays bare glass.
- **Where it opens.** At 60% of the place it left, never under 360×240 nor over 90% of the window,
  centred on where the view was and held 8pt inside the window; out of another float, a step down
  and right of that one (`float_rules.zig`, unit-tested).
- **A float covers what is under it.** A drag reads the floats as it reads the places — frozen at
  lift — and aims only at the topmost window under the pointer: a place a float covers is not
  reached through it, and over a float's header, its handle, nothing is aimed at. The float the
  view is carried out of covers only while it is firm (below).
- **A drop keeps out from under the floats.** A place's drop sits in the middle of the part of the
  place no float lies over — of the parts left clear, the one where it is biggest, and the largest
  of those — fitted there as a wheel or a strip as anywhere (`DropZones.uncovered`,
  `ViewDrag.zoneBounds`). A float lying over the middle of a place no longer hides its drop, so a
  view can be put exactly where it is meant to go, into the float or beside it. A float's own
  places have theirs inside it; a place floats lie all over has none. The zones, the release and
  the self-split all read that one rect. When the part left clear changes during a drag, the drop
  slides to its new middle and size on the glass, its bubbles running together on the way.
- **The float a view leaves is a ghost while the view is aimed elsewhere.** Carrying a view out of a
  float, the float fades to a faint, slightly blurred picture of itself once the view is aimed off
  it, and covers nothing: what it lies over shows through and can be aimed at, and is usually where
  the view is going. The drops of the places beneath it sit clear of it where there is room, as
  they do of every float (above) — but only while that leaves a drop three quarters or more of the
  size it would have with no ghost there (`ViewDrag.ghost_min_share`): squeezed smaller, or with nothing clear of it, a drop sits
  under the ghost at its whole size, and the view over it is aimed through the ghost at it. Either
  way it is the same firm or ghost, so no drop moves as the ghost comes and goes. Aimed back over
  the ghost, it firms up, live: the float again, covering what it lies over, with its own places'
  drops, so the view can go back in (its own middle, where it is alone, is no move), split it on an
  edge, or go to another of its places. It stays firm until the view is aimed off it, so its own
  middle can be reached wherever it lies. With every drop beneath clear of it, it firms the moment
  the view is over it. While a drop lies under it, it firms only for a rest over it of a quarter of
  a second (`ViewDrag.ghost_rest_ms`), off that drop or on its header: at once, it would firm as
  the view was carried across it to the drop, which could then never be reached. The header always
  counts — over a small ghost, a drop beneath at its whole size can leave nowhere else to rest. (A rest before it firmed, with
  every drop beneath it under it, was tried first: the drop beneath shut and slid away as the
  float's own opened in the same spot, and drops seemed to avoid floats only some of the time.)
  The ghost is a photograph of the float, taken from the frame at the lift, while
  the float itself goes on drawing its place clipped to nothing (its corner button holds the drag) —
  a view may draw in ways no alpha reaches, and none of it may show. Let go over nothing and the
  photograph comes back into focus, then the float takes over from it. Land the view elsewhere and
  the float comes back as it now is, fading in with its view drawn into a picture of itself, so that
  too fades whole — or, if that was its last view, its ghost fades the rest of the way and is gone,
  with no flight shut.
- **Moving and stacking.** A float moves by its header and resizes from its edges, no smaller than
  160×96. A press anywhere in it brings it to the front, as on an OS window.
- **Back again.** Dragged out by its corner button, a view lands like any other, and a float its
  last view leaves closes behind it. Closed from its header, its window's close button (or the
  picker's Remove), a float moves everything it holds back into the main window and loses
  nothing (`float_rules.goHome`): each view into the list of the place it floated out of when the
  user had arranged that place; let go where its keywords show it, which never freezes a place
  its keywords fill; and a view they would show nowhere — one merged in from elsewhere, a
  plugin's tools beside Files — into that place's list all the same, as a drop there writes it,
  or the first place of the main window's that shows several where that place is gone or holds
  something else. Every place a split of it made goes with it.
- **Remembered.** `layout.zon` keeps each float's window, its place in the stack and its home. One
  with nothing left to show is not brought back, and one saved on a bigger window comes back onto
  the window it opens in. A float remembers only where the user put it: a window that shrinks shows
  its floats held on screen, and gives them back their places when it grows.

A float is a window inside fizzy's own window for now. Taking one out into an OS window of its
own is the plan in `plans/POPOUT_WINDOWS_PLAN.md`.

## Edges and bands

Near an edge is 64pt, or 22% of that side, whichever is smaller (`DropZones.band`). The
fraction is what keeps a small pane usable: a fixed band on a 100pt place would leave no middle to aim at, and
swapping would be unreachable exactly where precision is hardest.

The place under the pointer is the *smallest* one containing it, so a document pane wins over
the main area it sits in. The one exception is the drag's own place: its edges outrank
anything nested inside, or a document filling it would make its edges unreachable.

A place only accepts what it can show. A shape place takes anything the user puts there; a
plugin's kind slot (a document pane) accepts only surfaces matching its keywords, so dropping
a log on the canvas lands on the main area instead of becoming a document tab. A document can be
carried before it is open — a file carried out of a tree, by the id its document will have, as
its file's icon in the drop — and goes only to a document's slot, whose own drop opens it.

## Removing a split

Carry the last view of one half onto the middle of the other (a join, above), carry it anywhere
else out of a minted half, or pick Remove. A minted leaf can be emptied and removed; a
shape-declared place can only be emptied. Removing
the last leaf collapses the branch and the origin becomes a whole place again, with its extent
and assignment untouched throughout — a split and its undo are symmetric.

## Where this lives

| File | Holds |
|---|---|
| `Drop.zig` | The rule. No drawing, no state, no allocator. |
| `ViewDrag.zig` | The gesture: drag state, hit-testing, the card, the drop zones over every place, and the assignment that lands. |
| `SplitTree.zig` | The tree: split, collapse, persistence links. Geometry-free. |
| `Region.zig` | Declaring a place and walking the tree to draw its leaves. |
| `Picker.zig` | The menu on a place: assign, clear, remove, split. |
| `Floats.zig` | The floats: their windows, landing, closing, stacking. |
| `float_rules.zig` | Where a float opens, what keeps it reachable, its name, where a closed float's views go. std-only, unit-tested. |

## Settled, and not to be re-litigated

Each of these was built and removed. The reasoning is the expensive part.

- **A facing edge is not a swap.** Treating the edge two places share as a swap gave the same
  gesture two meanings depending on neighbours the user cannot see. Every edge splits.
- **No four create-handles.** Permanent handles on a place's edges are chrome for a gesture
  that is already available by dragging.
- **No `reuse_parent` / `initInParent`.** Packing the leftover's contents into the split's
  grouping box put the sash on the wrong side and made it drag the opposite pane.
- **A leftover origin does not re-qualify its keywords.** It sits inside a grouping box whose
  prefix is its own word; qualifying again produced `main.main`, the grouping box kept the
  exact claim, and both sides of a split drew empty.
- **The dragged snapshot is never the destination's only content.** A swap must lay out the
  real view; blitting the card into the destination looked right for one frame and was wrong
  the moment anything resized.
