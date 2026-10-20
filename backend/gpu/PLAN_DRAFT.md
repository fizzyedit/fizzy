# Plan draft: our own GPU renderers behind `gpu.Device`

Draft of a follow-up plan issue for `fizzyedit/plans`, from windowing library plan step 10. Not
started: this PR is the seam (`README.md` beside this) and nothing below is built. Copy to an
issue when the seam is read and agreed.

**Goal.** fizzy draws without SDL_GPU: Metal on macOS, D3D12 on Windows, Vulkan on Linux, each a
`gpu.Device` written in Zig, selectable per run against the SDL_GPU adapter until they match.

**Constraints.**

- One step, one PR, 800 lines of diff or fewer outside tests and docs (`CONTRIBUTING.md`).
- Clean room: behaviour and public documentation only (the platform vendors' API docs, SDL_GPU's
  public documentation); no reading SDL's GPU source or any other renderer's.
- Verified on the platform changed. CI's cross-compile shows it links, not that it draws.
- Nothing optional costs a frame; measure frame time against the SDL_GPU adapter on each step.

## Steps

### 0. The seam (this PR)

`backend/gpu/`: `Device`, types, shader formats, `Null`, the audit. Decision to record: the
interface stays as narrow as the audit says; a renderer feature that needs more adds it in its
own PR with the call that needs it.

### 1. `GpuRenderer` on `Device`, with an SDL_GPU adapter

- `backend/gpu/sdl.zig` (needs SDL, so a module of its own, not part of the std-only root):
  `Device` over SDL_GPU, one function per vtable entry; handles are ids into tables; `prepareLayer`
  and the D3D12-for-transparent policy move here from `GpuRenderer`.
- `GpuRenderer` takes a `Device` and a `WindowId` map instead of `c.SDL_GPU*`; the logic above
  the seam (passes, merging, rings, textures, programs) does not change.
- Done when: all gates pass with output identical to today (the integration suite and
  `Health` counters: draws, passes, uploads per frame unchanged), and frame time within noise.
- Risk: the id tables cost a lookup per call. Measure in a draw-heavy frame; handles can be the
  pointer bits if the lookup shows.
- Size: about 600 lines of adapter plus a renderer diff that is mostly mechanical; split in two
  PRs if over (adapter dark behind the flag, then the switch).

### 2. Shaders by format

- `programs.Source` gains `dxbc` and a Zig-compiled SPIR-V origin; `GpuRenderer.programCreate`
  calls `shader.resolve` with the device's formats instead of its own switch.
- A `Translator` over SPIRV-Cross (MSL, HLSL) and `D3DCompile` (Windows), as in #658's
  recommendation: SPIRV-Cross built with `zig c++`, no DXC, no shadercross at authoring time.
