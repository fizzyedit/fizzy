# fizzy tests

This directory contains fizzy's test scaffolding. If you've never written
tests in a Zig project before, start here.

## Running the tests

```sh
zig build test                 # compile + run all tests
zig build check                # compile tests, don't run (fast feedback loop)
zig build test --summary all   # show step-by-step results
```

To narrow down to a single failing test while you debug:

```sh
zig build test -Dtest-filter="lerp endpoints"
```

`-Dtest-filter` accepts any substring of a test name and may be passed
multiple times.

## How Zig tests work (quick orientation)

Zig has tests built into the language. Anywhere in any `.zig` file you
can write:

```zig
test "lerp halfway" {
    const std = @import("std");
    try std.testing.expectEqual(@as(f32, 5.0), lerp(0.0, 10.0, 0.5));
}
```

A `test "..."` block compiles only when Zig builds a *test binary*. We
produce that binary with `b.addTest(...)` in `build.zig`. The runner
discovers every `test` block in the test binary's root file and any
file it transitively imports.

There is no separate framework. The standard library has assertions in
`std.testing`: `expect`, `expectEqual`, `expectEqualSlices`,
`expectEqualStrings`, `expectError`, `expectApproxEqAbs`.

## How fizzy tests are organized

fizzy has both pure logic (math, palette parsing, layer reorder) and a
GUI on top. Tests are split into two targets, cheapest first, so most
code gets fast unit-level coverage and only the parts that genuinely
need a window pay the integration cost. Both run under a single
`zig build test`.


| Target                   | What it tests                                                              | Needs a window? | Source root             |
| ------------------------ | -------------------------------------------------------------------------- | --------------- | ----------------------- |
| `fizzy-unit-tests`        | Pure logic: math helpers, easing, palette parser, layer-reorder algorithm  | No              | `tests/root.zig`        |
| `fizzy-integration-tests` | Real fizzy drawing / file functions against dvui's headless testing backend | Yes (no GPU)    | `tests/integration.zig` |


### Unit tests (pure logic)

`tests/root.zig` `@import`s a small set of source files that depend
only on `std` — no dvui, no fizzy globals, no SDL. Every `test "..."`
block in those files becomes part of the test binary. Currently
covered (named imports wired in `build/app.zig`):

- `[src/core/math/direction.zig](../src/core/math/direction.zig)` — 8-way / 4-way
direction encoding, `fromRadians`, rotation inverses.
- `[src/core/math/easing.zig](../src/core/math/easing.zig)` — `lerp`, `ease`,
endpoint pinning, midpoint bias.
- `[src/core/math/layout_anchor.zig](../src/core/math/layout_anchor.zig)` —
anchor math shared by grid/layout code.
- `[src/backend/window_layout.zig](../src/backend/window_layout.zig)` —
macOS window/Space transition geometry helpers.
- `[src/sdk/dylib.zig](../src/sdk/dylib.zig)` — plugin dylib ABI fingerprint helpers.
- `[src/backend/plugin_store/store.zig](../src/backend/plugin_store/store.zig)` —
plugin store manifest/catalog parsing.

The `_ = @import("...")` lines in `tests/root.zig` exist purely so
their `test` blocks are reachable from the test binary. Each module is
exposed as a named import (e.g. `fizzy-direction`) by `build.zig`,
because Zig 0.15 modules cannot import source files outside their own
directory via `../`.

### Integration tests (headless)

`tests/integration.zig` exercises real fizzy code that needs a live
`dvui.Window` and `fizzy.app` / `fizzy.editor` globals. dvui ships a
`testing` backend that creates a real `dvui.Window` with no GPU and no
SDL window; `tests/fizzy_shim.zig` heap-allocates `fizzy.app` and a
mostly-zeroed `fizzy.editor`, setting only the fields tests actually
read. The shim is deliberately minimal — when a new test needs a field
the shim doesn't set, set just that field at the top of that test
rather than expanding the shim.

Currently covered:

- A single smoke test that the shim brings up a working headless
`dvui.Window` with `fizzy.app` / `fizzy.editor` globals set.

Pixel-art-specific coverage that used to live here (`Internal.File`,
`Layer`, `Packer`, `Animation`, grid/pack/flood-fill regressions, the
`.pixi` JSON format-migration fixtures) moved out along with the pixi
plugin extraction — that logic now lives in the external
[`fizzyedit/pixi`](https://github.com/fizzyedit/pixi) repo and should
gain equivalent coverage there, not here.

What's intentionally **not** here yet:

- Any pixi-specific coverage (see above — belongs in the pixi repo).
- Full shell UI flows (workbench tabs/splits, menu/sidebar, real
undo through `App.zig`) driven via `dvui.testing.settle`. Needs asset
loading to work in CI without a real project root, theme bring-up
without a config dir, and a way to dismiss startup dialogs.
- Anything that goes through SDL (file dialogs, native menus).

## Adding a new test

### Pure-logic (preferred — fastest, no window)

1. Find a source file that has no dvui / fizzy imports, or extract the
  pure piece you want to test into one (look at how
   `src/math/easing.zig` was extracted from `src/math/math.zig` for a
   minimal example).
2. Add a `test "..."` block at the bottom of the file:
  ```zig
   const std = @import("std");

   test "my new thing" {
       try std.testing.expectEqual(@as(u32, 42), myFunction(...));
   }
  ```
3. If the file isn't already wired up, add it to the `inline for`
  table in `build.zig` (so it becomes a named import on the unit-test
   target) and add an `_ = @import("...")` line to `tests/root.zig`.
4. Run `zig build test`.

### Integration (when a test needs `dvui.currentWindow()` or fizzy globals)

1. Add the test to `tests/integration.zig`.
2. Bring up the shim at the top of the test:
  ```zig
   var ctx = try shim.init(std.testing.allocator);
   defer ctx.deinit(std.testing.allocator);
  ```
3. Construct a small in-memory `Internal.File` with the `makeBlankFile`
  helper, and tear it down with `deinitFile` (not `file.deinit()` —
   see the comment on `deinitFile` for why).
4. Drive the function under test directly (`fillPoint`, `drawPoint`,
  etc.) and assert on the resulting state.
5. If the code under test reads a `fizzy.editor` field the shim hasn't
  set, set it at the top of your test instead of broadening the shim.

## CI

`.github/workflows/ci.yml`: **push to `main`** runs only the fast
Ubuntu job (`zig build test`, `zig build check-web`, `zig build
test-sdk-version`). **Pull requests** and **manual**
(`workflow_dispatch`) runs additionally matrix across Linux/Windows/macOS.
Note `test-integration` / `test-all` are not run by CI at all today —
run them locally before relying on integration coverage.
`paths-ignore` skips doc-only changes on both `push` and
`pull_request`. Releases are handled separately by
`.github/workflows/release.yml`, triggered by pushing a `v*` tag.