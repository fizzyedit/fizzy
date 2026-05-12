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
covered:

- `[src/math/direction.zig](../src/math/direction.zig)` — 8-way / 4-way
direction encoding, `fromRadians`, rotation inverses.
- `[src/math/easing.zig](../src/math/easing.zig)` — `lerp`, `ease`,
endpoint pinning, midpoint bias.
- `[src/internal/layer_order.zig](../src/internal/layer_order.zig)` —
the layer-reorder algorithm used by the layers tree drag-and-drop.
- `[src/internal/palette_parse.zig](../src/internal/palette_parse.zig)`
— `.hex` palette file parser (valid hex, comments/blanks, malformed
input, CRLF).

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

- `Internal.File.init` — a blank file constructs with the expected
width/height/layer count.
- `Internal.File.fillPoint` mask-cache invalidation — regression for
the bucket-fill / selection-mask desync. After a fill on the
selected layer, `file.editor.mask_built_for_layer` must be `null` so
the selection overlay rebuilds from real pixels next frame. The
inverse case (filling the temporary layer) leaves the cache alone.
- `Internal.File.selectColorFloodFromPoint` — given a 4×4 layer split
into two solid color regions, flooding from one region selects
exactly those pixels and stops at the color boundary; out-of-bounds
seeds are no-ops.
- `fizzy.File` JSON parser — current-format parse + round-trip via
`std.json.Stringify.valueAlloc`, plus small fixtures for `FileV1`,
`FileV2`, and `FileV3` so that the legacy fallback chain in
`Internal.File.fromPathFizzy` keeps working as the public types
evolve.

What's intentionally **not** here yet:

- `History.undoRedo` — its `defer` block calls `dvui.toastAdd` and
reads `file.editor.canvas.id`, so testing it cleanly requires either
more shim or a small refactor to lift the toast logic into a
separate function.
- Full UI flows (tools, panels, transform, real undo). Driving
`App.zig` through dvui's testing harness with `dvui.testing.settle`
is the natural next step but needs asset loading to work in CI
without a real project root, theme bring-up without a config dir,
and a way to dismiss startup dialogs.
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

`.github/workflows/build.yml` is modeled on DVUI: **push to `main`**
(only) runs the fast Ubuntu `test` job (`zig build test`). **Pull
requests** and **manual** runs (`workflow_dispatch`) run the same
tests first, then the per-platform `zig build` jobs (`x86_64-linux`,
`x86_64-windows`, `arm64-macos`); those jobs `needs: test` so a
failing test stops the run before the matrix. Pushes to other branches
do not start this workflow unless you open a PR or trigger it
manually. `paths-ignore` skips doc-only changes on both `push` and
`pull_request` where applicable.