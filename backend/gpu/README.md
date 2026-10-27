# gpu: the device interface

Replacing SDL3 replaces SDL_GPU, and SDL_GPU is what `GpuRenderer` draws on. This directory is the
seam that makes that a swap of a device and not a rewrite of the renderer: a narrow `Device`
(`Device.zig`), the plain types it speaks (`types.zig`), shader formats and how one is picked
(`shader.zig`), and a device that draws nothing (`Null.zig`). All std-only; nothing outside this
directory uses it yet (`GpuRenderer` moves onto it in step 1 of the follow-up plan, fizzyedit/plans).

Status: windowing library plan, step 10. Clean room: the surface is cut from what `GpuRenderer`
does today and from SDL_GPU's public documentation and behaviour, never from its source.

## The shape, and why

Maintainer's direction (2026-10-20): the interface is shaped like SDL_GPU: a device, windows
claimed on it, command buffers, copy and render passes, pipelines built from shaders, shader
formats negotiated. Two implementations stand behind it during development, an **SDL_GPU adapter**
(so nothing regresses while the interface settles) and **renderers of our own** (Metal, D3D12,
Vulkan), swappable per run. What was taken from SDL_GPU's design, because it earns its keep:

- **Command buffers are the unit of submission and presentation.** A drawable is acquired on one
  and presented when it is submitted, so many windows are one submission (`presentInto`).
- **Copy passes and render passes are separate, and never nest.** Uploads are not render work.
  `acquireSwapchain` with a pass open is an error; `GpuRenderer` closes its copy pass first.
- **Transfer buffers with `cycle`.** The CPU writes into memory the GPU may still be reading;
  `cycle` says the old contents are not needed, so a device renames the allocation instead of
  stalling. `GpuRenderer`'s two rings are built on exactly this and need nothing else.
- **Resources are released while in use,** and the device frees them when the GPU is done. No
  caller tracks frames in flight.
- **Pipelines are immutable and keyed by what varies** (shader, colour format, blend). The
  renderer caches them; the device only builds them.
- **Shader formats are a capability, not a build flag.** The device says which it compiles; the
  program ships what it has; they are matched at run time (below).

Where it is narrower than SDL_GPU, on purpose: one colour target and no depth, stencil or
multisampling; 2D textures of one level; triangle lists, no culling; additive blend operations;
no compute, storage buffers or textures, instancing, viewports (the scissor is the clip), fences
beyond "submit and wait". A field is added when a renderer needs it.

Where it differs: the uniform push is on the **pass** (`pushFragmentUniforms`), since its data
means nothing without a bound pipeline, and `WindowId` is `winsys.Window.id` where SDL_GPU takes
its window object, so a device maps the id to a native surface itself.

## Shaders

A device compiles code in some *formats* (`Caps.shader_formats`): SPIR-V, MSL, DXIL, DXBC. A
program ships a `shader.Set`, the same shader in as many formats as its author made, and
`shader.resolve(set, device.caps.shader_formats, preference, stage, translator)` returns the
`Code` to hand to `createShader`: the first preferred format the device has and the set ships,
else one made from the set's SPIR-V by a `Translator` (the seam for SPIRV-Cross to MSL or HLSL,
then `D3DCompile` for DXBC).

That is how **shaders compiled by Zig** arrive (#658, a spike compiling the glass to SPIR-V with
`-target spirv32-vulkan`): a `Set` with only `.spirv`. Vulkan takes it as it is; Metal and D3D12
get a translator, and nothing about the renderer or `Device` changes. HLSL shaders compiled by
shadercross arrive as a `Set` with all three, as `programs.Source` carries them today. The binding
convention (vertex textures set 0, uniforms set 1; fragment textures set 2, uniforms set 3) is one
convention for every format and is what both fizzy's HLSL and #658's Zig shaders already follow.
Entry points are `main0` for MSL and `main` otherwise (`Format.defaultEntry`), and `Code` carries
its own, so a shader that names its entry otherwise needs no new field.

`createShader` is callable from any thread: `GpuRenderer` compiles Metal source on its own
thread because a cold compile is 40–240 ms (`GpuRenderer.Compile`). A device that cannot needs a
`Caps` flag so the caller compiles inline (`TODO(seam)` in `Device.zig`); none exists yet.

## Audit: every SDL_GPU call

