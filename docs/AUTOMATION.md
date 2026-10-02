# Demo automation

Fizzy can play demos of itself: the real app, driven by recorded or scripted input, that a
viewer can pause, take over, rewind and resume. The same demo plays in the desktop app and in the
browser, at any window size, so a demo can be embedded in a web page and play live there.

```
 Script (high level)  ──builds──▶  Tape (data, ZON)  ◀──writes──  a recorder (future)
                                       │
                                  Sequencer          std-only: what happens, when, a frame at a time
                                       │ Sink
                                    Player           dvui: tape input → dvui events; transport; interrupts
                                       │ Stage
                                  Editor.Demo        fizzy: what a keyframe *is*; the user's session
```

Everything above the `Stage` line lives in `app/automation/` and knows nothing about fizzy; an
app built on fizzy gets it by filling in a `Stage`. `src/editor/Demo.zig` is fizzy's stage and
`src/editor/demos/` its bundled demos.

## Playing one

| Where | How |
|---|---|
| Command palette | **Demo: A Tour of Fizzy**, **Demo: Markdown, Previewed as You Type**; **Demo: Play / Pause**, **Demo: Restart**, **Demo: Stop** |
| Menu | Help › Take the Tour |
| Desktop | `FIZZY_DEMO=tour fizzy` plays from launch (how a screen recording is made) |
| Web | `?demo=tour` plays a bundled demo; `?demo=<url>.zon` fetches a tape and plays it. Add `&storage=<name>` to an embed so it keeps its own settings and layout |

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
off. A replay costs a frame per op rather than per millisecond, so seeking back a minute takes
about a second and shows as a quick replay.

**Demo time is not wall time.** A `wait` holds the clock until the app catches up (a file still
loading, a pane still opening); every targeted action waits for its target first. A slow machine
therefore plays the same demo slower, never a different demo.

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
which costs nothing unless a demo is loaded (`Player.frame` publishes whether anchors are wanted
each frame). dvui keeps tags on the shared window, so a plugin dylib's anchors are visible to the app.

**The overlay is a function of time.** The synthetic pointer and its click ripple (the pointer
goes away while the tape types, as a desktop's does, and comes back when it moves), the keystroke
pill (the key or command just pressed, with its chord from the user's own keymap), captions and
chapters are all read from the tape at the current moment, so a seek shows exactly what live play
did. Its cards are the app's floating surface — frosted at the dialog style (blur, opacity, lift,
detail, refraction), with its corners and shadow — and open and close on a menu's curves at the
user's motion settings, timed in demo time.

## Anchors fizzy publishes

| Name | What |
|---|---|
| `workbench.file:<abs path>` | an explorer row (a file or a folder) |
| `workbench.tab:<abs path>` | a document's tab |
| `text.editor:<abs path>` | a text document's editor |
| `text.end:<abs path>` | where typing at the end of a text document begins, just after its last character |
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
it takes to read (`Script.readingMs`) unless given `ms`, and the next caption takes over from it.
A caption sits over the view it is about — `.on`, an anchor, defaulting to `s.caption_on`
(fizzy's demos: `catalog.documents`, the documents' place) — a quarter, half or three quarters of
the way down it by `.place`, so on a large window it is beside the action rather than at the foot.

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

A tape is plain data (`app/automation/Tape.zig`) and round-trips through ZON — what a script
builds is what `Tape.write` emits, what `Tape.parse` reads, and what a recorder will produce.
`docs/demos/hello.zon` is a complete hand-written one.

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
    .captions = .{ .{ .at = 300, .ms = 5200, .title = "Hi", .text = "…", .place = .middle, .on = "region:Main" } },
    .ops = .{                        // ordered by .at; the first is a keyframe at 0
        .{ .at = 0, .do = .{ .keyframe = 0 } },
        .{ .at = 0, .do = .{ .wait = .{ .until = .idle } } },
        .{ .at = 0, .do = .{ .wait = .{ .until = .{ .shown = "text.editor:demo://hello/hello.md" }, .timeout = 10000 } } },
        .{ .at = 4400, .ms = 900, .do = .{ .move = .{ .tag = "text.end:demo://hello/hello.md" } } },
        .{ .at = 5460, .do = .{ .press = .left } },     // .left | .right | .middle
        .{ .at = 5570, .do = .{ .release = .left } },
        .{ .at = 6000, .ms = 3600, .do = .{ .type = "\n- written by a tape\n" } },
        .{ .at = 10400, .do = .{ .key = "mod+a" } },    // the keymap's spelling; mod is ⌘ or Ctrl
        .{ .at = 11000, .do = .{ .command = "fizzy.toggleExplorer" } },
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
| `command: "id"` | Run a command, as its menu row or shortcut would. |
| `wait: .{ .until, .timeout }` | Hold demo time until `.idle`, `.shown = "tag"` or `.gone = "tag"`; give up after `timeout` ms of wall time. |

## For apps built on fizzy

`app.automation` is framework: an app fills in a `Stage` (`begin`, `end`, `keyframe`, `idle`,
`command`, `chordFor`, `commandTitle`, `fastForward`), calls `player.frame()` first thing in its
frame — before anything reads `dvui.events()` — and `automation.overlay.draw(&player)` last.
`src/editor/Demo.zig` is the worked example.

## Tests

- `zig build test` — `fizzy-automation-tests` (`app/automation_tests.zig`): the tape format and
  its ZON round-trip, the script's pacing, and the sequencer's rules — waits and timeouts, a frame
  per op, keystroke-at-a-time typing, and that rewinding to a keyframe and replaying lands exactly
  where live play did.
- `zig build test-integration` — `demo:` tests in `tests/integration.zig`: the player against a
  headless window with a tagged button and the text plugin's editor (plays as a person's input,
  rewinds to exactly the live state, a person's click pauses it and is undone on resume, real
  motion cannot move the tape's pointer), every bundled demo builds, and `docs/demos/hello.zon`
  parses and round-trips.

## Next

- **Recording.** The format is ready for it: a recorder captures real dvui events between
  keyframes, maps each pointer event to the anchor under it (`dvui.tagGet` over the frame's tags)
  so the recording is size-independent, and writes the tape with `Tape.write`.
- **Quick open over mounts** — the palette's index should come from `core.FileTable`, which
  already lists mounts; then a demo can show it.
- **A `demos` build step** that writes every bundled demo as ZON, for a site to host.
