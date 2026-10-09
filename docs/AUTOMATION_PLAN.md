# Record and playback for dvui apps — the plan

Where demo automation goes next: from fizzy's demo player (`docs/AUTOMATION.md`) to a few small
libraries any dvui app can take — **record** what a person does, **serialize** it fast, and **play
it back** with seeking as smooth as a video's: a scrubber that follows the finger, chapter jumps
that fast-forward rather than stutter, a viewer who can take over and hand back at any moment.
Game engines do this for replays; immediate mode makes it easier than it is for them, if we lean
into it.

## What there is, and what it costs

- The `tape` library (`sdk/tape/`, std-only): a `Tape` (keyframes, input ops aimed at anchors,
  captions, chapters; ZON and binary), the `Sequencer`, the `Script` builder, key spelling. The
  `replay` library (`sdk/replay/`, dvui and `tape` only): the `Player`, the `LiveDriver`, their
  dvui `Input`, the `Stage` seam, anchors. In `app/automation/`: fizzy's glass overlay and the
  `automation` service; in fizzy, its `Stage`.
- **Seeking replays silently, within a budget** (milestone 2), **from runtime snapshots**
  (milestone 3). A seek goes back to the nearest snapshot the player took while playing — a cut
  to the authored keyframe only when none will do — and replays the ops since, a frame each,
  unseen, up to 8 ms of them per displayed frame. A seek lands in the frame it was asked in, and
  the scrubber follows as it is dragged.
- **Keyframes are authored, and heavy** — cutting to one closes every document, remounts the files,
  resets the layout and reopens, async loads and all — so a seek cuts to one only when it crosses
  into another scene, or no snapshot of this one can be restored from where the app is.
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
   point of it. The one piece of dvui state worth carrying is **focus**, because it routes keys —
   by name in anything saved, by widget id only in memory (see Decisions).
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

In fizzy: `tape` is in `sdk/tape/` (plugins author their own demos with `Script`, and a plugin
contributes a demo as tape bytes — see the plugin-demo proposal). `replay` is in `sdk/replay/`
beside it: it ships with the SDK because its anchors are how plugins mark their widgets
(`core.anchor` re-exports `replay.anchor`), while the players are the host's to run. Its build
check (`fizzy-replay-tests`, under `test-integration`) compiles it with nothing but dvui and
`tape`, so it stays a library any dvui app can take. Each becomes a standalone package at
milestone 7.

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
- **Binary** (`.tape`, `tape.binary`) for anything long — built in milestone 1: a header, a string
  table holding each distinct string once (anchors repeat constantly), then fixed-size records
  that index into it. Fixed records rather than varint-packed columns: reading stays one pass
  with nothing to decode, and the form is already 4.5× smaller than ZON. Loading checks every
  offset, index and enum and builds the `Tape` in one arena, so the sequencer and player never
  know which form a tape came from. Measured (`zig build bench-tape`, ReleaseFast): ten minutes
  of recording (10k ops) loads in 0.3 ms against ZON's 17 ms, and encodes in 0.7 ms.
- If recordings outgrow that, the records are already fixed-size and aligned, so a zero-copy
  view over the bytes is a reader change, not a format change. The recorder keeps its records in
  memory as it goes and encodes on Stop.
- Both are lossless and convert both ways (`Tape.load` takes either; a `tape` CLI step, and
  `zig build demos` for the site, to come).

## Seeking, scrubbing and chapters

The heart of it. Three pieces, then three behaviours built from them.

- **Silent frames** (built, milestone 2). An app frame run without presenting: `Window.end`
  without the present, `Window.begin` again, the app's frame — inside the displayed frame, by
  `Player.frames` wrapping the app's frame function. Its draws land in the frame's texture and are
  dropped; nothing is swapped. Offered upstream to dvui as a window option once proven.
- **Snapshots at runtime** (built, milestone 3). On the first pass through a demo the player takes a snapshot at every
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
| Silent frame (fizzy, a document open) | < 2 ms — measured ~0.9 ms CPU (`bench-replay`: the text editor over a 400-line file, ReleaseFast) |
| Restore a snapshot, settled | < 5 ms for a demo-sized model |
| Scrub to any point of a two-minute demo | in the same frame for moves within a snapshot's span; < 100 ms worst — measured 2.5 ms mean, 5.3 ms worst (three-minute recording) |
| Load a 10-minute recording (binary) | < 1 ms — measured 0.3 ms (10k ops, ReleaseFast) |
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
   Done: `sdk/tape/`, `tape.binary`, `zig build bench-tape`; key chords are the app's text,
   checked by a `Tape.Check` it supplies, so the library needs no keymap.
