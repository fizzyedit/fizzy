# The control server

A running fizzy answers HTTP on a Unix socket in its config folder. Its API is the commands every
loaded plugin registers, with the parameters each declares, so anything a plugin can do through a
command, a script can do with `curl`, with no agent and no MCP tooling in between.

```sh
SOCK="$(fizzy --control-path)"
curl --unix-socket "$SOCK" localhost/commands
curl --unix-socket "$SOCK" localhost/commands/fizzy.openFiles -d '{"path":"/abs/notes.md"}'
curl --unix-socket "$SOCK" localhost/commands/text.insert -d '{"text":"hello\n","line":1,"path":"/abs/notes.md"}'
curl -N --unix-socket "$SOCK" 'localhost/events?topics=fizzy.document.*'
```

It is on by default on every native platform (Settings > Control server, `control_server` in
`settings.zon`), and absent on the web. The code is `app/control/`; the design and what comes next
are in `plans/CONTROL_SERVER_PLAN.md`.

## Where it listens

`<config>/control/control.sock`, the config folder being the platform's (`~/Library/Application
Support/fizzy` on macOS, `$XDG_CONFIG_HOME/fizzy` (else `~/.config/fizzy`) on Linux, `%LOCALAPPDATA%\fizzy` on Windows) or the
profile's (`--profile <dir>`, `FIZZY_PROFILE`). A config folder so deep that the path would pass the
OS's limit for a socket (104 bytes on macOS, 108 on Linux) listens in a private folder of its own
under `$TMPDIR` (else `$XDG_RUNTIME_DIR`, else `/tmp`) instead, named by a hash of the config folder.
`fizzy --control-path`, with the same `--profile` or `FIZZY_PROFILE` as the fizzy it means, prints
the path either way and exits (1, saying why, when it cannot), whether a fizzy runs or not. A
Windows release has no console to print to: capture it, `$sock = fizzy --control-path`.

**A fizzy started beside the person** (an agent's build, a sandbox) takes `--quiet`, or
`FIZZY_QUIET=1`, beside its `--profile`: a quiet run is meant never to take the person's focus.
Like `--profile` it is never forwarded to another instance, and a restart into a rebuilt binary
keeps it. For now it is only carried; what it changes comes with `fizzyedit/plans#35`.

**Who can use it:** only you. The socket's folder is `0700` and the socket `0600`, so nobody else
on the machine can connect; there is no token. A link in the folder's place is refused rather than
followed. On Windows the default config folder is under `%LOCALAPPDATA%`, which only you can open; a
`--profile` folder elsewhere gets no tighter access than it already has. Nothing listens on the
network.

Windows has AF_UNIX from Windows 10 1803, and its bundled `curl` takes `--unix-socket`. fizzy's
build sets 1803 as its minimum: std offers Unix sockets only to such a target. An app built on
fizzy with its own Windows target must set it too, or its server logs that it cannot listen.

## The API

| Method and path | Answers |
|---|---|
| `GET /` | the app, its version, the SDK it was built against |
| `GET /commands` | every command: id, title, owner, visibility, whether it is enabled now, its params |
| `GET /commands/{id}` | one of them |
| `POST /commands/{id}` | runs it: the body is its arguments, the response its result |
| `GET /events?topics=a,b` | the app's events as Server-Sent Events |
| `GET /openapi.json` | all of this as OpenAPI 3.1, generated from what is registered now |
| `POST /mcp` | the Model Context Protocol, its tools the commands |
| `DELETE /mcp` | ends the MCP session its `Mcp-Session-Id` names |

**Bodies are JSON**, converted to the ZON commands take at the server's edge: an object of
arguments keyed by the command's parameter names, a string where the parameter is an enumeration
being its tag (`{"side": "right"}`). Results come back as JSON, `null` when a command returns
nothing. Send `Content-Type: application/zon` to send ZON and get ZON back, for an enum deeper than
a top-level argument.

**Errors are HTTP's.** Those about a command or a route carry `{"error": "…"}` saying why:

| Status | When |
|---|---|
| 400 | the arguments do not fit the parameters, or the body is not JSON |
| 404 | no such command, or nothing at that path |
| 405 | that method is not answered there |
| 409 | the command is not enabled now (no document open, say) |
| 500 | it ran and failed |

Those about the request itself, refused before the app sees it, are plain text:

| Status | When |
|---|---|
| 400 | a GET or HEAD sent a body |
| 413 | the body is over 64 MB |
| 417 | an `Expect` other than `100-continue` |
| 503 | the control server is stopping (fizzy is quitting, or the setting went off) |

A command runs on the UI thread at the start of the next frame, as a menu item or a keybind would,
so the frame after it shows what it did. A call costs one wake and returns within a frame, unless
the command answers later (`Command.Call.later`: a build, a reply from a language server): then the
request stays open until it does. Two of fizzy's own are like that, for scripts and tests:

