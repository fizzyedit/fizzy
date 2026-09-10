# fizzy tests

This directory contains fizzy's test scaffolding. If you've never written
tests in a Zig project before, start here.

## Running the tests

```sh
zig build test                 # pure-logic unit tests (CI entry point)
zig build check                # compile unit tests, don't run
zig build test --summary all   # show per-artifact pass/fail counts
zig build test-integration     # headless dvui + SDK tests (needs MSVC on Windows)
zig build test-all             # unit + integration + test-sdk-version
```

To narrow down to a single failing test while you debug:

```sh
zig build test -Dtest-filter="lerp endpoints"
```

`-Dtest-filter` accepts any substring of a test name and may be passed
multiple times. It applies to every test artifact under the step.

## How Zig tests work (quick orientation)

Zig has tests built into the language. Anywhere in any `.zig` file you
can write:

```zig
test "lerp halfway" {
    const std = @import("std");
    try std.testing.expectEqual(@as(f32, 5.0), lerp(0.0, 10.0, 0.5));
}
```

A `test "..."` block compiles only when Zig builds a *test binary* via
`b.addTest(...)` in `build/app.zig`. **Important:** Zig only registers
`test` blocks from that artifact's **root module**. Files pulled in as
a separate module (`addImport` / `addAnonymousImport` +
`_ = @import("name")`) are analyzed but their tests are never collected.
So every pure-logic file under test is itself a `b.addTest` root.

Same-module file imports (`@import("sibling.zig")` from the root file)
*do* collect tests — that is how `store.zig` picks up tests in
`registry.zig` / `download.zig`.

There is no separate framework. The standard library has assertions in
`std.testing`: `expect`, `expectEqual`, `expectEqualSlices`,
`expectEqualStrings`, `expectError`, `expectApproxEqAbs`.

## How fizzy tests are organized

fizzy has both pure logic and a GUI. Tests are split into two steps,
cheapest first. Wiring lives in `build/app.zig`.


| Step                   | Artifacts                                                                 | Needs a window? | Notes |
| ---------------------- | ------------------------------------------------------------------------- | --------------- | ----- |
| `zig build test`       | One `b.addTest` per pure-logic file (`fizzy-direction-tests`, …, `fizzy-fuzzy-tests`) | No | CI entry; no dvui/SDL/Velopack |
| `zig build test-integration` | `fizzy-sdk-tests` (`sdk/src/sdk.zig`) + `fizzy-plugin-loader-tests` (`src/editor/PluginLoader.zig`) + `fizzy-integration-tests` (`tests/integration.zig`) | Headless (dvui testing backend) | Not run by CI today |


### Unit tests (pure logic)

Each covered file is its own test artifact root in `build/app.zig`
(std-only, or std + a named dep like `zf` for fuzzy). Currently:

- [`core/math/direction.zig`](../core/math/direction.zig) —
  `fizzy-direction-tests` — 8-way / 4-way direction encoding,
  `fromRadians`, rotation inverses.
- [`core/math/easing.zig`](../core/math/easing.zig) —
  `fizzy-easing-tests` — `lerp`, `ease`, endpoint pinning, midpoint bias.
- [`core/math/layout_anchor.zig`](../core/math/layout_anchor.zig) —
  `fizzy-layout-anchor-tests` — anchor math shared by grid/layout code.
- [`src/backend/window_layout.zig`](../src/backend/window_layout.zig) —
  `fizzy-window-layout-tests` — macOS window/Space transition geometry helpers.
- [`src/backend/plugin_store/store.zig`](../src/backend/plugin_store/store.zig) —
  `fizzy-plugin-store-tests` — catalog/registry/download parsing (sibling
  file imports keep those tests in the same module).
- [`core/lsp/Protocol.zig`](../core/lsp/Protocol.zig) —
  `fizzy-lsp-protocol-tests` — LSP message framing/parsing.
- [`core/lsp/UriUtil.zig`](../core/lsp/UriUtil.zig) —
  `fizzy-lsp-uri-tests` — `file://` URI ↔ path conversion.
- [`src/editor/SettingsPluginsZon.zig`](../src/editor/SettingsPluginsZon.zig) —
  `fizzy-settings-plugins-zon-tests` — ZON-AST byte-span surgery on `settings.zon`.
