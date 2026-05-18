# Fizzy → Web (Wasm) Port Plan

Living plan for shipping fizzy as a browser app via WebAssembly. Read this top-to-bottom before resuming.

## Goal

Run the full fizzy editor client-side in a browser via DVUI's web backend, deployed to `https://fizzyed.it/app/` from the existing `docs/` directory on the fizzy repo. The native desktop build must continue to work unchanged at every step.

## Reference points

- **Graphl** at `/Users/foxnne/dev/graphl/ide/` — sibling DVUI project that ships as a web app. Uses `wasm32-wasi` + vite + npm. We are intentionally taking the simpler `wasm32-freestanding` + static-files path instead, since GH Pages only needs static files.
- **DVUI upstream** at `/Users/foxnne/dev/dvui-dev/` (also vendored under `/Users/foxnne/dev/fizzy/zig-pkg/dvui-…/`). Web backend lives at `src/backends/{web.zig, web.js, index.html}`. The `examples/web-test.zig` and `examples/app.zig` show the pattern we mirror.
- **DVUI `addWebExample` helper** at `/Users/foxnne/dev/dvui-dev/build.zig:1379` — we re-implement this in fizzy's `build.zig` rather than call it.

## Decisions made

| Topic | Decision |
|---|---|
| Target triple | `wasm32-freestanding` (no WASI shim, no npm) |
| DVUI backend | `.backend = .web, .freetype = false` via a second `b.dependency("dvui", …)` call |
| Deploy path | `docs/app/` under the existing `fizzyed.it` Pages site, future workflow uses `actions/deploy-pages` (migrating Pages source from "branch /docs" to "GitHub Actions" — repo setting change) |
| Asset strategy | Continue `@embedFile`ing the atlas. No extra runtime fetches beyond what DVUI does (Noto font). |
| File I/O | DVUI's built-in `wasm_open_file_picker` + `wasm_download_data`. No FS Access API gate. |
| Threading | `single_threaded = true` on the wasm exe; every `std.Thread.spawn` site gated `arch != .wasm32`. |
| Singleton / drag-drop / native menus | No-op stubs on web. Optional HTML5 drag-drop bridge is a stretch goal. |

## Architecture: arch-switching facade pattern

Native-only modules are split into two files plus a facade:

- `src/<name>_native.zig` — the original code, untouched (SDL3 / objc / win32 / threads / FS).
- `src/<name>_web.zig` — stubs mirroring the native public API. No-ops, minimal allocations, returns sensible defaults.
- `src/<name>.zig` — tiny facade re-exporting from one or the other based on `builtin.target.cpu.arch == .wasm32`.

**Why a facade rather than inline arch-conditional imports?** Both work, but the facade keeps call-site files unaware of the split. Zig's lazy semantic analysis means the non-chosen branch's symbols are never analyzed — so the wasm build never sees `backend_native.zig`'s SDL3 imports, and the native build never sees `backend_web.zig`'s stubs.

`fizzy.zig`'s `pub const backend` currently does the arch switch inline at file scope rather than via a facade file — that's an inconsistency to clean up later.

## Status

### Checkpoint A — `zig build web` produces a working wasm artifact ✅

- New `web` step in [build.zig](build.zig). Independent of native build paths.
- [src/web_main.zig](src/web_main.zig) — wasm entry, modeled on DVUI's `examples/web-test.zig`. Currently a placeholder app that imports `fizzy.zig` and shows the version string.
- Artifacts at `zig-out/web/`: `web.wasm`, `web.js`, `index.html` (cache-busted), `NotoSansKR-Regular.ttf`.
- Verified: serves cleanly via `python3 -m http.server` (see [.claude/launch.json](.claude/launch.json) — fizzy-web entry), DVUI renders, no console errors.

### Checkpoint B (in progress) — boot the real editor in browser

**Latest (this session):** Editor boots and draws in browser. Fixed runtime `wasm_renderGeometry: missing texture id N` when painting: DVUI web backend has no `textureUpdateSubRect`, so `updateSubRect` destroys/recreates the GPU texture while the texture cache kept the old id (destroyed at next `Window.begin`). `src/gfx/render.zig` now calls `textureAddToCache` when the texture pointer changes after upload.

