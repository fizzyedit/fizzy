# plugins/: the bundled plugins

Each directory is file for file the shape a third-party plugin has, and the template for one:
`plugin.zig`, an identity-only `plugin.zig.zon`, `build.zig` and `build.zig.zon`, an optional
`src/`. The one fizzy-specific part is `static/`, the glue that links a plugin into the app.
`shared/` is build helpers, not a plugin. The contract is `docs/PLUGINS.md`.

- **A plugin never imports another.** They meet at the SDK: a service, a command, an event. When
  one plugin needs something from fizzy, build the seam another plugin would reuse, not a path
  for this one.
- **Each one compiles twice:** static into the executable (every target, web included) and as the
  dylib that actually runs on the desktop. Code must work in both modes.
- **`cd plugins/<name> && zig build` also installs** into the real plugins directory. For a
  sandbox, set `FIZZY_PROFILE` to a directory of your own for the build and for the fizzy you run.
- **Keep app-only dependencies out.** A plugin depends on `sdk/`, never the repo root. After any
  build-graph change, run the Velopack acceptance test in the root `AGENTS.md`.
- **Tests:** a std-only file (`text/src/textcore/`, `markdown/src/md/block_heights.zig`, …) gets a
  root in `build/app.zig`'s unit list. A test that needs the plugin's module runs from
  `test-integration` (`fizzy-text-plugin-tests`, `fizzy-md-parser-tests`).

## Pitfalls

- **Two copies, two sets of globals.** The static copy and the dylib each have their own module
  variables. Host code that writes a plugin's global by symbol writes the static copy, which the
  running dylib never sees. Reach plugin state through a service or a vtable hook.
- **`sdk.host()` panics until the host installs the runtime,** which happens only on the plugin
  load path. Code that also compiles into `test-integration`, where the plugin is a plain module
  and nothing registers it, must take the host explicitly. See `render_ast.highlight_host`, set
  from `register`.
- **`Host.treeSitterHighlightFor` skips a provider with no `owner`.** A test that registers a fake
  `LanguageSupport` must give it a `sdk.Plugin`, or the lookup silently returns null.
- **A test build that overwrote a user's installed plugin is theirs to restore.** Say so. Don't
  copy anything back from the loader's `.load-copy/`.
- **An installed dylib refuses to load if its optimize mode differs from the app's**
  (`AbiOptimizeMismatch`). `zig build` defaults to Debug, and store plugins are built
  ReleaseFast.
- **A Fizzy built from `main` past an SDK release refuses plugins built against that release**
  (`AbiShapeMismatch`): `sdk` feature PRs move the shape and leave `sdk_version` alone. Build
  the plugin against the checkout's SDK with `zig build --fork=<fizzy>/sdk`.
- **A plugin built from the released SDK tarball ignores local `sdk/` and `core/` edits.** To
  test an SDK change end to end, point its `build.zig.zon` `.fizzy` dependency at a *relative*
  path (`../../fizzy/sdk`; absolute paths are rejected).
- **On the web,** plugins are wasm side modules: `zig build -Dtarget=wasm32-freestanding
  -Doptimize=ReleaseSmall`, loaded with `?plugin=<id>` (`web/AGENTS.md`). The host must be the
  same optimize class, and dvui on the web draws only on request, so a plugin with work in
  flight calls `sdk.refresh()`.
