# remote — the remote-view protocol

How a host application (Blender, Unreal, ...) shows a view of a running fizzy:
`plans/EMBEDDED_EDITOR_PLAN.md`. std-only; nothing under `sdk/src/**`, so the plugin fingerprint
does not move. The C API (`fizzy_remote.h`) is generated from these types, with two transports:
the socket (`GET /remote`, `Upgrade: fizzy-remote-view/1`, then frames both ways) via `Endpoint`,
and in-process, where `Message` values are handed straight across and only `Connection`'s rules
apply.

## Encoding

A frame is

| bytes | |
|---|---|
| 4 | `len`, u32: the bytes after this field (at least 4) |
| 2 | `type`, u16: `message.Type` |
| 2 | `flags`, u16: bit 0 = the type is *required* |
| len-4 | payload |

All integers are little-endian. The payload is the message struct's fields in order:

- ints, floats (IEEE bits), `bool` (one byte, 0 or 1), enums (their integer; unknown values pass
  through), packed flag structs (their integer);
- `?T`: a byte 0, or 1 and the `T`;
- byte strings: `u32` length and the bytes (UTF-8 where it is text, not validated);
- lists: `u32` count and the elements; a count larger than the bytes left is refused;
- structs: their fields in order.

## Versioning

- The first message each way is `hello` (versions `min..max`, ids, tiers offered/wanted, feature
  bits, mode). The highest common version is used; none in common closes with `bye`
  (`your_side_too_old` / `your_side_too_new`) and a text saying who updates. Nothing but `hello`
  and `bye` may be sent before both hellos are exchanged.
- **Fields append.** A new field goes last in its message with a default; a payload that ends
  early takes the defaults, and bytes past the known fields are ignored. Never reorder, retype or
  remove one, or reuse a type id.
- An unknown **optional** type is skipped by its length; an unknown **required** one (flag set by
  its sender) is an error. Required: `hello`, `bye`, the view lifecycle, `resize`,
  `frame_request`, `frame`.
- Enums are open: a newer peer's value is carried, not refused.

## Rules (`Connection`)

Host-sent: `create_view`, `close_view`, `resize`, input, `focus`, `clipboard_reply`,
`frame_request`. Editor-sent: `view_created`, `view_closed`, `cursor`, `ime_rect`,
`text_input_active`, `clipboard_request`, `wants_keys`, `open_url`, `drag_begin`, `frame`,
`frame_ready`.

- A view id is chosen by the host and used once at a time; the host may pipeline input after
  `create_view`. `view_closed` ends a view, whoever started it (host close, editor close, refused
  create). After `close_view` the host sends nothing more to it; the editor's in-flight messages
  still arrive until `view_closed`.
- `frame_request.seq` rises from 1 per view. A `frame` answers the newest request it covers: its
  `seq` is above the last answered and not above the last requested; older requests may be
  skipped.
- Tier 3 frames carry texture updates and an indexed triangle draw list; tier 2 a fence and
  slot; tier 1 only damage.

## Using it

```zig
var ep = remote.Endpoint.init(gpa, .host, .{ .app_id = "blender" });
try ep.start();                     // queues our hello
// write ep.pending() to the stream, then ep.consume(n); feed what the stream read:
try ep.feed(bytes);
while (try ep.poll(arena)) |msg| { ... }   // arena for lists; strings borrow until the next feed
```

`Endpoint.pump(a, b, chunk)` moves one end's bytes to the other for a loopback in tests.
