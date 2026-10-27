//! A GPU device: the one interface fizzy's renderer draws through, shaped like SDL_GPU (device,
//! window claim, command buffers, passes, pipelines, shader formats) and as narrow as
//! `GpuRenderer` is wide. Two implementations are meant to stand behind it during development, an
//! SDL_GPU adapter and renderers of our own (Metal, D3D12, Vulkan), swapped without the renderer
//! knowing. Neither is here: `Null.zig` is the compile-only skeleton, and `README.md` has the
//! audit this surface was cut from.
//!
//! A `{ctx, vtable}` as `winsys.Platform` is. Methods are the vtable functions under a camelCase
//! name; the rules the vtable cannot state are on the methods.
//!
//! **Threads.** Everything is called from the frame's thread, except `createShader` and
//! `releaseShader`, which a device must accept from any thread (`GpuRenderer` compiles Metal
//! source on a thread of its own so a cold compile does not stall a frame).
//! TODO(seam): a device that cannot compile off-thread needs a `Caps` flag; add it with the first
//! such device, and the caller compiles inline.
//!
//! **Lifetime.** `release*` may be called while the GPU still uses the object; the device frees
//! it once the command buffers that use it are done. `Device.destroy` waits for the GPU.
const std = @import("std");
const types = @import("types.zig");
const shader = @import("shader.zig");

const Device = @This();

ctx: *anyopaque,
vtable: *const VTable,
caps: Caps,

pub const Error = types.Error;

/// What a device can do at all, fixed for its life.
pub const Caps = struct {
    /// Which implementation this is, for logs ("metal", "vulkan", "direct3d12", ...).
    driver: []const u8,
    /// The shader formats it compiles (`shader.resolve` picks among them).
    shader_formats: shader.Formats,
};

pub const ShaderDesc = struct {
    code: shader.Code,
    stage: types.ShaderStage,
    /// Sampled textures with their sampler, and uniform buffers, the shader reads.
    num_samplers: u32 = 0,
    num_uniform_buffers: u32 = 0,
};

/// One vertex buffer in slot 0, triangle lists, no culling, filled, one colour target, no depth
/// or multisampling: the only state fizzy's renderer varies is below.
pub const PipelineDesc = struct {
    vertex_shader: types.Shader,
    fragment_shader: types.Shader,
    vertex_pitch: u32,
    attributes: []const types.VertexAttribute,
    color_format: types.TextureFormat,
    blend: types.BlendState,
};

