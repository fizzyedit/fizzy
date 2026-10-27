---
name: fan-boundary
description: Superfan for the plugin boundary and the SDK. Nitpicks sdk/src changes against the recorded fingerprint, relative imports across module edges, plugins importing each other, app-only deps leaking into plugin builds, allocator misuse, and the example repos. Files deduplicated findings in fizzyedit/work. Run as /fan-boundary by its routine.
needs: cloud-linux
---

# fan-boundary

Read `.claude/skills/fan-common/SKILL.md` first and follow it: setup, run-only-when-main-changed,
fingerprints and dedupe, the issue format, caps, budget, the run record.

## 1. Obsession

The line between the app and its plugins. A plugin sees `sdk/` and `core/` and nothing else;
the app consumes `sdk/` as a dependency; `recorded_sdk_shape_fingerprint` matches the live
shape. Anything that blurs that line, a regression or a near miss, is yours. Everything else
(performance, looks, docs wording, tests) is out of scope: leave it for its own fan.

## 2. Where to look

- `sdk/src/**`, `sdk/*.zig`, `sdk/build.zig*`, `sdk/core_module.zig`, `sdk/plugin_sdk.zig`
- `plugins/*/` (`plugin.zig`, `src/**`, `static/**`, `build.zig`, `build.zig.zon`)
- `src/**` and `app/**` imports; `build/*.zig`; the root and `sdk/` `build.zig.zon`
- `AGENTS.md` ("Keep the plugin build free of app-only dependencies") and `sdk/AGENTS.md`,
  `plugins/AGENTS.md`, `app/AGENTS.md` for the rules as written
- Commands: `zig build test-sdk-version`, `scripts/check-examples.sh`, the plugin acceptance
  test in `AGENTS.md`. Use `scripts/zb` for builds where it exists.

## 3. Checks

1. **fingerprint-drift**: `zig build test-sdk-version` fails, or a diff under `sdk/src/**` moves
   the boundary's shape (a `pub` signature, a vtable field, an extern struct) while
   `recorded_sdk_shape_fingerprint` is unchanged, or `sdk_version` moved outside a release PR.
   Hit: the failing step, or the diff hunk and the missing record.
2. **relative-sdk-import**: `grep -rn '@import("[./]*sdk/' src app --include=*.zig`. Nothing under `src/` may import an `sdk/` file by
   path; build scripts reach it through `@import("fizzy_sdk")`. Hit: file:line.
3. **plugin-cross-import**: a plugin's `@import` or `build.zig.zon` dependency naming another
   plugin (`plugins/<a>` reaching `plugins/<b>`), instead of a service through the host. Hit:
   file:line and the two plugin names.
4. **app-dep-leak**: in `plugins/image` after `rm -rf .zig-cache zig-out zig-pkg &&
   zig build -Doptimize=ReleaseFast`, `ls zig-pkg | grep -i velo` is not empty; or a plugin zon
   depends on the repo root instead of `sdk/`; or `@import("velopack_zig")` appears. Run it with
   `FIZZY_PROFILE` set to a scratch directory (a plain plugin build installs into the real plugins
   directory) and only when a `build.zig*`/`zon` file changed or on a full sweep; delete the caches after.
5. **dvui-second-pin**: a `.dvui` dependency in the root `build.zig.zon`, or dvui pinned in
   any place but `sdk/build.zig.zon`.
6. **allocator-misuse**: plugin code calling `dvui.currentWindow().gpa`, or keeping a
   `host.arena()` slice across frames, or storing a slice borrowed from plugin memory in host
   state. Hit: file:line and what outlives what.
7. **examples-break**: `scripts/check-examples.sh` fails (example-app or example-plugin no
   longer build against this tree). Hit: the failing step's first error line.
8. **register-by-name**: `app/` or `src/` registering or special-casing a plugin by name
   outside the bundled-plugin build data (`build/sdk.zig`, `build/plugins.zig`).

A hit is only filed after its Repro runs (or its lines are cited) per `fan-common` section 4.

## 4. Known and accepted

None yet. The PM adds a line here, as `fan:boundary/<check-id>/<path>[:<symbol>]`, for each
issue the maintainer dismissed.

## 5. Severity guide

- **high**: a released or releasable plugin breaks or a build fails (1, 4, 7 failing; a
  fingerprint change with `sdk_version` bumped by a feature PR).
- **med**: a rule from `AGENTS.md` is broken but builds today (2, 3, 5, 6).
- **low**: a near miss or style of boundary (8, a comment naming a banned import).

## 6. Budget

80k tokens, at most 40 files read in full (read diffs and grep results first). `zig build`
steps only those named above; nothing else is built.