`backend/src/glass/programs.zig` makes **no** SDL_GPU call. It is the program interface above the
renderer: `Source` carries a program's MSL, SPIR-V and DXIL (and GLSL for the web) and `Hooks`
are `programCreate`/`Begin`/`Blend`/`End`. Its shader-format contract is `shader.Set`; keep the
two in step when `programs.Source` gains a format (DXBC, or Zig-compiled SPIR-V).

Every call is in `GpuRenderer.zig` (1440 lines; about 60 distinct SDL_GPU functions). Its line
numbers are as of `fa2ad01`.

| SDL_GPU | Where | `Device` |
|---|---|---|
| `SDL_CreateGPUDevice` (all three shader formats, debug in Debug; Windows transparent window asks `"direct3d12"`) | `createDevice` 277 | not in the interface: each implementation has its own constructor and options (policy stays with the caller). Result is a `Device` |
| `SDL_DestroyGPUDevice`, `SDL_WaitForGPUIdle` | `destroy` 377 | `destroy`, `waitIdle` |
| `SDL_GetGPUDeviceDriver` | `create` 297 | `caps.driver` |
| `SDL_GetGPUShaderFormats` | `create` 309 | `caps.shader_formats` |
| `SDL_GPUTextureSupportsFormat` (R16G16B16A16_FLOAT, sampler + colour target) | `create` 322 | `supportsTexture` |
| `SDL_ClaimWindowForGPUDevice`, `SDL_ReleaseWindowFromGPUDevice` | `create` 302, `claimViewport`/`releaseViewport` 659/679 | `claimWindow`, `releaseWindow` |
| `SDL_GetGPUSwapchainTextureFormat` | `create` 330 | `swapchainFormat` |
| `SDL_SetGPUSwapchainParameters` (SDR + a present mode) | `setVSync` 425, `claimViewport` | `setPresentMode` (composition is always SDR) |
| `SDL_WindowSupportsGPUPresentMode` | `setVSync`, `claimViewport` | `supportsPresentMode` |
| `SDL_WaitAndAcquireGPUSwapchainTexture` | `acquireSwapchain` 608 | `acquireSwapchain(wait = true)` |
| `SDL_AcquireGPUSwapchainTexture` (viewports; never waits) | `presentInto` 688 | `acquireSwapchain(wait = false)` |
| `SDL_CreateGPUShader` (+ entry `main0` for MSL, sampler and uniform-buffer counts) / `SDL_ReleaseGPUShader` | `createShader` 447, `Compile.run` 153 (off-thread) | `createShader`, `releaseShader` |
| `SDL_CreateGPUGraphicsPipeline` / `…Release…` (one vertex buffer, 3 attributes, triangle list, no cull, one colour target, 4 blends) | `pipeline` 462 | `createPipeline`, `releasePipeline` |
| `SDL_CreateGPUSampler` / release (8 combos: filter × wrap u × wrap v) | `create` 348 | `createSampler`, `releaseSampler` |
| `SDL_CreateGPUTexture` / release (RGBA8 sampler; RGBA8 or RGBA16F sampler + target) | `textureCreate` 998, `textureCreateTarget` 1074, `textureDestroy` | `createTexture`, `releaseTexture` |
| `SDL_CreateGPUBuffer` / release (vertex + index) | `BufferRing` 1404 | `createBuffer`, `releaseBuffer` |
| `SDL_CreateGPUTransferBuffer` / release (upload rings, download per read) | `TransferRing` 1346, `download` 1158 | `createTransferBuffer`, `releaseTransferBuffer` |
| `SDL_MapGPUTransferBuffer` (with cycle) / `SDL_UnmapGPUTransferBuffer` | `TransferRing` 1374, `download` 1180 | `mapTransferBuffer`, `unmapTransferBuffer` |
| `SDL_AcquireGPUCommandBuffer` | `ensureCmd` 524 | `acquireCommandBuffer` |
| `SDL_SubmitGPUCommandBuffer`, `…AndAcquireFence`, `SDL_WaitForGPUFences` (one fence, all), `SDL_ReleaseGPUFence` | `submit` 552, `submitAndWait` 569 | `submit`, `submitWithFence`, `waitFence`, `releaseFence` |
| `SDL_BeginGPUCopyPass` / `SDL_EndGPUCopyPass` | `beginCopy` 535 | `beginCopyPass`, `endCopyPass` |
| `SDL_UploadToGPUBuffer` (cycle) | `encodePass` 914 | `uploadToBuffer` |
| `SDL_UploadToGPUTexture` | `upload` 1058 | `uploadToTexture` |
| `SDL_DownloadFromGPUTexture` | `download` 1173 | `downloadFromTexture` |
| `SDL_BlitGPUTexture` (clear load, nearest) | `presentInto` 720 | `blit` |
| `SDL_BeginGPURenderPass` (one colour target, load or clear, store) / `SDL_EndGPURenderPass` | `encodePass` 929, `clearPass` 878 | `beginRenderPass`, `endRenderPass` |
| `SDL_BindGPUGraphicsPipeline` | `encodePass` 962 | `bindPipeline` |
| `SDL_BindGPUVertexBuffers` (1), `SDL_BindGPUIndexBuffer` | `encodePass` 937 | `bindVertexBuffer`, `bindIndexBuffer` |
| `SDL_SetGPUScissor` | `encodePass` 966 | `setScissor` |
| `SDL_BindGPUFragmentSamplers` (1–3) | `encodePass` 976 | `bindFragmentSamplers` |
| `SDL_PushGPUFragmentUniformData` (slot 0) | `encodePass` 982 | `pushFragmentUniforms` |
| `SDL_DrawGPUIndexedPrimitives` | `encodePass` 986 | `drawIndexed` |

