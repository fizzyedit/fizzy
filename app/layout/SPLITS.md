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

Places, keywords and assignments are framework. `Main`, `Sidebar` and `Panel` are fizzy's own
shape (`src/editor/layout.zig`) and mean nothing here.

## The one rule

> **The edge you release on is where the dragged view ends up.**

Everything else follows from that sentence, including the case that is easy to get backwards.

| Release | Origin ends up | Minted leaf opens | The leaf holds |
|---|---|---|---|
| Middle of a *slot* (shows one) | the dest's view | — | the dragged view *(they trade)* |
| Middle of a *shelf* (shows many) | nothing back | — | the dragged view, added *(the rest stay)* |
| Edge of another place | untouched | that edge | the dragged view |
| Edge of its own place | that edge | the **opposite** edge | empty |
| Middle of its own place | — | — | *(nothing happens)* |

The third row is the one worth stating out loud. Dropping a view on its own right edge splits
that place and the view must finish on the right — so the *empty* leaf is what opens on the
left. Minting on the right instead would push the view to the left and the split would feel
mirrored.

A self-split also may not move the view onto the new leaf, even though that would put it on
the correct side. Remounting a surface into a fresh place tears down every widget inside it;
fizzy's Workspace would lose its open documents. The origin keeps the view, and the mint side
is what puts it under the pointer.

This table is `Drop.plan`, and it is about forty lines with no drawing and no state in it. The
preview and the release both call it, which is the reason they cannot disagree.

## Feedback while dragging

A drag is a question ("where does this go?") and the preview is the answer, shown as the
result rather than as a symbol for it.

- **The float is a photograph.** The dragged surface is captured once, at lift. The card
  following the pointer blits that texture, so no plugin is asked to draw twice in a frame.
- **A photograph is taken from the place's own draw.** The drag needs two stills — the lifted
  view for the card, the destination as it stood for the outgoing blur — and both come from the
  draw the place was going to do anyway, blitted back to the screen afterwards. Never a second
  `drawContents` in the same frame: that builds every widget under the place twice, and dvui
  reports a duplicate id for each one of them.
- **The float never hides.** It is the only thing saying what is being carried. Hiding it over
  a drop target made the gesture look cancelled.
- **A swap previews by swapping.** Both places remap their assignment for the frame and lay
  out the other's view for real, and each one's old pixels blur away over the new — the same
  crossfade a surface change uses anywhere else, so this is not a special motion to learn.
  The dissolve is on the preview's *linear* clock, not the pane's ease: the ease spends the
  blur (the first third) in a handful of frames and the rest is only alpha. The pose that is
  already opening stays the pose until it shuts — re-reading the pointer mid-slide restarted
  the clock every time the pointer brushed an edge.
- **A drop continues the preview.** A split that has already slid open does not ease the new
  leaf from zero (that snaps the leftover back to full). A swap that has already remapped
  does not start a second `transition` on release.
- **A split previews by splitting.** The place being split *pulls back* to the half it will
  keep — really laid out at that size, its contents reflowed, not a crop of the old picture —
  and the new pane slides open in the space it gave up, wearing the same card the real one
  will. Whatever is arriving draws live in it; a self-split's leaf is empty, so it hatches.
- **Over your own place, your content dims and stays.** The view is in your hand, not gone, so
  hatching your own place as a hole says the opposite of what dropping there does.
- **Leaving slides it shut.** The preview eases both directions at the same speed, so brushing
  past a place costs nothing and shows you it cost nothing.
- **A preview never remounts anything.** The pull-back is a margin on the place's *own* box.
  Putting the contents inside a sized child box would rebuild every widget in them, and a
  document pane would lose its scroll, selection and undo each time the pointer brushed an edge.
- **A drag does not change the map it is read against.** The places, and where they are, are
  photographed at lift, exactly like the view is. Two loops make this necessary: a preview draws
  the view it is about to land, and the panes *that* view declares would register as new, smaller
  places under the pointer; and a place previewing a split pulls back, moving the rect the pointer
  is aiming at. Either one flips the reading every frame — aim, preview, reading changes, preview
  closes, reading changes back — which is not a wobble to damp out but a loop to cut. Frozen, the
  hit-test is a pure function of where the pointer is.

## Where the view goes when a place is split

Whoever already holds the view keeps it, and the *empty* place is what moves out of the way.
This holds for both entry points:

- **Picker → Split → Vertical / Horizontal.** The existing view stays; an empty leaf opens
  beside it. The names describe the divider, not the layout axis — "Vertical" is a vertical
  bar, so the two panes sit side by side.
- **Drag onto an edge.** As the table above.

The rule keeps a split feeling like a division of something that already exists, rather than
a replacement of it by two new things.

A split lands where the preview showed it: even halves with the sash out of the middle, both
measured from the place as it stood *before* it pulled back. Measuring the live place instead
halves a half — the pane opens at a quarter of what the user was just shown.

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

## Edges and bands

Near an edge is 36pt, or 28% of the shorter side, whichever is smaller. The fraction is what
keeps a small pane usable: a fixed band on a 100pt place would leave no middle to aim at, and
swapping would be unreachable exactly where precision is hardest.

The place under the pointer is the *smallest* one containing it, so a document pane wins over
the main area it sits in. The one exception is the drag's own place: its edges outrank
anything nested inside, or a document filling it would make its edges unreachable.

A place only accepts what it can show. A shape place takes anything the user puts there; a
plugin's kind slot (a document pane) accepts only surfaces matching its keywords, so dropping
a log on the canvas lands on the main area instead of becoming a document tab.

## Removing a split

A minted leaf can be emptied and removed; a shape-declared place can only be emptied. Removing
the last leaf collapses the branch and the origin becomes a whole place again, with its extent
and assignment untouched throughout — a split and its undo are symmetric.

## Where this lives

| File | Holds |
|---|---|
| `Drop.zig` | The rule. No drawing, no state, no allocator. |
| `ViewDrag.zig` | The gesture: drag state, hit-testing, preview animation and painting, and the assignment that lands. |
| `SplitTree.zig` | The tree: split, collapse, persistence links. Geometry-free. |
| `Region.zig` | Declaring a place and walking the tree to draw its leaves. |
| `Picker.zig` | The menu on a place: assign, clear, remove, split. |

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
