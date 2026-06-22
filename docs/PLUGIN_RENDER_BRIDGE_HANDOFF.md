# Handoff: plugin render bridge (keep SDL/GPU in the shell)

> **Goal:** make Fizzy's runtime-loaded plugin **dylibs render correctly** without each one
> linking its own copy of SDL. Today every plugin dylib bakes in its own dvui SDL backend +
> its own SDL, which produces `SDL_RenderGeometryRaw ... Parameter 'renderer' is invalid` on
> every plugin draw (only shell-owned UI renders). The fix is a **forwarding/proxy dvui
> backend**: the plugin's dvui turns widgets into draw calls that are forwarded, through an
> injected C-ABI function table, to the **host's** real backend. SDL/GPU stay entirely in the
> shell; plugins link zero SDL.
>
> This work spans **two repos**:
> - **`dvui-dev`** (the `foxnne/dvui-dev` fork — checked out locally at `dev/dvui-dev`): add a
>   `proxy` backend + expose a `dvui_proxy` module. **This is the part to do first.**
> - **`fizzy`**: define the bridge table, implement host-side thunks, inject the table into each
>   loaded dylib, and switch plugin dylibs to import `dvui_proxy`. (Outlined here; do after dvui.)

Until this lands, plugins work in **static** mode (`FIZZY_STATIC_WORKBENCH=1
FIZZY_STATIC_PIXELART=1 ./fizzy`), where they share the shell's dvui/SDL directly.

---

## 1. Why this is needed (root cause)

dvui binds its backend **at compile time**. In `dvui-dev/src/Backend.zig`:

```zig
const Implementation = @import("backend");   // chosen when the dvui module is built
impl: *Implementation,
pub fn drawClippedTriangles(self: Backend, ...) { try self.impl.drawClippedTriangles(...); }
```

`self.impl.drawClippedTriangles(...)` is a **static call** into whichever backend the dvui
module was compiled with. Fizzy builds each plugin dylib against `dvui_sdl3`, so the dylib
contains its own copy of dvui's SDL backend (`sdl.drawClippedTriangles`) **and statically links
SDL** (confirmed: `nm libworkbench.dylib` shows `_SDL_RenderGeometryRaw` defined in `__TEXT`).

The host injects its live `current_window` into each plugin (see
`fizzy/src/sdk/dvui_context.zig`), so the plugin's dvui has the host's window — which holds the
host's SDL **renderer pointer**. But the *code* that consumes it is the plugin's own SDL backend
calling the plugin's own SDL. Passing the host's renderer handle to the plugin's separate SDL
runtime → "renderer is invalid", every frame, for every plugin draw.

Static plugins render fine because they're compiled into the exe and share the one true SDL.

**Conclusion:** plugins don't need SDL. They need a backend that converts dvui draw calls into
calls back to the host. That backend is the deliverable.

---

## 2. Architecture

```
   plugin dylib (its own dvui, NO SDL)            host exe (the one real dvui + SDL)
   ┌───────────────────────────────┐             ┌──────────────────────────────────┐
   │ widgets (textEntry, box, …)    │             │ real dvui_sdl3 backend (SDL)      │
   │        │ dvui immediate mode    │             │   drawClippedTriangles → SDL      │
   │        ▼                        │  C-ABI      │   textureCreate → SDL_Texture     │
   │ proxy backend Implementation   │ ─────────►  │   …                               │
   │   drawClippedTriangles(...) ─── calls ───────►│ thunk → host_window.backend.draw… │
   │   textureCreate(...)        ─── table ────────►│ thunk → host backend.textureCreate│
   └───────────────────────────────┘  (RenderBridge)└──────────────────────────────────┘
```

- The plugin's dvui is compiled with a **`proxy` backend** instead of `sdl3`.
- The proxy backend's methods forward to a **`RenderBridge`** — a struct of
  `*const fn(...) callconv(.c)` pointers the host fills in and injects into the plugin (exactly
  like the existing `fizzy_plugin_set_dvui_context` mechanism).
- The host implements each bridge fn as a thin thunk over its **real** `dvui.Backend`
  (the SDL one). All GPU/SDL state and calls stay in the host process's one SDL runtime.
- **Textures cross the boundary as opaque handles.** `dvui.Texture` is
  `{ ptr: *anyopaque, width, height, interpolation }`; `ptr` is the host backend's texture
  (e.g. `SDL_Texture*`). The proxy never interprets it — it just hands it back to the host on
  `drawClippedTriangles`. `dvui.Texture`/`Texture.Target` layout is identical in host and plugin
  because both compile the same dvui source.

### Key design insight — the proxy backend is **stateless**

