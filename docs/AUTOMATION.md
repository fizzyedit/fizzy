# Demo automation

Fizzy can play demos of itself: the real app, driven by recorded or scripted input, that a
viewer can pause, take over, rewind and resume. The same demo plays in the desktop app and in the
browser, at any window size, so a demo can be embedded in a web page and play live there.

```
 Script (high level)  ──builds──▶  Tape (data: ZON or binary)  ◀──writes──  a recorder (future)
                                       │
                                  Sequencer          std-only: what happens, when, a frame at a time
                                       │ Sink
                                    Player           dvui: tape input → dvui events; transport; interrupts
                                       │ Stage
                                  Editor.Demo        fizzy: what a keyframe *is*; the user's session
```

Everything above the `Stage` line knows nothing about fizzy. `Tape`, `Sequencer` and `Script` are
the `tape` library (`sdk/tape/`): std-only, no window, shipped with the SDK so a plugin can
author a demo too. The `Player` and its overlay are host framework (`app/automation/`); an app
built on fizzy gets them by filling in a `Stage`. `src/editor/Demo.zig` is fizzy's stage and
`src/editor/demos/` its bundled demos. Where this is going: `docs/AUTOMATION_PLAN.md`.

## Playing one

| Where | How |
|---|---|
| Command palette | **Demo: A Tour of Fizzy**, **Demo: Markdown, Previewed as You Type**; **Demo: Play / Pause**, **Demo: Restart**, **Demo: Stop** |
| Menu | Help › Take the Tour |
| Desktop | `FIZZY_DEMO=tour fizzy` plays from launch (how a screen recording is made) |
| Web | `?demo=tour` plays a bundled demo; `?demo=<url>.zon` (or `.tape`) fetches a tape and plays it. Add `&storage=<name>` to an embed so it keeps its own settings and layout |

While a demo plays:

- **A click, tap, scroll or key pauses it.** A pointer event goes on to do what the person meant;
  the first key is only taken as "stop". Real pointer *motion* is ignored — the tape owns the
  pointer while it plays.
- **Play resumes it.** If the person did anything to the app while it was paused, the demo first
  replays to where it was, so it carries on from its own state rather than from whatever was left
  behind.
- **The transport bar** (bottom; it fades while playing until the pointer comes near) has chapter
  back / play-pause / chapter forward, the time, a scrubber with chapter ticks, and close.
  Scrubbing backwards rewinds; forwards fast-forwards.
- **Nothing is persisted.** The stage sets the user's session aside when a demo loads (project
  folder, open documents, layout as on disk, plugin settings) and gives it back when it is
  stopped. A demo refuses to start over unsaved changes. Its files live in memory
  (`demo://<name>`), so it never touches disk, and its folder never enters Recents.

## How it works

**A tape is keyframes and deltas.** A `keyframe` op puts the app into a state declared outright —
these files, these open, this layout, these settings — and every other op is a small delta on what
is there: glide the pointer onto a target, press, release, scroll, a key chord, typed text, a
command, a wait. Any moment of a demo is "the last keyframe, plus the ops since", which is the
whole of how a demo rewinds: cut to the keyframe, then replay the ops to the moment with animation
off. A replay costs a frame per op rather than per millisecond, and those frames are never shown.

