# Spike: driving host dvui state from a prebuilt plugin dylib

Validates the load-bearing mechanism for fizzy's runtime native-plugin architecture
(see `~/.claude/plans/i-would-like-to-glowing-stroustrup.md`): can a **prebuilt
plugin dynamic library**, compiling its **own copy** of the dvui-like code, render
into the **host's** dvui state across the `dlopen` boundary?

`core.zig` stands in for dvui (a `current_window` global, an `ft2lib` global, a
`Window` carrying a per-frame arena, and a `label()` "widget" that uses all three).
The host exe and the plugin dylib each compile `core.zig` independently.

Run: `zig build run`

## Findings (macOS/arm64, Zig 0.16.0)

- **Globals are NOT auto-shared.** Even with `rdynamic` + `allow_shlib_undefined`,
  the host and plugin each get their own `current_window` (different addresses).
  macOS two-level namespace ⇒ no automatic interposition. So the "one shared
  `libdvui`" idea is out.
- **Mechanism B (context injection) works.** The host owns the dvui state; before
  invoking the plugin's draw it sets the plugin's `current_window` + `ft2lib`. The
  plugin's own statically-compiled `label()` then:
  - mutates the **host's** `Window` (`widget_count` 1→4),
  - allocates strings in the **host's** arena (round-tripped),
  - uses the **host's** `FreeType` handle (`shape_calls` 1→4).
- Works because struct layout is identical (same pinned source/version) and it's
  pure pointer-passing — so it ports to Linux/Windows unchanged, and the shared
  allocator means **no cross-allocator free hazard**.

## Design consequence

Plugins statically compile dvui + the SDK; the host injects its handful of dvui
globals each frame (`current_window` per-frame; `io`/`ft2lib`/`debug` at init — all
public `pub var`, so no dvui patch needed). Pinned Zig + SDK version + a load-time
ABI gate keep struct layouts compatible.

## Not covered here (validate in-fizzy at Phase 4)

Real GPU rendering with a live backend — but that's the host's job; the plugin only
records draw commands into the shared Window's render list.
