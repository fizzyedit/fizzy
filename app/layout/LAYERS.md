# Layered regions and blur

Agreed design, not yet built. Written down because the decisions here were reached by
discarding a more obvious design, and the reasoning is the expensive part to re-derive.

## The rejected shape: `behind()` as a layout verb

The proposal was to replace `split()`'s `rest()` with `behind()`: content declared after a split
becomes a *layer beneath* the tray rather than the space beside it, rendered first, and therefore
available to blur. Trays stack, and it composes recursively.

The instinct is right and the naming is better than `rest()` — which is a leftover from two-child
panes and means only "whatever space is left", which is why shapes still branch and return early.
But it fails the test this whole layer is written against: **a layout author would have to reason
about render order to place a panel.** That is mechanism leaking into the app's vocabulary,
exactly like `Chooser.panel_chrome` did, and it is the thing that makes an API feel like someone
else's furniture.

There is also a concrete hazard. Reversing paint order does not reverse dvui's event routing,
which is front-to-back by widget order. Declaration order and hit-test order would stop agreeing,
and the bugs that produces ("the click went to the pane behind") are the hardest kind to see.

## The shape to build: blur is a property of a region

```zig
f.region(@src(), .{ .name = "Panel", .keywords = kw.ide.panel, .blur_behind = true });
```

The region says it wants what is beneath it blurred; the framework owns capture, ordering and
the blur itself. One field, no new verb, and nothing about rendering enters the layout vocabulary
— the app says *what*, the framework says *how*, the same split as keywords and `content`.

**Trigger: the layer behind actually has content beneath the tray.** Not "always blur" — a blur
over the window background is just a tinted rectangle, and it costs a capture every frame for
nothing. A scroll area already knows whether its content exceeds its rect, so the question is
answerable rather than guessed at.

## The behavioural change this needs

The main area must extend to the **bottom of the window, beneath the panel**, instead of being
cut short by it. Otherwise dragging the panel up reveals window background, not editor content,
and the effect is pointless.

Worth stating that this is independently correct: today, opening the panel *reflows* everything
above it. Under a layered model the content beneath keeps its geometry and is simply covered,
which is both cheaper and less visually disruptive. The blur is the reason to do it, not the
only justification.

## Scroll edges: the better first target

Fizzy's scroll areas draw an edge shadow to say "there is more content here". The shadow is a
*symbol* for occlusion. A hard-edged blur showing the actual content receding behind the boundary
is the thing itself, and reads correctly even with other content over it.

Do this one first:

- **Self-contained.** One widget. No layout change, no render-order question, no panel behaviour
  change, no ABI move.
- **The trigger is already there** — overflow is exactly what the scroll area computes to decide
  whether to draw the shadow it would replace.
- **It exercises the primitive from a plugin.** Pixi's layers/palette is the natural first
  consumer, and it is out-of-tree, so it tests the seam the way a third party would.

## Sequencing, and the one real risk

1. Bump dvui to a pin with blur.
2. Scroll-edge blur (contained; proves the primitive).
3. Main area extends under the panel.
4. `.blur_behind` on regions.

### Deliberately not rushed in front of 0.2.0 (2026-09-22)

`.blur_behind` is a field on a region declaration, so it moves the ABI fingerprint, which
raised the question of whether it had to land before the SDK's first release. It does not.
A new field with a default breaks no plugin's *source* — it costs a recompile and a patch
bump, which 0.2.x supports by design (the store keys binaries by fingerprint, so an older
build keeps matching its own SDK). Shipping the field ahead of steps 2 and 3 would instead
put a switch in the public API that the framework does not yet honour, which is worse than
adding it a version later. Sequence stands as written.

**The dvui bump is the risk item, and it should land on its own.** `sdk/build.zig.zon` is the
repo's only dvui pin and is deliberately absent from the root zon (CLAUDE.md explains why adding
a second pin cannot work). Fizzy has also diverged `PanedWidget`, and the layered work diverges
it further — so bumping dvui *and* changing the widget in one change makes a regression
unbisectable. Land the bump against a green tree first.

`SplitBox` and `core/split_layout.zig` are unaffected throughout: boundaries, persistence,
minimums and drag behaviour are orthogonal to who paints first.