pub const VTable = struct {
    // ---- the device ----------------------------------------------------------------------
    /// Waits for the GPU, then frees everything the device still owns.
    destroy: *const fn (ctx: *anyopaque) void,
    wait_idle: *const fn (ctx: *anyopaque) void,
    supports_texture: *const fn (ctx: *anyopaque, format: types.TextureFormat, usage: types.TextureUsage) bool,

    // ---- windows -------------------------------------------------------------------------
    /// Makes the window a place the device can present into. Failing leaves it unclaimed.
    claim_window: *const fn (ctx: *anyopaque, window: types.WindowId) Error!void,
    /// Gives it back, waiting out what is still in flight to it.
    release_window: *const fn (ctx: *anyopaque, window: types.WindowId) void,
    /// Applies from the next acquire. Always SDR; `Unsupported` for a mode the window lacks.
    set_present_mode: *const fn (ctx: *anyopaque, window: types.WindowId, mode: types.PresentMode) Error!void,
    supports_present_mode: *const fn (ctx: *anyopaque, window: types.WindowId, mode: types.PresentMode) bool,
    /// The format of the window's drawables, to build a pipeline that renders into them.
    swapchain_format: *const fn (ctx: *anyopaque, window: types.WindowId) types.TextureFormat,
    /// The window's next drawable on `cmd`, presented when `cmd` is submitted. Null while there
    /// is none (minimized, occluded). `wait`: block until one is free; else null when none is.
    /// No pass may be open on `cmd`.
    acquire_swapchain: *const fn (ctx: *anyopaque, cmd: types.CommandBuffer, window: types.WindowId, wait: bool) Error!?types.Swapchain,

    // ---- resources -----------------------------------------------------------------------
    create_texture: *const fn (ctx: *anyopaque, desc: types.TextureDesc) Error!types.Texture,
    release_texture: *const fn (ctx: *anyopaque, texture: types.Texture) void,
    create_buffer: *const fn (ctx: *anyopaque, desc: types.BufferDesc) Error!types.Buffer,
    release_buffer: *const fn (ctx: *anyopaque, buffer: types.Buffer) void,
    create_transfer_buffer: *const fn (ctx: *anyopaque, desc: types.TransferBufferDesc) Error!types.TransferBuffer,
    release_transfer_buffer: *const fn (ctx: *anyopaque, buffer: types.TransferBuffer) void,
    /// `cycle`: the device gives back fresh memory if the GPU still reads the last mapping, so
    /// the bytes a recorded copy will read are not overwritten. Valid until `unmap`.
    map_transfer_buffer: *const fn (ctx: *anyopaque, buffer: types.TransferBuffer, cycle: bool) Error![*]u8,
    unmap_transfer_buffer: *const fn (ctx: *anyopaque, buffer: types.TransferBuffer) void,
    create_sampler: *const fn (ctx: *anyopaque, desc: types.SamplerDesc) Error!types.Sampler,
    release_sampler: *const fn (ctx: *anyopaque, sampler: types.Sampler) void,
    /// Any thread. `Failed` when the code does not compile; `Unsupported` for a format the
    /// device lacks.
    create_shader: *const fn (ctx: *anyopaque, desc: ShaderDesc) Error!types.Shader,
    release_shader: *const fn (ctx: *anyopaque, shader: types.Shader) void,
    create_pipeline: *const fn (ctx: *anyopaque, desc: PipelineDesc) Error!types.Pipeline,
    release_pipeline: *const fn (ctx: *anyopaque, pipeline: types.Pipeline) void,

    // ---- command buffers -----------------------------------------------------------------
    acquire_command_buffer: *const fn (ctx: *anyopaque) Error!types.CommandBuffer,
    /// Hands `cmd` to the GPU and presents the drawables acquired on it. It is gone after.
    submit: *const fn (ctx: *anyopaque, cmd: types.CommandBuffer) Error!void,
    submit_with_fence: *const fn (ctx: *anyopaque, cmd: types.CommandBuffer) Error!types.Fence,
    wait_fence: *const fn (ctx: *anyopaque, fence: types.Fence) Error!void,
    release_fence: *const fn (ctx: *anyopaque, fence: types.Fence) void,

    // ---- copy passes: transfer buffers <-> buffers and textures --------------------------
    begin_copy_pass: *const fn (ctx: *anyopaque, cmd: types.CommandBuffer) Error!types.CopyPass,
    end_copy_pass: *const fn (ctx: *anyopaque, pass: types.CopyPass) void,
    /// `cycle`: the destination's old contents are not needed, so a device may give the buffer
    /// fresh memory instead of waiting for the GPU to finish with it.
    upload_to_buffer: *const fn (ctx: *anyopaque, pass: types.CopyPass, src: types.TransferLocation, dst: types.BufferRegion, cycle: bool) void,
    upload_to_texture: *const fn (ctx: *anyopaque, pass: types.CopyPass, src: types.TextureTransfer, dst: types.TextureRegion) void,
    download_from_texture: *const fn (ctx: *anyopaque, pass: types.CopyPass, src: types.TextureRegion, dst: types.TextureTransfer) void,

    // ---- outside passes ------------------------------------------------------------------
    blit: *const fn (ctx: *anyopaque, cmd: types.CommandBuffer, blit: types.Blit) void,

    // ---- render passes -------------------------------------------------------------------
    begin_render_pass: *const fn (ctx: *anyopaque, cmd: types.CommandBuffer, target: types.ColorTarget) Error!types.RenderPass,
    end_render_pass: *const fn (ctx: *anyopaque, pass: types.RenderPass) void,
    bind_pipeline: *const fn (ctx: *anyopaque, pass: types.RenderPass, pipeline: types.Pipeline) void,
    bind_vertex_buffer: *const fn (ctx: *anyopaque, pass: types.RenderPass, binding: types.BufferBinding) void,
    bind_index_buffer: *const fn (ctx: *anyopaque, pass: types.RenderPass, binding: types.BufferBinding, size: types.IndexSize) void,
    set_scissor: *const fn (ctx: *anyopaque, pass: types.RenderPass, rect: types.Rect) void,
    /// Fragment samplers from slot 0 up.
    bind_fragment_samplers: *const fn (ctx: *anyopaque, pass: types.RenderPass, bindings: []const types.SamplerBinding) void,
    /// Uniform data for fragment uniform buffer `slot`, copied now: later draws in the pass see
    /// it until it is pushed again. SDL_GPU pushes on the command buffer; here it is the pass's,
    /// as the data means nothing without a bound pipeline.
    push_fragment_uniforms: *const fn (ctx: *anyopaque, pass: types.RenderPass, slot: u32, data: []const u8) void,
    draw_indexed: *const fn (ctx: *anyopaque, pass: types.RenderPass, draw: types.DrawIndexed) void,
};

