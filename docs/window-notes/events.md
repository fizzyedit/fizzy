# Events

## Recorded findings

Our macOS pitfalls record full-screen requests made during a frame re-entering the
frame loop. AppKit can request a picture of the destination state before the request
returns. A transition must not nest one application frame inside another.

The live-resize patch descriptions report different failure pictures:

- macOS 26: window geometry reached the screen before matching content, producing
  alternating stretched and correctly sized pictures. The recorded 120 Hz edge-drag
  run had 428 matching frames with the synchronized path. This is one reported run,
  not coverage of other Macs or display rates.
- macOS tiling: resize activity can stop without the expected end notification.
  A stopped drag must not leave the application permanently in resize mode.
- Windows: growing a transparent window exposed an undrawn strip; shrinking clipped
  the earlier picture. The report used an Arm VM and software rendering, so smooth
  hardware behaviour remains unverified. Moving without resizing should not be
  mistaken for a new content size.

Public contract: Windows enters a separate modal loop during interactive movement
or sizing. Normal outer-loop cadence alone is insufficient evidence of responsiveness
([WM_ENTERSIZEMOVE](https://learn.microsoft.com/en-us/windows/win32/winmsg/wm-entersizemove)).

## Cases to pin

Record the size used to draw and the size actually shown at each resize step.
Pause the pointer mid-drag, release it, tile, restore and repeat. Check both ongoing
animation while paused and return to idle afterward. A resize initiated by a frame
must not trigger a recursively nested frame.

Our foundation plan (`plans/WINDOWING_FOUNDATION_PLAN.md`, private repo fizzyedit/plans) treats a drag between app windows as one continuous interaction.
Crossing from the main window into a float should not create a spurious app-wide
pointer departure. Record destination identity as well as event order; a sequence
with correct coordinates but the wrong recipient is still wrong.

Apple describes event routing through application, window and responder objects
([Cocoa Event Handling Guide](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/Introduction/Introduction.html)).
Exact delivery under our custom loop still needs observation; do not infer it from
that general routing description or from a headless geometry test.