- Move the glass (`liquid_glass.zig` of #658) from spike to a real shader once its Zig gaps close
  (uniform array indexing, discard, `SampleLevel`); HLSL stays as the fallback until then.
- Done when: the Zig-compiled example program draws through the SDL_GPU adapter on Metal and
  Vulkan, and D3D12 through DXBC, pixel-equal to its HLSL twin (the comparison #658 made).

### 3. Conformance suite

- `backend/gpu/conformance.zig` (std-only driver, hardware-run): draws known frames through a
  `Device` into a texture, reads back, and compares to goldens: blends (over, add, copy, punch),
  scissors, sampler wrap/filter, a 16-bit float target, upload/download round trip, cycled
  transfer buffers while the GPU still reads, viewport blit, a drawable that is `null`.
- Runs on the adapter first; every renderer below must pass it before it draws a real frame. A
  renderer's bug becomes a conformance case, not a fizzy regression.
- Also `Null`-based tests for the call-order rules (the sequence `Null` already refuses).

### 4. Metal renderer (macOS)

- `backend/gpu/metal/`: Zig over the Objective-C runtime (zig-objc is pinned already) or a small
  `.m` file, per the build's existing pattern (`backend/AGENTS.md`: no ARC, autorelease pools).
- Owns its `CAMetalLayer` (no sRGB tag, `displayLayer` live resize, the native glass overlay),
  which retires `prepareLayer` and the `macos_monitor.m` swapchain hook.
- Shaders: MSL, compiled at run time on the thread `Compile` uses; entry point `main0`.
- Command buffers/encoders map onto the interface; cycling is a ring of `MTLBuffer`s per
  command buffer.
- Done when: conformance passes; the live-resize and float-window measurements in
  `docs/MACOS_LIVE_RESIZE.md` do not regress; `nextDrawable` pacing matches the adapter.
- Likely two PRs: device, resources and passes dark behind a flag; swapchain and windows.

### 5. D3D12 renderer (Windows)

- `backend/gpu/d3d12/` over `zigwin32` (pinned). DirectComposition swapchain for transparent
  windows (what makes D3D12 the Windows choice today), flip-model otherwise.
- Resource states and barriers are inside the device: the interface has no barriers, so the
  device tracks state per texture and inserts transitions at pass boundaries.
- Descriptor heaps and root signature fixed to the binding convention in `README.md`.
- Shaders: DXIL where shipped, else DXBC from the translator. SM 5.1 limits to be checked
  against the glass.
- Done when: conformance on a real GPU and under WARP in CI; live-resize behaviour per
  `docs/WINDOWS_LIVE_RESIZE.md` unchanged.

### 6. Vulkan renderer (Linux; Windows as a non-transparent fallback)

- `backend/gpu/vulkan/`: instance/device/queue selection, swapchain per window (X11 and
  Wayland surfaces), render passes or dynamic rendering, a descriptor layout fixed to the binding
  convention. Memory: a small suballocator for the rings; the interface's `cycle` maps to
  renaming the backing memory.
- Layers in Debug builds.
- Shaders: SPIR-V as is (the cheapest path: Zig-compiled shaders arrive untouched).
- Done when: conformance on Mesa (radeonsi or anv) and under lavapipe in CI (software Vulkan, so
  CI proves behaviour, not speed).

### 7. Make ours the default, remove the adapter

- Per platform, ours becomes default once conformance and the frame-time/latency comparisons hold
  for a release; the adapter stays one release as a fallback flag, then goes, with SDL's GPU
  patches (`backend/patches/sdl`, `docs/DEPENDENCIES.md`) and `SDL_GPU` from the SDL build.
- Window creation and the presentation surface leave SDL with the windowing steps of the
  library plan; this plan does not wait on them (the claim takes a `WindowId` and a native
  handle the adapter and the renderers each resolve).

## Open questions (decide before step 1 merges)

1. **Handle representation.** Ids with tables (safe, a lookup) or pointer bits (fast, a stale
   handle crashes)? The interface says "an id the device checks"; the adapter may start with
   pointers behind that promise if the lookup shows in a profile.
2. **Who owns the native surface?** The renderers need `HWND`, `CAMetalLayer`/`NSView` or an X11 or
   Wayland surface for a `WindowId`. Proposal: `winsys.Platform` gains `nativeSurface(window)`
   (its own step, in the windowing plan), the device constructor takes the lookup.
3. **Barriers and states.** Hidden in the device (proposed: the interface is small enough that a
   device tracks them) or exposed? Exposing them would make the SDL_GPU adapter's job harder, not
   easier.
4. **Async shader compile.** Kept as a device property (`threaded_shader_compile`) with the
   compile thread in the renderer. A Vulkan or D3D12 device may want pipeline-cache files; that
   is a constructor option, not an interface call.
5. **Zig as a shader language.** #658's gaps decide when a Zig shader replaces HLSL; this plan
   only guarantees it can arrive (`shader.Set` with `.spirv`).
6. **Web.** WebGL stays dvui's path (`src/backend/WebBackend.zig`); a WebGPU `Device` would be a
   fourth implementation later (WGSL needs Tint or Naga, which SPIRV-Cross does not cover).

## Out of scope

Compute, a render graph, multi-GPU, HDR swapchains, video decode, anything beyond fizzy's current
2D renderer; the windowing steps (events, windows, input), which have their own plan.
