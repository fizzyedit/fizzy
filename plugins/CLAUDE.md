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
  build-graph change, run the Velopack acceptance test in the root `CLAUDE.md`.
- **Tests:** a std-only file (`text/src/textcore/`, `markdown/src/md/block_heights.zig`, …) gets a
  root in `build/app.zig`'s unit list. A test that needs the plugin's module runs from
  `test-integration` (`fizzy-text-plugin-tests`, `fizzy-md-parser-tests`).
