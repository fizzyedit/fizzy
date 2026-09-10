# Handoff: generalized screen transitions

**Goal.** One host-owned mechanism that cross-fades between any two "screens" in fizzy — center
providers, document tabs, store pages, sidebar views — using an offscreen render of the outgoing
screen. Plugins should get this for free: no plugin should have to know a transition is happening,
opt in, or draw anything differently.

Status: the technique is **built and confirmed working** for center providers. The red-rect
artifact is fixed (capture ID isolation + blit rect = `pic.r`). The host-owned `transition()`
helper is in place and `Editor.drawActiveCenter` uses it. What remains is deciding where else to
apply it.

---

## 1. Why transitions are needed at all

dvui sizes a widget from the **previous frame's min-size cache**. A widget id that did not exist
last frame has no entry, lays out at zero, and snaps to its real size on the next frame. Any screen
swap therefore has one frame of visibly wrong layout.

Two shapes of fix exist in the tree, and they are *not* interchangeable:

| | `core.anim.reveal` | `core.anim.transition` / `CrossFade` |
|---|---|---|
| what it does | hides the incoming subtree one frame, then fades it up | records the outgoing screen to a texture and fades that out over the incoming one |
| needs | nothing | backend render-target support |
| correct when | the pane's chrome is drawn **outside** the swap and stays put | the background is **part of** what changes |
| used by | document tabs, store detail pages | center providers |

