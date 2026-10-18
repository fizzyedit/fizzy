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
profile's (`--profile <dir>`, `FIZZY_PROFILE`). `fizzy --control-path`, with the same `--profile`
or `FIZZY_PROFILE` as the fizzy it means, prints it and exits, whether a fizzy runs or not.

**Who can use it:** only you. The socket's folder is `0700` and the socket `0600`, so nobody else
on the machine can connect; there is no token. On Windows the folder sits in your profile, which
only you can open. Nothing listens on the network.

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

**Bodies are JSON**, converted to the ZON commands take at the server's edge: an object of
arguments keyed by the command's parameter names, a string where the parameter is an enumeration
being its tag (`{"side": "right"}`). Results come back as JSON, `null` when a command returns
nothing. Send `Content-Type: application/zon` to send ZON and get ZON back, for an enum deeper than
a top-level argument.

**Errors are HTTP's**, each with `{"error": "…"}` saying why:

| Status | When |
|---|---|
| 400 | the arguments do not fit the parameters, or the body is not JSON |
| 404 | no such command |
| 409 | the command is not enabled now (no document open, say) |
| 500 | it ran and failed |
| 503 | fizzy is closing |

A command runs on the UI thread at the start of the next frame, as a menu item or a keybind would,
so the frame after it shows what it did. A call costs one wake and returns within a frame.

## Events

`GET /events` streams every event on the app's bus: fizzy's `fizzy.document.*` (opened, changed,
saved, closed), `fizzy.folder.*`, `fizzy.files.*`, and whatever plugins announce. `?topics=` picks
names, or prefixes ending in `*`; none means all of them. Each is one SSE message:

```
event: fizzy.document.saved
data: {"path":"/abs/notes.md"}
```

`/openapi.json` lists the events plugins declared, with an example payload each. A stream gets a
keep-alive comment every 15 seconds; one that falls more than 8 MB behind gets nothing more. With
no stream open, events cost the bus nothing extra.

## The description

`GET /openapi.json` describes the server as it is now, so it changes as plugins load and reload.
It types what the server enforces: each parameter's type, and an enumeration's choices. A number's
bounds and suggested choices are hints the server does not check, so they are in the parameter's
description instead. Commands whose `runWith` takes arguments it does not declare (written by
hand) take any object. Results are not typed yet: any JSON value.

## Not yet

From the plan, in order: MCP on the same socket and sessions (claims and tapes for scripts and
agents), loopback TCP for clients that cannot dial a socket, the chat plugin's conversations as
commands and events, and a second launch forwarding its files over this socket.
