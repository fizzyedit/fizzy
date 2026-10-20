# Displays and coordinates

## Recorded findings

Our macOS pitfalls identify the window's backing scale as the density to use during
full-screen changes, and report native size changes arriving before the normal size
event. Test the drawable against the actual window size at transition time rather
than assuming the last queued size remains current.

`plans/WINDOWING_FOUNDATION_PLAN.md` (private repo fizzyedit/plans) distinguishes desktop and window-local points from drawable
pixels and the app's layout coordinates. Its virtual areas for secondary windows
are layout constructs, not positions on a physical monitor. A conversion must retain
which window and display it belongs to. Mixed-DPI behaviour is identified as further
work in that plan, not established coverage. These coordinate distinctions are from
the private foundation plan only; a reader without access should treat them as
proposed, and check them against `app/layout` and `AGENTS.md`.

A display-sized overlay presented every frame was reported to halve drag frame rate
on macOS, while changing blur did not explain the cost. Check window count and
presented area alongside visual correctness; a small carry image should not require
an unnoticed desktop-sized presentation.

## Documented behaviour

macOS separates point-based layout from backing pixels; high-resolution displays
increase pixel density without requiring the same increase in logical dimensions
([Apple high-resolution overview](https://developer.apple.com/library/archive/documentation/GraphicsAnimation/Conceptual/HighResolutionOSX/Explained/Explained.html)).

## Cases to pin

Move a window and a carried view between displays with different scales. Check
pointer hit tests, drawable sharpness, popup anchoring and caret/candidate positioning.
Include monitors left of or above the primary display; desktop positions need not be
positive. Record full display bounds separately from the usable area around system UI.

Disconnect a display holding a float, reconnect it, change resolution and restore a
saved window position. Record reachability and placement instead of assuming stable
display ordering. These are pending observations, including Windows DPI changes and
Wayland fractional scaling. Headless compositor checks in the patch reports do not
establish those desktop outcomes.