// The surface: one method per vtable function, so a call site reads `device.createTexture(desc)`.

pub fn destroy(self: Device) void {
    self.vtable.destroy(self.ctx);
}

pub fn waitIdle(self: Device) void {
    self.vtable.wait_idle(self.ctx);
}

pub fn supportsTexture(self: Device, format: types.TextureFormat, usage: types.TextureUsage) bool {
    return self.vtable.supports_texture(self.ctx, format, usage);
}

pub fn claimWindow(self: Device, window: types.WindowId) Error!void {
    return self.vtable.claim_window(self.ctx, window);
}

pub fn releaseWindow(self: Device, window: types.WindowId) void {
    self.vtable.release_window(self.ctx, window);
}

pub fn setPresentMode(self: Device, window: types.WindowId, mode: types.PresentMode) Error!void {
    return self.vtable.set_present_mode(self.ctx, window, mode);
}

pub fn supportsPresentMode(self: Device, window: types.WindowId, mode: types.PresentMode) bool {
    return self.vtable.supports_present_mode(self.ctx, window, mode);
}

pub fn swapchainFormat(self: Device, window: types.WindowId) types.TextureFormat {
    return self.vtable.swapchain_format(self.ctx, window);
}

pub fn acquireSwapchain(self: Device, cmd: types.CommandBuffer, window: types.WindowId, wait: bool) Error!?types.Swapchain {
    return self.vtable.acquire_swapchain(self.ctx, cmd, window, wait);
}

pub fn createTexture(self: Device, desc: types.TextureDesc) Error!types.Texture {
    return self.vtable.create_texture(self.ctx, desc);
}

pub fn releaseTexture(self: Device, texture: types.Texture) void {
    self.vtable.release_texture(self.ctx, texture);
}

pub fn createBuffer(self: Device, desc: types.BufferDesc) Error!types.Buffer {
    return self.vtable.create_buffer(self.ctx, desc);
}

pub fn releaseBuffer(self: Device, buffer: types.Buffer) void {
    self.vtable.release_buffer(self.ctx, buffer);
}

pub fn createTransferBuffer(self: Device, desc: types.TransferBufferDesc) Error!types.TransferBuffer {
    return self.vtable.create_transfer_buffer(self.ctx, desc);
}

pub fn releaseTransferBuffer(self: Device, buffer: types.TransferBuffer) void {
    self.vtable.release_transfer_buffer(self.ctx, buffer);
}

pub fn mapTransferBuffer(self: Device, buffer: types.TransferBuffer, cycle: bool) Error![*]u8 {
    return self.vtable.map_transfer_buffer(self.ctx, buffer, cycle);
}

pub fn unmapTransferBuffer(self: Device, buffer: types.TransferBuffer) void {
    self.vtable.unmap_transfer_buffer(self.ctx, buffer);
}

pub fn createSampler(self: Device, desc: types.SamplerDesc) Error!types.Sampler {
    return self.vtable.create_sampler(self.ctx, desc);
}

pub fn releaseSampler(self: Device, sampler: types.Sampler) void {
    self.vtable.release_sampler(self.ctx, sampler);
}

