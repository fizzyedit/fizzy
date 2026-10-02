# Record and playback for dvui apps — the plan

Where demo automation goes next: from fizzy's demo player (`docs/AUTOMATION.md`) to a few small
libraries any dvui app can take — **record** what a person does, **serialize** it fast, and **play
it back** with seeking as smooth as a video's: a scrubber that follows the finger, chapter jumps
that fast-forward rather than stutter, a viewer who can take over and hand back at any moment.
Game engines do this for replays; immediate mode makes it easier than it is for them, if we lean
into it.

## What there is, and what it costs

- `app/automation/` today: a `Tape` (keyframes, input ops aimed at anchors, captions, chapters;
  ZON), a std-only `Sequencer`, a `Script` builder, a dvui `Player`, fizzy's `Stage`, an overlay.
- **Seeking is a visible replay.** A seek cuts to the last authored keyframe and replays every op
  since, one frame each, drawn. A minute back is about a second of the app twitching through it;
  scrubbing is a seek on release, not a live follow.
- **Keyframes are authored only, and heavy.** Cutting to one closes every document, remounts the
  files, resets the layout and reopens — async loads and all.
- **ZON only.** Fine to author; slow and allocation-heavy for long recordings.
- **No recorder**, and everything a tape aims at has to be marked by hand (`core.anchor.mark`).

## Principles

1. **A tape is inputs, never UI.** Immediate mode re-derives the whole UI every frame from two
   things: the app's model (documents, settings, layout) and dvui's per-widget store (scroll
   offsets, focus, carets, animations, text-layout caches). We record and replay only what goes
   *into* that function — input events and time.
2. **Snapshot the model, rebuild the rest.** A snapshot is the app's model as data — the same
   declarative shape as a keyframe — taken through the app's `Stage`. dvui's widget store is never
   saved: after a restore it is rebuilt by running frames until dvui stops asking for more
   (`refresh` → no extra frames needed). Immediate mode guarantees it converges; that is the
   point of it. The one piece of dvui state worth carrying is **focus** (a widget id), because it
   routes keys.
3. **Time is an input.** dvui already takes the frame's time from the app (`Window.begin(time_ns)`).
   During playback the player supplies it — demo time — so animations, caret blink and timers are
   deterministic, and run fast when playback does.
4. **Frames are cheap if nobody looks.** A frame that is laid out but not presented costs little;
   seeking spends many of them inside one displayed frame.
5. **Name things by what they are, not where.** No pixel positions: an anchor and a point inside it.

## The libraries

Three small packages, layered so each is usable without the next.

| Package | Depends on | Holds |
|---|---|---|
| `tape` | `std` | `Tape` and its ops, `Target`; the ZON and binary codecs; the `Sequencer`; the `Script` builder. Unit-tested without a window. |
| `replay` | `tape`, `dvui` | `Recorder`, `Player` (injection, interruption, the seek driver), `Anchors` (resolution and marking), the `Stage` seam, the virtual clock and silent-frame driver. |
| `replay-ui` | `replay` | An optional plain overlay: pointer, keys, captions, transport. Fizzy keeps its own (the glass one in `app/automation/overlay.zig`) on the same hooks. |

In fizzy: `tape` goes in `sdk/` (plugins author their own demos with `Script`, and a plugin
contributes a demo as tape bytes — see the plugin-demo proposal), `replay` stays in `app/`
(host only), anchors stay in `core` (plugins mark their widgets). Each is also a standalone dvui
package.

## Aiming without positions

A target is a name and a point inside what it names: `{ anchor, x, y }` as fractions of its rect,
plus an offset in points. What a name can be, tried in this order:

1. **An explicit anchor** — `dvui.tag` / `core.anchor.mark` (`workbench.file:<path>`).
2. **An accessible name** — dvui widgets already carry an AccessKit `role` and `label` every frame
   (a button "Save", a tab "README.md"). `role:label`, made unique by its nearest anchored or
   labelled ancestor: free, semantic, survives any layout, and rewards accessible apps.
3. **A widget id** — stable within one build only; recorded for convenience, flagged on load.
4. **The window** — a fraction of it; the last resort, flagged.

An anchor can define its own space: a canvas publishes the sprite's on-screen rect, so a fraction
is a pixel of the art whatever the zoom or pan (a pixi stroke).

## Recording

- **Where:** right after `Window.begin`, before any widget sees the frame — the same point the
  player injects at. The recorder reads `dvui.events()` and appends; nothing is allocated per event
  (a growing arena of fixed-size records).
- **Resolving a pointer event:** the innermost visible named thing under the point in the topmost
  subwindow — tags first, then accessible names — and the point as a fraction of it. The event's
  own `target_widgetId` breaks ties.
- **Coalescing:** text events into `type` spans with their timing; motion into glides — kept as a
  simplified path (Ramer–Douglas–Peucker) only where it matters (drags, strokes), else just the
  arrival; hovers that dwell (a tooltip opened) as `move` plus a hold.
