# Pitfalls

Things that cost someone a day, written down so they cost the next person a minute. Most live
beside the code they bite, in each area's `AGENTS.md`: `sdk/`, `app/`, `core/`, `backend/`
(macOS windows, full screen, autorelease pools), `plugins/`, `web/`, `tests/`. This file holds
the ones that belong to no single area. A fix that settles a pitfall updates its entry; a new one
goes beside the code if it has an area, here if not.

## Zig

- **A struct declared inside a generic function is one type for every instantiation** unless it
  uses the comptime parameter. Its `var`s are shared, so the first call's answer serves all of
  them. `Popout.envSwitch` read the first `FIZZY_*` switch for every name this way (#235). Fix:
  name the parameter inside the struct (`const variable = name;`) and use it. In review, look
  for function-local structs with `var`s inside generic functions.
- **Tests run only from files their root module analyzes** (`tests/AGENTS.md`).
  `zig build check-tests-reached` names any that don't.
- **On Windows, "test runner failed to respond" with every test passed means a leaked pipe.**
  Zig 0.16's Windows spawn makes each child inherit every inheritable handle the build runner
  holds, its other children's pipes among them. A long-lived child (a compiler, a sleeper)
  spawned beside a test keeps that test's stdout open, so after the test exits the runner waits a
  minute for EOF and fails it. CI compiles the tests (`zig build check`) before running them for
  this; don't fold the two steps back together, or start anything long-lived inside `zig build
  test`.

## The build (Zig 0.17)

`build.zig` runs in a configurer, and its result is cached; a separate maker runs the steps.
Four things in that split cost time on the move to 0.17:

- **The configuration is cached without regard to the environment.** A variable that
  `build.zig` reads with `b.graph.environ_map` is seen on the first configure and then ignored
  until something else forces a reconfigure. Anything that changes the build is a `-D` option.
  Scripts that hold a setting in the environment (`scripts/release.sh`, `release.yml`) turn it
  into the option.
- **`Run.setEnvironmentVariable` freezes the whole environment.** Its first call copies the
  configure-time environment into the Run, and that copy is cached with the configuration. The
  command then keeps the environment of the first configure (a `DOTNET_ROOT` exported later never
  arrived). A command that needs its environment changed runs through velopack-zig's
  `tools/run_env.zig` (`velopack.addVpkRun`), which applies the changes when it runs. A step
  that reads the environment itself, as `sdk/plugin_sdk_install.zig` does, reads it at make time.
- **A file read while configuring must be declared**, or a change to it is never seen:
  `b.dependOnFileContents`, `dependOnFileMetadata` (existence), `dependOnDirectoryContents`
  (a listing). `--cache-poison=disallowed` does not catch an undeclared read.
- **A declared path must not be inside a missing directory.** The maker cannot load the
  configuration ("configuration failed: FileSystemFailure"); a plugin without `.github/` hit it.
  `common.dependOnPathExistence` (and its copy in `sdk/plugin_sdk.zig`) declares the nearest
  directory that exists instead.
- **A tarball `zig fetch` cached breaks the next build's hash.** `zig fetch <url>` prints the
  right hash and saves the tarball to the global cache (`~/.cache/zig/p/<hash>.tar.gz`). A build
  that finds it there unpacks it with its top folder kept: no `build.zig.zon` at the package's
  root, an unnamed `N-V-...` hash, and "hash mismatch". It is not the URL: it hit GitHub
  `archive/<sha>.tar.gz` URLs (fizzyedit/dvui `bd7736d`) and fizzy's own `fizzy-sdk-v0.2.30.tar.gz`
  alike. Delete `p/<hash>.tar.gz` after a `zig fetch` and the build fetches the package itself.
  fizzyedit/plugin-build-action's repin does (fizzyedit/plugin-build-action#4).

### Windows, on 0.17

Three that the release builds (`zig build package`, MSVC) hit and the macOS build never shows:

- **An `*-windows-msvc` exe must link `oldnames` itself.** MSVC's C runtime spells the POSIX
  calls `_getcwd`, `_chdir`, ..., and `oldnames.lib` maps the plain names onto them. Zig 0.16
  linked it into every MSVC exe; 0.17 does not, so C that calls `getcwd` (dvui's
  tinyfiledialogs, fizzy's startup) fails to link with unresolved symbols. `build/exe.zig` adds
  it for `abi == .msvc`; any other MSVC exe built from this tree needs the same line.
- **The `translate-c` tool takes `--libc=<ini>` before its `--`.** Everything after `--` goes to
  the C front end, which doesn't know the flag, so a `--libc` appended at the end is lost and the
  MSVC headers aren't found. `build/msvc.zig` inserts it ahead of the `--`. Every translation here
  (SDL, Velopack, dvui's) is a `translate_c` package `Translator` now, so this is the only path.
- **sdl_zig must leave SDL's `core/linux/` out of a Windows build.** SDL lists those sources as
  generic because they compile to nothing off Linux, but `core/linux/SDL_dbus.c` includes
  `<unistd.h>` before its guard, and MSVC has no `unistd.h`. fizzyedit/sdl_zig filters them
  (`ef7eb36`, pinned in `backend/build.zig.zon`); a move to upstream sdl_zig or a new SDL must
  keep the filter.

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
  frame function, not fps (`core/AGENTS.md`, "Judge performance by main-thread CPU"). Revert the
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

## Window behaviour notes: clean-room hygiene

Write `docs/window-notes/` in our own words from observed behaviour or documentation read,
citing only public OS documentation. Do not consult source code or copy code, comments or
tables from SDL, GLFW or another implementation while writing a note. Our patch descriptions and
recorded pitfalls can identify a behaviour to investigate; patch files mix prose and
implementation hunks, so read only the commit-message part above the first `---`.
Separate recorded observations, documented contracts and cases still awaiting observation,
and include platform and verification limits so a proposed test is not mistaken for a pass.