`web_main.zig` uses `fizzy.App.dvui_app` (real `AppInit` / `AppFrame` / `AppDeinit`). `zig build check-web` and `zig build web` both succeed. Debug wasm is ~29 MB; use `-Doptimize=ReleaseSmall` before deploy.

Sub-tasks landed so far:
- ✅ **`backend.zig` split** — [src/backend_native.zig](src/backend_native.zig) (the original SDL3 + objc + win32 code, renamed), [src/backend_web.zig](src/backend_web.zig) (19 stubs). [src/fizzy.zig:75-78](src/fizzy.zig) switches inline.
- ✅ **`singleton.zig` split** — [src/singleton_native.zig](src/singleton_native.zig), [src/singleton_web.zig](src/singleton_web.zig), [src/singleton.zig](src/singleton.zig) facade.
- ✅ **`auto_update.impl` gate** — was `os.tag != .wasi`, now `arch != .wasm32` ([src/auto_update.zig:5](src/auto_update.zig)). Covers freestanding too.
- ✅ **web_main pulls `fizzy.zig`** — confirms Zig's lazy analysis means the unreferenced parts of `fizzy.zig` (App, Editor, etc.) don't get analyzed on wasm.
- ✅ **Probe block in [src/web_main.zig](src/web_main.zig)** — comptime references to ~20 `fizzy.*` symbols, all compile clean for wasm32-freestanding (including `fizzy.Editor` and `fizzy.App` as types, and `fizzy.dvui.FileWidget` whose file has an unused `@import("backend").c` SDL3 import).

### Major finding from probe session

**Zig's lazy analysis is doing far more work than initially feared.** A file-scope `const x = @import("backend").c;` that is *never referenced inside the file's body* is not analyzed — the missing `backend` module doesn't error. This is the case for many of fizzy's editor files, including widgets that look at first glance like they'd block wasm.

**Important nuance**: `_ = some_fn` (a const-discard reference to a function) does NOT trigger full body analysis. The body is only fully analyzed when the function is **wired into a reachable call site** — e.g. assigned to a `dvui.App` function-pointer field, or directly called. The comptime probe block in `web_main.zig` is therefore a *lower bound* on the wasm surface — it catches type-level failures (missing pub decls, type signature mismatches) but **not** body-level failures (missing modules in imports a function actually uses, posix surfaces, threads, etc.).

Implication: **the port no longer requires pre-emptively splitting every native-tied module.** The pattern shifts to:

1. Wire `App.zig`'s init/frame/deinit functions into `dvui_app` (real call sites).
2. Compile.
3. Each compile error pinpoints one specific reachable line that touches an unavailable API (FS, threads, SDL3 calls, native dialogs).
4. Gate or refactor that line.
5. Repeat until clean.

### Concrete error inventory (updated)

Wiring `fizzy.App.AppInit/AppFrame/AppDeinit` as the `dvui_app` lifecycle fns currently surfaces **14 compile errors**. Down from the original 10 surface because deeper analysis surfaced more — but the categories are clearer now. See "What this session landed" below for what's already fixed.

### What landed in the most recent push session

The current session landed a *lot* of incremental gates and source fixes. Each one shrank the leap-attempt error count. Pattern: an arch-gate at the call site (not the implementation) where the wasm-incompatible path is reached.

**Source fixes (improve both builds)**:
- `History.zig:621` allocator was `[]usize`, should be `[]u64` matching `layers_order.order`.
- `History.zig:735` same pattern for animation orders.
- `Tools.zig:245`, `editor/explorer/tools.zig:499/542/555`, `editor/explorer/sprites.zig:99/831/843/1604` — many `id_extra = id_u64` sites needed `@intCast(usize)`.
- `editor/Workspace.zig:93/127/140` `.id_extra = self.grouping` (u64) needed `@intCast`.
- `editor/explorer/sprites.zig:99` `(c << 48)` overflowed u32 (usize on wasm); widened to `@as(u64, c)`.

**Module wiring (web build)**:
- `assets`, `build_opts`, `known-folders`, `zip` (Zig wrapper only, not the C source).

