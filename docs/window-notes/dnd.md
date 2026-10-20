# Drag and drop

## Recorded findings and design goals

Our foundation plan (`plans/WINDOWING_FOUNDATION_PLAN.md`, private repo fizzyedit/plans) requires an internal view drag to continue across native app
windows, with targets chosen from visible, uncovered areas. It calls out release
onto a target, an empty place, a chooser and outside the current place as separate
cases. These are conformance goals; the plan's proposed lifecycle is not an observed
OS drag protocol. Keep internal view movement separate from importing external data. All of this
paragraph is from the private foundation plan; the shipped floating-view behaviour
is described in `app/layout/SPLITS.md` ("Floating a view").

The Wayland patch reports place popups relative to the parent's visible frame,
excluding its shadow. A shifted popup or drop affordance can therefore be a geometry
error even when the pointer's window-local position is correct.

## Documented external-drag behaviour

On macOS a destination registers accepted data types. Entry and movement negotiate
an operation; leaving ends that visit, and re-entry begins another. Releasing does
not guarantee acceptance: preparation or transfer can fail. The drag session supplies
its own pasteboard; assuming a particular named pasteboard can select the wrong data
([Apple dragging destinations](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/DragandDrop/Concepts/dragdestination.html)).

## Cases to pin

For internal drags, cover occluded targets, overlap, window crossings, release after
crossing, cancellation, closing a target mid-drag and release outside every window.
Check that the carried picture and pointer agree across display scales and that a
cancelled drag leaves no carry window or stale highlight.

For external drags, observe files, multiple files, text and unsupported data. Record
operation negotiation, cancellation and transfer failure separately from a successful
drop. Include leaving and returning before release, and dropping into a float.
External-drop behaviour on Windows and Linux remains unobserved in this note.
