# sdk/: the plugin contract

Everything a plugin compiles against. What the contract *is* lives in `docs/PLUGINS.md`; this
file is the rules for changing it.

- **The boundary has a fingerprint.** Changing the shape of a type a plugin sees (fields, enum
  tags, fn signatures) fails the build with the new value. Record it as
  `recorded_sdk_shape_fingerprint` in `src/version.zig` and label the PR `sdk`. Never touch
  `sdk_version.zig` outside a release PR (`CONTRIBUTING.md`, "Changing the SDK").
- **A new boundary type goes in `sdk_boundary_types`** (`src/dylib.zig`), or the fingerprint never
  sees it change.
- **This directory ships on its own** as `fizzy-sdk-v*.tar.gz` (`scripts/pack-sdk.sh`), holding
  only what `build.zig.zon`'s `.paths` lists. A new top-level file here goes in that list too;
  `scripts/check-examples.sh` builds the example plugin from the packed tarball and catches it.
- **dvui is pinned here and nowhere else** (`build.zig.zon`). See the root `CLAUDE.md` for why
  re-adding it to the root zon breaks the fingerprint.
- **One module per file.** Nothing outside reaches in by relative path; the app and build scripts
  go through `@import("fizzy_sdk")`. Nothing here imports `app/` or `src/`.
- **`tape/` is std-only, `replay/` is dvui and `tape` only.** A reach into `core` or `app` from
  either fails to compile on purpose: they are libraries any dvui app can take.
- **Tests** in `src/` run in `fizzy-sdk-tests` (`zig build test-integration`), rooted at
  `src/sdk.zig`. A file reached only through a `pub const x = @import(…)` nothing uses is never
  analyzed; `zig build check-tests-reached` names its tests. A std-only file can take a root of
  its own in `build/app.zig` instead (`Manifest.zig`, `services/wikilink.zig`).
- After touching `src/**`, run every gate: `zig build`, `test`, `test-integration`, `check-web`,
  `test-sdk-version`.