**Refactor — DialogFileFilter unified**:
- `fizzy.backend.DialogFileFilter` re-exports SDL3's filter struct on native, defines its own extern struct on web. Editor call sites changed to use it. The `const sdl3 = @import("backend").c;` in `Editor.zig` / `Export.zig` / `FileWidget.zig` is now dead — Zig's lazy analysis skips it. No `backend` stub module needed in the web build.

**Wasm-only gates added**:
- `App.zig` `executableDirPath` + `chdir` block.
- `App.zig` Packer.init (uses tools/Packer.zig zstbi).
- `editor/Editor.zig:195-197` env-map / known_folders.getPath (Environ.put GlobalBlock.view error).
- `editor/Editor.zig:343` appendUserThemes (Io.Dir iterator → NAME_MAX).
- `editor/Editor.zig:213-231` legacy config-folder migration (Io.Dir.renameAbsolute → posix.AT).
- `editor/Editor.zig:376-401` config/palette folder access + createDirAbsolute, Recents.load.
- `editor/Editor.zig:669` processPackJob.
- `editor/Editor.zig:1805` async file load thread spawn.
- `editor/Editor.zig:1904-1918` startPackProject (whole body — pulls Io.Dir.Iterator).
- `editor/Editor.zig:2982-3000` deinit's project.save / recents.save / saveSettingsRaw.
- `editor/dialogs/AboutFizzy.zig:134` std.c.getenv.
- `editor/explorer/project.zig` whole `draw()` (file-scope Packer field accesses).
- `editor/explorer/files.zig` whole `draw()` (file tree recurses disk).
- `internal/File.zig:2891-2914` initSaveQueue / deinitSaveQueue (Thread.spawn / Thread.join).
- `auto_update.impl` widened to `arch != .wasm32`.

**Build infrastructure**:
- New `check-web` step in [build.zig](build.zig): compile-only smoke test for wasm. Pair with `check` for CI.

### Major finding from probe session

- ✅ `src/internal/File.zig:2766` — `self.id` (u64) → `@intCast(usize, …)` for `dvui.toastAdd`. (Native unaffected since usize == u64.)
- ✅ `src/internal/History.zig:623` — same pattern: layer id u64 → `@intCast(usize)`.
- ✅ `icons` module wired into the web step in [build.zig](build.zig).
- ✅ **Refactor: `DialogFileFilter` is now a fizzy-owned type.** Native: re-exports `sdl3.SDL_DialogFileFilter`. Web: defines its own extern struct. Editor call sites changed from `sdl3.SDL_DialogFileFilter` to `fizzy.backend.DialogFileFilter` in `Editor.zig` (1) and `Export.zig` (4). The `const sdl3 = @import("backend").c;` decls in those files are now dead — Zig's lazy analysis skips them. **No `backend` stub module needed in the web build.**
- ✅ `App.zig` `executableDirPath` + `chdir` block gated to native (`arch != .wasm32`); on web the path is just `"."`.
- ✅ New `check-web` build step — compile-only smoke test for the wasm target. Pair with `check` for unit tests. Useful for CI.

### Remaining errors (14) — resolved this session

The leap to `fizzy.App.dvui_app` is **compile-clean**. Remaining work is runtime (open/save via DVUI file picker + `wasm_download_data`, explorer file tree on wasm, ReleaseSmall size).

**stdlib surfaces** (8 errors — all from depths beyond direct App.zig calls):
1. `std.Io.Dir.NAME_MAX` — `NAME_MAX not implemented for freestanding`.
2. `std.Io.Threaded:2064 getrandom` — Threaded.zig reached for some Io impl.
3. `std.Thread:346` — `Cannot spawn thread when building in single-threaded mode` (×2).
4. `std.Thread:493` — `Unsupported operating system freestanding`.
5. `std.c.zig:1` — `dependency on libc must be explicitly specified`.
6. `std.posix.AT` — somewhere using `AT_FDCWD` etc.
7. `std.posix.IOV_MAX` — vectored I/O surface.
8. `std.process.Environ.GlobalBlock.view` — `fizzy.processEnviron()` uses `.block = .global` which is Windows-only.

