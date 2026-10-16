# macOS glass, measured

What AppKit's glass and blur materials actually do, measured on macOS 26.5 (October 2026) with
throwaway AppKit programs over striped and solid windows, captured on screen with
`CGWindowListCreateImage`. Fizzy's glass (`backend/src/platform/macos/visual_effect_view.m`,
`core/gfx/glass_look.zig`) is built on these numbers. Re-measure before relying on them on a
newer macOS.

## `NSGlassEffectView`

- The public styles, Regular and Clear, are both **heavy frosts**: no refraction, in-window or
  behind-window.
- The private `_variant` (default 2) selects the look. Set it with the typed setter
  (`set_variant:` through `objc_msgSend`), not KVC: an unexpected value through KVC hit a Swift
  fatal error.

  | Variant | Look |
  |---|---|
  | 11 | clear, unblurred lens: magnifies toward the rim, ignores `tintColor` |
  | 2, 3, 4, 7–10 | frost, all identical |
  | 5 | slightly stronger frost |
  | 6 | bright frost with a strong rim |
  | 12 | dark |
  | 13 | no glass at all |

- Lensing works behind-window (the window server refracts the window beneath) and over a
  `CAMetalLayer`.
- `NSGlassEffectContainerView` merges its glass views with a liquid bridge, only **within one
  window**. The merge is a quadratic smooth-min: joins form below `spacing / 2`.
- A piece with `_interactionState` 1 never merges with its neighbours.
- `tintColor` cannot make glass opaque: at alpha 1 it only lightens a frost, and the lens ignores
  it.
- A glass view's `contentView` fill is not clipped to the glass and doesn't cover merge bridges.
- Two containers holding the same shapes at complementary alphas cross-fade materials smoothly
  with matching outlines. That is how fizzy blends lens → frost → heavy frost along the opacity
  slider.
- A `CALayer` mask (one radial `CAGradientLayer` per piece) on a container's layer fades its
  glass and keeps the merging.
- `_subduedState`, `_contentLensing`, `_adaptiveAppearance` and `_subvariant` do nothing to the
  lens. `_scrimState` 1 is a dark blurred scrim.

## No material is a plain blur

Every OS material pulls toward grey:
- **Frost (variant 2):** output ≈ `lerp(background, 117, 0.286 × share)`. A dark background is
  lifted (26 → 52), a light one darkened (243 → 207).
- **Vibrancy materials are worse.** The full-screen UI material maps 26–243 into 40–158.

So glass over fizzy's dark window colour reads lighter grey than the window. An alpha layer over
the frost can undo the pull at only one background.

**The neutral blur:** a `CABackdropLayer` (private) with `windowServerAware` and *only* a
`CAFilter` `gaussianBlur` keeps the mean unchanged. At radius 2, 4 and 6 it keeps 71%, 38% and
14% of a 14 pt checker. Fizzy's drag overlay uses it over the lens; the variant-2 frost is the
fallback.

`inputNormalizeEdges` on a mostly transparent image layer renders the clear parts black.

## Layering rules learned the hard way

- Colour *under* the lens is bent into a disc.
- Frost *over* the colour lifts its brightness.
- Vibrancy shows the desktop whatever is beneath it, so never leave it partly visible over an
  opaque colour.
- A mask on the layer AppKit *lends* a view that never called `setWantsLayer:YES` is silently
  dropped. The glass and the blur views need `wantsLayer`.
- Window-only captures (`screencapture -l`) render a glass window over black, with no backdrop.
  Judge a look on screen, over a real window.