**Seeking is silent.** The app runs its frame through `Player.frames`, which, while a seek is
catching up, runs the frame again and again inside one displayed frame — each run laid out and
never presented — until the seek lands or a budget of 8 ms of wall time is spent; the displayed
frame shows where the catch-up got to. On a backend with an `unseen` switch (the web's), the runs
draw nothing: the player marks each one (`core.FrameTarget.setUnseen`, read through the shared
window by every image), the backend drops its draws to the window, the frame target, frosts and
cross-fades leave themselves out, and one more run, drawn, ends the displayed frame. Elsewhere
each run is drawn over the last, and the last is shown. A seek within a scene lands in
the frame it was asked in; one across a long recording spreads over a few displayed frames, and
only a seek that takes longer than 150 ms says "Catching up…". `zig build bench-replay`
(ReleaseFast, the text editor's widget over a 400-line file): a frame costs about 0.9 ms, so
replaying a three-minute recording — 281 frames — takes 31 displayed frames where it took 281.

**Snapshots make the way back short.** While the tape drives, at calm moments — nothing gliding
or typing, nothing held, the app idle — the player asks the stage for the app's model: once a
scene has settled after its keyframe, at every chapter, and every 3 s of demo time. A seek back
goes to the nearest one before the moment and replays only from there, the app put back in place
rather than cut to its keyframe and reloaded. Fizzy's snapshot holds the demo's files as saved,
each open document's state from its owner (`captureDocumentState`: contents, caret, scroll),
which is active, the explorer and its open folders, every plugin's settings, and focus; restoring
one closes what was opened since and puts the rest back where it sits. It is restored only into
the scene it came from with its documents still open — otherwise the player tries the snapshot
before it, and a seek forward simply carries on — and taken only while nothing is loading and the
palette is shut. **The scrubber seeks as it is dragged**, not only when let go: with a snapshot
every few seconds, each move replays a second or two of demo and lands in the frame it was made.
`zig build bench-replay` (ReleaseFast): 32 random seeks across a three-minute recording land in
2.5 ms on average and 5.3 ms at worst from snapshots, against 76 ms and 225 ms from the keyframe.

**A demo that does not replay exactly is caught.** Each snapshot keeps a fingerprint of the
model (`Stage.fingerprint`: documents' `documentFingerprint`, which is active, the explorer, the
files); a replay that reaches the same moment again compares, and a mismatch is logged ("did not
reach what playing did") and counted (`Player.mismatches`) — an unawaited load or an unnamed
target, found rather than carried.

**The app's clock follows the demo while it catches up.** Each silent run begins at the demo
moment of the next thing the tape does (`Sequencer.nextAt`), so a press and its release are as
far apart, and timers and debounces fire, as they did live. That leaves the app's clock ahead of
the wall; fizzy's backends add the difference to their clock (`clock_ahead_ns`), so dvui's stays
monotonic, and the transport bar, which answers the viewer, runs on the wall (`Player.wallNs`).

**A glide replayed in one frame still passes along its path**, a point per 16 ms of demo time as
live play would draw, so whatever it crosses sees the pointer pass: a text field it leaves
forgets its click count, rather than reading the next click on it as a double-click.

**Demo time is not wall time.** A `wait` holds the clock until the app catches up (a file still
loading, a pane still opening); every targeted action waits for its target first. A slow machine
therefore plays the same demo slower, never a different demo. Only waits slow it, though: between
them a frame's wall time is all demo time, however long the frame took, so a browser that drops to
a few frames a second plays the demo at its pace, choppily, rather than in slow motion. (The first
frame after a pause counts as a frame, not the pause; and a gap past a second — a hidden tab draws
nothing — counts as a second.)

**Demo time never runs ahead of what has been applied.** The sequencer yields — ends the frame —
after any op the app must draw before the next can land: a button, a key, a command, a keyframe,
the end of a glide (so a widget that only appears on hover has appeared before the click). After a
hitch, the ops it skipped over still land a frame each.

**Typing is a keystroke at a time.** One character per text event, `\n` as Enter and `\t` as Tab,
so the editor closes brackets, steps over closers and auto-indents exactly as it does for a
person. Keystrokes are spaced unevenly, like a person's, but as a function of the text alone, so
every replay types the same bytes on the same frames.

**Ops aim at anchors, never at pixels.** A target is a `dvui.tag` name plus a point in its rect
(fractions, then an offset in natural pixels). Widgets publish names through `core.anchor.mark`,
which costs nothing unless someone asked for anchors this frame (`core.anchor.want`: the player
while a demo is loaded, the live driver while a live tape plays). dvui keeps tags on the shared
window, so a plugin dylib's anchors are visible to the app.

**The overlay is a function of time.** The synthetic pointer and its click ripple (none until the
tape first uses it after a keyframe; it goes away while the tape types, as a desktop's does, and
comes back when it moves), the keys pressed (each with its chord from the user's own keymap),
captions and chapters are all read from the tape at the current moment, so a seek shows exactly
what live play did. Its cards are the app's floating surface — frosted at the dialog style (blur, opacity, lift,
detail, refraction), with its corners and shadow — and open and close on a menu's curves at the
user's motion settings, timed in demo time.

## Anchors fizzy publishes

| Name | What |
|---|---|
| `workbench.file:<abs path>` | an explorer row (a file or a folder) |
| `workbench.tab:<abs path>` | a document's tab |
| `text.editor:<abs path>` | a text document's editor |
| `text.end:<abs path>` | where typing at the end of a text document begins, just after its last character |
| `text.body:<abs path>` | what of a text document's text is in view, out to its longest line |
| `text.preview:<abs path>` | a text document's preview pane, while it shows |
| `text.preview.raw:<abs path>`, `.split:`, `.preview:` | the markdown Raw / Split / Preview pill |
| `fizzy.palette` | the command palette's text field |
| `fizzy.rail:<view id>` | a sidebar rail icon (`fizzy.rail:workbench.files` is the explorer's; `catalog.files_icon`) |
| `fizzy.palette.row:<command id or abs path>` | a palette row |
| `fizzy.menu:<title>` | a menu-bar menu (the in-app bar; macOS uses the native one) |
| `fizzy.command:<command id>` | a menu row that runs a command |
| `region:<name>` | a layout region (`Main`, `Panel`, …) |

A demo's files live under its keyframe's `root`, so a path is `demo://tour/src/main.zig`.
`src/editor/demos/catalog.zig` has helpers (`catalog.file(s, "src/main.zig")`) that build these.

To make something new targetable, mark it where it is drawn:

```zig
core.anchor.mark(button.data(), "myplugin.thing:{s}", .{name});
```

## Writing a demo

A bundled demo is a Zig file in `src/editor/demos/` with `pub fn build(s: *Script) !void`, listed
in `catalog.zig`. It then has a command, a `FIZZY_DEMO` name and a `?demo=` name.

```zig
pub fn build(s: *Script) !void {
    try s.keyframe(.{
        .root = "demo://tour",
        .files = &.{ .{ .path = "src/main.zig", .text = main_zig } },
        // Settings the script depends on, whatever the viewer has chosen.
        .settings = &.{ .{ .owner = "text", .key = "auto_close_brackets", .value = "true" } },
    });
    try s.chapter("Editing");
    try s.caption("Brackets close themselves.", .{});
    try s.click(.{ .tag = catalog.files_icon }, .{});                    // the explorer, from the rail
    try s.click(.{ .tag = try catalog.file(s, "src") }, .{});            // waits for the row
    try s.click(.{ .tag = try catalog.file(s, "src/main.zig") }, .{});
    try s.click(.{ .tag = catalog.files_icon }, .{});                    // and away again
    try s.click(.{ .tag = try catalog.end(s, "src/main.zig") }, .{});   // where typing goes on
    try s.typeText("\npub fn greet() void {\nreturn;", .{});
    try s.command("fizzy.commandPalette");                               // pill shows its chord
    try s.waitFor(catalog.palette, .{});
    try s.typeText("toggle explorer", .{});
    try s.key("enter");
}
```

`Script` keeps a pen (`s.t`) and moves it at an unhurried person's pace (`Script.Pace`: an 800 ms
glide, a hover before the press, a beat after each action, 12 characters a second). `pause`,
`caption(.., .{ .hold = true })` and every option's `ms` adjust it. A caption shows for as long as
it takes to read (`Script.readingMs`) unless given `ms`.

A caption that narrates what the pointer does is a **callout beside the action**, where the viewer
is looking: next to what the pointer is aimed at while it shows (or `.near`, an anchor), to its
right, below, left or above — the first that covers none of it, the pointer, the other things the
pointer goes to in the caption's time, or what `.clear` names (what the viewer is meant to be
watching). It glides along as the pointer moves on. So write one caption per action rather than
one over several. For typing, `catalog.aboutWriting(s, "README.md")` puts the callout beside where
the words go, clear of them and of the preview.

Everything else gathers at the demo's **home** — `s.home`, an anchor (fizzy's demos:
`catalog.documents`, the documents' place): captions with no pointer action in their time, and
the keys and commands the demo presses. They **stack** there, near the foot of it, the newest
lowest and the older pushed up, each fading on its own time. `.place = .middle` makes a caption a
title card in the middle of the home view instead, for a demo's opening and close.

Captions at home stack with one another; any other caption begins alone — a callout or a title
card ends the captions still showing, so they close as it opens rather than competing with it.

A keyframe starts with the explorer put away (`.layout = .focused`), so the editor has the room;
a demo opens it from the rail when it is about to use it and puts it away after —
`catalog.openFile(s, "README.md")` does all three.

Things that bite:

- **The editor pairs brackets and quotes.** Type code the way a person would — `{` then Enter
  gives you the closing `}` on its own line, so don't type it again. A run of backticks or quotes
  pairs badly; leave code fences out of typed text or put them in the keyframe's file.
- **Click where the typing goes**: `catalog.end(s, "src/main.zig")` (`text.end:`) is just after
  the file's last character, so the pointer goes where the words will appear.
- **Use commands for shortcuts** (`s.command("fizzy.toggleExplorer")`) rather than `s.key` with
  a chord: a command runs whatever the user has bound it to (and on macOS the native menu owns
  most chords), and the pill still shows the chord.
- **Quick open does not see a mounted folder** (its index walks the local disk, and is off on the
  web), so a demo opens files from the explorer.

## The tape format

A tape is plain data (`sdk/tape/Tape.zig`) with two forms that hold exactly the same thing: ZON
to read and write by hand, and a binary form for anything long (below). What a script builds is
what `Tape.write` emits and `Tape.parse` reads. `docs/demos/hello.zon` is a complete hand-written
one.

```zig
.{
    .name = "hello",                 // short id: the mount demo://hello, the web's ?demo=
    .title = "Hello from a tape",
    .keyframes = .{ .{
        .root = "demo://hello",
        .files = .{ .{ .path = "hello.md", .text = "# Hello\n" } },
        .open = .{"hello.md"},       // the last one is active
        .layout = .focused,          // .keep | .reset | .focused (default; fizzy: no panel, explorer away)
        .settings = .{ .{ .owner = "markdown", .key = "default_md_view", .value = ".split" } },
    } },
    .chapters = .{ .{ .at = 0, .title = "Hello" } },
    .home = "region:Main",           // where popups about no one thing gather; empty: the window
    .captions = .{ .{ .at = 300, .ms = 5200, .title = "Hi", .text = "…", .place = .middle } },
    .ops = .{                        // ordered by .at; the first is a keyframe at 0
        .{ .at = 0, .do = .{ .keyframe = 0 } },
        .{ .at = 0, .do = .{ .wait = .{ .until = .idle } } },
        .{ .at = 0, .do = .{ .wait = .{ .until = .{ .shown = "text.editor:demo://hello/hello.md" }, .timeout = 10000 } } },
        .{ .at = 4400, .ms = 900, .do = .{ .move = .{ .tag = "text.end:demo://hello/hello.md" } } },
        .{ .at = 5460, .do = .{ .press = .left } },     // .left | .right | .middle
        .{ .at = 5570, .do = .{ .release = .left } },
        .{ .at = 6000, .ms = 3600, .do = .{ .type = "\n- written by a tape\n" } },
        .{ .at = 10400, .do = .{ .key = "mod+a" } },    // the keymap's spelling; mod is ⌘ or Ctrl
        .{ .at = 11000, .do = .{ .command = .{ .id = "fizzy.toggleExplorer" } } },
        .{ .at = 11200, .do = .{ .command = .{ .id = "text.goToLine", .args = ".{ .line = 1 }" } } },
        .{ .at = 11500, .do = .{ .scroll = .{ .y = -3 } } },
    },
}
```

| Op | Meaning |
|---|---|
| `keyframe: i` | Cut to `keyframes[i]`. Seeks replay from the last one before the moment. |
| `move: Target` | Glide the pointer onto `tag` (empty: the window) at `x`,`y` (fractions) + `dx`,`dy` (natural px) over `ms`. |
| `press` / `release` | A pointer button where the pointer is. |
| `scroll: .{ .x, .y }` | Wheel ticks at the pointer; positive scrolls up / right. |
| `key: "chord"` | Press and release a chord (`enter`, `escape`, `mod+s`, `mod+k mod+c`). |
| `type: "text"` | Type over `ms`; `\n` is Enter, `\t` is Tab. |
| `command: .{ .id, .args }` | Run a command: with no `args`, as its menu row or shortcut would (one that needs arguments asks for them); with `args`, ZON keyed by its parameters (`".{ .line = 1 }"`), as the palette does once they are given. A script writes `s.command(id)` or `s.commandWith(id, .{ .line = 1 })`. |
| `wait: .{ .until, .timeout }` | Hold demo time until `.idle`, `.shown = "tag"` or `.gone = "tag"`; give up after `timeout` ms of wall time. |

Key chords are the app's spelling: the `tape` library carries them as text, and a `Tape.Check`
the app passes to `parse`, `load` and `Script` says which it accepts (fizzy's is
`automation.Input.check`, the keymap's parser).

### The binary form (`.tape`)

`tape.binary` writes and reads the same `Tape` as a few flat tables: a 60-byte header (`FZTP`,
a version, the counts), a string table that holds each distinct string once (anchors repeat
constantly), then fixed-size records — ops, keyframes and their files, captions, chapters —
that point into it by index. Reading is one bounds-checked pass that builds the `Tape` in a
single arena, with every offset, index and enum checked: a damaged or truncated file is an
error, never a crash. It is lossless both ways, so a tape converts freely between the forms.

`Tape.load(gpa, bytes, check)` takes either form and tells them apart by the magic. How they
compare (`zig build bench-tape -Doptimize=ReleaseFast`; recording-shaped tapes, best of seven):

| Ops | ZON size | ZON load | Binary size | Binary load |
|---:|---:|---:|---:|---:|
| 200 (a scripted demo) | 31 KB | 0.34 ms | 8 KB | 0.012 ms |
| 10,000 (about ten minutes recorded) | 1.5 MB | 17 ms | 353 KB | 0.29 ms |
| 100,000 | 15 MB | 179 ms | 3.4 MB | 3.9 ms |

## Live tapes

A demo cuts to a keyframe and plays at its authored pace. A **live tape** plays on the app as it
is, a step at a time: a plugin's test, a macro, a scripted tutorial, anything that drives fizzy
the way a person does. `automation.LiveDriver` plays one, beside the `Player` and sharing its
dvui input (`automation.Input`):

```zig
var s: automation.Script = .init(gpa, "rename", "");
s.check = automation.Input.check;
s.check.live = true;                                   // no keyframe, anywhere
try s.click(.{ .tag = "workbench.file:/work/notes.md" }, .{});   // waits for it to be drawn
try s.waitFor("text.editor:/work/notes.md", .{});
try s.commandWith("text.goToLine", .{ .line = 12 });
try s.typeText("// here\n", .{});
try editor.demo.playLive(try s.finish());               // fizzy: refused while a demo is loaded
```

- **Pacing:** authored times are ignored. Each op is applied once the stage is idle, and the
  sequencer still yields after anything the app must draw before the next op lands.
- **Waits** hold as in a demo. One that gives up **stops** the tape, with
  `outcome = .{ .timed_out = <op> }`: a live tape that has lost its place is stopped, not
  carried on blind.
- **A person's input** (click, tap, scroll, key, text) stops it,
  `outcome = .{ .interrupted = <first op not applied> }`, and goes on to do what they meant.
- **Going back** is not the driver's: there are no keyframes or snapshots, so it is undo, through
  the commands the tape ran.
- A tape with a keyframe is refused (`error.KeyframeInLiveTape`), and so is a second tape while
  one plays (`error.Busy`).

The overlay does not draw a live tape's pointer yet.

## For apps built on fizzy

`app.automation` is framework: an app fills in a `Stage` (`begin`, `end`, `keyframe`, `idle`,
`command`, `chordFor`, `commandTitle`, `fastForward`), calls `player.frame()` first thing in its
frame — before anything reads `dvui.events()` — and `automation.overlay.draw(&player)` last, and
runs the frame itself through the player, from inside its `dvui.App` frame function:

```zig
pub fn appFrame() !dvui.App.Result {
    const win = dvui.currentWindow();
    return player.frames(win, frameOnce, automation.Player.backendClock(win));
}
```

`backendClock` finds a `clock_ahead_ns: i128` on the backend, which its `nanoTime` adds to the
wall (fizzy's SDL and web backends have one); a backend without it still seeks silently, only
with timers waiting for the wall. An `unseen: bool` on the backend, dropping draws to the window
while it is set, spares the GPU the runs nobody sees (see above). The player's `frame` runs before
anything that asks whether a run is seen — in fizzy, first in `frameOnce`, ahead of the frame
target. Snapshots are four more, optional, `Stage` hooks — `capture`,
`restore`, `release`, `fingerprint` — over whatever the app's model is; without them seeks go back
to keyframes. `src/editor/Demo.zig` and `src/Entry.zig` are the worked example.

## Tests

- `zig build test` — `fizzy-tape-tests` (`sdk/tape/root.zig`): the tape format and its ZON
  round-trip; the binary form (field-for-field round-trip, conversion both ways, every
  truncation and thousands of random bit flips refused cleanly); the script's pacing; and the
  sequencer's rules — waits and timeouts, a frame per op, keystroke-at-a-time typing, a glide
  replayed in one frame passing along its path, and that rewinding to a keyframe and replaying
  lands exactly where live play did.
- `zig build bench-tape` — saving and loading, ZON against binary (prints timings).
- `zig build bench-replay` — a seek across recordings of a minute to ten, silent against shown a
  frame at a time; and scrubbing — random seeks — from snapshots against from the keyframe
  (prints timings).
- `zig build test-integration` — `demo:` tests in `tests/integration.zig`: the player against a
  headless window with a tagged button and the text plugin's editor (plays as a person's input,
  rewinds to exactly the live state, a seek lands in the frame that asked for it with the app's
  clock following the demo, a seek back restores the nearest snapshot instead of the keyframe and
  the moments after it match the first pass, the scrubber follows as it is dragged, a replay that
  differs is caught, a person's click pauses it and is undone on resume, real motion cannot move
  the tape's pointer), every bundled demo builds, and `docs/demos/hello.zon` parses and
  round-trips.
- `zig build test` — `fizzy-text-doc-state-tests` (`plugins/text/src/doc_state.zig`): a text
  document's snapshot state round-trips, a backwards selection with it, and damaged state is
  refused.

## Next

- **Recording.** The format is ready for it: a recorder captures real dvui events between
  keyframes, maps each pointer event to the anchor under it (`dvui.tagGet` over the frame's tags)
  so the recording is size-independent, and writes the tape in its binary form.
- **Quick open over mounts** — the palette's index should come from `core.FileTable`, which
  already lists mounts; then a demo can show it.
- **A `demos` build step** that writes every bundled demo as a tape, for a site to host.