The host injects its own `current_window` into the plugin, so the plugin's
`current_window.backend.impl` actually points at the **host's** backend instance, reinterpreted
through the plugin's `Implementation = ProxyBackend` type. That's fine **as long as the proxy's
methods never dereference `self`/the Context pointer** — they must forward to a **module-global
`RenderBridge`** set at injection time. Write every proxy method to ignore its receiver and use
the global table. (`begin`/`end`/`renderPresent` are driven by the host's dvui on the host's
window and generally won't be invoked from the plugin; implement them as no-ops or forwards.)

---

## 3. Part 1 — Changes in `dvui-dev` (do this first)

### 3a. Add the proxy backend: `src/backends/proxy.zig`

**Template:** copy the structure of `src/backends/testing.zig` — it is a complete, non-SDL
backend that already implements the entire interface headlessly. The proxy is the same shape,
but its rendering/size/clipboard methods forward to the injected `RenderBridge` instead of
no-op/test-buffer behavior.

The backend must implement **the same method set as `testing.zig`** (that set is authoritative —
it's every method `Backend.zig` calls on `self.impl`). For reference, the methods and how each
should behave in the proxy:

| Method | Proxy behavior |
|--------|----------------|
| `pub const kind` | add a new `dvui.enums.Backend` tag, e.g. `.proxy` (see 3c) |
| `pub const Context = *ProxyBackend` | a tiny struct; methods ignore it (stateless) |
| `init` / `deinit` | trivial; `init` returns an empty `ProxyBackend` |
| **`drawClippedTriangles(texture, vtx, idx, clipr)`** | **forward to bridge** (the core render op) |
| **`textureCreate(pixels, opts) → Texture`** | **forward**; wrap returned host `ptr` in `dvui.Texture` |
| **`textureUpdateSubRect(texture, pixels, x,y,w,h)`** | **forward** |
| **`textureDestroy(texture)`** | **forward** |
| **`textureCreateTarget(opts) → TextureTarget`** | **forward** |
| **`textureReadTarget(target, pixels_out)`** | **forward** |
| **`textureDestroyTarget(target)`** | **forward** |
| **`textureFromTarget` / `textureFromTargetTemp` / `textureClearTarget`** | **forward** |
| **`renderTarget(?target)`** | **forward** |
| `pixelSize` / `windowSize` / `contentScale` | **forward** (host owns the window) |
| `clipboardText` / `clipboardTextSet` / `openURL` | **forward** (host owns the OS) |
| `setCursor` / `textInputRect` | forward or no-op (cosmetic) |
| `preferredColorScheme` / `prefersReducedMotion` | forward or sensible default |
| `nanoTime` / `sleep` | local is fine (`std.time`) — no need to forward |
| `begin` / `end` / `renderPresent` / `refresh` | no-op or forward; host drives the frame |
| `accessKitInitInBegin` / `accessKitShouldInitialize` / `native` | match `testing.zig` (likely off/no-op) |
| `backend(self) → dvui.Backend` | `return Backend.init(self)` (mirror testing) |

> Confirm the exact list against the installed dvui by reading `testing.zig`'s `pub fn`s plus
> `grep -oE 'self\.impl\.[a-zA-Z_]+' src/Backend.zig`. If the interface gains/loses a method in a
> future dvui bump, the proxy must track it (a missing method is a compile error — good).

### 3b. The `RenderBridge` table

Define the C-ABI table the proxy forwards through. Put it where both the dvui backend and the
host can reference the **same definition** — simplest is a small file in the proxy backend, e.g.
`src/backends/proxy_bridge.zig`, exporting the struct type and a module-global setter:

```zig
// src/backends/proxy_bridge.zig  (illustrative — match real dvui types/signatures)
const dvui = @import("dvui");

pub const RenderBridge = extern struct {
    ctx: ?*anyopaque, // host-side backend handle, passed back to every fn

    draw_clipped_triangles: *const fn (ctx: ?*anyopaque, texture_ptr: ?*anyopaque,
        vtx: [*]const dvui.Vertex, vtx_len: usize,
        idx: [*]const dvui.Vertex.Index, idx_len: usize,
        clip: ?*const dvui.Rect.Physical) callconv(.c) void,

    texture_create: *const fn (ctx: ?*anyopaque, pixels: [*]const u8,
        width: u32, height: u32, interpolation: u8) callconv(.c) ?*anyopaque,
    texture_update_sub_rect: *const fn (ctx: ?*anyopaque, texture_ptr: ?*anyopaque,
        pixels: [*]const u8, x: u32, y: u32, w: u32, h: u32) callconv(.c) void,
    texture_destroy: *const fn (ctx: ?*anyopaque, texture_ptr: ?*anyopaque) callconv(.c) void,

    texture_create_target: *const fn (ctx: ?*anyopaque, width: u32, height: u32,
        interpolation: u8) callconv(.c) ?*anyopaque,
    texture_read_target: *const fn (ctx: ?*anyopaque, target_ptr: ?*anyopaque,
        pixels_out: [*]u8) callconv(.c) bool, // false = error
    texture_destroy_target: *const fn (ctx: ?*anyopaque, target_ptr: ?*anyopaque) callconv(.c) void,
    render_target: *const fn (ctx: ?*anyopaque, target_ptr: ?*anyopaque) callconv(.c) void,

    pixel_size_w: ... , pixel_size_h: ... ,  // or one fn returning a small struct
    // clipboard_text / clipboard_text_set / open_url / content_scale / window_size … as needed
};

/// Module-global, set once by the host via the dylib's C entry (see fizzy Part 2).
pub var bridge: ?*const RenderBridge = null;
```

Notes:
- Use plain `extern`/C-ABI scalar params (slices → `ptr,len`; enums → `u8`). The proxy methods
  marshal dvui types into these calls.
- Texture handles: `dvui.Texture.ptr` ⇄ the host's `?*anyopaque`. `textureCreate` returns the
  host pointer; the proxy builds `dvui.Texture{ .ptr = host_ptr, .width=…, .height=…,
  .interpolation=… }`. `drawClippedTriangles`/destroy pass `texture.ptr` back.
- Error mapping: render ops that can fail (`textureCreate`, `textureReadTarget`) signal failure
  via null/bool; the proxy converts to dvui's `TextureError`.

### 3c. Register `.proxy` as a backend and expose a `dvui_proxy` module

1. Add a `proxy` variant to the build `Backend` enum and to `dvui.enums.Backend` (mirror how
   `testing`/`sdl3` are listed).
2. In `build.zig`'s `buildBackend`, add a `.proxy =>` arm that mirrors the **`.testing`** arm:

   ```zig
   .proxy => {
       dvui_opts.setDefaults(.{ .libc = true, .freetype = true, .stb_image = true, .tree_sitter = true });
       const proxy_mod = b.addModule("proxy", .{
           .root_source_file = b.path("src/backends/proxy.zig"),
           .target = target, .optimize = optimize,
       });
       const dvui_proxy = addDvuiModule("dvui_proxy", dvui_opts);
       linkBackend(dvui_proxy, proxy_mod);   // <-- the supported custom-backend hook
   },
   ```
   `linkBackend(dvui_mod, backend_mod)` (build.zig:1002) does `dvui_mod.addImport("backend", backend_mod)`
   — this is the *intended* extension point (`build.zig:375` even documents it).
3. Make sure the `dvui_proxy` and `proxy` modules are reachable to consumers via
   `dvui_dep.module("dvui_proxy")` (and the bridge type, if it lives in `proxy_bridge.zig`,
   via a module too). Crucially: the proxy backend **must not link SDL** — it links nothing
   platform-specific (no `linkLibrary(SDL3)`), so a dylib built against `dvui_proxy` has **zero
   SDL**. That's the whole point.

**Acceptance for Part 1:** a throwaway exe/lib that imports `dvui_proxy` compiles and contains
**no** SDL symbols (`nm | grep SDL` → empty), and the proxy backend implements the full
`Implementation` interface (no missing-method compile errors when used as a dvui backend).

---

## 4. Part 2 — Changes in `fizzy` (after dvui exposes `dvui_proxy`)

1. **SDK bridge + injection symbol.** Mirror the existing dvui-context plumbing:
   - `src/sdk/dvui_context.zig` already injects window/io/ft2lib/debug via the C export
     `fizzy_plugin_set_dvui_context` (declared in `src/sdk/dylib.zig`, called from
     `Editor.syncLoadedPluginDvuiContexts`). Add a sibling: a `fizzy_plugin_set_render_bridge`
     C export (symbol name listed in `dylib.zig`, exported by each plugin's `dylib.zig`) that
     stores the `*const RenderBridge` into the proxy backend's global `bridge`.
   - The `RenderBridge` type comes from dvui's `proxy_bridge.zig` (single source of truth) — the
     SDK and host reference the same type.

2. **Host thunks.** In the shell, implement a `RenderBridge` whose `ctx` is the host and whose
   fns call the host's real `dvui.Backend` (the SDL one for native). e.g.
   `draw_clipped_triangles` → reconstruct slices/`Texture` and call
   `host_window.backend.drawClippedTriangles(...)`. Build this once; the host's backend instance
   is stable, so the bridge can be **injected once at load** (no per-frame push needed, unlike
   `current_window`).

3. **Inject at load.** In `Editor.loadWorkbenchDylib` / `loadPixelartDylib` (and the generic
   loader), after `installRuntime`/`set_dvui_context`, look up and call the dylib's
   `fizzy_plugin_set_render_bridge` with `&host_bridge`. Store nothing per-frame.
   - `PluginLoader.LoadedLib` (in `src/editor/PluginLoader.zig`) currently holds `set_globals`
     and `set_dvui_context`; add `set_render_bridge` alongside.

4. **Build wiring.** Switch the **plugin dylib** modules from `dvui_sdl3` → `dvui_proxy`:
   - In `build.zig`, `addWorkbenchDylib` / `addPixelartDylib` (and a future `addCodeDylib`) pass
     `.dvui = dvui_dep.module("dvui_proxy")` instead of `dvui_sdl3`. The **static** module
     wiring (`wireWorkbenchModule` etc., used for the in-exe fallback and web) keeps `dvui_sdl3`
     / the normal dvui — only the **dylib** roots change.
   - The dylib now links no SDL; keep `linker_allow_shlib_undefined = true` so the remaining
     dvui/sdk/core symbols still resolve from the host at load.
   - `core` also re-exports dvui (`core.dvui`); make sure the dylib's `core` is built against the
     same `dvui_proxy` so there's one dvui flavor inside the dylib.

5. **Texture/format sanity.** Confirm `dvui.Texture`/`Texture.Target`/`Vertex`/`Rect.Physical`
   have identical layout in the host's `dvui_sdl3` and the plugin's `dvui_proxy` (same dvui
   source + same relevant build options → they will, but the interpolation enum and any
   `default_options` that affect struct layout must match).

---

## 5. Verification

- `nm zig-out/<target>/plugins/libworkbench.dylib | grep -i SDL` → **empty** (no SDL in the dylib).
- `otool -L` (macOS) on the dylib → no SDL; only libSystem/libobjc + `@rpath/...`.
- Run **dylib mode** (the default — no `FIZZY_STATIC_*`): the file tree, canvas, and pixel-art
  panes render correctly (no `renderer is invalid` spam).
- Open a `.zig`/`.json` with the **code** plugin and a pixel-art file side by side; both render.
- `zig build test` still green (static/testing path unaffected).

---

## 6. Reference (exact, from the pinned dvui)

- dvui fork: `foxnne/dvui-dev`; pinned in `fizzy/build.zig.zon` (`dvui-0.5.0-dev-…`); vendored copy
  for reading at `fizzy/zig-pkg/dvui-0.5.0-dev-AQFJmdw09w…/`.
- Backend interface & dispatch: `src/Backend.zig` (note `render_backend.kind == .default` → all
  rendering goes through `self.impl`, i.e. the proxy).
- Complete backend template: `src/backends/testing.zig`.
- Custom-backend hook: `linkBackend(dvui_mod, backend_mod)` at `build.zig:1002`; usage documented
  at `build.zig:375`; `.testing` arm (the pattern to copy) around `build.zig:395–417`.
- Types crossing the boundary: `src/Texture.zig` — `Texture { ptr: *anyopaque, width: u32,
  height: u32, interpolation }`, `Texture.Target { ptr, width, height, interpolation }`,
  `CreateOptions { width, height, interpolation = .linear }`; `dvui.Vertex`, `dvui.Vertex.Index`,
  `dvui.Rect.Physical`.

### Fizzy-side files to mirror/extend
| File | Role |
|------|------|
| `src/sdk/dylib.zig` | C entry symbol names + `abi_version` (bump it when adding `set_render_bridge`) |
| `src/sdk/dvui_context.zig` | existing per-image dvui injection — pattern to copy for the bridge |
| `src/plugins/<name>/dylib.zig` | each plugin's C exports (`fizzy_plugin_set_dvui_context`, …) — add the bridge setter |
| `src/editor/PluginLoader.zig` | `LoadedLib` (add `set_render_bridge`) + symbol lookup at load |
| `src/editor/Editor.zig` | `loadWorkbenchDylib`/`loadPixelartDylib`, `syncLoadedPluginDvuiContexts` |
| `build.zig` | `addWorkbenchDylib`/`addPixelartDylib` → switch dylib `dvui` dep to `dvui_proxy` |

---

## 7. Notes / decisions for the implementer

- **Do dvui Part 1 fully first** and prove "import `dvui_proxy` ⇒ no SDL symbols" before touching
  fizzy. That de-risks the whole effort.
- **Stateless proxy is mandatory** (see §2 insight): methods must use the module-global bridge,
  never `self`, because the injected `current_window.backend.impl` actually points at the host's
  backend instance.
- **One SDL, in the host, forever** — this is also exactly what a **third-party** plugin needs: it
  will import the Fizzy SDK + `dvui_proxy` and draw, never touching SDL/GPU libraries.
- Keep **static mode** working throughout (it's the fallback and the test path); only the dylib
  build flavor changes.
- If a clean proxy backend proves hard to land quickly, a stopgap that *shares one SDL* (host
  exports SDL; dylib built `-undefined dynamic_lookup` with SDL not statically linked, or a shared
  `libSDL3.dylib`) would also fix rendering — but it keeps SDL in the plugin's build graph and is
  worse for the third-party SDK story. The proxy backend is the real answer.