- [`sdk/src/manifest.zig`](../sdk/src/manifest.zig) —
  `fizzy-sdk-manifest-tests` — `plugin.zig.zon` parsing (std-only, so it lives
  in the unit layer even though it sits under `sdk/src/`).
- [`core/fuzzy.zig`](../core/fuzzy.zig) —
  `fizzy-fuzzy-tests` — fuzzy matcher wrapper over `zf` (needs a `zf` import).

### Integration / SDK tests (headless)

`zig build test-integration` runs three artifacts:

1. **`fizzy-sdk-tests`** — root module `sdk/src/sdk.zig`, with
   dvui-testing + `proxy_bridge` + `core` wired the same way as the app.
   Collects same-module `test` blocks under `sdk/src/` (`dylib.zig` ABI
   fingerprint, `fingerprint.zig`, `settings.zig`, `Host.zig`,
   `version.zig`). These cannot live under `zig build test` because the
   SDK imports dvui. Caveat: a file reached only through an *unreferenced*
   `pub const x = @import("x.zig")` in `sdk.zig` is analyzed lazily and
   contributes no tests — that is why `manifest.zig` has its own root in
   the unit layer. Always confirm the reported test count went up.

2. **`fizzy-plugin-loader-tests`** — root module
   `src/editor/PluginLoader.zig`. Pure-logic tests (plugin dir/path
   resolution) that only need the integration layer because the file
   imports `dvui` and `fizzy_sdk`.

3. **`fizzy-integration-tests`** — `tests/integration.zig` exercises
   real fizzy code that needs a live `dvui.Window` and the `fizzy.entry()` /
   `fizzy.editor()` instances. dvui's `testing` backend creates a window with
   no GPU and no SDL; `tests/fizzy_shim.zig` heap-allocates just enough
   of those globals. The shim is deliberately minimal — when a new test
   needs a field the shim doesn't set, set just that field at the top of
   that test rather than expanding the shim.

Currently covered in the integration artifact:

- A single smoke test that the shim brings up a working headless
  `dvui.Window` with the `fizzy.entry()` / `fizzy.editor()` instances set.

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
   `core/math/easing.zig` was extracted from `math.zig` for a
   minimal example).
2. Add a `test "..."` block at the bottom of the file:
   ```zig
   const std = @import("std");

   test "my new thing" {
       try std.testing.expectEqual(@as(u32, 42), myFunction(...));
   }
   ```
3. If the file isn't already a unit-test root, add a
   `{ "fizzy-<name>-tests", "path/to/file.zig" }` entry to the
   `inline for` table in `build/app.zig` (or mirror the `fuzzy` block
   if it needs named imports like `zf`). Do **not** wire it through an
   aggregator root or `addAnonymousImport` — those do not collect tests.
4. Run `zig build test --summary all` and check the count for your
   artifact went up. A plain green run proves nothing.

### SDK (needs dvui / `proxy_bridge` / `core`)

1. Add a `test "..."` block in the relevant `sdk/src/*.zig` file.
2. Usually no build wiring: `fizzy-sdk-tests` is already rooted at
   `sdk.zig`, so same-module file imports pick the new block up.
3. Run `zig build test-integration --summary all` and verify the
   `fizzy-sdk-tests` count grew. If it didn't, the file is only reached
   through a lazily-analyzed decl — give it its own `addTest` root.

### Integration (when a test needs `dvui.currentWindow()` or fizzy globals)

1. Add the test to `tests/integration.zig`.
2. Bring up the shim at the top of the test:
   ```zig
   var ctx = try shim.init(std.testing.allocator);
   defer ctx.deinit(std.testing.allocator);
   ```
3. Drive the function under test and assert on the resulting state.
4. If the code under test reads a `fizzy.editor()` field the shim hasn't
   set, set it at the top of your test instead of broadening the shim.
5. Run `zig build test-integration`.

## CI

`.github/workflows/ci.yml`: **push to `main`** runs only the fast
Ubuntu job (`zig build test`, `zig build check-web`, `zig build
test-sdk-version`). **Pull requests** and **manual**
(`workflow_dispatch`) runs additionally matrix across Linux/Windows/macOS.
Note `test-integration` / `test-all` are not run by CI at all today —
run them locally before relying on integration or SDK coverage.
`paths-ignore` skips doc-only changes on both `push` and
`pull_request`. Releases are handled separately by
`.github/workflows/release.yml`, triggered by pushing a `v*` tag.