**Missing modules** (4 errors):
9. `src/editor/Editor.zig:5` — `known-folders` (pure Zig, should compile clean — easy wire).
10. `src/editor/dialogs/AboutFizzy.zig:7` — `assets` (use `assetpack.pack(b, …)` like native; should compile).
11. `src/internal/File.zig:3` — `zip` (need to check if portable; likely needs source surgery).
12. `src/tools/Packer.zig:2` — `zstbi` (deferred — zstbi.c needs source patch to compile for wasm32-freestanding).

**Source bugs** (2 errors):
13. `src/internal/History.zig:653` — second pointer-type mismatch. Same `usize` vs `u64` family of issue (similar to the one already fixed at line 623). Need to look at the context.
14. (one residual error that follows from the others)

### Current leap status (after most recent push)

Wiring `fizzy.App.AppInit / AppFrame / AppDeinit` currently surfaces ~10 remaining errors. Most are:

**Persistent stdlib errors** (don't trace to a single fizzy call site — appear to come from stdlib globals reached by the debug allocator or std.std.debug_io path):
- `NAME_MAX not implemented for freestanding` — Io.Dir.Iterator. Was reachable via files.zig (gated) and gatherPackInputs (gated). May still reach via other dir iterators.
- `posix.system.getrandom` — via `std.debug_threaded_io` → `Io.Threaded` global instance → `std.debug.captureCurrentStackTrace`. Suggests std.debug is being pulled in (probably any reachable code that uses std.heap.DebugAllocator or std.debug.print).
- `posix.AT` — via Io.Dir.cwd. Was reached via Editor.deinit (gated), Project.save (gated), Editor.init's renameAbsolute (gated), Recents.save (gated). May still reach.
- `posix.IOV_MAX` — same chain as getrandom.

These four likely trace to **one or two common fizzy call sites** that pull in the debug allocator or a debug-print path. Need fresh `-freference-trace=12` to identify.

**Outstanding source bugs** (u64 → usize on wasm32):
- `editor/explorer/sprites.zig:1604` etc. — keep cropping up. Audit-pass needed.
- `editor/widgets/FileWidget.zig:988` and `:3678` — `?usize` from `u64`.
- `editor/Workspace.zig:127`, `:140` — already fixed.

**Outstanding module errors**:
- `Export.zig:5 msf_gif` — wire `msf_gif` module into the web build (similar to zstbi situation — likely needs gating instead).
- `Export.zig:7 zstbi` — same as Packer; gate Export.draw on wasm.

### Strategy for next session

1. **Audit + fix all remaining u64-where-usize-expected sites in one sweep.** Use a grep like `grep -rn "id_extra\s*=" src/` and `grep -rn "getDVUIColor\(.*\.id\)" src/` to find them all.
2. **Identify the debug-allocator reach.** The stdlib `getrandom`/`IOV_MAX` errors come from `std.debug.captureCurrentStackTrace` → `debug_allocator.free`. Find what fizzy code is using `std.heap.GeneralPurposeAllocator` or `std.debug.print` on a wasm-reachable path. Likely it's an error-path log. Gate or switch the allocator on wasm.
3. **Gate Export.draw and any other dialog draws** that reach msf_gif / zstbi at file scope.
4. **Re-attempt the leap.** If <5 errors remain, push through them. If the editor compiles, swap to `fizzy.App.AppInit` and screenshot the browser.

### What I'd actually try first next session

Run `zig build web -freference-trace=20 2>&1 | head -200` and look for the **deepest common ancestor** of the four stdlib errors. That likely identifies one or two call sites that are pulling in the debug-stacktrace + Threaded-Io chain. Gating those should resolve all four at once.

## Remaining work (ordered)

### 1. ~~Wire more modules into the web build → check what's already wasm-clean~~ ✅ DONE

Probe block landed in [src/web_main.zig](src/web_main.zig). No additional module wiring was needed — the wasm-reachable surface of `fizzy.*` analyzed clean against just the `dvui` + `web-backend` modules already wired. See "Major finding" above.

### 2. Probe-compile the C deps for `wasm32-freestanding`

Try building each as wasm-only libraries: `src/deps/zip`, `src/deps/stbi`, `src/deps/msf_gif`. If any fail, that's a real blocker — `zip` is most at risk (it's a static lib with platform code). Fallback: pure-Zig zip reader/writer, or skip on wasm and don't offer .pixi save/load until later.

