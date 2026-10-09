# Agents — the plan

Status: in progress, #250. Milestone 1 (command parameters and results) is #251, with #253 (keybinds) and #254 (tapes); milestone 2 (profiles) is #255; milestone 3 has begun, #257 and #258.

How fizzy becomes something an agent can drive, build plugins for and check its own work in —
**without fizzy, or any app built on it, carrying anything agent-shaped.** Agent support is an
external plugin, installed by whoever wants it, the same way pixi is. What fizzy owes it is a set
of seams in the SDK and the framework; this document is those seams.

## Principles

1. **Agent support is a plugin.** Its socket, its protocol, its tools, its chat pane: all in a
   plugin repo (`fizzyedit/agent`, say), never in `src/`, `app/` or `sdk/` by name. A user who
   does not install it carries none of it, and neither does an app built on fizzy.
2. **Every seam has a consumer that is not an agent.** Each one below names it — demos, the
   recorder, the palette, tests, an ordinary plugin. A seam only an agent would use is the agent
   plugin's business leaking into the contract under a neutral name. The consumer goes in the
   seam's doc comment, so the rule survives review.
3. **The agent plugin is the SDK's forcing function.** It is the most demanding third-party
   plugin there will be: it wants to see everything and do anything. Anything it needs that only
   fizzy can reach is a gap in the SDK, never a reason for a special case — the same rule the
   shipped layout shapes keep for `Layout` (CLAUDE.md, "Shipped shapes").
4. **An agent acts as a person does.** Input goes through the same anchors and tapes a demo uses;
   changes to the model go through commands a plugin chose to offer. There is no back door that
   writes a document's text or moves a split directly, so an agent can do nothing a person could
   not, and everything it does shows up the way a person's would — on screen, in undo.
5. **The person wins.** A click, tap or key from the person interrupts whatever an agent is
   playing, exactly as it pauses a demo (`docs/AUTOMATION.md`, "Playing one").

## What there is

Most of what an agent needs exists already, for demos and tests. It is just not reachable from
a plugin.

| An agent needs | Already in fizzy | Reachable by a plugin? |
|---|---|---|
| Actions it can take | the `Command` registry: id, title, `isEnabled` | runs by id (`Host.runCommand`); no arguments, no result; listed only by reading `host.commands` |
| Names for UI, not pixels | `core.anchor.mark`; `role:label` accessible names planned (AUTOMATION_PLAN, "Aiming without positions") | marks, yes; publishing is host-only (`anchor.publish`, on while a demo is loaded) |
| Input that lands | `Player` + `Sequencer`: synthetic dvui input aimed at anchors, with interruption | no — `app/automation`, host only |
| Knowing the app is idle | `Stage.idle`, and dvui's own convergence (no further refresh asked for) | no |
| The model as data | `Stage.capture`; per-document `captureDocumentState` / `documentFingerprint` | the per-document hooks, as an owner only |
| Pictures of the frame | frame readback (`core/gfx/FrameTarget.zig`, the glass) | no |
| A run without a display | the headless window behind `tests/integration.zig` (`tests/fizzy_shim.zig`) | no — fizzy's own tests only |
| Picking up a rebuilt plugin | `reconcileChangedPluginBinaries`: `zig build install` of a loaded user plugin hot-reloads it, documents reopened | happens, but reports only to the log |
| A channel into a running app | the single-instance listener (argv forwarding, wakes the app) | no; and a plugin can open its own anyway |

## The plugin

`fizzyedit/agent` — desktop first, the four-file shape like any other.

