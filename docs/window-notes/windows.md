# Windows

These are behaviour notes for future conformance tests, written on 2026-10-20.
They summarize existing reports, not fresh runs. No app was launched for this pass.
Recorded findings below come from our macOS pitfalls, dependency descriptions and
patch prose; no SDL or GLFW implementation hunks were read. The foundation plan
(`plans/WINDOWING_FOUNDATION_PLAN.md`, private repo fizzyedit/plans)
provides test goals, not evidence that its proposed behaviour has shipped.
External citations throughout this directory are public OS documentation only.

Other areas: [events](events.md), [input](input.md), [clipboard](clipboard.md),
[drag and drop](dnd.md), [IME](ime.md), [displays](displays.md).

## Recorded findings

- On macOS under our frame loop, secondary-window show/close animations can leave
  a visible window behind. Verify that closing a menu or float removes it entirely.
- A non-activating secondary window can appear behind the key window. Changing its
  level does not immediately make an ordering query reliable. Check visible order
  after opening, raising, attaching and detaching, without stealing keyboard focus.
- Attaching a child changes its level and makes it follow the parent's movement
  and full-screen Space. A float with its own native frame must remain independently
  usable; keeping it permanently above the main window breaks that independence.
- Elevated palettes can enter a full-screen Space before the app receives the Space
  change. Test both entering full screen and swiping between Spaces.
- Borderless windows need explicit inclusion in the Window menu. Test selection
  from that menu separately from pointer activation.
- A closed macOS window that remains alive can be a lifetime problem rather than a
  stacking problem. Our pitfalls record missing autorelease pools as one cause.
- Transparency must survive GPU attachment and presentation, not just window
  creation. Our SDL patch prose (`backend/patches/sdl`, 0001) records the Cocoa Metal
  and Vulkan drivers as already handling a transparent window, and 0002 adds
  Windows D3D12 presentation through DirectComposition; neither is a run on
  hardware here. The Windows composition patch was
  cross-compiled but its header records no hardware verification. Do not call that
  a visual pass. Test opaque controls alongside partially transparent content.
- Wayland decorations include a shadow outside the visible frame. Placement,
  size limits and snapping must use the frame; shadow pixels must not become an
  opaque or fully clickable rectangle. Keep a narrow resize band around the frame.
- The Wayland reports cover hidden creation, hide/show and surface recreation:
  each must preserve framing. Maximizing or entering full screen removes the
  shadow insets; restoring brings them back. Tiling, compositor-selected floating
  sizes, bounds, fractional scale and server decorations still need desktop checks.

## Cases to pin

Open several floats, then a menu and dialog; record any capacity failure explicitly.
Close and reopen each kind. Preserve the distinction between a user close request
and completed removal. Check transparent content after resize and presentation-mode
changes. On Wayland, check popup placement against the parent's visible frame.

From the private foundation plan: it calls for decisions that can be tested without native windows.
Use those tests for geometry and lifecycle rules; they cannot establish visible
stacking, focus, compositor behaviour or Space transitions.