### 3. Refactor direct `@import("backend")` SDL3 sites

Three files use `@import("backend").c` directly:
- [src/editor/Editor.zig:7](src/editor/Editor.zig)
- [src/editor/widgets/FileWidget.zig:6](src/editor/widgets/FileWidget.zig)
- [src/editor/dialogs/Export.zig:6](src/editor/dialogs/Export.zig)

Either:
- (a) Add a `backend` module mapping that returns a stub `c` namespace on wasm (e.g. `src/sdl3_stub.zig` with a `pub const c = struct { pub const SDL_DialogFileFilter = …; };`), wired via build.zig's web step.
- (b) Refactor each call site to go through `fizzy.backend` (the facade), so the SDL3 type leaks from these files.

(a) is faster, (b) is cleaner. Probably do (a) first to unblock, refactor later.

### 4. Gate thread spawns

Three sites, each a discrete `std.Thread.spawn` (already audited):
- [src/Assets.zig:185](src/Assets.zig) — watcher (also: the `Watcher` selector at line 22 has `else => @compileError(…)` — needs a wasm branch returning a no-op).
- [src/internal/File.zig:2891](src/internal/File.zig) — `saveQueueWorker`. The save flow needs an inline path on wasm (one save → one `wasm_download_data` blob).
- [src/update_notify.zig:64](src/update_notify.zig) — already unreachable on wasm because `auto_update.impl == false` short-circuits earlier.

### 5. FS watcher modules

[src/tools/watcher/{Linux,Macos,Windows}Watcher.zig](src/tools/watcher) — none compile on wasm. Add a `noop_watcher.zig` and add a wasm branch to the selector in [src/Assets.zig:22](src/Assets.zig).

### 6. App.zig wasm path

Gate the native init calls in [src/App.zig](src/App.zig):
- Line 97: `std.process.executableDirPath` — wasm doesn't have an exe path. Skip; assets are `@embedFile`d.
- Lines 100-105: `std.posix.system.chdir` — wasm has no cwd. Skip.
- Singleton / file-open / SDL metadata / macOS menu bar calls are already facade-routed, so they're already no-ops on wasm.
- Editor + Packer construction call chains are the long pole — surfaces tons of editor-deep native deps.

### 7. ~~Update `web_main.zig` to use `fizzy.App.dvui_app`~~ ✅ DONE

`src/web_main.zig` re-exports `fizzy.App.dvui_app`, `main`, `panic`, and `std_options`.

### 8. HTML5 drag-drop bridge (stretch)

DVUI's `web.js` has no `drop` listener. Extend it to call a fizzy-exported `wasm_drop_file(name_ptr, name_len, data_ptr, data_len)` on drop. Mirror the SDL_EVENT_DROP_FILE path in `backend_native.zig:1097-1132` so the editor's existing open-file handler is the consumer.

### 9. GH Pages deploy workflow

Add `.github/workflows/deploy-web.yml`:
- Trigger: `push: { branches: [main] }` + `workflow_dispatch`.
- Build: `zig build web -Doptimize=ReleaseSmall`.
- Stage: copy `docs/*` (existing landing) into `site/`, then `zig-out/web/*` into `site/app/`.
- Deploy: `actions/upload-pages-artifact@v3` + `actions/deploy-pages@v4`.

One-time repo setting: **Settings → Pages → Source = "GitHub Actions"** (currently "branch: main /docs"). After flipping, the workflow assembles the published site. The CNAME `docs/CNAME` = `fizzyed.it` continues to work.

Add a "Try it in your browser →" link from [docs/index.html](docs/index.html) to `/app/`.

### 10. Polish

- Loading screen while wasm streams in (1–3 MB at ReleaseSmall).
- WebGL2 feature check before wasm instantiation.
- Optional: File System Access API path for browsers that support it, so "Save" overwrites instead of re-downloading. Gate by feature detection.

## Files touched by this port (so far)