2. **Virtual clock and silent frames** in fizzy's loop; seeking catches up silently within a budget.
   Done: `Player.frames` runs the app's frame again inside a displayed frame while a seek catches
   up, each run ended unseen; silent runs begin at the demo moment of what they apply
   (`Sequencer.nextAt`) and the backend's clock is moved on to match (`clock_ahead_ns`); a glide
   replayed in one frame passes along its path; `zig build bench-replay`. Two things turned out
   differently from the sketch above: a silent frame *does* draw — into the frame's texture,
   dropped unpresented — because icons and glass render into cached textures a frame without
   draws would leave blank (on a GPU the draws are queued, not waited on, so the cost is the
   CPU's layout, ~0.9 ms); and it lives in the player, wrapping the app's frame function, rather
   than in each backend's loop, so it serves the SDL, callback and web paths alike.
3. **Snapshots** (`Stage.capture`/`restore`) and the determinism hash; scrubbing follows the knob.
   Done: the player takes snapshots at calm moments (a scene settled, each chapter, every 3 s),
   seeks back through the nearest it can restore, and checks each moment's fingerprint again
   when a replay reaches it; the scrubber seeks as it is dragged. Fizzy's are in place — the
   demo's files, each document's state from its owner through three new optional SDK hooks
   (`captureDocumentState`, `restoreDocumentState`, `documentFingerprint`; `text` implements
   them), the explorer, settings, focus — and refuse a scene they did not come from. Measured
   (`bench-replay`, ReleaseFast): a random seek across a three-minute recording lands in 2.5 ms
   on average and 5.3 ms at worst, against 76 ms and 225 ms from the keyframe. Not yet: a heavy
   restore across scenes (it cuts to the keyframe), and snapshots of transient UI (the palette
   open, a menu) — moments with one are not taken.
4. **Transitions:** visible fast-forward for chapter jumps, the crossfade back.
5. **The recorder**, with accessible-name anchors; Record / Stop in fizzy, saving ZON or binary.
6. **Plugin demos** (`registerDemo`, chapters with `requires`) and the first pixi demo.
7. **Standalone packages** for any dvui app, with a minimal example app. In progress: `replay`
   is dvui and `tape` only (`sdk/replay/`, guarded by `fizzy-replay-tests`); any dvui app builds
   the pair against its own dvui with `replay.modules` from the SDK package
   (`sdk/replay_module.zig`); `replay.overlay` is the plain overlay (the pointer and its clicks),
   which fizzy's glass one draws its pointer with; a `Stage` for live tapes needs only `idle` and
   `command`; and fizzyedit/example-app's replay app (`zig build run-replay`) is a plain dvui app on
   dvui's own SDL3 backend that plays
   a live tape into its window and prints its snapshot. Left: `replay` and `tape` as packages of
   their own (their own `build.zig.zon`, outside the SDK tarball), and the plain overlay's
   captions and keys.

## Decisions

- **Binary as well as ZON.** ZON to author and read; binary for recordings and anything long. Both
  lossless, either loads through `Tape.load`.
- **Accessible names name click targets** a recorder can't find an explicit anchor for: an
  anchor first, then `role:label` from dvui's AccessKit data, then (flagged) a widget id or the
  window. Chapters and captions are written by people and need no such naming.
- **Focus: never a widget id in anything saved.** Widget ids hash the call site and parent chain,
  so a saved one goes stale with any change to the app or its layout. A tape re-establishes focus
  the way a person does — its ops click or tab into the editor after a keyframe — and a keyframe
  that needs focus as it opens names it by anchor (`focus = "text.editor:demo://tour/main.zig"`),
  which the stage resolves on the first frame the anchor is drawn. In-memory seek snapshots, which
  live only for one session of one build, may carry the focused widget id: they restore exactly
  and cost nothing to keep right.
- **Silent frames as a fizzy-side wrapper first** — no swap, wrapping the app's frame function
  (`Player.frames`) — offered to dvui as a `Window` option once it has proved itself.