pub fn createShader(self: Device, desc: ShaderDesc) Error!types.Shader {
    return self.vtable.create_shader(self.ctx, desc);
}

pub fn releaseShader(self: Device, s: types.Shader) void {
    self.vtable.release_shader(self.ctx, s);
}

pub fn createPipeline(self: Device, desc: PipelineDesc) Error!types.Pipeline {
    return self.vtable.create_pipeline(self.ctx, desc);
}

pub fn releasePipeline(self: Device, pipeline: types.Pipeline) void {
    self.vtable.release_pipeline(self.ctx, pipeline);
}

pub fn acquireCommandBuffer(self: Device) Error!types.CommandBuffer {
    return self.vtable.acquire_command_buffer(self.ctx);
}

pub fn submit(self: Device, cmd: types.CommandBuffer) Error!void {
    return self.vtable.submit(self.ctx, cmd);
}

pub fn submitWithFence(self: Device, cmd: types.CommandBuffer) Error!types.Fence {
    return self.vtable.submit_with_fence(self.ctx, cmd);
}

pub fn waitFence(self: Device, fence: types.Fence) Error!void {
    return self.vtable.wait_fence(self.ctx, fence);
}

pub fn releaseFence(self: Device, fence: types.Fence) void {
    self.vtable.release_fence(self.ctx, fence);
}

pub fn beginCopyPass(self: Device, cmd: types.CommandBuffer) Error!types.CopyPass {
    return self.vtable.begin_copy_pass(self.ctx, cmd);
}

pub fn endCopyPass(self: Device, pass: types.CopyPass) void {
    self.vtable.end_copy_pass(self.ctx, pass);
}

pub fn uploadToBuffer(self: Device, pass: types.CopyPass, src: types.TransferLocation, dst: types.BufferRegion, cycle: bool) void {
    self.vtable.upload_to_buffer(self.ctx, pass, src, dst, cycle);
}

pub fn uploadToTexture(self: Device, pass: types.CopyPass, src: types.TextureTransfer, dst: types.TextureRegion) void {
    self.vtable.upload_to_texture(self.ctx, pass, src, dst);
}

pub fn downloadFromTexture(self: Device, pass: types.CopyPass, src: types.TextureRegion, dst: types.TextureTransfer) void {
    self.vtable.download_from_texture(self.ctx, pass, src, dst);
}

pub fn blit(self: Device, cmd: types.CommandBuffer, b: types.Blit) void {
    self.vtable.blit(self.ctx, cmd, b);
}

pub fn beginRenderPass(self: Device, cmd: types.CommandBuffer, target: types.ColorTarget) Error!types.RenderPass {
    return self.vtable.begin_render_pass(self.ctx, cmd, target);
}

pub fn endRenderPass(self: Device, pass: types.RenderPass) void {
    self.vtable.end_render_pass(self.ctx, pass);
}

pub fn bindPipeline(self: Device, pass: types.RenderPass, pipeline: types.Pipeline) void {
    self.vtable.bind_pipeline(self.ctx, pass, pipeline);
}

pub fn bindVertexBuffer(self: Device, pass: types.RenderPass, binding: types.BufferBinding) void {
    self.vtable.bind_vertex_buffer(self.ctx, pass, binding);
}

pub fn bindIndexBuffer(self: Device, pass: types.RenderPass, binding: types.BufferBinding, size: types.IndexSize) void {
    self.vtable.bind_index_buffer(self.ctx, pass, binding, size);
}

pub fn setScissor(self: Device, pass: types.RenderPass, rect: types.Rect) void {
    self.vtable.set_scissor(self.ctx, pass, rect);
}

pub fn bindFragmentSamplers(self: Device, pass: types.RenderPass, bindings: []const types.SamplerBinding) void {
    self.vtable.bind_fragment_samplers(self.ctx, pass, bindings);
}

pub fn pushFragmentUniforms(self: Device, pass: types.RenderPass, slot: u32, data: []const u8) void {
    self.vtable.push_fragment_uniforms(self.ctx, pass, slot, data);
}

pub fn drawIndexed(self: Device, pass: types.RenderPass, draw: types.DrawIndexed) void {
    self.vtable.draw_indexed(self.ctx, pass, draw);
}