- **Bookends:** a snapshot when recording starts (the tape's first keyframe), and the user's
  chapters and captions added afterwards in an editor, or by `Script` over the recording.

## Serialization

- **ZON** stays the authoring and interchange format, exactly as now.
- **Binary** (`.tape`) for anything long: a header, a string table (anchors, text), and the ops as
  struct-of-arrays with varint time deltas. Loading is a bounds-checked view over the bytes — no
  parse, no allocation — and writing is append-only, so a recorder streams straight to it.
- Both are lossless, and convert both ways (a `tape` CLI step, and `zig build demos` for the site).

## Seeking, scrubbing and chapters

The heart of it. Three pieces, then three behaviours built from them.

- **Silent frames.** An app frame run without presenting: `Window.begin` → the app's frame →
  `Window.end`, with the backend's draw calls going nowhere and no swap. Needs one hook in the app
  loop (fizzy: the SDL and web backends' frame functions); offered upstream to dvui as a window
  option.
- **Snapshots at runtime.** On the first pass through a demo the player takes a snapshot at every
  chapter and every few seconds of demo time (`Stage.capture`), keeping them in memory. Restoring
  one (`Stage.restore`) applies it in place — replace a document's text, set its selection,
  reopen only what differs — never a close-everything-and-reload. Then a few silent frames to
  settle.
- **A frame budget.** Catching up runs silent frames until a budget (say 6 ms) is spent, then
  presents and carries on next frame. A seek never blocks the app.

With those:

- **Scrubbing follows the finger.** Each frame the knob moves: the nearest snapshot at or before it
  (if the way back or forward is shorter from there), then silent catch-up to the knob within the
  budget. With snapshots every few seconds and silent frames at a millisecond or two, most moves
  land in the same frame; a big jump lands within a few, the last good frame held meanwhile. Like
  scrubbing a video, not replaying one.
- **Chapter forward is a visible fast-forward.** Play the span at a rate `r = clamp(distance /
  700 ms, 4, 24)`, frames drawn: the pointer zips, text streams in, and the app's animations run
  `r` times faster too (the motion speed is published scaled, and the virtual clock agrees). Past
  what fits in under a second: silent catch-up to a second before the chapter, then the visible
  last second.
- **Back is a crossfade.** Freeze the current frame into a texture (the glass already reads the
  frame back), restore and catch up silently, then fade from the frozen frame to the live one over
  ~180 ms — or wipe it away as liquid.
- **Resuming after someone took over** is the same restore-and-catch-up, so it is seamless too.

**Determinism**, checked rather than hoped for: on the first pass each snapshot records a hash of
the model; a seek that lands on a snapshot's time compares, and a mismatch is a bug in the tape
(an unnamed target, an unawaited load) — reported in debug builds and by the tests.

## Performance targets

Measured by a `zig build bench-replay` step on fizzy's tour, Debug and ReleaseFast:

| What | Target |
|---|---|
| Recording overhead | < 0.05 ms a frame |
| Silent frame (fizzy, a document open) | < 2 ms |
| Restore a snapshot, settled | < 5 ms for a demo-sized model |
| Scrub to any point of a two-minute demo | in the same frame for moves within a snapshot's span; < 100 ms worst |
| Load a 10-minute recording (binary) | < 1 ms |
| Anchors published while a demo runs | < 0.1 ms a frame |

## What it asks of dvui and fizzy

- **dvui:** a silent-frame option on `Window` (no draw, no swap); nothing else is required — time
  already comes from the app, and tags and accessible names already exist.
- **The app's `Stage`** grows `capture() Snapshot`, `restore(Snapshot)` (in place) and `settled()`;
  fizzy's implements them over its model (documents, layout, settings, explorer state).
- **The app loop** asks the player for the frame's time and for how many silent frames to run.

## Milestones

Each lands on its own and leaves the demos working.

1. **Split `tape` out**, std-only, into `sdk/`; add the binary codec and the benchmark step.
2. **Virtual clock and silent frames** in fizzy's loop; seeking catches up silently within a budget.
3. **Snapshots** (`Stage.capture`/`restore`) and the determinism hash; scrubbing follows the knob.
4. **Transitions:** visible fast-forward for chapter jumps, the crossfade back.
5. **The recorder**, with accessible-name anchors; Record / Stop in fizzy, saving ZON or binary.
6. **Plugin demos** (`registerDemo`, chapters with `requires`) and the first pixi demo.
7. **Standalone packages** for any dvui app, with a minimal example app.

## Open questions

- **Binary as well as ZON**, or ZON only with a faster loader? (The plan says both.)
- **How far to go on accessible names** — default for recording, or only behind explicit anchors?
- **Focus in snapshots** — carry the focused widget's id (same build, same session), or require a
  tape to re-establish focus after every keyframe?
- **Silent frames upstream** in dvui, or a fizzy-side wrapper first?