- **A control socket.** A Unix domain socket (a named pipe on Windows) in the profile's runtime
  directory, mode 0600, with a token file beside it. A background thread accepts requests and
  queues them; the plugin drains the queue in `beginFrame`, on the UI thread, and wakes the app
  with `host.refresh()` (proven from a dylib's thread, 2026-07-13). Replies that wait — "when it
  has settled" — are answered from a later frame.
- **Tools, mostly generated.** One tool per enabled command, its arguments from the command's
  parameters (below); plus a fixed few over the services: `ui.snapshot`, `ui.act`,
  `wait.settled`, `state.get`, `screenshot`, `log.tail`, `plugins.status`. A plugin installed
  next week contributes tools without the agent plugin knowing it exists.
- **A bridge, `fizzy-mcp`.** A second, std-only artifact in the same repo: an MCP server on stdio
  that relays to the socket. Pointed at a profile, it can launch a sandbox fizzy with the agent
  plugin installed there and drive that one, leaving the person's own instance alone.
- **Showing that an agent is there.** An infobar entry while a client is connected; the demo
  overlay's pointer while it is playing input, so a person sees what is being clicked.
- **Later, a chat surface** — perhaps a plugin of its own: Claude Code over
  `--input-format stream-json --output-format stream-json`, or ACP, both JSON over stdio as LSP is
  (`core.lsp.Client` is the template). Edits shown as diffs in the `text` plugin; permission
  prompts as fizzy dialogs. Nothing in it asks the SDK for more than the rest does.

## What an agent wants from it

The plugin is for agents, so it is shaped by how an agent works: a turn is expensive, a token
is expensive, it sees nothing it does not ask for, and it is often on a Linux machine with no
display. Written from an agent's side, after a session spent working around each of these
(screenshots by window id, input that moved the person's pointer, a demo loader that only takes
bundled names, `HOME` and `TMPDIR` surgery, reading a 900-line file to learn what a panel does).
In priority order:

1. **A run with no display, and none of the person's things.** A sandbox instance from a profile
   (milestone 2), with the plugins asked for, at a window size asked for, either headless (dvui's
   testing backend or an offscreen video driver) or in a hidden window that never takes focus.
   Several at once. A cloud agent has no screen at all, so without this, nothing below can be
   used where most agent work happens.
2. **Act, wait and observe in one call.** `ui.act` takes a step (click, type, key, scroll, aimed
   at an anchor or a `role:label`), waits until the app has settled or a condition holds (an
   anchor appears, a document is dirty, a log line matches) with a timeout, and returns what
   changed. One turn per step rather than three. A failure says which part failed: the target
   was not drawn, the wait timed out, a command was disabled.
3. **Observation as text, diffed.** `ui.snapshot` returns the tree (anchors, roles, labels, rects,
   focus, open popups and dialogs), filterable to a subtree, and on later calls only what changed
   since the last one. Names stay stable between calls. Screenshots exist, but only on request, of
   an anchor or a region, downscaled: a picture costs far more than the text that says the same.
4. **The plugin loop as one tool.** `plugin.new` (from the template), then `plugin.build`: build,
   install into the sandbox's profile, reload, and report. Compiler errors come back structured
   (file, line, column, message), load failures by kind (fingerprint, missing symbol,
   registration error, the plugin's own message), the reload's outcome (documents reopened,
   state carried or dropped). Then `plugin.test` through the headless harness. This is what turns
   "write a plugin" into a loop an agent can close on its own.
5. **The registries, described.** `sdk.describe`: every command with its parameters, surfaces and
   their keywords, regions, services with versions, settings schemas, file kinds, which plugin
   owns what, the SDK version and fingerprint. Writing a plugin correctly starts with knowing
   what is already there; today that means reading source.
6. **Documents through commands.** Reading an open document's text or a range of it, the
   selection, dirty state; editing through commands its owner offers (`text.replaceRange`,
   `text.insert` — commands with arguments, so milestone 1 again). No back door, and every edit
   lands in undo where a person can see it.
7. **Logs as a stream with a cursor.** `log.tail(since)`, filtered by level and source; plugin
   load and reload events; a panic's message and stack where there is one; frame times from the
   profiler, so "did this make it slower" has an answer.
8. **Time under the agent's control.** Motion off and the virtual clock ahead, so a wait for an
   animation is free rather than 300 ms of wall time, and a run is deterministic.
9. **A session becomes a tape.** Everything the agent did, written out as a tape: a reproduction
   for a bug, a regression test for the integration suite, a demo for the site. Loading a tape
   from a file rather than only bundled ones.
10. **Small, stable output.** Compact by default, paged, with ids that do not change between
    calls, and errors that say what to do next.

Last, and for the person rather than the agent: a pane in fizzy showing what the agent is doing,
diffs of its edits to review, and a way to stop it.

**What building it exercises.** The plugin is also the most thorough test of the SDK there will
be, and is meant to be: a dylib with background threads waking the host; commands with arguments
called across plugins; every service above, versioned; dvui's shared state (anchors, tags, the
frame dump) read from another image; frame capture through the render bridge; its own settings
schema (permissions, socket, limits), a surface (the pane above), an infobar entry; and hot reload
while connected. Each is something any plugin might do; this one does them all, so a break in any
shows up here first.

## The seams

Two kinds. A change to `Host`, `Plugin` or `Command` moves the ABI fingerprint and needs every
store plugin rebuilt. A **service** (`Host.registerService` / `getServiceTyped`) does not: it is
optional by construction, checked by its own `service_version`, and an app can supply its own or
none (`sdk/src/services/files.zig` explains why `files` became one). So: services wherever the
shape allows, contract changes only where a plugin *contributes* something.

### Commands take arguments and return a result — contract (moves the fingerprint)

Today `run(state) !void`. Add, all optional:

- **Parameters**, declared the way settings are: a comptime struct turned into descriptors
  (name, kind, doc, default) by an `sdk.command.Params(struct { … })`, mirroring
  `sdk.settings.Schema`.
- **`runWith(state, args, out)`** — `args` the arguments as ZON bytes, `out` a writer for a ZON
  result. Bytes cross the boundary and types live on each side: the helper parses into the
  plugin's struct and writes its result back, so the argument struct's layout never enters the
  fingerprint and can change freely.
- **Failure as a message**, not an error name: error values are numbered per compilation, so a
  name read on the host's side is another compilation's error (`Plugin.VTable`'s doc comment).
- **Listing** through functions (`commandCount`, `commandAt`) rather than the `commands` field,
  so the registry can change shape behind them.

Consumers: the palette prompting for arguments (Go to Line, Rename Symbol); keybinds that carry
them (`"text.goToLine"`, `.{ .line = 1 }`); a tape's `command` op with arguments; one plugin
running another's command with input.

This is the one seam to land first: it is the only one that moves the fingerprint, and the
cheapest moment for that is before the next SDK release, batched with whatever else moves it.

### `automation` — service

What `app/automation` already does, offered to plugins. Registered by an app that has a
`Player`; fizzy does.

- **`wantAnchors()`** — anyone may ask for anchors this frame; `core.anchor.publish` becomes
  "someone asked", not "a demo is loaded". Consumers: the recorder, plugin demos, plugin tests.
  *Built in #258 as `core.anchor.want()`, and not a service call:* `core.anchor` already agrees
  across dylibs through the window's data, so a plugin asks the same way the player does. The
  service need not wrap it, and the frame's named rects are dvui's tags, which a plugin can read
  as directly. The service keeps what only the app can do: `play`, and `settled`.
- **`anchors(arena)`** — the frame's named rects (name, rect, visible), and accessible
  `role:label` names (below). Consumers: the recorder, plugin tests.
- **`play(tape, opts)`** — play tape bytes (ZON or binary, `Tape.load`) **live**: no keyframe,
  the person's session left where it is, ops acting on the app as it is. A plugin builds its
  tapes with `tape.Script`, already in the SDK. Consumers: plugin tests, a scripted tutorial, a
  macro. (A plugin *demo* is the other kind — keyframed, seekable — and goes to the `Player` by
  `registerDemo`, AUTOMATION_PLAN milestone 6.) How a live tape is driven is below.
- **`settled()`** — `Stage.idle`, and nothing asked dvui for another frame, and nothing animating.
  With a callback form, so a caller can wait without polling. Consumers: demos, tests, a plugin
  that acts once a load has landed. *Open:* "nothing asked dvui for another
  frame" is not observable at the start of the next frame through dvui's public API. `refresh`
  sets `Window.extra_frames_needed`, which `Window.begin` counts back down, and running
  animations sit in `Window.animations`. Either the app notes it at the end of its own frame
  function, reading those fields (a reach into dvui's state, which CONTRIBUTING asks against), or
  dvui says it: an accessor beside the frame-dump fields, in the same fizzy-dev patch. The second
  is the right one. Until then the live driver paces on `Stage.idle` and the sequencer's yields
  alone, which the tests show is enough for input to land.

#### Driving a live tape: its own driver, not the `Player`

A live tape and a demo want different things, and the difference decides where one is played.

| | A demo | A live tape |
|---|---|---|
| Starts from | a keyframe, the person's session set aside | the app as it is |
| Pacing | the tape's authored times (a viewer watches) | each op once the last has settled (a caller waits) |
| The person steps in | pause; on resume, replay to where it was | stop, and report the op it stopped before |
| Going back | seek: snapshots, keyframes | undo, through the commands it ran |
| Transport, chapters | yes | none |

Two ways to play one:

- **Through the `Player`, in a live mode.** One injection path; the overlay's pointer and
  keystrokes come free; one tape at a time by construction. But every demo-shaped part of the
  player — resume-by-replay, seeking, the transport, `Stage.begin`/`end`/`keyframe` — grows a
  "not when live" branch, in the most intricate and most tested piece of the automation code.
  That is a mode flag on a shipped thing, which this codebase prefers to avoid.
- **A `LiveDriver` beside it.** The `Sequencer` (already std-only) plus the dvui sink — the
  injection now inside `Player` (`addEventMouseMotion`, `addEventKey`, …) — factored out so both
  use it. The player stays as it is; the live driver is small and its rules are its own. It costs
  that extraction first, one arbitration rule (a live tape is refused while a demo is loaded, and
  the reverse), and the overlay learning to draw for either.

**The `LiveDriver`.** The extraction is the split AUTOMATION_PLAN already wants for its `replay`
package (`Recorder`, `Player`, `Anchors` as separate pieces), so it is work that would happen
anyway. Of the `Stage`, a live tape needs only the read side — `idle`, `command`, `chordFor`,
`commandTitle`, `fastForward` — never `begin`, `end`, `keyframe` or the snapshot hooks, and a
tape with a keyframe in it is refused.

#### Accessible names

Not AccessKit. dvui builds its AccessKit tree only when built with it (fizzy's default is
`-Daccesskit=off`), never on the web or testing backends (`dvui.accesskit_enabled`), and only
while an assistive technology has switched it on. A snapshot that exists only while VoiceOver
runs is no use to a test.

What is there instead: every widget's `Options.role` and `Options.label` as it registers
(`WidgetData.register`), and dvui main already has a machine-readable widget-tree dump
(`dvui.debug.captureFrame` / `dumpFrame`: ids, parents, rects, subwindow, focus, visibility,
call site) — on every backend, armed for one frame, free when not. It records neither role, label
nor tag. Adding those three fields is a small, upstreamable dvui change and gives the snapshot a
whole tree: the anchors fizzy marks, named `role:label`s for the rest, and the structure between.
The snapshot no longer waits on the recorder; whichever lands first brings the names.

What it shows about fizzy: 17 anchor marks, 20 `role`s and 4 `label`s across `src/`, `core/`,
`app/` and `plugins/`. dvui's own widgets set roles (a button is `.button`), but an icon button
with no text has no name a person or agent can use. Labelling them is accessibility work worth
doing for its own sake, and is what makes the snapshot useful past the anchored widgets.

### `state` — service

The app's model as data: the declarative shape a keyframe has (files, open documents, layout,
settings, focus by anchor) written as ZON, plus each document's owner state where it has one.
Not the in-memory seek snapshot, which is opaque and dies with the session. Consumers: bug
reports ("attach the session"), a session-restore that is more than the open-file list,
asserting in a test.

### `frames` — service

`capture(rect or whole window, callback)`: the next presented frame as PNG bytes, delivered a
frame later. Consumers: a Screenshot command, thumbnails, test assertions, images for the docs
and the site.

### `log` — service

Subscribe to the output log — level, source, line — from any thread. Consumers: a plugin's own
output pane, a test asserting nothing warned (the integration suite already fails on any log
output).

### `plugins` — service

What is loaded, at what version and from where, and what happened to each load and reload:
reloaded, refused (fingerprint, missing symbol), documents reopened or skipped. Today that is a
line in the log. Consumers: the plugin store UI, a plugin author's build loop, an "it didn't
pick up my rebuild" diagnosis.

## In the framework, not the SDK

These decide where plugins come from, so a plugin cannot provide them.

- **Profiles.** `--profile <dir>` (and `FIZZY_PROFILE`): the config directory, the plugins
  directory, the single-instance lock, recents and the runtime directory, all under one root.
  Before it, a sandbox meant moving `HOME` (CONTRIBUTING.md) and `TMPDIR` (the lock lived there),
  and a plugin build installed into the real plugins dir unless `HOME` was moved. Consumers: every sandbox recipe, the integration
  tests, portable installs, two configs side by side. Built: `app/profile.zig`. The root *is*
  the config folder (`<dir>/plugins`, `<dir>/settings.zon`, …), `<dir>/run` is the runtime
  directory, and the lock is named for the profile (`<app id>.p<hash>`), so it is its own on
  Windows too, where a named pipe has no directory. A socket path too long for a socket address
  (104 bytes on macOS) falls back to the temp directory under that same name. A plugin's
  `zig build` installs into `<FIZZY_PROFILE>/plugins`. The runtime directory is not offered to
  plugins yet. The agent plugin's socket wants it, and it will reach plugins as an `EditorAPI`
  read or a `paths` service, whichever lands with milestone 5.
- **Hot reload keeps state.** Reload exists: `zig build install` of a loaded user plugin swaps
  it in (`reconcileChangedPluginBinaries`), its documents reopened from disk. What it drops is
  everything else the plugin held — undo history, unsaved edits (a dirty document blocks the
  reload), tool and view state. An optional hook pair that hands state across — the outgoing
  build writes it as bytes, the incoming one reads what it understands — and the reload's result
  reported through `plugins`. The per-document half exists already
  (`captureDocumentState`/`restoreDocumentState`, for demo snapshots); a reload can use it first.
- **A headless harness for plugin tests.** `tests/fizzy_shim.zig` grown into something a plugin
  repo can use: its plugin linked statically into a minimal host (`examples/minimal-app` is the
  shape), a headless window, then open a document from bytes, run commands, play a tape, step
  until settled, and assert on anchors, state or a frame. Exposed as a build step beside
  `fizzy.plugin.create`. Consumers: every plugin's `zig build test`, and the plugin-build-action
  CI. Of everything here this is the largest piece, and the one that most changes what writing
  a plugin is like.

## Running with no display (spike)

Can fizzy run on Linux with no display: a CI runner, a server, a remote agent's machine? Two
ways were open:
SDL with a video driver that needs no display, or fizzy hosted over dvui's testing backend, the
way `tests/integration.zig` already draws pieces of it.

**Over the testing backend: yes, the whole app.** `tests/integration.zig`, "headless: …", brings
fizzy up exactly as `Entry.AppInit` does: real `Editor.init` and `postInit`, the bundled plugins
registered, frames through `Entry.AppFrame` (demo player, frame target, editor). Then it opens a
`.md` from a project folder, plays the bundled tour to its end, and tears down. The profile is a
fresh temp directory (#255), so nothing of anyone's config comes in. In a Debug build: up in
about 130 ms, the document open in about 50 ms, the tour in 714 frames and about 2 s. The testing backend's clock moves 100 ms a step, so a minute of demo runs about
33 times faster than it plays. That is wishlist item 8 (time under the agent's control) for free.

- **Plugin dylibs load into it.** `plugins/archive` built with `FIZZY_PROFILE=<dir> zig build`
  (#255) was picked up by the ordinary user-plugin scan and registered beside the bundled ones.
  The dvui context injection and the fingerprint check hold against a testing-backend host.
- **A dropped-in plugin is undecided until someone says yes.** It loaded only once the
  profile's `settings.zon` said `.plugins.archive = .{ .enabled = true }`. That is the person's
  consent, and a sandbox recipe has to write it ahead of time. Kept as it is: an agent's
  `plugin.build` writes it into the sandbox profile it owns, never into the person's.
- **A reused profile restores its last session.** A second run in the same profile reopened the
  first run's documents, from a temp project that no longer existed, and logged the failure.
  That is session restore working as it should. A sandbox wants a fresh profile per run, or a way
  to start without restoring. That is a wish below, not a bug.
- **What it does not have: pixels.** The testing backend draws nothing (`drawClippedTriangles`
  is empty, `textureCreateTarget` fails, so the frame target draws straight through), and
  `dvui.Picture` is unsupported. Nor are there OS dialogs, native menus or pop-out windows: those
  are backend calls with nothing behind them. The clipboard is in memory.
- **Input is dvui events**: `dvui.testing`'s, or the `Player`'s sink. The same path a live tape
  takes (milestone 3), so the `LiveDriver` works in it unchanged.

**SDL with no display: not tried yet.** What it would take: SDL3's `offscreen` video driver (EGL
pbuffers) or `dummy`. Fizzy's default renderer is its own SDL_GPU backend (Vulkan on Linux), so
it would need a software Vulkan driver such as Mesa's lavapipe. Alternatively,
`-Dnative-backend=sdl3` with `SDL_RENDER_DRIVER=software` on the `dummy` driver draws into
memory, and `SDL_RenderReadPixels` reads the frame back. Either one gives pixels; either one
costs system packages, real-time pacing and a renderer that is not the one people see.

**So:** the headless host is fizzy over the testing backend. It is the path the integration
tests already exercise, it needs nothing installed, it is deterministic, and it runs at the
speed of its own clock. It becomes milestone 6's harness and the agent's sandbox. Pixels are a
separate, later question with a named seam: the `frames` service answers "unsupported" under the
headless host until a renderer exists. That renderer is either a software dvui render backend
(`dvui.enums.RenderBackend` already has the slot) or the SDL software route above.

The test build has a `bundled_plugins` module for it, so `Editor.postInit` has its plugins
(`build/app.zig`). What a product needs besides: an entry
point that runs this loop outside a test (a `fizzy-headless` executable, or a mode of the
harness), and tapes loaded from a file.

Wishes from it, for "What an agent wants" (#252):

- **Start without restoring the session**, for a reused sandbox profile: a flag or a profile
  setting.
- **Approve a plugin in a sandbox profile in one step**, rather than editing its
  `settings.zon` by hand.

## The SDK tarball

`fizzy-sdk-v*.tar.gz` ships an `AGENTS.md` — the four-file shape, the rules that bite, how to
build, test and load a plugin — so a third-party plugin repo starts with it. Most of it exists
already as the `fizzy` skill and CLAUDE.md; this is a copy that travels with the SDK, kept by
the same PR that changes what it describes. A person starting a plugin reads it too.

## Safety

- Nothing listens unless the agent plugin is installed, and it listens only on a local socket
  only the user can open, behind a token.
- An agent reaches only what a person can: offered commands, and input through anchors.
- A person's input interrupts it, and the infobar says when one is connected.
- Commands with arguments let any plugin drive any other's commands with input. That is already
  true without arguments; `docs/PLUGINS.md` §3.4 says so once the seam lands.

## The web

The agent plugin is desktop-only to start: a wasm side module cannot open a socket. Nothing in
the seams assumes a transport, so a web variant — the page's `postMessage`, a devtools bridge —
can come later as another plugin over the same services.

## Milestones

Each lands on its own and is useful without the next.

1. **Command parameters and results**, with listing functions; the palette prompts for arguments
   (the non-agent proof). Moves the fingerprint. Built in #251: `Command.Params` /
   `Arg` / `runWith` / `Call`, `Host.callCommand` and `CommandOutcome`, `commandCount` /
   `commandAt`, `EditorAPI.askCommandArguments`, `sdk.Command.answer`, the palette's argument
   step, and `text.goToLine`. The rest of this seam, none of it moving the fingerprint again:
   keybinds that carry arguments (`keybinds.zon`, #253) and a tape's `command` op with arguments
   (#254).
2. **Profiles.** #255: `--profile <dir>` / `FIZZY_PROFILE` (`app/profile.zig`; see "In the framework" above).
3. **The `automation` service**: anchors on request, settled, and live tapes — the dvui sink
   factored out of the `Player` first, then the `LiveDriver` on it. Role, label and tag in dvui's
   frame dump (a fizzy-dev patch), the snapshot over it, and a pass labelling fizzy's icon-only
   buttons. First consumers: plugin tests, and plugin demos
   (AUTOMATION_PLAN milestone 6) through the same anchors. So far: the sink as
   `automation.Input` (#257); the `LiveDriver`, and anchors on request as `core.anchor.want`
   (#258). Next: the service itself (`play`, `stop`, `outcome`, `settled`), and the overlay
   drawing a live tape's pointer. **On the dvui fork:** the frame-dump fields, and the "another
   frame?" accessor `settled` wants. Both are a patch on `foxnne/dvui-dev`'s `fizzy-dev` stack,
   then a tag and a repin, not yet made.
4. **`state`, `frames`, `log`, `plugins`.**
5. **`fizzyedit/agent` and `fizzy-mcp`**, desktop. Everything it needs exists by now; if it
   needs anything else, that is a missing seam to add here, not a reach into fizzy.
6. **The headless plugin-test harness**, and `AGENTS.md` in the tarball. Over dvui's testing
   backend ("Running with no display"): the whole editor already runs there.
7. **A chat surface**, if wanted.

## Decisions

- **A plugin, never a feature.** Nothing names agents in `src/`, `app/` or `sdk/`.
- **Each seam's doc comment names its non-agent consumer.**
- **Services over `Host` members** wherever a plugin consumes rather than contributes: optional,
  replaceable, versioned on their own, and no fingerprint move.
- **Bytes across the boundary, types on each side**, for command arguments and results — and the
  bytes are **ZON**, like every other piece of data fizzy writes. The MCP bridge converts to and
  from JSON at its edge; nothing inside fizzy sees JSON.
- **Live tapes get their own driver**, sharing the dvui sink with the `Player`, never a mode of it.
- **Accessible names come from widget options through dvui's frame dump**, not from AccessKit.
  The dump's role, label and tag fields are a patch on the fizzy-dev stack
  (`docs/DEPENDENCIES.md`), written to be upstreamed later.
- **Fizzy labels its own widgets** as part of milestone 3: every icon-only button gets a
  `label`, so the snapshot (and a screen reader) can name it.
- **No back door.** Agents change the model only through commands, and the UI only through
  input.
- **Arguments travel as ZON text wherever a command is named** (#253, #254): a tape's
  `command` op is `.{ .id, .args }`, with `args` the text `Host.callCommand` takes, and a
  keybind's `.args` is ZON written in place and kept verbatim. Neither the tape library nor the
  keymap parses them; the command says whether they fit, when it runs.
- **A binding with arguments is a use of a command, not its shortcut** (#253): menus, the
  palette and the Keyboard Shortcuts pane show and edit only the binding without.
- **A profile's root is its config folder** (#255), not a folder holding one: every path fizzy
  keeps was already relative to the config folder, and a profile made from an existing one just
  works. The lock is named for the profile, so it is its own on every OS.
- **The headless host is fizzy over dvui's testing backend** (#256), not SDL without a display:
  no system packages, deterministic, and its own clock. Pixels come later, behind `frames`.
- **A live tape that loses its place stops** (#258): a wait that gives up, or a person's input,
  ends it and says before which op. A demo carries on, and that difference is why they are two
  drivers.
- **Anchors are asked for, a frame at a time, by anyone** (`core.anchor.want`, #258), through
  `core` rather than a service call: the request already crosses dylibs through the window's
  data.

## Open

- What a reload carries beyond documents, and whether that hook moves the fingerprint now or
  waits for the next batch.
