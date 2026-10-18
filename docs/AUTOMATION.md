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
author a demo too. The `Player`, the live driver and their input are the `replay` library
(`sdk/replay/`: dvui and `tape`, nothing of fizzy's), which any dvui app can drive by filling in
a `Stage`; fizzy's glass overlay and its plugin service are host framework (`app/automation/`). `src/editor/Demo.zig` is fizzy's stage and
`src/editor/demos/` its bundled demos. Where this is going: `plans/AUTOMATION_PLAN.md`.

## Playing one

| Where | How |
|---|---|
| Command palette | **Demo: A Tour of Fizzy**, **Demo: Markdown, Previewed as You Type**; **Demo: Play / Pause**, **Demo: Restart**, **Demo: Stop** |
| Menu | Help › Take the Tour |
| Desktop | `FIZZY_DEMO=tour fizzy` plays from launch (how a screen recording is made); `FIZZY_DEMO=<file>.zon` (or `.tape`) plays a tape file, a live one through the live driver |
| Web | `?demo=tour` plays a bundled demo; `?demo=<url>.zon` (or `.tape`) fetches a tape and plays it. Add `&storage=<name>` to an embed so it keeps its own settings and layout |

**Hosted tapes.** `zig build demos` (part of `zig build web`) writes every tape fizzy hosts into
`zig-out/web/demos/`: the bundled demos built from their scripts, and each hand-written tape in
`docs/demos/`, all in the deflated binary form, with an `index.json` naming each one's title,
length and whether it is live (`scripts/demos.zig`). Each copy of the app on the site serves the
tapes built from its own commit, so a page embeds `fizzyed.it/app/?demo=demos/hello.tape` and
the tape always matches the app that plays it. A new tape for the site is a `.zon` in
`docs/demos/`, and nothing else. A bundled demo plays without fetching anything (`?demo=tour`);
its tape is for a player that is not that build of fizzy. The scripts in `src/editor/demos/` need
only `tape`, so the tool builds them on the host; one that needs more breaks `zig build demos`.

While a demo plays:

- **A click, tap, scroll or key pauses it.** A pointer event goes on to do what the person meant;
  the first key is only taken as "stop". Real pointer *motion* is ignored — the tape owns the
  pointer while it plays.
- **Play resumes it.** If the person did anything to the app while it was paused, the demo first
  replays to where it was, so it carries on from its own state rather than from whatever was left
  behind.
- **The transport bar** (bottom) has chapter back / play-pause / chapter forward, the time, a
  scrubber with chapter ticks, and close. Scrubbing backwards rewinds; forwards fast-forwards.
  While the demo plays it hides into a dome on the window's bottom edge (`app/dome.zig`, the
  same one a document's history transport hides into), filling with the demo's progress. The
  pointer held on the dome (or a press on it) grows the bar back out; it goes back soon after
  the pointer leaves it. Paused or ended it stays out, unless its chevron tab sent it in.
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
| `fizzy.dialog.close` | the close button in a dialog's header |
| `fizzy.dialog:<title>:<label>` | a button in a dialog: its footer's, or one drawn with `core.dialogs.bodyButton` (`fizzy.dialog:About Fizzy:Close`) |
| `history.line:<abs path>` | a document's transport line, from its first stop to its last, while the transport shows: `x` is that fraction of its history (`x = 0` before any change) |
| `history.back:<abs path>`, `history.forward:<abs path>` | its undo and redo buttons |
| `fizzy.window:main` | the main window |
| `fizzy.window:dialog:<title>`, `fizzy.window:float:<title>`, `fizzy.window:menu` | an OS window of the app's own: a dialog's, a popped-out view's, a menu's (a second of the same name gets `:2`) |
| `region:<name>` | a layout region (`Main`, `Panel`, …) |
| `picker:<view id>` | a view's card in a place's picker |
| `picker.mode:one`, `picker.mode:many` | the picker's Single / Multiple |
| `picker.action:split`, `:clear`, `:defaults`, `:remove` | the picker's actions, each only while it can be pressed (a dimmed Clear has no name) |
| `picker.split:vertical`, `picker.split:horizontal` | the rows of the picker's Split menu |

A demo's files live under its keyframe's `root`, so a path is `demo://tour/src/main.zig`.
`src/editor/demos/catalog.zig` has helpers (`catalog.file(s, "src/main.zig")`) that build these.

To make something new targetable, mark it where it is drawn:

```zig
core.anchor.mark(button.data(), "myplugin.thing:{s}", .{name});
```

A dialog with buttons of its own (`hide_footer`) draws them with `core.dialogs.bodyButton`, which names
each for its dialog's title and its label.

**Other windows.** Where dialogs, menus and popped-out views are OS windows of their own (macOS),
each still draws in fizzy's one frame — a dialog over the main window's part of it, a float in a
band of its own past the window's edge — and its OS window shows that part. A tape's points are in
that frame, so a click aimed at a dialog's button lands in the dialog's window. A window's tag aims
into it: `.{ .tag = "fizzy.window:dialog:Unsaved changes", .dx = 40, .dy = 60 }` is 40 by 60
natural pixels from its top left.

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
| `step: .{ .file, .effect, .motion }` | Apply one step of a document's history to `file` of the keyframe before it, shown being made over `ms`: `effect` is what the step did and `motion` how it was made (optional), both in the file's `owner`'s encoding. Steps land together, with no frame between them, so a seek across an hour of drawing is one call. |

Key chords are the app's spelling: the `tape` library carries them as text, and a `Tape.Check`
the app passes to `parse`, `load` and `Script` says which it accepts (fizzy's is
`automation.Input.check`, the keymap's parser).

**Steps** record what a document became, not the input that made it, so they replay exactly at
any window size and in any layout (`plans/RECORDING_PLAN.md`). A file a step changes names the
plugin that applies it and its encoding: `.{ .path = "sprite.pixi", .text = <the file's bytes>,
.owner = "pixi", .format = 1 }`. A file's `text` is its bytes as on disk, a binary document's
included (ZON escapes them). `Check.steps` says whose steps, in which format, the app can apply;
without it a tape with steps is refused (`error.StepsUnsupported`), since a step nobody applied
would play a document that never changes. The app applies them through its stage
(`Stage.step`).

Fizzy applies them: a tape's steps are checked against the plugins loaded (`Demo.stepsCheck`: the
owner loaded, writing that step format) and played on the demo stage into the documents its
keyframe opened. A document's own history becomes such a tape with `fizzy.tracks.export` (while
tracks record: by default, the History setting's "Record document history"): its file as the track began, then its
steps, pauses past 2 s played as 0.6 s unless `real_time`. `fizzy.demo.playTape` plays it.

A link plays one on the web: `fizzyed.it/app?tape=<url>` fetches the tape, loads each plugin its
documents belong to from the store if the page has not (for the visit: not installed, not
remembered, nothing asked), and plays it in a tab of its own with nothing else in view
(`TapeTabs.openWhenReady`). On the desktop, `Demo: Play a Tape…` opens one the same way, and says
which plugin a tape needs when it is not loaded.

### The binary form (`.tape`)

`tape.binary` writes and reads the same `Tape` as a few flat tables: a header (`FZTP`, a
version, the counts), a string table that holds each distinct string once (anchors repeat
constantly), a blob table of the steps' effects and motion, then fixed-size records — ops,
keyframes and their files, captions, chapters — that point into them by index. With
`.{ .deflate = true }` everything after the version and flags is one zlib stream, for a tape that
is sent somewhere. Reading is one bounds-checked pass that builds the `Tape` in a
single arena, with every offset, index and enum checked: a damaged or truncated file is an
error, never a crash. It is lossless both ways, so a tape converts freely between the forms.

`Tape.load(gpa, bytes, check)` takes either form and tells them apart by the magic. How they
compare (`zig build bench-tape -Doptimize=ReleaseFast`; recording-shaped tapes, best of seven):

| Ops | ZON size | ZON load | Binary size | Binary load |
|---:|---:|---:|---:|---:|
| 200 (a scripted demo) | 31 KB | 0.34 ms | 8 KB | 0.012 ms |
| 10,000 (about ten minutes recorded) | 1.5 MB | 17 ms | 353 KB | 0.29 ms |
| 100,000 | 15 MB | 179 ms | 3.4 MB | 3.9 ms |

A recording of drawing, plain against deflated (steps shaped as a pixi stroke's effect, with the
pen's path; the same bench, ReleaseFast):

| Steps | Plain | Plain load | Deflated | Deflated write | Deflated load |
|---:|---:|---:|---:|---:|---:|
| 2,000 (about an hour of drawing) | 275 KB | 0.04 ms | 100 KB | 8.7 ms | 0.86 ms |
| 20,000 | 2.7 MB | 0.25 ms | 873 KB | 87 ms | 7.9 ms |

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

### What a plugin sees

The `automation` service (`sdk.services.automation`) is how a plugin plays a live tape, and reads
the app back:

- **`snapshot`**: what is on screen as ZON, a node a line (`replay.Snapshot`): role, name, tag,
  rect (physical pixels of the frame) and the node it sits in. The app's OS windows come first,
  each `.role = "window"` with its title and tag, the main window first; a node in any other
  window says which (`.window = 2`, by index). Dialogs are in it: dvui shows them after it stops
  capturing the frame, so each dialog captures its own widgets in a frame being taken
  (`Snapshot.scopeBegin`, in `core.dialogs.dialogWindow`), and the snapshot is written at the very
  end of the frame (`Demo.frameEnd`).
- **`capture(window)`**: a window as fizzy drew it, its raw premultiplied pixels read back from
  what it drew it into, on screen or not: the main window for `""`, a window by its tag, or every
  window laid out as they lie round the main one for `"*"`. Empty when no window has that tag.
  Nothing is encoded in fizzy's frame (one read back, one copy); the agent's bridge crops, scales
  and encodes in its own process (`plans/AGENTS_PLAN.md`, "Senses").

Naming the windows costs nothing unless someone is looking: a snapshot, a picture or anchors
asked for this frame.

## A run that ends in a verdict

```sh
FIZZY_VERDICT=out/verdict.zon FIZZY_DEMO=tests/tapes/soak.zon \
  FIZZY_VERDICT_EXPECT=tests/tapes/soak.expect.zon fizzy --profile out/profile
```

`FIZZY_VERDICT` makes a run of the real app one that plays its tape (`FIZZY_DEMO`: a bundled demo,
or a `.zon`/`.tape` file, a demo through the `Player` or a live tape through the `LiveDriver`) to
the end, quits, and exits 1 when anything went wrong (`src/editor/verdict.zig`):

- the tape did not start or did not end (a person's input paused or stopped it, or
  `Expect.timeout_s` ran out), or lost its place (a wait gave up);
- a replay did not reach what playing did (`Player.mismatches`);
- SDL logged an error, launch to exit (the native backend's health counters, `SDLBackend.health`);
- the debug allocator found memory still allocated at exit (Debug builds);
- the backend's counters break what the run expects: by default the OS windows alive at the end
  are as many as at the start, and the main window was presented to. `FIZZY_VERDICT_EXPECT` names
  a ZON file of `verdict.Expect` for more: per-frame GPU budgets (draws, passes, target switches),
  SDL warnings, AppKit's windows, a p99 frame time for a run on known hardware.

The verdict, with the counters as the tape began and as it ended, goes to the `FIZZY_VERDICT` path as
ZON for CI to keep. Relative paths are taken from where fizzy was launched. A verdict run needs a
profile of its own (`--profile` or `FIZZY_PROFILE`) and refuses to start without one (exit 2): it
quits by itself, and must never touch a person's settings, plugins, lock or socket.

`tests/tapes/soak.zon` is the first soak tape: a view floated out of the main window (an OS window
where floats are: macOS, or `FIZZY_POPOUT=1`) and put back three times, full screen in and out
twice, the About dialog over the frost closed from its header twice, and the palette. CI plays it
on Linux under Xvfb with Mesa's lavapipe (`ci.yml`, "Verdict run").

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
- `zig build test-integration` — `fizzy-demo-tests` (`tests/demos.zig`): every bundled demo, in
  the whole editor through fizzy's own stage. It plays to the end with no wait giving up and no
  replay mismatched, then seeks to seeded random moments and to each chapter, and each lands on
  the fingerprint straight play reached there — a property test of every document owner's
  snapshot state and of putting it back.
- `zig build test` — `fizzy-text-doc-state-tests` (`plugins/text/src/doc_state.zig`): a text
  document's snapshot state round-trips, a backwards selection with it, and damaged state is
  refused.

## Next

- **Recording.** The format is ready for it: a recorder captures real dvui events between
  keyframes, maps each pointer event to the anchor under it (`dvui.tagGet` over the frame's tags)
  so the recording is size-independent, and writes the tape in its binary form.
- **Quick open over mounts** — the palette's index should come from `core.FileTable`, which
  already lists mounts; then a demo can show it.