```sh
curl --unix-socket "$SOCK" localhost/commands/fizzy.settled -d '{"timeout_ms":5000}'  # true once nothing is in flight
curl --unix-socket "$SOCK" localhost/commands/fizzy.screen                           # what is on screen: windows, widgets, rects
```

Asked for often, `fizzy.screen` answers at once from the frame last drawn: once asked, every frame
fizzy draws is taken until two seconds pass without asking, which adds about 0.04 ms to a frame
in ReleaseFast (more in Debug, whose allocator makes the capture dear). The first asking, and one right behind a command in the same frame, wait for
the next frame instead.

## Events

`GET /events` streams every event on the app's bus: fizzy's `fizzy.document.*` (opened, changed,
saved, closed), `fizzy.folder.*`, `fizzy.files.*`, and whatever plugins announce. `?topics=` picks
names, or prefixes ending in `*`; none means all of them. Each is one SSE message:

```
event: fizzy.document.saved
data: {"path":"/abs/notes.md"}
```

**The screen, pushed.** `?topics=fizzy.screen` streams what is on screen, the same data
`fizzy.screen` answers, as JSON, each frame it changes, the moment that frame is drawn: an agent
watching what it does reads the screen without asking for it, about one frame after its command
answered. It goes only to streams that name it (`fizzy.screen`, or a prefix like `fizzy.*`), never
to one asking for everything, since it can be large and frequent. A stream joining gets the screen as
it is at once. While any stream names it, every frame is taken (as asking for `fizzy.screen` often
does); with none, nothing is.

**As changes on a base.** A screen comes as `{"seq": n, "nodes": [...]}`, each node with a `key`
that stays the same from frame to frame: its tag where it has one, else the path to it from the
nearest node with a tag (`fizzy.window:main/tab:notes.md`), and its parent and window named by key.
Ask `fizzy.screen` with `{"since": n}`, the `seq` of a screen you read, and the answer is what
changed since: `{"seq", "since", "added": [nodes], "removed": [keys], "changed": [{key, and only
what changed: name, rect, focused, parent}]}`. The last 8 screens `fizzy.screen` answered are kept
for this; an older `since` gets the whole screen, your new base. A stream with `&diff=1` is sent
the whole screen first, then each frame's changes on the one before, each change's `since` the
`seq` of the event before it, and the whole screen again whenever it would miss a step, or when
the change would be larger than the screen (about 7× less data through a tab opening).

Keys follow from the path, which has two consequences. A node without a tag that is renamed or
moves is removed and added, with everything under it that has no tag of its own. And like
siblings are numbered by position, so removing the first of two unnamed buttons reads as the
second removed and the first moved. Widgets that matter publish tags, which neither touches. In a
change, a name, parent or window that went away is `""`. Screen numbers start somewhere new each
run, so a `since` kept from an earlier run gets the whole screen.

`/openapi.json` lists the events plugins declared, with an example payload each. A stream gets a
keep-alive comment every 15 seconds; one that falls more than 8 MB behind gets nothing more. With
no stream open, events cost the bus nothing extra.

## MCP

`POST /mcp` speaks the Model Context Protocol's Streamable HTTP transport: one JSON-RPC message
per request, answered as JSON. Its tools are the commands. `tools/list` reads the registry, each
tool's `inputSchema` is the body schema `/openapi.json` gives the command, and `tools/call` runs it
as `POST /commands/{id}` would. A command that answers later answers its call then.

```sh
curl --unix-socket "$SOCK" localhost/mcp -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
curl --unix-socket "$SOCK" localhost/mcp -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"fizzy.screen"}}'
```

It answers `initialize`, `ping`, `tools/list` and `tools/call`, and notifications get a `202`. There
is no server-sent stream yet (`GET /mcp`), and no resources or prompts. An MCP client that can only
dial a URL or speak stdio reaches it through a proxy for now.

**Sessions.** `initialize` answers with an `Mcp-Session-Id` header, and each request that sends it
back is made as that client: its tool calls run as the author `.{ .kind = .agent, .plugin =
"control", .session = <id> }`, labelled with `clientInfo.name`, so history and undo say which agent
made a step. A request without the header is made as one shared author ("An agent"). One naming a
session that is not open gets `404`, and the client initializes again. A session ends at
`DELETE /mcp`, after an hour with no request, or when the server stops, and
`fizzy.mcp.session_ended` (`.{ .session, .label, .plugin }`) says so.

## The description

`GET /openapi.json` describes the server as it is now, so it changes as plugins load and reload.
It types what the server enforces: each parameter's type, and an enumeration's choices. A number's
bounds and suggested choices are hints the server does not check, so they are in the parameter's
description instead. Commands whose `runWith` takes arguments it does not declare (written by
hand) take any object. Results are not typed yet: any JSON value.

## Not yet

From the plan, in order: the agent plugin's claims and tapes per session, loopback TCP for clients that cannot dial a socket, the chat plugin's conversations as
commands and events, and a second launch forwarding its files over this socket.