```
build.zig                       (web step added; check-web step; icons wired for web)
build.zig.zon                   (unchanged — single dvui dep services both arches)
.claude/launch.json             (new — fizzy-web dev server entry)
src/web_main.zig                (new — wasm entry using DVUI App pattern + probe block)
src/backend.zig                 (deleted; arch switch inlined in fizzy.zig)
src/backend_native.zig          (renamed from backend.zig; +DialogFileFilter re-export)
src/backend_web.zig             (new — 19 stubs + DialogFileFilter type)
src/singleton.zig               (rewritten as facade)
src/singleton_native.zig        (renamed from singleton.zig)
src/singleton_web.zig           (new — no-op stubs)
src/auto_update.zig             (impl gate widened to arch != .wasm32)
src/fizzy.zig                   (arch switch for backend)
src/App.zig                     (executableDirPath/chdir + Packer.init wasm-gated)
src/internal/File.zig           (toastAdd id cast; initSaveQueue/deinitSaveQueue gated)
src/internal/History.zig        (layer/animation id alloc fixes)
src/editor/Editor.zig           (DialogFileFilter refactor; many wasm gates)
src/editor/Tools.zig            (id_extra @intCast)
src/editor/Workspace.zig        (id_extra @intCast — 5 sites)
src/editor/dialogs/AboutFizzy.zig (std.c.getenv gated)
src/editor/dialogs/Export.zig   (DialogFileFilter refactor, 4 sites)
src/editor/dialogs/Export_web.zig (wasm stub — no msf_gif/zstbi)
src/editor/dialogs/Dialogs.zig  (arch-switch Export import)
src/editor/Project.zig          (wasm gates on load/save)
src/editor/Settings.zig         (wasm default settings, no fs.read)
src/editor/explorer/IgnoreRules.zig (wasm no-op load)
src/editor/explorer/tools.zig   (skip searchPalettes on wasm)
src/gfx/perf.zig                (no std.debug.print on wasm)
src/web_main.zig                (wired to fizzy.App.dvui_app)
src/editor/explorer/files.zig   (whole draw() wasm-gated)
src/editor/explorer/project.zig (whole draw() wasm-gated)
src/editor/explorer/sprites.zig (selectionUiKey u64 widening; @intCast sites)
src/editor/explorer/tools.zig   (getDVUIColor + id_extra @intCast sites)
WEB_PORT_PLAN.md                (this file)
```

## Important Zig gotchas learned

- **Lazy semantic analysis**: `@import("missing_module")` at file scope does NOT error unless the resulting const is actually referenced. This is why `fizzy.zig`'s `const mach = @import("mach")` survives even though no `mach` module is wired. Use this — don't pre-emptively gate file-scope `pub const` decls; they only get analyzed when referenced from a reachable path.
- **`usingnamespace` is removed in Zig 0.16.** Facades must do explicit `pub const X = impl.X;` re-exports.
- **`if (comptime_bool) @import("a") else @import("b")`**: only the chosen branch is semantically analyzed for any symbols you go on to use. The unchosen file is parsed but not analyzed. This is the foundation of the facade pattern.
- **DVUI web backend requires `vertex_index = .u16`** ([dvui-dev/build.zig:864](../dvui-dev/build.zig)). Currently we don't override it; default is fine.
- **DVUI web exports** are set on the `web` module's `export_symbol_names`. They propagate transitively through the import graph — fizzy's `web_main.zig` doesn't need to repeat them.
- **`wasm32-freestanding` has no libc, no threads, no FS, no `std.process.executableDirPath`, no `std.posix.chdir`, no `std.c.environ`.** Every reachable site that uses these needs an arch gate.

## How to resume after a long pause

1. `cd /Users/foxnne/dev/fizzy && git status` — verify clean tree.
2. `zig build && zig build web` — confirm both targets compile.
3. Re-read this file. Pick the next item from "Remaining work".
4. The convention this port has settled on:
   - Native-only modules get the `<name>_native.zig` + `<name>_web.zig` + `<name>.zig` (facade) split.
   - Inline `if (arch == .wasm32)` is fine for one-or-two-line gates inside otherwise-portable files.
   - Each session leaves both `zig build` and `zig build web` green. No half-stubbed states between sessions.
5. After landing a change, screenshot via the preview MCP at http://localhost:8765 (server entry: `fizzy-web` in `.claude/launch.json`) to verify the wasm still boots.
