# Pitfalls

Things that cost someone a day, written down so they cost the next person a minute. Most live
beside the code they bite, in each area's `CLAUDE.md`: `sdk/`, `app/`, `core/`, `backend/`
(macOS windows, full screen, autorelease pools), `plugins/`, `web/`, `tests/`. This file holds
the ones that belong to no single area. A fix that settles a pitfall updates its entry; a new one
goes beside the code if it has an area, here if not.

## Zig

- **A struct declared inside a generic function is one type for every instantiation** unless it
  uses the comptime parameter. Its `var`s are shared, so the first call's answer serves all of
  them. `Popout.envSwitch` read the first `FIZZY_*` switch for every name this way (#235). Fix:
  name the parameter inside the struct (`const variable = name;`) and use it. In review, look
  for function-local structs with `var`s inside generic functions.
- **Tests run only from files their root module analyzes** (`tests/CLAUDE.md`).
  `zig build check-tests-reached` names any that don't.

## Running a second fizzy

- **`fizzy --profile <dir>`** keeps config, recents, plugins, the single-instance lock and its
  socket under `<dir>`, apart from the person's own fizzy. Build plugins for it with
  `FIZZY_PROFILE=<dir>`.
  - Keep `<dir>` short (the socket path caps at 104 bytes) and outside the jj workspace, or jj
    snapshots it into your change.
  - Delete its `layout.zon` and `recents.zon` between runs, or it reopens the last run's tabs.
- **Launch it in the background and keep its PID;** kill that PID. Before killing by name, check
  the parent PID: the person may be running the same binary from their own shell. Strays from an
  earlier agent shell show `ppid=1`.
- **Drive it with a demo tape, not OS input** (`docs/AUTOMATION.md`). Synthetic dvui input never
  moves the person's real pointer; posted HID events do.
- **A fizzy started from a shell isn't the active app.** AppKit stalls or refuses some window
  transitions (full screen) for it. With the display asleep, screen capture returns nothing.
  That's not a regression.

## Measuring

- **Frames happen only on input or a refresh.** To profile a still scene, add a temporary hook
  that calls `dvui.refresh` every frame, then `sample <pid> 6`. Read inclusive samples of the
  frame function, not fps (`core/CLAUDE.md`, "Judge performance by main-thread CPU"). Revert the
  hook.
- **Debug builds SDL's C at `-O0`** with UBSan, which inflates renderer time in a Debug profile.
- **A stripped release crash can still be placed.** In the `.ips` report (line 1 is a JSON
  header, the body JSON), each frame has an `imageOffset`:
  - the static address is `0x100000000 + imageOffset`;
  - disassemble back from it with `objdump` and resolve its `adrp`/`add` pairs into `__cstring`;
  - the strings a function uses identify it better than a symbol would, since Zig inlines
    aggressively.

  A fault address "not in any region" beside freed 16K `VM_ALLOCATE` regions is a
  use-after-free.

## Tools around the repo

- **`patch -p1` can leave `*.orig` files,** and the next jj command snapshots them into your
  change. Remove them before any jj command, and read `jj diff --stat` before pushing.