`reveal` is not sufficient for center providers, and this is the whole reason `CrossFade` exists:
each provider paints its own pane. The workbench document canvas is square and full-bleed; the
homepage, the pixi pack-project window and the store detail page are rounded cards. Fading the
incoming one up from nothing exposes the window (and the explorer's fill) behind it, *and* the
corner shape changes mid-swap. An earlier attempt had the host hold a flat colour underneath
(`Reveal.fillBehind`, now removed) — rejected, because the host cannot know whether the screen it
is fading between has rounded corners.

## 2. What exists now

**`core/reveal.zig`** — pure phase machine (`hidden → fading → shown`, restart on key change).
4 unit tests, wired into `zig build test` as `fizzy-reveal-tests`.

**`core.anim.reveal(id, key, opts) Reveal`** (`core/anim.zig`) — maps those phases onto
`dvui.alpha` + a dvui animation. State lives in dvui's data store under `id`, which must be a
*stable* widget id (source-derived, not parent-derived — see §5).

**`core.anim.transition(state, opts) TransitionFrame`** — the host-owned entry point:

```zig
var frame = core.anim.transition(&region.transition, .{
    .key = current_key,
    .rect = rs.r,
    .draw_previous = drawOutgoing,   // called only on the swap frame
    .ctx = ctx,
});
defer frame.deinit();                // blits the fading snapshot
drawIncoming();
```

Swap detection, capture, ID isolation, and blit teardown all live inside. `CrossFade` remains the
low-level primitive `transition` drives.

**`core.anim.CrossFade`** — offscreen capture via `dvui.Picture`. `endCapture` keeps the texture
(not `Picture.deinit`, which would draw-and-destroy). Blit rect is `pic.r` (pixel-enlarged), and
the target is cleared explicitly after create. Capture runs under an isolate parent so its widget
ids cannot collide with the incoming tree.

**`Editor.drawActiveCenter`** — the one call site, now three lines around `transition`. Tracks
`center_prev_id` only so the outgoing provider can be looked up again by id (never cache the
pointer: a plugin can unload between frames).

## 3. Red-rect artifact + empty capture — fixed

Two related bugs showed up as "no fade, just a one-frame flash" plus (earlier) a red outline:

**Red outline.** Confirmed in the log as:

```
error(dvui): layout.zig:24 rectFor() got child … after expanded child
```

The capture packed an `expand = .both` child into the parent, then the incoming screen packed
another. `BasicLayout` `errorOutline`s the parent stack in red.

**Empty capture (no visible fade).** An isolate parent was tried to avoid that layout error. New
parent ⇒ new widget ids ⇒ the store page's `reveal` restarted at alpha 0 and min-size caches went
cold. The snapshot was transparent, so there was nothing to fade over the incoming settle frame.

**Fix.** `Editor.drawActiveCenter` hosts a **stable slot box** every frame. Capture and live draw
both parent there, so ids match last frame (`reveal` stays shown, min-sizes stay warm). After
capture, `after_capture` resets that box's pack state so the incoming screen is once again its
first child. Blit uses `pic.r`; the target is cleared explicitly after `Picture.start`.

## 4. Where else to apply

- **Document tabs / store pages** already use `reveal` and look fine (chrome stays outside the
  swap). Leave them unless a case shows the background changing mid-swap.
- **Sidebar view switches** and the **settings tree** are untouched. Apply `transition` only when
  the region's background is part of what changes — each capture costs one full offscreen draw of
  the region on the swap frame.
- **Plugin-facing surface.** Nothing is required of plugins today and that should stay true. The
  only plugin-visible seam worth considering is letting a provider *opt out* (a provider that
  animates its own entrance would fight the fade).

## 5. Traps already hit — don't re-learn these

- **Reveal/transition state must not be keyed to a parent-derived widget id.** `drawActiveCenter`
  runs under two different parents (bottom panel shown vs hidden), and the workspace box's id moves
  with layout. Keying to the parent restarts the fade on panel toggles and split changes — changes
  that are not content swaps. Use `dvui.Id.extendId(null, @src(), <sub-key>)` or a content hash.
- **Do not key a single-instance layout container by its content.** The store's detail header used
  `.id_extra = hashId(entry.id)`, which made it a new widget on every page switch → cold min-size
  cache → one frame of zero-height header. That was the original bug this whole thread started
  from; a stable id fixed it at the root. Per-item widgets in a *list* still want content ids
  (`dvui.animate` re-triggers on new ids).
- **Never leave a per-frame `dvui.log` call in a draw path.** One left in a task-list marker cost
  ~11 fps on pixi's README (per checkbox, per frame, allocating and appending to the Output panel).
- **Capture must keep last frame's widget ids.** Reparenting the capture (an isolate box) restarts
  `reveal` at alpha 0 and freezes min-size caches — the snapshot is empty and there is no fade.
  Use a stable slot parent, then reset that slot's pack state in `after_capture` so the incoming
  screen is not a second expanded child (`rectFor() got child after expanded child` → red outline).
- **dvui's testing backend has no render targets** (`textureCreateTarget` returns an error), so the
  capture path cannot be covered by `zig build test-integration`. The integration tests pin the
  *fallback*: a clean instant swap, nothing retained, and no draw of a provider that has been
  unregistered. The capture path itself needs on-screen verification (§6).

## 6. How to verify on screen

Synthetic clicks do not reach the app in this environment (raw `CGEvent` posts are ignored, and
`osascript`/System Events lacks assistive access), so a center swap cannot be driven by clicking
the store tab. What worked was a temporary self-driving hook in `Editor.drawActiveCenter`, gated on
an env var, that alternated `host.setActiveCenter` between `center_providers[0]` and `[1]` every
few seconds and called `dvui.refresh` each frame (an idle app renders no frames, so a frame-counted
toggle never fires). Lengthen `CrossFade.duration_ns` to ~1.5s while looking at it. **Remove the
hook before committing.**

Run a sandboxed instance so the user's own fizzy is untouched:

```bash
HOME=/tmp/fizzy-sandbox TMPDIR=/tmp/fzmd ./zig-out/arm64-macos/fizzy
```

`TMPDIR` must be short — the singleton's unix socket path has a 104-byte limit — and a distinct
`TMPDIR` is what gives the sandbox its own single-instance lock. Quit it with
`NSRunningApplication.terminate()` (fizzy ignores SIGTERM); screenshot with
`screencapture -o -x -l <windowid>`, finding the id via `CGWindowListCopyWindowInfo` with
`.optionAll` (an unfocused window is absent from `.optionOnScreenOnly`).

## 7. Related change in the same branch

`sdk.pane_layout.emptyStateCard` and the store's detail pane lost their `.margin = .{ .y = 10 }`.
Measured: the center region, the workspace vbox and the tab bar all start at the same y (72
physical / 36pt, directly under the titlebar), but every card sat 10pt lower — a visible step when
swapping between a document canvas and the homepage, and one more thing a transition cannot
compensate for. Cards are now flush at the top; their rounded top corners now meet the titlebar
directly. Confirmed working.