Not used anywhere, so not in the interface: compute passes, storage buffers and textures, vertex
uniforms, depth/stencil, multisampling, mip generation, 3D/array/cube textures, instancing,
`SDL_SetGPUViewport`, `SDL_SetGPUBlendConstants`, `SDL_CopyGPUBufferToBuffer`, indirect draws,
debug groups, `SDL_GPUTextureSupportsSampleCount`, cycle on textures.

### What stays above the seam (not the device's)

All of `GpuRenderer`'s own logic is renderer, not device, and moves over unchanged: the per-pass
recording and merging (`draw`, `flush`, `resetPass`), `window_offset`, scissor clamping, the late
swapchain acquire, the epoch-cycled rings, texture bookkeeping (`Tex.used_in`, `needs_clear`),
pixel-format conversion, program state, and `Health` counters.

### Not SDL_GPU, but tied to the device today

- `prepareLayer` (`GpuRenderer.zig` 417, `macos_monitor.m`) reaches SDL's window properties for
  the swapchain's `CAMetalLayer` and removes the sRGB tag SDL_GPU puts on it. A Metal renderer of
  our own owns that layer and makes it right when it creates it, so the hook goes away with the
  adapter; until then it is the **adapter's** business (called from `claimWindow` and
  `setPresentMode`), not the interface's. Its absence on other platforms is already a no-op.
- The D3D12-for-transparent-windows rule (`createDevice`) is DirectComposition-specific: a D3D12
  renderer of our own will own that, a Vulkan one cannot do it (an opaque swapchain on Windows).
  It stays a *constructor* option, which is why the interface has no device-creation call.
- `SDLBackend.zig` reaches the renderer through `gpu.*` (`present`, `beginFrame`, `presentInto`,
  `claimViewport`, `window_held`, `window_offset`, `presented`). That surface is the renderer's
  and does not change when its device does.

### Behaviour any implementation has to reproduce

Recorded because the SDL_GPU adapter hides them and a new renderer will meet them again:

- A drawable acquired while a copy pass is open asserted in SDL on every frame
  (`acquireSwapchain`): close passes first. `Null` returns `Failed` for it.
- A swapchain texture is not readable and not acquired until the frame's end, so a read of the
  window is an error (`readPixels`), and a frame's drawable is acquired by its first window pass.
- A drawable is `null` while minimized or occluded; the frame then draws nothing and
  `presented` is false, which paces the loop.
- A viewport window's acquire must not block (`presentInto`) and on macOS the main window and a
  viewport both wait for the display (measured, `GpuRenderer.claimViewport`).
- A transparent window's alpha is composited by the driver on Metal, Vulkan and D3D12 through
  DirectComposition, not by the interface; swapchain format and layer tagging matter
  (`prepareLayer`).
- Releasing a texture that a recorded pass uses is legal; the device defers it
  (`textureDestroy`).

## Skeleton and tests

`Null` implements every vtable function: ids, live counts, misuse errors (`Failed`), and counters
for submits, passes, draws and presents. Its test replays one `GpuRenderer` frame in the order the
renderer records it (setup, uploads on a copy pass, the drawable, the pass, present, a fenced
read, releases). `shader.zig` tests the pick, including a SPIR-V-only (Zig-compiled) shader on a
Metal-only device with a translator. `zig build test` runs them (`unit_tests` in `build.zig`).
Nothing here touches a GPU, so these are the only tests: the implementations are to be checked on
hardware, on each platform, by the plan.
